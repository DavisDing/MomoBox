import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_homeassistant_api.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

const _credentials = NasAuthResponse(
  user: NasUser(id: 'user', email: 'user@example.com', nickname: '家人'),
  accessToken: 'access-a', refreshToken: 'refresh-a', expiresIn: 900,
);
const _newCredentials = NasAuthResponse(
  user: NasUser(id: 'user-b', email: 'b@example.com', nickname: '新家人'),
  accessToken: 'access-b', refreshToken: 'refresh-b', expiresIn: 900,
);

http.Response _json(Map<String, Object?> body, [int status = 200]) =>
    http.Response(jsonEncode(body), status,
      headers: {'content-type': 'application/json; charset=utf-8'});

http.Response _me() => _json({
  'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
  'families': [], 'devices': [],
});

http.Response _refresh() => _json({
  'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
  'access_token': 'rotated-access', 'refresh_token': 'rotated-refresh',
  'expires_in': 900,
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  for (final binding in <String?>[
    null,
    'https://b.example/proxy/api/v1/',
    'http://a.example/proxy/api/v1/',
    'https://a.example:8443/proxy/api/v1/',
    'https://a.example/other/api/v1/',
  ]) {
    test('unbound or different endpoint cannot restore or send tokens: $binding', () async {
      final credentials = NasCredentialsService();
      await credentials.save(_credentials, serverIdentity: binding);
      var requests = 0;
      final repository = NasSmartHomeRepository.fromBaseUrl(
        'https://a.example/proxy', credentials: credentials,
        apiClientFactory: (url) => NasApiClient(url, client: MockClient((_) async {
          requests++;
          return _json({'integrations': []});
        })),
      );
      addTearDown(repository.close);
      expect(await repository.restoreCredentials(), isFalse);
      await expectLater(repository.listIntegrations(), throwsA(isA<NasApiError>()));
      expect(requests, 0);
      final stored = (await credentials.read())!;
      expect(stored.accessToken, 'access-a');
      expect(stored.serverIdentity, binding);
    });
  }

  test('matching canonical endpoint refreshes with its binding intact', () async {
    final credentials = NasCredentialsService();
    await credentials.save(_credentials, serverIdentity: 'https://a.example/proxy/api/v1/');
    final requests = <http.Request>[];
    final repository = NasSmartHomeRepository.fromBaseUrl(
      'https://A.example:443/proxy/api/v1/', credentials: credentials,
      apiClientFactory: (url) => NasApiClient(url, client: MockClient((request) async {
        requests.add(request);
        expect(request.url.host, 'a.example');
        if (request.url.path.endsWith('/auth/refresh')) {
          expect(jsonDecode(request.body), {'refresh_token': 'refresh-a'});
          expect(request.headers['Authorization'], isNull);
          return _refresh();
        }
        if (request.headers['Authorization'] == 'Bearer access-a') return _json({}, 401);
        expect(request.headers['Authorization'], 'Bearer rotated-access');
        if (request.url.path.endsWith('/me')) return _me();
        return _json({'integrations': []});
      })),
    );
    addTearDown(repository.close);
    expect(await repository.restoreCredentials(), isTrue);
    expect(await repository.listIntegrations(), isEmpty);
    expect(requests.where((r) => r.url.path.endsWith('/auth/refresh')), hasLength(1));
    final stored = (await credentials.readForServer('https://a.example/proxy/api/v1/'))!;
    expect(stored.accessToken, 'rotated-access');
    expect(stored.refreshToken, 'rotated-refresh');
    expect(stored.serverIdentity, 'https://a.example/proxy/api/v1/');
  });

  for (final unauthorized in [false, true]) {
    test('closed independent repository ignores late refresh ${unauthorized ? 'failure' : 'success'}', () async {
      final credentials = NasCredentialsService();
      await credentials.save(_credentials, serverIdentity: 'https://a.example/api/v1/');
      final entered = Completer<void>();
      final release = Completer<http.Response>();
      var requests = 0;
      late NasApiClient client;
      final repository = NasSmartHomeRepository.fromBaseUrl(
        'https://a.example', credentials: credentials,
        apiClientFactory: (url) => client = NasApiClient(url, client: MockClient((request) async {
          requests++;
          if (request.url.path.endsWith('/auth/refresh')) {
            entered.complete();
            return release.future;
          }
          return _json({}, 401);
        })),
      );
      addTearDown(repository.close);
      final pending = repository.restoreCredentials();
      await entered.future;
      repository.close();
      await credentials.save(_newCredentials, serverIdentity: 'https://b.example/api/v1/');
      release.complete(unauthorized ? _json({}, 401) : _refresh());
      expect(await pending, isFalse);
      expect(client.accessToken, isNull);
      expect(await repository.restoreCredentials(), isFalse);
      await expectLater(repository.listIntegrations(), throwsA(isA<NasApiError>()));
      expect(requests, 2);
      final stored = (await credentials.readForServer('https://b.example/api/v1/'))!;
      expect(stored.accessToken, 'access-b');
      expect(stored.refreshToken, 'refresh-b');
    });
  }

  test('shared session rejects late results and never closes the account client', () async {
    var current = true;
    var requests = 0;
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final client = NasApiClient('https://a.example', client: MockClient((_) async {
      requests++;
      if (requests == 1) {
        entered.complete();
        return release.future;
      }
      return _json({'integrations': []});
    }));
    addTearDown(client.close);
    client.setAccessToken('shared-access');
    final repository = NasSmartHomeRepository.withSession(
      client, isSessionCurrent: () => current,
    );
    addTearDown(repository.close);
    expect(await repository.restoreCredentials(), isTrue);
    final pending = repository.listIntegrations();
    final rejected = expectLater(pending, throwsA(isA<NasApiError>()));
    await entered.future;
    current = false;
    release.complete(_json({'integrations': []}));
    await rejected;
    await expectLater(repository.listIntegrations(), throwsA(isA<NasApiError>()));
    expect(requests, 1);
    repository.close();
    expect(await NasHomeAssistantApi(client).listIntegrations(), isEmpty);
    expect(client.accessToken, 'shared-access');
    expect(requests, 2);
  });

  test('direct API constructor remains usable without owning its client', () async {
    final client = NasApiClient('https://a.example', client: MockClient((_) async =>
        _json({'integrations': []})));
    addTearDown(client.close);
    client.setAccessToken('direct-access');
    final repository = NasSmartHomeRepository(NasHomeAssistantApi(client));
    expect(await repository.listIntegrations(), isEmpty);
    repository.close();
    expect(await NasHomeAssistantApi(client).listIntegrations(), isEmpty);
  });

  test('family change before a 401 prevents starting a refresh', () async {
    var current = true;
    var requests = 0;
    var refreshCalls = 0;
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final client = NasApiClient('https://a.example', client: MockClient((_) async {
      requests++;
      entered.complete();
      return release.future;
    }));
    addTearDown(client.close);
    client.setAccessToken('shared-access');
    client.setRefreshHandler(() async {
      refreshCalls++;
      return 'new-access';
    });
    final repository = NasSmartHomeRepository.withSession(client,
      isSessionCurrent: () => current,
    );
    addTearDown(repository.close);
    final rejected = expectLater(repository.listIntegrations(), throwsA(isA<NasApiError>()));
    await entered.future;
    current = false;
    release.complete(_json({}, 401));
    await rejected;
    expect(requests, 1);
    expect(refreshCalls, 0);
  });

  for (final closeRepository in [false, true]) {
    test('${closeRepository ? 'close' : 'family change'} during shared refresh prevents retry', () async {
      var current = true;
      var requests = 0;
      final entered = Completer<void>();
      final release = Completer<String?>();
      final client = NasApiClient('https://a.example', client: MockClient((_) async {
        requests++;
        return _json({}, 401);
      }));
      addTearDown(client.close);
      client.setAccessToken('shared-access');
      client.setRefreshHandler(() {
        entered.complete();
        return release.future;
      });
      final repository = NasSmartHomeRepository.withSession(client,
        isSessionCurrent: () => current,
      );
      addTearDown(repository.close);
      final rejected = expectLater(repository.listIntegrations(), throwsA(isA<NasApiError>()));
      await entered.future;
      if (closeRepository) {
        repository.close();
      } else {
        current = false;
      }
      release.complete('new-access');
      await rejected;
      expect(requests, 1);
      expect(client.accessToken, 'shared-access');
    });
  }
}
