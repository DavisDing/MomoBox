import '../../domain/models/nas_family_device_models.dart';
import 'nas_api_client.dart';
import 'nas_api_error.dart';

/// Optional request seam for tests or alternate transports. By default the
/// API delegates to [NasApiClient.requestJson], preserving shared auth,
/// refresh, timeout, and error handling.
typedef NasFamilyDeviceRequest = Future<Map<String, dynamic>> Function({
  required String method,
  required String path,
  Map<String, dynamic>? body,
  bool expectBody = true,
});

class NasFamilyDeviceApi {
  NasFamilyDeviceApi({
    required NasApiClient apiClient,
    NasFamilyDeviceRequest? request,
  }) : _request = request ??
            ({
              required String method,
              required String path,
              Map<String, dynamic>? body,
              bool expectBody = true,
            }) =>
                apiClient.requestJson(
                  method: method,
                  path: path,
                  body: body,
                  expectBody: expectBody,
                );

  final NasFamilyDeviceRequest _request;

  Future<NasFamilyResponseDto> createFamily(
    NasCreateFamilyRequest request,
  ) async {
    return _decode(
      await _send('POST', '/families', request.toJson()),
      NasFamilyResponseDto.fromJson,
    );
  }

  Future<NasFamilyResponseDto> currentFamily() async {
    return _decode(
      await _send('GET', '/families/current'),
      NasFamilyResponseDto.fromJson,
    );
  }

  Future<List<NasFamilyMemberDto>> listMembers() async {
    return _decodeList(
      await _send('GET', '/families/members'),
      parseNasFamilyMembers,
    );
  }

  Future<NasFamilyInviteDto> createInvite(
    NasCreateInviteRequest request,
  ) async {
    return _decode(
      await _send('POST', '/families/invites', request.toJson()),
      NasFamilyInviteDto.fromJson,
    );
  }

  Future<NasFamilyResponseDto> joinFamily(
    NasJoinFamilyRequest request,
  ) async {
    return _decode(
      await _send('POST', '/families/join', request.toJson()),
      NasFamilyResponseDto.fromJson,
    );
  }

  Future<NasDeviceDto> registerDevice(
    NasRegisterFamilyDeviceRequest request,
  ) async {
    return _decode(
      await _send('POST', '/devices', request.toJson()),
      NasDeviceDto.fromJson,
    );
  }

  Future<List<NasDeviceDto>> listDevices() async {
    return _decodeList(
      await _request(
        method: 'GET',
        path: '/devices',
        expectBody: true,
      ),
      parseNasDevices,
    );
  }

  Future<void> revokeDevice(String deviceId) async {
    await _send('DELETE', '/devices/${Uri.encodeComponent(deviceId)}', null,
        expectBody: false);
  }

  Future<Map<String, dynamic>> _send(
    String method,
    String path,
    Map<String, dynamic>? body, {
    bool expectBody = true,
  }) async {
    return _request(
      method: method,
      path: path,
      body: body,
      expectBody: expectBody,
    );
  }

  T _decode<T>(Map<String, dynamic> json, T Function(Object? value) parser) {
    try {
      return parser(json);
    } on FormatException catch (error) {
      throw NasApiError.invalidResponse(error);
    } on TypeError catch (error) {
      throw NasApiError.invalidResponse(error);
    }
  }

  T _decodeList<T>(
    Map<String, dynamic> json,
    T Function(Object? value) parser,
  ) {
    try {
      return parser(json);
    } on FormatException catch (error) {
      throw NasApiError.invalidResponse(error);
    } on TypeError catch (error) {
      throw NasApiError.invalidResponse(error);
    }
  }
}
