import '../../domain/models/nas_homeassistant_models.dart';
import '../nas/nas_homeassistant_api.dart';

/// Remote Home Assistant repository boundary.
///
/// This repository deliberately exposes NAS contract models rather than
/// silently converting remote state into the existing mock UI models. The UI
/// can adopt it in a separate integration task once loading/error semantics
/// are confirmed.
class NasSmartHomeRepository {
  NasSmartHomeRepository(this._api);

  final NasHomeAssistantApi _api;

  Future<List<NasHaIntegration>> listIntegrations() => _api.listIntegrations();

  Future<NasHaIntegration> addIntegration(NasHaIntegrationInput input) =>
      _api.addIntegration(input);

  Future<NasHaIntegration> updateIntegration(
    String integrationId,
    NasHaIntegrationUpdate update,
  ) =>
      _api.updateIntegration(integrationId, update);

  Future<void> deleteIntegration(String integrationId) =>
      _api.deleteIntegration(integrationId);

  Future<NasHaConnectionTestResult> testIntegration(String integrationId) =>
      _api.testIntegration(integrationId);

  Future<NasHaDiscoverResult> discover(String integrationId) =>
      _api.discover(integrationId);

  Future<List<NasHaEntity>> listEntities({
    String? integrationId,
    bool controllableOnly = false,
  }) =>
      _api.listEntities(
        integrationId: integrationId,
        controllableOnly: controllableOnly,
      );

  Future<NasHaEntityState> fetchEntityState({
    required String integrationId,
    required String entityId,
  }) =>
      _api.fetchEntityState(integrationId: integrationId, entityId: entityId);

  Future<NasHaCommandResult> sendCommand({
    required String integrationId,
    required String entityId,
    required NasHaCommand command,
    required String requestId,
    NasHaCommandParameters? parameters,
  }) =>
      _api.sendCommand(
        integrationId: integrationId,
        entityId: entityId,
        command: command,
        requestId: requestId,
        parameters: parameters,
      );

  Future<List<NasHaEntityPermission>> listPermissions() => _api.listPermissions();

  Future<NasHaEntityPermission> updatePermission(
    NasHaEntityPermission permission,
  ) =>
      _api.updatePermission(permission);
}
