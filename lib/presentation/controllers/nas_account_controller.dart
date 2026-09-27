import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/nas_auth_service.dart';
import '../../application/nas_connection_service.dart';
import '../../application/nas_family_service.dart';
import '../../data/nas/nas_api_client.dart';
import '../../data/nas/nas_sync_api.dart';
import '../../data/nas/nas_api_error.dart';
import '../../data/nas/nas_family_device_api.dart';
import '../../domain/models/nas_family_device_models.dart';
import '../../domain/models/nas_models.dart';
import '../../application/settings_service.dart';
import '../../services/nas_credentials_service.dart';

const nasDeviceIdKey = 'nas_device_id';

enum NasAccountStatus {
  unconfigured,
  restoring,
  signedOut,
  signingIn,
  signingOut,
  authenticated,
  error,
}

enum NasFamilyStatus {
  idle,
  loading,
  available,
  missing,
  error,
}

enum NasDeviceStatus {
  idle,
  loading,
  ready,
  needsRegistration,
  error,
}

class NasFamilyState {
  const NasFamilyState({
    this.status = NasFamilyStatus.idle,
    this.current,
    this.members = const <NasFamilyMemberDto>[],
    this.errorMessage,
    this.membersErrorMessage,
  });

  final NasFamilyStatus status;
  final NasFamilyResponseDto? current;
  final List<NasFamilyMemberDto> members;
  final String? errorMessage;
  final String? membersErrorMessage;

  bool get hasFamily => current != null && status == NasFamilyStatus.available;
  String? get familyId => current?.family.id;

  NasFamilyState copyWith({
    NasFamilyStatus? status,
    NasFamilyResponseDto? current,
    bool clearCurrent = false,
    List<NasFamilyMemberDto>? members,
    String? errorMessage,
    bool clearError = false,
    String? membersErrorMessage,
    bool clearMembersError = false,
  }) {
    return NasFamilyState(
      status: status ?? this.status,
      current: clearCurrent ? null : current ?? this.current,
      members: members ?? this.members,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
      membersErrorMessage: clearMembersError
          ? null
          : membersErrorMessage ?? this.membersErrorMessage,
    );
  }
}

class NasDeviceState {
  const NasDeviceState({
    this.status = NasDeviceStatus.idle,
    this.devices = const <NasDeviceDto>[],
    this.currentDeviceId,
    this.errorMessage,
  });

  final NasDeviceStatus status;
  final List<NasDeviceDto> devices;
  final String? currentDeviceId;
  final String? errorMessage;

  NasDeviceDto? get currentDevice {
    final id = currentDeviceId;
    if (id == null) return null;
    for (final device in devices) {
      if (device.id == id) return device;
    }
    return null;
  }

