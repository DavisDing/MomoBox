import '../../application/nas_auth_service.dart';
import '../../data/nas/nas_api_client.dart';
import '../../data/nas/nas_api_error.dart';
import '../../domain/models/nas_homeassistant_models.dart';
import '../../services/nas_credentials_service.dart';
import '../nas/nas_homeassistant_api.dart';

/// Remote Home Assistant repository boundary.
///
/// The direct constructor is kept for callers/tests that already own an API
/// client. The presentation layer shares the account's authenticated session;
/// [fromBaseUrl] remains available for callers owning an independent session.
class NasSmartHomeRepository {
  NasSmartHomeRepository(this._api)
      : _client = null,
        _auth = null,
        _isSessionCurrent = null;

  factory NasSmartHomeRepository.withSession(
    NasApiClient? client, {
    required bool Function() isSessionCurrent,
  }) {
    late final NasSmartHomeRepository repository;
    bool current() => !repository._closed && isSessionCurrent();
    repository = NasSmartHomeRepository._shared(
      client == null ? null : NasHomeAssistantApi(client, isSessionCurrent: current),
      current,
    );
    return repository;
  }

  NasSmartHomeRepository._shared(this._api, this._isSessionCurrent)
      : _client = null,
        _auth = null;

  factory NasSmartHomeRepository.fromBaseUrl(
    String? baseUrl, {
    NasCredentialsService? credentials,
    NasApiClient Function(String)? apiClientFactory,
  }) {
    final client = _createClient(baseUrl, apiClientFactory);
    late final NasSmartHomeRepository repository;
    repository = NasSmartHomeRepository._configured(
      client,
      credentials ?? NasCredentialsService(),
      client == null ? null : NasHomeAssistantApi(client,
        isSessionCurrent: () => !repository._closed,
      ),
    );
    return repository;
  }

  NasSmartHomeRepository._configured(
    NasApiClient? client,
    NasCredentialsService credentials,
    this._api,
  )  : _client = client,
        _auth = client == null ? null : NasAuthService(
          apiClient: client, credentials: credentials,
        ),
        _isSessionCurrent = null;

  final NasHomeAssistantApi? _api;
  final NasApiClient? _client;
  final NasAuthService? _auth;
  final bool Function()? _isSessionCurrent;
  bool _closed = false;

  bool get isConfigured => !_closed && _api != null;

  /// Restores the NAS session for a repository created with [fromBaseUrl].
  ///
  /// Returns false when the NAS URL or secure credentials are unavailable.
  /// It never treats a configured URL alone as an authenticated session.
  Future<bool> restoreCredentials() async {
    if (_closed) return false;
    final isSessionCurrent = _isSessionCurrent;
    if (isSessionCurrent != null) return isSessionCurrent();
    final auth = _auth;
    if (auth == null) return false;
    final snapshot = await auth.restore();
    return !_closed && snapshot.isAuthenticated;
  }

  Future<List<NasHaIntegration>> listIntegrations() =>
      _withApi((api) => api.listIntegrations());

  Future<NasHaIntegration> addIntegration(NasHaIntegrationInput input) =>
      _withApi((api) => api.addIntegration(input));

  Future<NasHaIntegration> updateIntegration(
    String integrationId,
    NasHaIntegrationUpdate update,
  ) =>
      _withApi((api) => api.updateIntegration(integrationId, update));

  Future<void> deleteIntegration(String integrationId) =>
      _withApi((api) => api.deleteIntegration(integrationId));

  Future<NasHaConnectionTestResult> testIntegration(String integrationId) =>
      _withApi((api) => api.testIntegration(integrationId));

  Future<NasHaDiscoverResult> discover(String integrationId) =>
      _withApi((api) => api.discover(integrationId));

  Future<List<NasHaEntity>> listEntities({
    String? integrationId,
    bool controllableOnly = false,
  }) =>
      _withApi((api) => api.listEntities(
        integrationId: integrationId,
        controllableOnly: controllableOnly,
      ));

  Future<NasHaEntityState> fetchEntityState({
    required String integrationId,
    required String entityId,
  }) =>
      _withApi((api) => api.fetchEntityState(integrationId: integrationId, entityId: entityId));

  Future<NasHaCommandResult> sendCommand({
    required String integrationId,
    required String entityId,
    required NasHaCommand command,
    required String requestId,
    NasHaCommandParameters? parameters,
  }) =>
      _withApi((api) => api.sendCommand(
        integrationId: integrationId,
        entityId: entityId,
        command: command,
        requestId: requestId,
        parameters: parameters,
      ));

  Future<List<NasHaConsumableGroup>> listConsumableGroups() =>
      _withApi((api) => api.listConsumableGroups());

  Future<NasHaConsumableGroup> saveConsumableGroup(
    NasHaConsumableGroup group,
  ) =>
      _withApi((api) => api.saveConsumableGroup(group));

  Future<List<NasHaConsumableRecipe>> listConsumableRecipes() =>
      _withApi((api) => api.listConsumableRecipes());

  Future<NasHaConsumableRecipe> saveConsumableRecipe(
    NasHaConsumableRecipe recipe,
  ) =>
      _withApi((api) => api.saveConsumableRecipe(recipe));

  Future<List<NasHaLinkageRule>> listLinkageRules() =>
      _withApi((api) => api.listLinkageRules());

  Future<NasHaLinkageRule> saveLinkageRule(NasHaLinkageRule rule) =>
      _withApi((api) => api.saveLinkageRule(rule));

  Future<List<NasHaLinkageSuggestion>> listLinkageSuggestions({
    NasHaLinkageSuggestionStatus? status,
  }) =>
      _withApi((api) => api.listLinkageSuggestions(status: status));

  Future<NasHaLinkageSuggestion> resolveLinkageSuggestion({
    required String suggestionId,
    required NasHaSuggestionDecision decision,
  }) =>
      _withApi((api) => api.resolveLinkageSuggestion(
        suggestionId: suggestionId,
        decision: decision,
      ));

  Future<List<NasHaEntityPermission>> listPermissions() =>
      _withApi((api) => api.listPermissions());

  Future<NasHaEntityPermission> updatePermission(
    NasHaEntityPermission permission,
  ) =>
      _withApi((api) => api.updatePermission(permission));

  void close() {
    if (_closed) return;
    _closed = true;
    _auth?.abandon();
    _client?.close();
  }

  Future<T> _withApi<T>(Future<T> Function(NasHomeAssistantApi) operation) async {
    _assertCurrentSession();
    final api = _api;
    if (api == null) {
      throw StateError('NAS Home Assistant repository is not configured.');
    }
    final result = await operation(api);
    _assertCurrentSession();
    return result;
  }

  void _assertCurrentSession() {
    if (_closed || !(_isSessionCurrent?.call() ?? true)) {
      throw NasApiError(
        kind: NasApiErrorKind.unauthorized,
        message: 'NAS 登录会话已改变，请重新登录。',
        statusCode: 401,
      );
    }
  }

  static NasApiClient? _createClient(
    String? baseUrl,
    NasApiClient Function(String)? apiClientFactory,
  ) {
    final normalized = baseUrl?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return (apiClientFactory ?? NasApiClient.new)(normalized);
  }
}
