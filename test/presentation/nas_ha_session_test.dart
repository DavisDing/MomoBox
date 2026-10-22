import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

import '../support/memory_settings_repository.dart';

const _login = NasLoginRequest(email: 'user@example.com', password: 'valid-password');

http.Response _json(Map<String, Object?> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _auth(String suffix) => _json({
  'user': {'id': suffix == 'rotated' || suffix == 'late' ? 'user-a' : 'user-$suffix',
    'email': 'user@example.com', 'nickname': '家人'},
  'access_token': 'access-$suffix', 'refresh_token': 'refresh-$suffix',
  'expires_in': 900,
});

http.Response _family(String id) => _json({
  'family': {'id': id, 'name': '家庭', 'created_at': '2026-10-22T00:00:00Z'},
  'membership': {'family_id': id, 'role': 'owner'},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('HA shares account transport and refresh without owning either lifetime', () async {
    final settingsRepository = MemorySettingsRepository();
    settingsRepository.values[nasServerUrlKey] = 'https://a.example';
    final settings = SettingsService(settingsRepository);
    final connection = NasConnectionService(settings);
    final credentials = NasCredentialsService();
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    var clients = 0;
    var refreshCalls = 0;
    final controller = NasAccountController(
      settings: settings, connection: connection, credentials: credentials,
      apiClientFactory: (url) {
        clients++;
        return NasApiClient(url, client: MockClient((request) async {
          if (request.url.path.endsWith('/auth/login')) return _auth('a');
          if (request.url.path.endsWith('/auth/refresh')) {
            refreshCalls++;
            if (refreshCalls == 1) {
              entered.complete();
              return release.future;
            }
            return _auth('rotated');
          }
          if (request.url.path.endsWith('/home-assistant/integrations')) {
            if (request.headers['Authorization'] == 'Bearer access-a') return _json({}, 401);
            expect(request.headers['Authorization'], 'Bearer access-rotated');
            return _json({'integrations': []});
          }
          return _json({}, 404);
        }));
      },
    );
    addTearDown(settingsRepository.close);
    addTearDown(connection.close);
    addTearDown(controller.dispose);
    await controller.login(_login);
    expect(controller.state.isAuthenticated, isTrue);
    final repository = controller.createHomeAssistantRepository();
    addTearDown(repository.close);
    expect(await repository.restoreCredentials(), isTrue);
    final first = repository.listIntegrations();
    await entered.future;
    final second = repository.listIntegrations();
    release.complete(_auth('rotated'));
    expect(await first, isEmpty);
    expect(await second, isEmpty);
    expect(clients, 1);
    expect(refreshCalls, 1);
    expect((await credentials.readForServer('https://a.example/api/v1/'))!.refreshToken,
      'refresh-rotated');
    repository.close();
    await controller.refreshSession();
    expect(controller.state.isAuthenticated, isTrue);
    expect(refreshCalls, 2);
    final next = controller.createHomeAssistantRepository();
    addTearDown(next.close);
    expect(await next.restoreCredentials(), isTrue);
    expect(await next.listIntegrations(), isEmpty);
    expect(clients, 1);
  });

  for (final unauthorized in [false, true]) {
    test('late HA refresh ${unauthorized ? 'failure' : 'success'} cannot replace the next endpoint login', () async {
      final settingsRepository = MemorySettingsRepository();
      settingsRepository.values[nasServerUrlKey] = 'https://a.example';
      final settings = SettingsService(settingsRepository);
      final connection = NasConnectionService(settings);
      final credentials = NasCredentialsService();
      final entered = Completer<void>();
      final release = Completer<http.Response>();
      final requests = <http.Request>[];
      final controller = NasAccountController(
        settings: settings, connection: connection, credentials: credentials,
        apiClientFactory: (url) => NasApiClient(url, client: MockClient((request) async {
          requests.add(request);
          final isOld = request.url.host == 'a.example';
          if (request.url.path.endsWith('/auth/login')) return _auth(isOld ? 'a' : 'b');
          if (request.url.path.endsWith('/auth/logout')) return http.Response('', 204);
          if (request.url.path.endsWith('/auth/refresh')) {
            expect(isOld, isTrue);
            entered.complete();
            return release.future;
          }
          if (request.url.path.endsWith('/home-assistant/integrations')) {
            if (isOld) return _json({}, 401);
            expect(request.headers['Authorization'], 'Bearer access-b');
            return _json({'integrations': []});
          }
          return _json({}, 404);
        })),
      );
      addTearDown(settingsRepository.close);
      addTearDown(connection.close);
      addTearDown(controller.dispose);
      await controller.login(_login);
      final oldRepository = controller.createHomeAssistantRepository();
      addTearDown(oldRepository.close);
      final rejected = expectLater(oldRepository.listIntegrations(), throwsA(isA<NasApiError>()));
      await entered.future;
      await controller.logout();
      expect(await oldRepository.restoreCredentials(), isFalse);
      await settings.setValue(nasServerUrlKey, 'https://b.example');
      await controller.login(_login);
      expect(controller.state.isAuthenticated, isTrue);
      release.complete(unauthorized ? _json({}, 401) : _auth('late'));
      await rejected;
      final count = requests.length;
      await expectLater(oldRepository.listIntegrations(), throwsA(isA<NasApiError>()));
      expect(requests, hasLength(count));
      final stored = (await credentials.readForServer('https://b.example/api/v1/'))!;
      expect(stored.accessToken, 'access-b');
      expect(stored.refreshToken, 'refresh-b');
      expect(controller.state.auth.user!.id, 'user-b');
      final next = controller.createHomeAssistantRepository();
      addTearDown(next.close);
      expect(await next.listIntegrations(), isEmpty);
    });
  }

  test('family change rejects an old HA response before refresh or retry', () async {
    final settingsRepository = MemorySettingsRepository();
    settingsRepository.values[nasServerUrlKey] = 'https://a.example';
    final settings = SettingsService(settingsRepository);
    final connection = NasConnectionService(settings);
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    var refreshCalls = 0;
    var haRequests = 0;
    final controller = NasAccountController(
      settings: settings, connection: connection, credentials: NasCredentialsService(),
      apiClientFactory: (url) => NasApiClient(url, client: MockClient((request) async {
        if (request.url.path.endsWith('/auth/login')) return _auth('a');
        if (request.url.path.endsWith('/auth/refresh')) {
          refreshCalls++;
          return _auth('rotated');
        }
        if (request.url.path.endsWith('/families/current')) return _family('family-a');
        if (request.url.path.endsWith('/families/join')) return _family('family-b');
        if (request.url.path.endsWith('/families/members')) return _json({'members': []});
        if (request.url.path.endsWith('/devices')) return _json({'devices': []});
        if (request.url.path.endsWith('/home-assistant/integrations')) {
          haRequests++;
          if (haRequests == 1) {
            entered.complete();
            return release.future;
          }
          return _json({'integrations': []});
        }
        return _json({}, 404);
      })),
    );
    addTearDown(settingsRepository.close);
    addTearDown(connection.close);
    addTearDown(controller.dispose);
    await controller.login(_login);
    expect(controller.state.family.familyId, 'family-a');
    final oldRepository = controller.createHomeAssistantRepository();
    addTearDown(oldRepository.close);
    final rejected = expectLater(oldRepository.listIntegrations(), throwsA(isA<NasApiError>()));
    await entered.future;
    await controller.joinFamily('invite-code');
    expect(controller.state.family.familyId, 'family-b');
    release.complete(_json({}, 401));
    await rejected;
    expect(refreshCalls, 0);
    expect(haRequests, 1);
    await expectLater(oldRepository.listIntegrations(), throwsA(isA<NasApiError>()));
    expect(haRequests, 1);
    final next = controller.createHomeAssistantRepository();
    addTearDown(next.close);
    expect(await next.listIntegrations(), isEmpty);
  });
}
