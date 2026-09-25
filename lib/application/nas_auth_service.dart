import '../data/nas/nas_api_client.dart';
import '../data/nas/nas_api_error.dart';
import '../domain/models/nas_models.dart';
import '../services/nas_credentials_service.dart';

enum NasAuthStatus {
  signedOut,
  restoring,
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

  NasAuthSnapshot get snapshot => _snapshot;
  bool get isAuthenticated => _snapshot.isAuthenticated;
  NasUser? get user => _snapshot.user;

  Future<NasAuthSnapshot> restore() async {
    _snapshot = const NasAuthSnapshot(
      status: NasAuthStatus.restoring,
    );
    try {
      final stored = await _credentials.read();
      if (stored == null) {
        _apiClient.setAccessToken(null);
        return _setSnapshot(const NasAuthSnapshot.signedOut());
      }

      _apiClient.setAccessToken(stored.accessToken);
      NasMeResponse me;
      try {
        me = await _apiClient.me();
      } on NasApiError catch (error) {
        if (!error.isUnauthorized) rethrow;
        final refreshed = await refresh();
        if (!refreshed.isAuthenticated) return refreshed;
        me = await _apiClient.me();
      }
      return _setSnapshot(
        NasAuthSnapshot(
          status: NasAuthStatus.authenticated,
          user: me.user,
          expiresAt: (await _credentials.read())?.expiresAt ?? stored.expiresAt,
        ),
      );
    } on NasApiError catch (error) {
      return _setSnapshot(
        NasAuthSnapshot(status: NasAuthStatus.error, error: error),
      );
    } on NasCredentialsException {
      rethrow;
    }
  }

  Future<NasAuthSnapshot> register(NasRegisterRequest request) async {
    final response = await _apiClient.register(request);
    return _accept(response);
  }

  Future<NasAuthSnapshot> login(NasLoginRequest request) async {
    final response = await _apiClient.login(request);
    return _accept(response);
  }

  Future<NasAuthSnapshot> refresh() async {
    final stored = await _credentials.read();
    if (stored == null) {
      _apiClient.setAccessToken(null);
      return _setSnapshot(const NasAuthSnapshot.signedOut());
    }
    try {
      final response = await _apiClient.refresh(
        NasRefreshRequest(stored.refreshToken),
      );
      return _accept(response);
    } on NasApiError catch (error) {
      if (error.isUnauthorized) {
        await _credentials.clear();
        _apiClient.setAccessToken(null);
        return _setSnapshot(const NasAuthSnapshot.signedOut());
      }
      rethrow;
    }
  }

  Future<void> logout() async {
    final stored = await _credentials.read();
    Object? failure;
    try {
      if (stored != null) {
        _apiClient.setAccessToken(stored.accessToken);
        await _apiClient.logout(NasRefreshRequest(stored.refreshToken));
      }
    } catch (error) {
      failure = error;
    } finally {
      _apiClient.setAccessToken(null);
      await _credentials.clear();
      _snapshot = const NasAuthSnapshot.signedOut();
    }
    if (failure != null) throw failure!;
  }

  Future<String?> _refreshAccessTokenForClient() async {
    final refreshed = await refresh();
    if (!refreshed.isAuthenticated) return null;
    final stored = await _credentials.read();
    return stored?.accessToken;
  }

  Future<NasAuthSnapshot> _accept(NasAuthResponse response) async {
    final now = _now().toUtc();
    await _credentials.save(response, now: now);
    _apiClient.setAccessToken(response.accessToken);
    return _setSnapshot(
      NasAuthSnapshot(
        status: NasAuthStatus.authenticated,
        user: response.user,
        expiresAt: now.add(Duration(seconds: response.expiresIn)),
      ),
    );
  }

  NasAuthSnapshot _setSnapshot(NasAuthSnapshot snapshot) {
    _snapshot = snapshot;
    return snapshot;
  }
}