  NasDeviceState copyWith({
    NasDeviceStatus? status,
    List<NasDeviceDto>? devices,
    String? currentDeviceId,
    bool clearCurrentDevice = false,
    String? errorMessage,
    bool clearError = false,
  }) {
    return NasDeviceState(
      status: status ?? this.status,
      devices: devices ?? this.devices,
      currentDeviceId: clearCurrentDevice
          ? null
          : currentDeviceId ?? this.currentDeviceId,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

class NasAccountState {
  const NasAccountState({
    required this.status,
    required this.auth,
    this.family = const NasFamilyState(),
    this.devices = const NasDeviceState(),
    this.errorMessage,
  });

  const NasAccountState.initial()
      : status = NasAccountStatus.unconfigured,
        auth = const NasAuthSnapshot.signedOut(),
        family = const NasFamilyState(),
        devices = const NasDeviceState(),
        errorMessage = null;

  final NasAccountStatus status;
  final NasAuthSnapshot auth;
  final NasFamilyState family;
  final NasDeviceState devices;
  final String? errorMessage;

  bool get isLoading => status == NasAccountStatus.restoring ||
      status == NasAccountStatus.signingIn ||
      status == NasAccountStatus.signingOut ||
      family.status == NasFamilyStatus.loading ||
      devices.status == NasDeviceStatus.loading;

  bool get isAuthenticated => auth.isAuthenticated;

  NasAccountState copyWith({
    NasAccountStatus? status,
    NasAuthSnapshot? auth,
    NasFamilyState? family,
    NasDeviceState? devices,
    String? errorMessage,
    bool clearError = false,
  }) {
    return NasAccountState(
      status: status ?? this.status,
      auth: auth ?? this.auth,
      family: family ?? this.family,
      devices: devices ?? this.devices,
      errorMessage: clearError ? null : errorMessage ?? this.errorMessage,
    );
  }
}

/// Coordinates the NAS session, current family and this device's membership.
///
/// This is deliberately a presentation-facing state layer around the existing
/// application/data services. It does not perform synchronization or expose
/// Home Assistant state. A missing family is represented as a normal state so
/// the UI can offer create/join actions without treating it as a network error.
class NasAccountController extends StateNotifier<NasAccountState> {
  NasAccountController({
    required SettingsService settings,
    required NasConnectionService connection,
    required NasCredentialsService credentials,
  })  : _settings = settings,
        _connection = connection,
        _credentials = credentials,
        super(const NasAccountState.initial());

  final SettingsService _settings;
  final NasConnectionService _connection;
  final NasCredentialsService _credentials;

  NasApiClient? _apiClient;
  NasAuthService? _authService;
  NasFamilyService? _familyService;
  String? _configuredServerUrl;
  Future<void>? _restoreInFlight;

  Future<void> restore() {
    final inFlight = _restoreInFlight;
    if (inFlight != null) return inFlight;
    final operation = _restoreInternal();
    _restoreInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_restoreInFlight, operation)) _restoreInFlight = null;
    });
  }

  Future<void> _restoreInternal() async {
    state = state.copyWith(
      status: NasAccountStatus.restoring,
      auth: const NasAuthSnapshot(status: NasAuthStatus.restoring),
      family: const NasFamilyState(),
      devices: const NasDeviceState(),
      clearError: true,
    );

    try {
      final connectionState = await _connection.loadState();
      final serverUrl = connectionState.serverUrl.trim();
      if (serverUrl.isEmpty) {
        _clearRuntime();
        if (mounted) {
          state = const NasAccountState.initial();
        }
        return;
      }

      await _configure(serverUrl);
      final auth = await _authService!.restore();
      if (!mounted) return;
      if (!auth.isAuthenticated) {
        state = state.copyWith(
          status: _accountStatusFor(auth),
          auth: auth,
          family: const NasFamilyState(),
          devices: const NasDeviceState(),
          errorMessage: auth.error?.message,
          clearError: auth.error == null,
        );
        return;
      }

      state = state.copyWith(
        status: NasAccountStatus.authenticated,
        auth: auth,
        clearError: true,
      );
      await refreshFamilyAndDevices();
    } catch (error) {
      await _handleFailure(error);
    }
  }

  Future<void> login(NasLoginRequest request) async {
    await _runAuthOperation(() => _authService!.login(request));
  }

  Future<void> register(NasRegisterRequest request) async {
    await _runAuthOperation(() => _authService!.register(request));
  }

  /// Creates a sync transport sharing this controller's authenticated NAS
  /// session. The returned client owns its HTTP connection and must be closed
  /// by the caller. It is null until the server, login and session are ready.
  NasSyncApi? createSyncApi() {
    final baseUrl = _configuredServerUrl;
    final authService = _authService;
    if (baseUrl == null || authService == null || !state.isAuthenticated) {
      return null;
    }
    final api = NasSyncApi(
      baseUrl,
      accessTokenProvider: () => _apiClient?.accessToken,
    );
    api.setRefreshHandler(() async {
      final refreshed = await authService.refresh();
      if (!refreshed.isAuthenticated) {
        if (mounted) {
          _setSignedOut(refreshed.error?.message);
        }
        return null;
      }
      if (mounted) {
        state = state.copyWith(
          status: NasAccountStatus.authenticated,
          auth: refreshed,
          clearError: true,
        );
      }
      return _apiClient?.accessToken;
    });
    return api;
  }

  Future<void> refreshSession() async {
    final authService = _authService;
    if (authService == null) {
      await restore();
      return;
    }
    try {
      final auth = await authService.refresh();
      if (!mounted) return;
      if (!auth.isAuthenticated) {
        _setSignedOut(auth.error?.message);
        return;
      }
      state = state.copyWith(
        status: NasAccountStatus.authenticated,
        auth: auth,
        clearError: true,
      );
      await refreshFamilyAndDevices();
    } catch (error) {
      await _handleFailure(error);
    }
  }

  Future<void> logout() async {
    final authService = _authService;
    state = state.copyWith(
      status: NasAccountStatus.signingOut,
      auth: const NasAuthSnapshot(status: NasAuthStatus.signingOut),
      clearError: true,
    );
    if (authService == null) {
      _setSignedOut();
      return;
    }

    try {
      await authService.logout();
      if (mounted) _setSignedOut();
    } catch (error) {
      // The auth service clears local credentials even when remote logout
      // fails. Keep the UI signed out while surfacing the safe error.
      if (mounted) _setSignedOut(_messageFor(error));
    }
  }

  Future<void> refreshFamilyAndDevices() async {
    final familyService = _familyService;
    if (!state.isAuthenticated || familyService == null) return;

    state = state.copyWith(
      family: state.family.copyWith(
        status: NasFamilyStatus.loading,
        clearError: true,
        clearMembersError: true,
      ),
      devices: const NasDeviceState(status: NasDeviceStatus.idle),
      clearError: true,
    );

    try {
      final family = await familyService.currentFamily();
      if (!mounted) return;
      state = state.copyWith(
        family: NasFamilyState(
          status: NasFamilyStatus.available,
          current: family,
        ),
        devices: const NasDeviceState(status: NasDeviceStatus.loading),
      );
      await _loadMembers(familyService);
      if (!mounted || !state.isAuthenticated) return;
      await _loadDevices(familyService);
    } on NasApiError catch (error) {
      if (!mounted) return;
      if (error.isUnauthorized) {
        await _expireSession(error.message);
        return;
      }
      if (error.kind == NasApiErrorKind.notFound) {
        state = state.copyWith(
          family: const NasFamilyState(status: NasFamilyStatus.missing),
          devices: const NasDeviceState(),
          clearError: true,
        );
        return;
      }
      state = state.copyWith(
        family: NasFamilyState(
          status: NasFamilyStatus.error,
          errorMessage: error.message,
        ),
        devices: const NasDeviceState(),
        errorMessage: error.message,
      );
    } catch (error) {
      await _handleFailure(error);
    }
  }

  Future<void> _loadMembers(NasFamilyService familyService) async {
    try {
      final members = await familyService.listMembers();
      if (!mounted || !state.isAuthenticated) return;
      state = state.copyWith(
        family: state.family.copyWith(
          members: members,
          clearMembersError: true,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        family: state.family.copyWith(membersErrorMessage: _messageFor(error)),
      );
      if (error is NasApiError && error.isUnauthorized) {
        await _expireSession(error.message);
      }
    }
  }

  Future<void> _loadDevices(NasFamilyService familyService) async {
    if (!mounted) return;
    state = state.copyWith(
      devices: state.devices.copyWith(
        status: NasDeviceStatus.loading,
        clearError: true,
      ),
    );
    try {
      final devices = await familyService.listDevices();
      final currentDeviceId = await _readDeviceId();
      if (!mounted || !state.isAuthenticated) return;
      final matched = _currentDeviceId(devices, currentDeviceId);
      state = state.copyWith(
        devices: NasDeviceState(
          status: matched == null
              ? NasDeviceStatus.needsRegistration
              : NasDeviceStatus.ready,
          devices: List<NasDeviceDto>.unmodifiable(devices),
          currentDeviceId: matched,
        ),
      );
    } catch (error) {
      if (!mounted) return;
      state = state.copyWith(
        devices: NasDeviceState(
          status: NasDeviceStatus.error,
          devices: state.devices.devices,
          currentDeviceId: state.devices.currentDeviceId,
          errorMessage: _messageFor(error),
        ),
      );
      if (error is NasApiError && error.isUnauthorized) {
        await _expireSession(error.message);
      }
    }
  }

  Future<void> createFamily(String name) async {
    final familyService = _familyService;
    if (familyService == null) {
      _setFamilyError('请先配置并登录 NAS。');
      return;
    }
    final normalized = name.trim();
    if (normalized.isEmpty) {
      _setFamilyError('家庭名称不能为空。');
      return;
    }
    await _changeFamily(() => familyService.createFamily(normalized));
  }

  Future<void> joinFamily(String code) async {
    final familyService = _familyService;
    if (familyService == null) {
      _setFamilyError('请先配置并登录 NAS。');
      return;
    }
    final normalized = code.trim();
    if (normalized.isEmpty) {
      _setFamilyError('邀请码不能为空。');
      return;
    }
    await _changeFamily(() => familyService.joinFamily(normalized));
  }

  Future<NasFamilyInviteDto?> createInvite({
    int expiresInHours = 72,
    int maxUses = 1,
  }) async {
    final familyService = _familyService;
    if (familyService == null) {
      _setFamilyError('请先配置并登录 NAS。');
      return null;
    }
    if (!state.family.hasFamily) {
      _setFamilyError('请先加入或创建家庭。');
      return null;
    }
    try {
      return await familyService.createInvite(
        expiresInHours: expiresInHours,
        maxUses: maxUses,
      );
    } catch (error) {
      await _handleFailure(error);
      return null;
    }
  }

  Future<void> registerCurrentDevice({
    required String deviceName,
    String? platform,
    String? appVersion,
  }) async {
    final familyService = _familyService;
    if (familyService == null) {
      _setDeviceError('请先配置并登录 NAS。');
      return;
    }
    if (!state.family.hasFamily) {
      _setDeviceError('请先加入或创建家庭。');
      return;
    }
    final normalizedName = deviceName.trim();
    if (normalizedName.isEmpty) {
      _setDeviceError('设备名称不能为空。');
      return;
    }

    state = state.copyWith(
      devices: state.devices.copyWith(
        status: NasDeviceStatus.loading,
        clearError: true,
      ),
      clearError: true,
    );
    try {
      final deviceId = await _ensureDeviceId();
      final device = await familyService.registerDevice(
        deviceId: deviceId,
        deviceName: normalizedName,
        platform: platform ?? _platformName(),
        appVersion: appVersion,
      );
      if (!mounted) return;
      final devices = <NasDeviceDto>[
        ...state.devices.devices.where((item) => item.id != device.id),
        device,
      ];
      state = state.copyWith(
        devices: NasDeviceState(
          status: NasDeviceStatus.ready,
          devices: List<NasDeviceDto>.unmodifiable(devices),
          currentDeviceId: device.id,
        ),
        clearError: true,
      );
    } catch (error) {
      await _handleDeviceFailure(error);
    }
  }

  Future<void> revokeDevice(String deviceId) async {
    final familyService = _familyService;
    if (familyService == null) {
      _setDeviceError('请先配置并登录 NAS。');
      return;
    }
    final normalized = deviceId.trim();
    if (normalized.isEmpty) {
      _setDeviceError('设备标识不能为空。');
      return;
    }
    state = state.copyWith(
      devices: state.devices.copyWith(
        status: NasDeviceStatus.loading,
        clearError: true,
      ),
      clearError: true,
    );
    try {
      await familyService.revokeDevice(normalized);
      if (!mounted) return;
      final remaining = state.devices.devices
          .where((device) => device.id != normalized)
          .toList(growable: false);
      final currentId = state.devices.currentDeviceId == normalized
          ? null
          : state.devices.currentDeviceId;
      state = state.copyWith(
        devices: NasDeviceState(
          status: currentId == null
              ? NasDeviceStatus.needsRegistration
              : NasDeviceStatus.ready,
          devices: List<NasDeviceDto>.unmodifiable(remaining),
          currentDeviceId: currentId,
        ),
        clearError: true,
      );
    } catch (error) {
      await _handleDeviceFailure(error);
    }
  }

  Future<void> _runAuthOperation(
    Future<NasAuthSnapshot> Function() operation,
  ) async {
    try {
      await _ensureConfigured();
      state = state.copyWith(
        status: NasAccountStatus.signingIn,
        auth: const NasAuthSnapshot(status: NasAuthStatus.signingIn),
        clearError: true,
      );
      final auth = await operation();
      if (!mounted) return;
      if (!auth.isAuthenticated) {
        state = state.copyWith(
          status: _accountStatusFor(auth),
          auth: auth,
          family: const NasFamilyState(),
          devices: const NasDeviceState(),
          errorMessage: auth.error?.message,
          clearError: auth.error == null,
        );
        return;
      }
      state = state.copyWith(
        status: NasAccountStatus.authenticated,
        auth: auth,
        family: const NasFamilyState(),
        devices: const NasDeviceState(),
        clearError: true,
      );
      await refreshFamilyAndDevices();
    } catch (error) {
      await _handleFailure(error);
    }
  }

  Future<void> _changeFamily(
    Future<NasFamilyResponseDto> Function() operation,
  ) async {
    if (!state.isAuthenticated) {
      _setFamilyError('请先登录 NAS 账号。');
      return;
    }
    final familyService = _familyService;
    if (familyService == null) {
      _setFamilyError('请先配置并登录 NAS。');
      return;
    }
    state = state.copyWith(
      family: state.family.copyWith(
        status: NasFamilyStatus.loading,
        clearError: true,
        clearMembersError: true,
      ),
      devices: const NasDeviceState(),
      clearError: true,
    );
    try {
      final family = await operation();
      if (!mounted) return;
      state = state.copyWith(
        family: NasFamilyState(
          status: NasFamilyStatus.available,
          current: family,
        ),
        devices: const NasDeviceState(status: NasDeviceStatus.loading),
        clearError: true,
      );
      await _loadMembers(familyService);
      if (!mounted || !state.isAuthenticated) return;
      await _loadDevices(familyService);
    } catch (error) {
      if (error is NasApiError && error.isUnauthorized) {
        await _expireSession(error.message);
      } else {
        _setFamilyError(_messageFor(error));
      }
    }
  }

  Future<void> _ensureConfigured() async {
    if (_authService != null && _familyService != null) return;
    final connectionState = await _connection.loadState();
    final serverUrl = connectionState.serverUrl.trim();
    if (serverUrl.isEmpty) {
      throw const _NasAccountException('请先在 NAS 设置中保存服务器地址。');
    }
    await _configure(serverUrl);
  }

  Future<void> _configure(String serverUrl) async {
    final normalized = NasConnectionService.normalizeServerUrl(serverUrl);
    if (normalized == null) {
      throw const _NasAccountException('NAS 地址无效，请先检查连接配置。');
    }
    if (_configuredServerUrl == normalized && _authService != null) return;

    _apiClient?.close();
    final apiClient = NasApiClient(normalized);
    _apiClient = apiClient;
    _authService = NasAuthService(
      apiClient: apiClient,
      credentials: _credentials,
    );
    _familyService = NasFamilyService(NasFamilyDeviceApi(apiClient: apiClient));
    _configuredServerUrl = normalized;
  }

  Future<String?> _readDeviceId() async {
    final value = await _settings.getValue(nasDeviceIdKey);
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }

  Future<String> _ensureDeviceId() async {
    final existing = await _readDeviceId();
    if (existing != null) return existing;
    final generated = const Uuid().v4();
    await _settings.setValue(nasDeviceIdKey, generated);
    return generated;
  }

  String? _currentDeviceId(List<NasDeviceDto> devices, String? persistedId) {
    for (final device in devices) {
      if (device.isCurrent == true) return device.id;
    }
    if (persistedId != null) {
      for (final device in devices) {
        if (device.id == persistedId && device.revokedAt == null) return device.id;
      }
    }
    return null;
  }

  void _setFamilyError(String message) {
    if (!mounted) return;
    state = state.copyWith(
      family: state.family.copyWith(
        status: NasFamilyStatus.error,
        errorMessage: message,
      ),
      errorMessage: message,
    );
  }

  void _setDeviceError(String message) {
    if (!mounted) return;
    state = state.copyWith(
      devices: state.devices.copyWith(
        status: NasDeviceStatus.error,
        errorMessage: message,
      ),
      errorMessage: message,
    );
  }

  Future<void> _handleDeviceFailure(Object error) async {
    if (!mounted) return;
    final message = _messageFor(error);
    state = state.copyWith(
      devices: state.devices.copyWith(
        status: NasDeviceStatus.error,
        errorMessage: message,
      ),
      errorMessage: message,
    );
    if (error is NasApiError && error.isUnauthorized) {
      await _expireSession(error.message);
    }
  }

  Future<void> _handleFailure(Object error) async {
    if (!mounted) return;
    if (error is NasApiError && error.isUnauthorized) {
      await _expireSession(error.message);
      return;
    }
    final message = _messageFor(error);
    state = state.copyWith(
      status: NasAccountStatus.error,
      auth: NasAuthSnapshot(
        status: NasAuthStatus.error,
        user: state.auth.user,
        expiresAt: state.auth.expiresAt,
        error: error is NasApiError ? error : null,
      ),
      errorMessage: message,
    );
  }

  Future<void> _expireSession(String message) async {
    final authService = _authService;
    if (authService != null) {
      try {
        await authService.invalidateSession();
      } catch (_) {
        // The visible state still becomes signed out; the credential service
        // will report a storage failure on the next explicit restore.
      }
    }
    if (mounted) _setSignedOut(message);
  }

  void _setSignedOut([String? message]) {
    state = NasAccountState(
      status: NasAccountStatus.signedOut,
      auth: const NasAuthSnapshot.signedOut(),
      errorMessage: message,
    );
  }

  void _clearRuntime() {
    _apiClient?.close();
    _apiClient = null;
    _authService = null;
    _familyService = null;
    _configuredServerUrl = null;
  }

  @override
  void dispose() {
    _clearRuntime();
    super.dispose();
  }

  NasAccountStatus _accountStatusFor(NasAuthSnapshot auth) {
    return switch (auth.status) {
      NasAuthStatus.signedOut => NasAccountStatus.signedOut,
      NasAuthStatus.restoring => NasAccountStatus.restoring,
      NasAuthStatus.signingIn => NasAccountStatus.signingIn,
      NasAuthStatus.signingOut => NasAccountStatus.signingOut,
      NasAuthStatus.authenticated => NasAccountStatus.authenticated,
      NasAuthStatus.error => NasAccountStatus.error,
    };
  }

  String _platformName() {
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'android',
      TargetPlatform.iOS => 'ios',
      TargetPlatform.macOS => 'macos',
      TargetPlatform.windows => 'windows',
      TargetPlatform.linux => 'linux',
      TargetPlatform.fuchsia => 'fuchsia',
    };
  }

  String _messageFor(Object error) {
    if (error is NasApiError) return error.message;
    if (error is NasCredentialsException) return error.message;
    if (error is _NasAccountException) return error.message;
    return 'NAS 操作失败，请稍后重试。';
  }
}

class _NasAccountException implements Exception {
  const _NasAccountException(this.message);

  final String message;
}
