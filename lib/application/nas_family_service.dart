import '../data/nas/nas_family_device_api.dart';
import '../domain/models/nas_family_device_models.dart';

/// Application boundary for family membership and sync-device management.
///
/// It deliberately contains no UI state or persistence. API errors and
/// transport failures from the API layer are allowed to propagate unchanged.
class NasFamilyService {
  const NasFamilyService(this._api);

  final NasFamilyDeviceApi _api;

  Future<NasFamilyResponseDto> createFamily(String name) {
    return _api.createFamily(NasCreateFamilyRequest(name: name));
  }

  Future<NasFamilyResponseDto> currentFamily() => _api.currentFamily();

  Future<List<NasFamilyMemberDto>> listMembers() => _api.listMembers();

  Future<NasFamilyInviteDto> createInvite({
    required int expiresInHours,
    required int maxUses,
  }) {
    return _api.createInvite(
      NasCreateInviteRequest(
        expiresInHours: expiresInHours,
        maxUses: maxUses,
      ),
    );
  }

  Future<NasFamilyResponseDto> joinFamily(String code) {
    return _api.joinFamily(NasJoinFamilyRequest(code: code));
  }

  Future<NasDeviceDto> registerDevice({
    required String deviceId,
    required String deviceName,
    required String platform,
    String? appVersion,
  }) {
    return _api.registerDevice(
      NasRegisterFamilyDeviceRequest(
        deviceId: deviceId,
        deviceName: deviceName,
        platform: platform,
        appVersion: appVersion,
      ),
    );
  }

  Future<List<NasDeviceDto>> listDevices() => _api.listDevices();

  Future<void> revokeDevice(String deviceId) => _api.revokeDevice(deviceId);
}
