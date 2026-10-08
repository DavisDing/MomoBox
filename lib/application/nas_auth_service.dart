import '../data/nas/nas_api_client.dart';
import '../data/nas/nas_api_error.dart';
import '../domain/models/nas_models.dart';
import '../services/nas_credentials_service.dart';

enum NasAuthStatus {
  signedOut,
  restoring,
  signingIn,
  signingOut,
  authenticated,
  error,
}

class NasAuthSnapshot {
  const NasAuthSnapshot({
    required this.status,
    this.user,
    this.expiresAt,
    this.error,
  });

  const NasAuthSnapshot.signedOut()
      : status = NasAuthStatus.signedOut,
        user = null,
        expiresAt = null,
        error = null;

  final NasAuthStatus status;
  final NasUser? user;
  final DateTime? expiresAt;
  final NasApiError? error;

  bool get isAuthenticated => status == NasAuthStatus.authenticated;
}

/// Application-level NAS authentication flow.
///
/// This service deliberately stops at authentication/session management. It
/// does not implement family UI, device registration UI, or synchronization.
class NasAuthService {
  NasAuthService({
    required NasApiClient apiClient,
    required NasCredentialsService credentials,
    DateTime Function()? now,
  })  : _apiClient = apiClient,
        _credentials = credentials,
        _now = now ?? (() => DateTime.now().toUtc()) {
    _apiClient.setRefreshHandler(_refreshAccessTokenForClient);
  }

  final NasApiClient _apiClient;
  final NasCredentialsService _credentials;
  final DateTime Function() _now;

  NasAuthSnapshot _snapshot = const NasAuthSnapshot.signedOut();
  int _sessionGeneration = 0;
  bool _abandoned = false;
  bool _signingOut = false;
  Future<NasAuthSnapshot>? _refreshInFlight;

  NasAuthSnapshot get snapshot => _snapshot;
  bool get isAuthenticated => _snapshot.isAuthenticated;
  NasUser? get user => _snapshot.user;

  bool _isCurrent(int generation) =>
      !_abandoned && generation == _sessionGeneration;

  /// Invalidates pending responses without deleting persisted credentials.
  /// Used before loading a possibly changed connection configuration.
  void cancelPending() {
    _sessionGeneration++;
    _refreshInFlight = null;
    _apiClient.setAccessToken(null);
    _snapshot = const NasAuthSnapshot.signedOut();
  }

  /// Detaches an old server/client without deleting the persisted session.
  /// Any already-running network/storage work can no longer accept a result.
  void abandon() {
    _abandoned = true;
    cancelPending();
    _apiClient.setRefreshHandler(null);
  }

  Future<NasAuthSnapshot> restore() async {
    if (_abandoned) return _snapshot;
    final generation = ++_sessionGeneration;
    _signingOut = false;
    _refreshInFlight = null;
    _apiClient.setAccessToken(null);
    _snapshot = const NasAuthSnapshot(status: NasAuthStatus.restoring);
    try {
      final stored = await _credentials.readForServer(_apiClient.serverIdentity);
      if (!_isCurrent(generation)) return _snapshot;
      if (stored == null) {
        return _setSnapshot(const NasAuthSnapshot.signedOut());
      }

      _apiClient.setAccessToken(stored.accessToken);
      NasMeResponse me;
      try {
        me = await _apiClient.me();
      } on NasApiError catch (error) {
        if (!_isCurrent(generation)) return _snapshot;
        if (!error.isUnauthorized) rethrow;
        final refreshed = await refresh();
        if (!_isCurrent(generation) || !refreshed.isAuthenticated) return _snapshot;
        me = await _apiClient.me();
      }
      if (!_isCurrent(generation)) return _snapshot;
      final latest = await _credentials.readForServer(_apiClient.serverIdentity);
      if (!_isCurrent(generation)) return _snapshot;
      return _setSnapshot(NasAuthSnapshot(
        status: NasAuthStatus.authenticated,
        user: me.user,
        expiresAt: latest?.expiresAt ?? stored.expiresAt,
      ));
    } on NasApiError catch (error) {
      if (!_isCurrent(generation)) return _snapshot;
      return _setSnapshot(NasAuthSnapshot(status: NasAuthStatus.error, error: error));
    } catch (error) {
      if (!_isCurrent(generation)) return _snapshot;
      if (error is NasCredentialsException) cancelPending();
      rethrow;
    }
  }

  Future<NasAuthSnapshot> register(NasRegisterRequest request) async {
    if (_abandoned) return _snapshot;
    final generation = _beginSignIn();
    try {
      final response = await _apiClient.register(request);
      return await _accept(response, generation);
    } catch (error) {
      if (!_isCurrent(generation)) return _snapshot;
      if (error is NasCredentialsException) cancelPending();
      rethrow;
    }
  }

