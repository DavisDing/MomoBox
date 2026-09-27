import '../../domain/models/nas_homeassistant_models.dart';
import 'nas_api_client.dart';

class NasHomeAssistantApi {
  NasHomeAssistantApi(this._client);

  final NasApiClient _client;

  Future<List<NasHaIntegration>> listIntegrations() async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/integrations',
    );
    return _parseList(json['integrations'], NasHaIntegration.fromJson);
  }

  Future<NasHaIntegration> addIntegration(NasHaIntegrationInput input) async {
    final json = await _client.requestJson(
      method: 'POST',
      path: '/home-assistant/integrations',
      body: input.toJson(),
    );
    return NasHaIntegration.fromJson(json);
  }

  Future<NasHaIntegration> updateIntegration(
    String integrationId,
    NasHaIntegrationUpdate update,
  ) async {
    final json = await _client.requestJson(
      method: 'PATCH',
      path: '/home-assistant/integrations/${_pathSegment(integrationId)}',
      body: update.toJson(),
    );
    return NasHaIntegration.fromJson(json);
  }

  Future<void> deleteIntegration(String integrationId) async {
    await _client.requestJson(
      method: 'DELETE',
      path: '/home-assistant/integrations/${_pathSegment(integrationId)}',
      expectBody: false,
    );
  }

  Future<NasHaConnectionTestResult> testIntegration(String integrationId) async {
    final json = await _client.requestJson(
      method: 'POST',
      path: '/home-assistant/integrations/${_pathSegment(integrationId)}/test',
    );
    return NasHaConnectionTestResult.fromJson(json);
  }

  Future<NasHaDiscoverResult> discover(String integrationId) async {
    final json = await _client.requestJson(
      method: 'POST',
      path: '/home-assistant/integrations/${_pathSegment(integrationId)}/discover',
    );
    return NasHaDiscoverResult.fromJson(json);
  }

  Future<List<NasHaEntity>> listEntities({
    String? integrationId,
    bool controllableOnly = false,
  }) async {
    final query = <String, String>{
      if (integrationId != null) 'integration_id': integrationId,
      'controllable_only': '$controllableOnly',
    };
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/entities',
      queryParameters: query,
    );
    return _parseList(json['entities'], NasHaEntity.fromJson);
  }

  Future<NasHaEntityState> fetchEntityState({
    required String integrationId,
    required String entityId,
  }) async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/entities/${_pathSegment(entityId)}/state',
      queryParameters: {'integration_id': integrationId},
    );
    return NasHaEntityState.fromJson(json);
  }

  Future<NasHaCommandResult> sendCommand({
    required String integrationId,
    required String entityId,
    required NasHaCommand command,
    required String requestId,
    NasHaCommandParameters? parameters,
  }) async {
    final json = await _client.requestJson(
      method: 'POST',
      path: '/home-assistant/entities/${_pathSegment(entityId)}/commands',
      queryParameters: {'integration_id': integrationId},
      body: {
        'command': nasHaCommandValue(command),
        if (parameters != null) 'parameters': parameters.toJson(),
        'request_id': requestId,
      },
    );
    return NasHaCommandResult.fromJson(json);
  }



  Future<List<NasHaConsumableGroup>> listConsumableGroups() async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/consumable-groups',
    );
    return _parseEnvelopeList(json, 'groups', NasHaConsumableGroup.fromJson);
  }

  Future<NasHaConsumableGroup> saveConsumableGroup(
    NasHaConsumableGroup group,
  ) async {
    final json = await _client.requestJson(
      method: group.id.isEmpty ? 'POST' : 'PUT',
      path: group.id.isEmpty
          ? '/home-assistant/consumable-groups'
          : '/home-assistant/consumable-groups/${_pathSegment(group.id)}',
      body: group.toJson(),
    );
    return NasHaConsumableGroup.fromJson(json['group'] ?? json);
  }

  Future<List<NasHaConsumableRecipe>> listConsumableRecipes() async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/consumable-recipes',
    );
    return _parseEnvelopeList(json, 'recipes', NasHaConsumableRecipe.fromJson);
  }

  Future<NasHaConsumableRecipe> saveConsumableRecipe(
    NasHaConsumableRecipe recipe,
  ) async {
    final json = await _client.requestJson(
      method: recipe.id.isEmpty ? 'POST' : 'PUT',
      path: recipe.id.isEmpty
          ? '/home-assistant/consumable-recipes'
          : '/home-assistant/consumable-recipes/${_pathSegment(recipe.id)}',
      body: recipe.toJson(),
    );
    return NasHaConsumableRecipe.fromJson(json['recipe'] ?? json);
  }

  Future<List<NasHaLinkageRule>> listLinkageRules() async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/linkage-rules',
    );
    return _parseEnvelopeList(json, 'rules', NasHaLinkageRule.fromJson);
  }

  Future<NasHaLinkageRule> saveLinkageRule(NasHaLinkageRule rule) async {
    final json = await _client.requestJson(
      method: rule.id.isEmpty ? 'POST' : 'PUT',
      path: rule.id.isEmpty
          ? '/home-assistant/linkage-rules'
          : '/home-assistant/linkage-rules/${_pathSegment(rule.id)}',
      body: rule.toJson(),
    );
    return NasHaLinkageRule.fromJson(json['rule'] ?? json);
  }

  Future<List<NasHaLinkageSuggestion>> listLinkageSuggestions({
    NasHaLinkageSuggestionStatus? status,
  }) async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/linkage-suggestions',
      queryParameters: {
        if (status != null) 'status': _linkageSuggestionStatusValue(status),
      },
    );
    return _parseEnvelopeList(
      json,
      'suggestions',
      NasHaLinkageSuggestion.fromJson,
    );
  }

  Future<NasHaLinkageSuggestion> resolveLinkageSuggestion({
    required String suggestionId,
    required NasHaSuggestionDecision decision,
  }) async {
    final json = await _client.requestJson(
      method: 'POST',
      path: '/home-assistant/linkage-suggestions/${_pathSegment(suggestionId)}/resolve',
      body: {'decision': nasHaSuggestionDecisionValue(decision)},
    );
    return NasHaLinkageSuggestion.fromJson(json['suggestion'] ?? json);
  }

  Future<List<NasHaEntityPermission>> listPermissions() async {
    final json = await _client.requestJson(
      method: 'GET',
      path: '/home-assistant/permissions',
    );
    return _parseList(json['permissions'], NasHaEntityPermission.fromJson);
  }

  Future<NasHaEntityPermission> updatePermission(
    NasHaEntityPermission permission,
  ) async {
    final json = await _client.requestJson(
      method: 'PUT',
      path: '/home-assistant/permissions',
      body: permission.toJson(),
    );
    return NasHaEntityPermission.fromJson(json);
  }
}

List<T> _parseList<T>(Object? value, T Function(Object?) parser) {
  if (value is! List) throw const FormatException('Expected a JSON array');
  return List<T>.unmodifiable(value.map(parser));
}

List<T> _parseEnvelopeList<T>(
  Map<String, dynamic> json,
  String key,
  T Function(Object?) parser,
) {
  final nested = json['data'];
  final value = json[key] ?? (nested is Map ? nested[key] : null);
  return _parseList(value, parser);
}

String _linkageSuggestionStatusValue(NasHaLinkageSuggestionStatus value) {
  switch (value) {
    case NasHaLinkageSuggestionStatus.pending:
      return 'pending';
    case NasHaLinkageSuggestionStatus.deducted:
      return 'deducted';
    case NasHaLinkageSuggestionStatus.ignored:
      return 'ignored';
    case NasHaLinkageSuggestionStatus.insufficientStock:
      return 'insufficient_stock';
    case NasHaLinkageSuggestionStatus.unknown:
      return 'unknown';
  }
}

String _pathSegment(String value) => Uri.encodeComponent(value);
