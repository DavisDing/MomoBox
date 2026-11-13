import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

import '../support/memory_settings_repository.dart';

http.Response _json(Map<String, Object?> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _auth(String token) => _json({
  'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
  'access_token': token,
  'refresh_token': 'refresh-$token',
  'expires_in': 900,
});

Map<String, Object?> _device(String id) => {
  'id': id,
  'device_name': '手机',
  'platform': 'android',
  'created_at': '2026-11-12T00:00:00Z',
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final restored in [false, true]) {
    for (final rejectBinding in [false, true]) {
      test(
        '${restored ? 'restored' : 'new'} device waits for device-bound token; rejection=$rejectBinding',
        () async {
          final settingsRepository = MemorySettingsRepository();
          settingsRepository.values[nasServerUrlKey] = 'https://nas.example';
          if (restored) settingsRepository.values[nasDeviceIdKey] = 'phone';
          final settings = SettingsService(settingsRepository);
          final connection = NasConnectionService(settings);
          final credentials = NasCredentialsService();
          final entered = Completer<void>();
          final release = Completer<http.Response>();
          var boundDeviceId = '';
          var registrations = 0;
          final controller = NasAccountController(
            settings: settings,
            connection: connection,
            credentials: credentials,
            apiClientFactory:
                (url) => NasApiClient(
                  url,
                  client: MockClient((request) async {
                    final path = request.url.path;
                    if (path.endsWith('/auth/login')) {
                      return _auth('without-device');
                    }
                    if (path.endsWith('/families/current')) {
                      return _json({
                        'family': {
                          'id': 'family',
                          'name': '家庭',
                          'created_at': '2026-11-12T00:00:00Z',
                        },
                        'membership': {'family_id': 'family', 'role': 'owner'},
                      });
                    }
                    if (path.endsWith('/families/members')) {
                      return _json({'members': []});
                    }
                    if (path.endsWith('/devices')) {
                      if (request.method == 'GET') {
                        return _json({
                          'devices': restored ? [_device('phone')] : [],
                        });
                      }
                      registrations++;
                      final body = jsonDecode(request.body) as Map;
                      return _json(_device(body['device_id'] as String), 201);
                    }
                    if (path.endsWith('/auth/refresh')) {
                      final body = jsonDecode(request.body) as Map;
                      expect(body['refresh_token'], 'refresh-without-device');
                      boundDeviceId = body['device_id'] as String;
                      expect(
                        boundDeviceId,
                        settingsRepository.values[nasDeviceIdKey],
                      );
                      entered.complete();
                      return release.future;
                    }
                    return _json({}, 404);
                  }),
                ),
          );
          addTearDown(controller.dispose);
          addTearDown(connection.close);
          addTearDown(settingsRepository.close);
          final login = controller.login(
            const NasLoginRequest(
              email: 'user@example.com',
              password: 'valid-password',
            ),
          );
          late Future<void> operation;
          if (restored) {
            operation = login;
          } else {
            await login;
            expect(
              controller.state.devices.status,
              NasDeviceStatus.needsRegistration,
            );
            operation = controller.prepareCurrentDevice();
          }
          await entered.future;
          expect(controller.state.devices.status, NasDeviceStatus.loading);
          expect(controller.state.devices.currentDeviceId, isNull);
          release.complete(
            rejectBinding
                ? _json({
                  'error': {
                    'code': 'AUTH_INVALID_TOKEN',
                    'message': 'device unavailable',
                  },
                }, 401)
                : _auth('with-device'),
          );
          await operation;
          expect(registrations, restored ? 0 : 1);
          if (rejectBinding) {
            expect(controller.state.isAuthenticated, isFalse);
            expect(controller.state.devices.currentDeviceId, isNull);
            expect(await credentials.read(), isNull);
          } else {
            expect(controller.state.devices.status, NasDeviceStatus.ready);
            expect(controller.state.devices.currentDeviceId, boundDeviceId);
            expect((await credentials.read())!.accessToken, 'with-device');
          }
        },
      );
    }
  }
}