  Future<NasAuthSnapshot> login(NasLoginRequest request) async {
    if (_abandoned) return _snapshot;
    final generation = _beginSignIn();
    try {
      final response = await _apiClient.login(request);
      return await _accept(response, generation);
    } catch (error) {
      if (!_isCurrent(generation)) return _snapshot;
      if (error is NasCredentialsException) cancelPending();
      rethrow;
    }
  }

  int _beginSignIn() {
    _signingOut = false;
    _refreshInFlight = null;
    _apiClient.setAccessToken(null);
    _snapshot = const NasAuthSnapshot(status: NasAuthStatus.signingIn);
    return ++_sessionGeneration;
  }

  Future<NasAuthSnapshot> refresh() {
    if (_abandoned || _signingOut || _snapshot.status == NasAuthStatus.signingIn) {
      return Future.value(_snapshot);
    }
    final existing = _refreshInFlight;
    if (existing != null) return existing;
    final operation = _refresh(_sessionGeneration);
    _refreshInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_refreshInFlight, operation)) _refreshInFlight = null;
    });
  }

  Future<NasAuthSnapshot> _refresh(int generation) async {
    try {
      final stored = await _credentials.readForServer(_apiClient.serverIdentity);
      if (!_isCurrent(generation)) return _snapshot;
      if (stored == null) {
        _apiClient.setAccessToken(null);
        return _setSnapshot(const NasAuthSnapshot.signedOut());
      }
      final response = await _apiClient.refresh(NasRefreshRequest(stored.refreshToken));
      return await _accept(response, generation);
    } on NasApiError catch (error) {
      if (!_isCurrent(generation)) return _snapshot;
      if (error.isUnauthorized) return invalidateSession();
      rethrow;
    } catch (error) {
      if (!_isCurrent(generation)) return _snapshot;
      if (error is NasCredentialsException) cancelPending();
      rethrow;
    }
  }

  /// Clears the local session after a definitive authentication failure.
  Future<NasAuthSnapshot> invalidateSession() async {
    final generation = ++_sessionGeneration;
    _refreshInFlight = null;
    _apiClient.setAccessToken(null);
    _snapshot = const NasAuthSnapshot.signedOut();
    await _credentials.clearIfCurrent(isCurrent: () => _isCurrent(generation));
    return _snapshot;
  }

  Future<void> logout() async {
    if (_abandoned) return;
    // Invalidate before the first await, not after the remote logout completes.
    _signingOut = true;
    final generation = ++_sessionGeneration;
    _refreshInFlight = null;
    _apiClient.setAccessToken(null);
    _snapshot = const NasAuthSnapshot.signedOut();
    Object? failure;
    try {
      final stored = await _credentials.readForServer(_apiClient.serverIdentity);
      if (!_isCurrent(generation)) return;
      await _credentials.clearIfCurrent(isCurrent: () => _isCurrent(generation));
      if (!_isCurrent(generation)) return;
      if (stored != null) {
        // Revoke using the captured credentials without reinstating a usable
        // in-memory session while logout is awaiting its network response.
        await _apiClient.logout(
          NasRefreshRequest(stored.refreshToken),
          accessToken: stored.accessToken,
        );
      }
    } catch (error) {
      failure = error;
    } finally {
      if (_isCurrent(generation)) {
        _apiClient.setAccessToken(null);
        _snapshot = const NasAuthSnapshot.signedOut();
        try {
          await _credentials.clearIfCurrent(isCurrent: () => _isCurrent(generation));
        } catch (error) {
          failure = error;
        }
        if (_isCurrent(generation)) _signingOut = false;
      }
    }
    if (failure != null && _isCurrent(generation)) throw failure;
  }

  Future<String?> _refreshAccessTokenForClient() async {
    final generation = _sessionGeneration;
    final refreshed = await refresh();
    if (!_isCurrent(generation) || !refreshed.isAuthenticated) return null;
    return _apiClient.accessToken;
  }

  Future<NasAuthSnapshot> _accept(NasAuthResponse response, int generation) async {
    if (!_isCurrent(generation)) return _snapshot;
    final now = _now().toUtc();
    final accepted = await _credentials.saveIfCurrent(
      response,
      now: now,
      serverIdentity: _apiClient.serverIdentity,
      isCurrent: () => _isCurrent(generation),
    );
    if (!accepted || !_isCurrent(generation)) return _snapshot;
    _apiClient.setAccessToken(response.accessToken);
    return _setSnapshot(NasAuthSnapshot(
      status: NasAuthStatus.authenticated,
      user: response.user,
      expiresAt: now.add(Duration(seconds: response.expiresIn)),
    ));
  }

  NasAuthSnapshot _setSnapshot(NasAuthSnapshot snapshot) {
    _snapshot = snapshot;
    return snapshot;
  }
}
