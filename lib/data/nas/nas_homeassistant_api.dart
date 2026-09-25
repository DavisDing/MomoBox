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

String _pathSegment(String value) => Uri.encodeComponent(value);
