import '../../data/nas/nas_api_client.dart';
import '../../data/nas/nas_api_error.dart';
import '../../domain/models/nas_homeassistant_models.dart';
import '../../domain/models/nas_models.dart';
import '../../services/nas_credentials_service.dart';
import '../nas/nas_homeassistant_api.dart';

/// Remote Home Assistant repository boundary.
///
/// The direct constructor is kept for callers/tests that already own an API
/// client. [fromBaseUrl] is used by the presentation layer when the NAS URL
/// is known but the access token must be restored from secure storage first.
class NasSmartHomeRepository {
  NasSmartHomeRepository(this._api)
      : _client = null,
        _credentials = null;

  factory NasSmartHomeRepository.fromBaseUrl(
    String? baseUrl, {
    NasCredentialsService? credentials,
  }) {
    final client = _createClient(baseUrl);
    return NasSmartHomeRepository._configured(
      client,
      credentials ?? NasCredentialsService(),
    );
  }

  NasSmartHomeRepository._configured(
    NasApiClient? client,
    NasCredentialsService credentials,
  )  : _client = client,
        _credentials = credentials,
        _api = client == null ? null : NasHomeAssistantApi(client);

  final NasHomeAssistantApi? _api;
  final NasApiClient? _client;
  final NasCredentialsService? _credentials;

  bool get isConfigured => _api != null;

  /// Restores the NAS session for a repository created with [fromBaseUrl].
  ///
  /// Returns false when the NAS URL or secure credentials are unavailable.
  /// It never treats a configured URL alone as an authenticated session.
  Future<bool> restoreCredentials() async {
    final client = _client;
    final credentials = _credentials;
    if (client == null || credentials == null) return false;

    final stored = await credentials.read();
    if (stored == null) {
      client.setAccessToken(null);
      return false;
    }

    client.setAccessToken(stored.accessToken);
    client.setRefreshHandler(_refreshAccessToken);
    return true;
  }

  Future<String?> _refreshAccessToken() async {
    final client = _client;
    final credentials = _credentials;
    if (client == null || credentials == null) return null;

    final stored = await credentials.read();
    if (stored == null) return null;

    try {
      final response = await client.refresh(
        NasRefreshRequest(stored.refreshToken),
      );
      await credentials.save(response);
      client.setAccessToken(response.accessToken);
      return response.accessToken;
    } on NasApiError catch (error) {
      if (error.isUnauthorized) {
        await credentials.clear();
        client.setAccessToken(null);
        return null;
      }
      rethrow;
    }
  }

  Future<List<NasHaIntegration>> listIntegrations() => _requiredApi.listIntegrations();

  Future<NasHaIntegration> addIntegration(NasHaIntegrationInput input) =>
      _requiredApi.addIntegration(input);

  Future<NasHaIntegration> updateIntegration(
    String integrationId,
    NasHaIntegrationUpdate update,
  ) =>
      _requiredApi.updateIntegration(integrationId, update);

  Future<void> deleteIntegration(String integrationId) =>
      _requiredApi.deleteIntegration(integrationId);

  Future<NasHaConnectionTestResult> testIntegration(String integrationId) =>
      _requiredApi.testIntegration(integrationId);

  Future<NasHaDiscoverResult> discover(String integrationId) =>
      _requiredApi.discover(integrationId);

  Future<List<NasHaEntity>> listEntities({
    String? integrationId,
    bool controllableOnly = false,
  }) =>
      _requiredApi.listEntities(
        integrationId: integrationId,
        controllableOnly: controllableOnly,
      );

  Future<NasHaEntityState> fetchEntityState({
    required String integrationId,
    required String entityId,
  }) =>
      _requiredApi.fetchEntityState(integrationId: integrationId, entityId: entityId);

  Future<NasHaCommandResult> sendCommand({
    required String integrationId,
    required String entityId,
    required NasHaCommand command,
    required String requestId,
    NasHaCommandParameters? parameters,
  }) =>
      _requiredApi.sendCommand(
        integrationId: integrationId,
        entityId: entityId,
        command: command,
        requestId: requestId,
        parameters: parameters,
      );

  Future<List<NasHaConsumableGroup>> listConsumableGroups() =>
      _requiredApi.listConsumableGroups();

  Future<NasHaConsumableGroup> saveConsumableGroup(
    NasHaConsumableGroup group,
  ) =>
      _requiredApi.saveConsumableGroup(group);

  Future<List<NasHaConsumableRecipe>> listConsumableRecipes() =>
      _requiredApi.listConsumableRecipes();

  Future<NasHaConsumableRecipe> saveConsumableRecipe(
    NasHaConsumableRecipe recipe,
  ) =>
      _requiredApi.saveConsumableRecipe(recipe);

  Future<List<NasHaLinkageRule>> listLinkageRules() =>
      _requiredApi.listLinkageRules();

  Future<NasHaLinkageRule> saveLinkageRule(NasHaLinkageRule rule) =>
      _requiredApi.saveLinkageRule(rule);

  Future<List<NasHaLinkageSuggestion>> listLinkageSuggestions({
    NasHaLinkageSuggestionStatus? status,
  }) =>
      _requiredApi.listLinkageSuggestions(status: status);

  Future<NasHaLinkageSuggestion> resolveLinkageSuggestion({
    required String suggestionId,
    required NasHaSuggestionDecision decision,
  }) =>
      _requiredApi.resolveLinkageSuggestion(
        suggestionId: suggestionId,
        decision: decision,
      );

  Future<List<NasHaEntityPermission>> listPermissions() => _requiredApi.listPermissions();

  Future<NasHaEntityPermission> updatePermission(
    NasHaEntityPermission permission,
  ) =>
      _requiredApi.updatePermission(permission);

  void close() => _client?.close();

  NasHomeAssistantApi get _requiredApi =>
      _api ?? (throw StateError('NAS Home Assistant repository is not configured.'));

  static NasApiClient? _createClient(String? baseUrl) {
    final normalized = baseUrl?.trim();
    if (normalized == null || normalized.isEmpty) return null;
    return NasApiClient(normalized);
  }
}
