import 'dart:async';
import 'dart:convert';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_auth_service.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

const _user = NasUser(id: 'user', email: 'user@example.com', nickname: '家人');
const _login = NasLoginRequest(email: 'user@example.com', password: 'valid-password');
const _response = NasAuthResponse(
  user: _user, accessToken: 'access-a', refreshToken: 'refresh-a', expiresIn: 900,
);

http.Response _authResponse({String access = 'access-a', String refresh = 'refresh-a'}) =>
    http.Response(jsonEncode({
      'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
      'access_token': access, 'refresh_token': refresh, 'expires_in': 900,
    }), 200);

http.Response _me() => http.Response(jsonEncode({
  'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
  'families': [], 'devices': [],
}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('unbound or foreign credentials skip corrupt residual token reads', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    storage.values.addAll({
      'nas_access_token': 'residual-access',
      'nas_refresh_token': 'residual-refresh',
      'nas_access_token_expires_at_ms': '8640000000000001',
    });
    storage.failReadKey = 'nas_access_token';
    var requests = 0;
    final api = NasApiClient('https://a.example', client: MockClient((_) async {
      requests++;
      return _me();
    }));
    addTearDown(api.close);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    expect((await auth.restore()).status, NasAuthStatus.signedOut);
    expect((await auth.refresh()).status, NasAuthStatus.signedOut);
    storage.values['nas_server_identity'] = 'https://b.example/api/v1/';
    expect((await auth.restore()).status, NasAuthStatus.signedOut);
    storage.failReadKey = null;
    storage.values.remove('nas_server_identity');
    expect((await auth.restore()).status, NasAuthStatus.signedOut);
    expect(requests, 0);
    expect(storage.values['nas_access_token'], 'residual-access');
    storage.values['nas_server_identity'] = api.serverIdentity;
    // A matching binding must still report the out-of-range expiration rather
    // than treating genuinely broken current-server storage as a valid login.
    await expectLater(auth.restore(), throwsA(isA<NasCredentialsException>()));
    expect(api.accessToken, isNull);
  });

  test('late refresh storage-read failure cannot disturb a newer login', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      expect(request.url.path, endsWith('/login'));
      return _authResponse(access: 'new-access', refresh: 'new-refresh');
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    storage.pauseReadKey = 'nas_server_identity';
    final oldRefresh = auth.refresh();
    await storage.entered.future;
    final newLogin = auth.login(_login);
    storage.release.complete();
    await oldRefresh; // The gated read throws, but its generation is obsolete.
    expect((await newLogin).isAuthenticated, isTrue);
    expect(auth.snapshot.isAuthenticated, isTrue);
    expect(api.accessToken, 'new-access');
    expect((await credentials.readForServer(api.serverIdentity))!.accessToken, 'new-access');
  });

  test('late refresh binding-write failure cannot invalidate a newer login', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      return _authResponse(
        access: request.url.path.endsWith('/login') ? 'new-access' : 'rotated-access',
        refresh: request.url.path.endsWith('/login') ? 'new-refresh' : 'rotated-refresh',
      );
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    storage.pauseBinding = true;
    storage.failPausedBinding = true;
    final oldRefresh = auth.refresh();
    await storage.entered.future;
    final newLogin = auth.login(_login);
    storage.release.complete();
    await oldRefresh;
    expect((await newLogin).isAuthenticated, isTrue);
    expect(auth.snapshot.isAuthenticated, isTrue);
    expect(api.accessToken, 'new-access');
    expect((await credentials.readForServer(api.serverIdentity))!.accessToken, 'new-access');
  });

  test('late login network failure after logout is discarded', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final credentials = NasCredentialsService();
    final api = NasApiClient('https://a.example', client: MockClient((_) async {
      entered.complete();
      return release.future;
    }));
    addTearDown(api.close);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    final pending = auth.login(_login);
    await entered.future;
    await auth.logout();
    release.completeError(http.ClientException('late failure'));
    expect((await pending).status, NasAuthStatus.signedOut);
    expect(api.accessToken, isNull);
    expect(await credentials.read(), isNull);
  });

  test('refresh save failure invalidates the old in-memory session', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    var requests = 0;
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      requests++;
      return _authResponse(access: 'rotated-access', refresh: 'rotated-refresh');
    }));
    addTearDown(api.close);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    await auth.login(_login);
    storage.failWriteKey = 'nas_refresh_token';
    await expectLater(auth.refresh(), throwsA(isA<NasCredentialsException>()));
    expect(auth.snapshot.status, NasAuthStatus.signedOut);
    expect(api.accessToken, isNull);
    expect(await credentials.readForServer(api.serverIdentity), isNull);
    expect((await auth.restore()).status, NasAuthStatus.signedOut);
    await expectLater(api.me(), throwsA(isA<NasApiError>()));
    expect(requests, 2);
    storage.failWriteKey = null;
    expect((await auth.login(_login)).isAuthenticated, isTrue);
  });

  test('obsolete logout cleanup failure cannot clear a concurrent login', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      if (request.url.path.endsWith('/login')) {
        return _authResponse(access: 'new-access', refresh: 'new-refresh');
      }
      return http.Response('', 204);
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    // First clear succeeds; the second (finally) clear pauses and then fails.
    storage.pauseDeleteKey = 'nas_server_identity';
    storage.deleteCallsToSkip = 1;
    final oldLogout = auth.logout();
    await storage.entered.future;
    final newLogin = auth.login(_login);
    storage.release.complete();
    await oldLogout;
    expect((await newLogin).isAuthenticated, isTrue);
    expect(api.accessToken, 'new-access');
    expect((await credentials.readForServer(api.serverIdentity))!.accessToken, 'new-access');
  });

  test('capabilities is an authenticated read without bootstrap side effects', () async {
    final requests = <http.Request>[];
    final api = NasSyncApi('https://a.example/proxy', accessToken: 'current-token',
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(jsonEncode({
          'schema_version': 1, 'sync_protocol_version': 2,
          'snapshot': 'ignored', 'checkpoint': 'ignored',
        }), 200);
      }),
    );
    addTearDown(api.close);
    final versions = await api.capabilities();
    expect(versions.schemaVersion, 1);
    expect(versions.syncProtocolVersion, 2);
    expect(requests, hasLength(1));
    expect(requests.single.method, 'GET');
    expect(requests.single.url.toString(), 'https://a.example/proxy/api/v1/capabilities');
    expect(requests.single.headers['Authorization'], 'Bearer current-token');
    expect(requests.single.body, isEmpty);
  });

  test('capabilities rejects a refresh retry after session invalidation', () async {
    var current = true;
    final entered = Completer<void>();
    final release = Completer<String?>();
    final requests = <http.Request>[];
    final api = NasSyncApi('https://a.example/proxy', accessToken: 'old-token',
      isSessionCurrent: () => current,
      refreshHandler: () {
        entered.complete();
        return release.future;
      },
      client: MockClient((request) async {
        requests.add(request);
        return http.Response('{}', 401);
      }),
    );
    addTearDown(api.close);
    final pending = api.capabilities();
    final assertion = expectLater(pending, throwsA(isA<NasApiError>().having(
      (error) => error.kind, 'kind', NasApiErrorKind.unauthorized,
    )));
    await entered.future;
    current = false;
    release.complete('late-token');
    await assertion;
    expect(requests, hasLength(1));
    expect(requests.single.url.toString(), 'https://a.example/proxy/api/v1/capabilities');
    expect(requests.single.headers['Authorization'], 'Bearer old-token');
  });

  test('capabilities rejects malformed versions and stale session responses', () async {
    var current = true;
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    var requests = 0;
    final api = NasSyncApi('https://a.example', accessToken: 'current-token',
      isSessionCurrent: () => current,
      client: MockClient((_) async {
        if (++requests == 1) {
          return http.Response('{"schema_version":1,"sync_protocol_version":"bad"}', 200);
        }
        entered.complete();
        return release.future;
      }),
    );
    addTearDown(api.close);
    await expectLater(api.capabilities(), throwsA(isA<NasApiError>().having(
      (error) => error.kind, 'kind', NasApiErrorKind.invalidResponse,
    )));
    final pending = api.capabilities();
    final assertion = expectLater(pending, throwsA(isA<NasApiError>().having(
      (error) => error.kind, 'kind', NasApiErrorKind.unauthorized,
    )));
    await entered.future;
    current = false;
    release.complete(http.Response('{"schema_version":1,"sync_protocol_version":1}', 200));
    await assertion;
    await expectLater(api.capabilities(), throwsA(isA<NasApiError>()));
    expect(requests, 2);
  });

  test('server identity canonicalizes API suffix but not server/path boundaries', () {
    final a = NasApiClient('HTTPS://NAS.EXAMPLE:443/proxy/api/v1/');
    final same = NasApiClient('https://nas.example/proxy');
    final httpServer = NasApiClient('http://nas.example/proxy');
    final path = NasApiClient('https://nas.example/other');
    final port = NasApiClient('https://nas.example:8443/proxy');
    for (final api in [a, same, httpServer, path, port]) {
      addTearDown(api.close);
    }
    expect(a.serverIdentity, same.serverIdentity);
    expect(a.serverIdentity, isNot(httpServer.serverIdentity));
    expect(a.serverIdentity, isNot(path.serverIdentity));
    expect(a.serverIdentity, isNot(port.serverIdentity));
  });

  test('old server tokens are never sent to a new server, even after a 401', () async {
    final credentials = NasCredentialsService();
    final a = NasApiClient('https://a.example');
    addTearDown(a.close);
    await credentials.save(_response, serverIdentity: a.serverIdentity);
    final requests = <http.Request>[];
    final b = NasApiClient('https://b.example', client: MockClient((request) async {
      requests.add(request);
      return http.Response('{}', 401);
    }));
    addTearDown(b.close);
    final auth = NasAuthService(apiClient: b, credentials: credentials);
    expect((await auth.restore()).status, NasAuthStatus.signedOut);
    expect((await auth.refresh()).status, NasAuthStatus.signedOut);
    expect(requests, isEmpty);
    expect(b.accessToken, isNull);
    expect((await credentials.read())!.serverIdentity, a.serverIdentity);
  });

  test('legacy unbound credentials require login without deleting local data', () async {
    FlutterSecureStorage.setMockInitialValues({
      'nas_access_token': 'legacy-access', 'nas_refresh_token': 'legacy-refresh',
      'nas_access_token_expires_at_ms': '1800000000000',
    });
    final credentials = NasCredentialsService();
    var requests = 0;
    final api = NasApiClient('https://a.example', client: MockClient((_) async {
      requests++;
      return _me();
    }));
    addTearDown(api.close);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    expect((await auth.restore()).status, NasAuthStatus.signedOut);
    expect(requests, 0);
    expect((await credentials.read())!.accessToken, 'legacy-access');
  });

  test('login persists server binding and same-server restore works', () async {
    final credentials = NasCredentialsService();
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      if (request.url.path.endsWith('/login')) return _authResponse();
      expect(request.headers['Authorization'], 'Bearer access-a');
      return _me();
    }));
    addTearDown(api.close);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    expect((await auth.login(_login)).isAuthenticated, isTrue);
    expect((await credentials.read())!.serverIdentity, api.serverIdentity);
    expect((await auth.restore()).isAuthenticated, isTrue);
  });

  test('logout wins against a late successful refresh response', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final credentials = NasCredentialsService();
    final requests = <http.Request>[];
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      requests.add(request);
      if (request.url.path.endsWith('/refresh')) {
        entered.complete();
        return release.future;
      }
      expect(request.url.path, endsWith('/logout'));
      expect(request.headers['Authorization'], 'Bearer access-a');
      return http.Response('', 204);
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    final refresh = auth.refresh();
    await entered.future;
    await auth.logout();
    release.complete(_authResponse(access: 'late-access', refresh: 'late-refresh'));
    expect((await refresh).status, NasAuthStatus.signedOut);
    expect(auth.snapshot.status, NasAuthStatus.signedOut);
    expect(await credentials.read(), isNull);
    expect(api.accessToken, isNull);
    expect(requests, hasLength(2));
  });

  test('remote logout failure still clears credentials and rejects a late login', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final credentials = NasCredentialsService();
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      if (request.url.path.endsWith('/login')) {
        entered.complete();
        return release.future;
      }
      return http.Response('{}', 500);
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    final login = auth.login(_login);
    await entered.future;
    await expectLater(auth.logout(), throwsA(isA<NasApiError>()));
    release.complete(_authResponse());
    expect((await login).status, NasAuthStatus.signedOut);
    expect(await credentials.read(), isNull);
    expect(api.accessToken, isNull);
  });

  test('refresh calls share one request across sibling clients', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    var refreshCalls = 0;
    final credentials = NasCredentialsService();
    final api = NasApiClient('https://a.example', client: MockClient((_) async {
      refreshCalls++;
      entered.complete();
      return release.future;
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    final first = auth.refresh();
    await entered.future;
    final second = auth.refresh();
    release.complete(_authResponse());
    expect((await first).isAuthenticated, isTrue);
    expect((await second).isAuthenticated, isTrue);
    expect(refreshCalls, 1);
  });

  test('abandoned server refresh cannot overwrite a new server login', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final credentials = NasCredentialsService();
    final a = NasApiClient('https://a.example', client: MockClient((_) async {
      entered.complete();
      return release.future;
    }));
    final b = NasApiClient('https://b.example', client: MockClient((_) async =>
        _authResponse(access: 'access-b', refresh: 'refresh-b')));
    addTearDown(a.close);
    addTearDown(b.close);
    await credentials.save(_response, serverIdentity: a.serverIdentity);
    final oldAuth = NasAuthService(apiClient: a, credentials: credentials);
    final refresh = oldAuth.refresh();
    await entered.future;
    oldAuth.abandon();
    final newAuth = NasAuthService(apiClient: b, credentials: credentials);
    await newAuth.login(_login);
    release.complete(_authResponse(access: 'late-a', refresh: 'late-a-refresh'));
    await refresh;
    final stored = await credentials.read();
    expect(stored!.serverIdentity, b.serverIdentity);
    expect(stored.accessToken, 'access-b');
    expect(a.accessToken, isNull);
  });

  test('conditional persistence cannot commit an invalidated session', () async {
    final credentials = NasCredentialsService();
    expect(await credentials.saveIfCurrent(_response,
      serverIdentity: 'https://a.example/api/v1/', isCurrent: () => false,
    ), isFalse);
    expect(await credentials.read(), isNull);
    await credentials.save(_response, serverIdentity: 'https://a.example/api/v1/');
    await credentials.clearIfCurrent(isCurrent: () => false);
    expect(await credentials.read(), isNotNull);
  });

  test('invalidated partial save leaves no restorable server binding', () async {
    final credentials = NasCredentialsService();
    var checks = 0;
    final saved = await credentials.saveIfCurrent(_response,
      serverIdentity: 'https://a.example/api/v1/',
      isCurrent: () => ++checks == 1,
    );
    expect(saved, isFalse);
    expect(await credentials.readForServer('https://a.example/api/v1/'), isNull);
    await credentials.clear();
    expect(await credentials.read(), isNull);
  });

  test('refresh cannot run while logout is waiting for remote revocation', () async {
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final credentials = NasCredentialsService();
    var refreshCalls = 0;
    final api = NasApiClient('https://a.example', client: MockClient((request) async {
      if (request.url.path.endsWith('/refresh')) {
        refreshCalls++;
        return _authResponse();
      }
      entered.complete();
      return release.future;
    }));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    final logout = auth.logout();
    await entered.future;
    expect((await auth.refresh()).status, NasAuthStatus.signedOut);
    expect(refreshCalls, 0);
    release.complete(http.Response('', 204));
    await logout;
  });

  test('logout during secure-storage commit cannot resurrect credentials', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    final api = NasApiClient('https://a.example', client: MockClient((_) async => _authResponse()));
    addTearDown(api.close);
    await credentials.save(_response, serverIdentity: api.serverIdentity);
    final auth = NasAuthService(apiClient: api, credentials: credentials);
    storage.pauseBinding = true;
    final refreshing = auth.refresh();
    await storage.entered.future;
    final logout = auth.logout();
    expect(api.accessToken, isNull);
    storage.release.complete();
    await Future.wait([refreshing, logout]);
    expect(await credentials.read(), isNull);
    expect(auth.snapshot.status, NasAuthStatus.signedOut);
    expect(storage.values, isEmpty);
  });

  test('credential queue survives failed persistence without binding a partial pair', () async {
    final storage = _GatedStorage();
    final credentials = NasCredentialsService(storage: storage);
    await credentials.save(_response, serverIdentity: 'https://a.example/api/v1/');
    storage.failWriteKey = 'nas_refresh_token';
    await expectLater(credentials.save(_response,
      serverIdentity: 'https://b.example/api/v1/',
    ), throwsA(isA<NasCredentialsException>()));
    expect(await credentials.readForServer('https://a.example/api/v1/'), isNull);
    expect(await credentials.readForServer('https://b.example/api/v1/'), isNull);
    storage.failWriteKey = null;
    await credentials.save(_response, serverIdentity: 'https://b.example/api/v1/');
    expect(await credentials.readForServer('https://b.example/api/v1/'), isNotNull);
    await credentials.clear();
    expect(storage.values, isEmpty);
  });

  test('old transport cannot restore a token returned after session invalidation', () async {
    final entered = Completer<void>();
    final release = Completer<String?>();
    var requests = 0;
    final api = NasApiClient('https://a.example', client: MockClient((_) async {
      requests++;
      return http.Response('{}', 401);
    }));
    addTearDown(api.close);
    api.setAccessToken('access-a');
    api.setRefreshHandler(() {
      entered.complete();
      return release.future;
    });
    final pending = api.me();
    final assertion = expectLater(pending, throwsA(isA<NasApiError>()));
    await entered.future;
    api.setAccessToken(null);
    release.complete('late-access');
    await assertion;
    expect(api.accessToken, isNull);
    expect(requests, 1);
  });

  test('sync client rechecks session after refresh before sending a retry', () async {
    var current = true;
    var requests = 0;
    final entered = Completer<void>();
    final release = Completer<String?>();
    final api = NasSyncApi('https://a.example', accessToken: 'old-token',
      isSessionCurrent: () => current,
      refreshHandler: () {
        entered.complete();
        return release.future;
      },
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 401);
      }),
    );
    addTearDown(api.close);
    final pending = api.bootstrap(deviceId: 'device');
    final assertion = expectLater(pending, throwsA(isA<NasApiError>()));
    await entered.future;
    current = false;
    release.complete('late-token');
    await assertion;
    expect(requests, 1);
  });

  test('sync token provider returning null never falls back to stale cached token', () async {
    var requests = 0;
    final api = NasSyncApi('https://a.example', accessToken: 'stale',
      accessTokenProvider: () => null,
      client: MockClient((_) async {
        requests++;
        return http.Response('{}', 200);
      }),
    );
    addTearDown(api.close);
    await expectLater(api.bootstrap(deviceId: 'device'), throwsA(isA<NasApiError>()));
    expect(requests, 0);
  });
}

// noSuchMethod supplies the platform options accepted by FlutterSecureStorage
// without coupling this fake to per-platform option types.
class _GatedStorage implements FlutterSecureStorage {
  final values = <String, String>{};
  final entered = Completer<void>();
  final release = Completer<void>();
  bool pauseBinding = false;
  bool failPausedBinding = false;
  String? failWriteKey;
  String? failReadKey;
  String? pauseReadKey;
  String? pauseDeleteKey;
  int deleteCallsToSkip = 0;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String;
    switch (invocation.memberName) {
      case #read:
        return _read(key);
      case #delete:
        return _delete(key);
      case #write:
        return _write(key, invocation.namedArguments[#value] as String?);
      default:
        return super.noSuchMethod(invocation);
    }
  }

  Future<String?> _read(String key) async {
    if (key == pauseReadKey) {
      pauseReadKey = null;
      entered.complete();
      await release.future;
      throw StateError('late secure storage read failed');
    }
    if (key == failReadKey) throw StateError('secure storage read failed');
    return values[key];
  }

  Future<void> _delete(String key) async {
    if (key == pauseDeleteKey) {
      if (deleteCallsToSkip > 0) {
        deleteCallsToSkip--;
      } else {
        pauseDeleteKey = null;
        entered.complete();
        await release.future;
        throw StateError('late secure storage delete failed');
      }
    }
    values.remove(key);
  }

  Future<void> _write(String key, String? value) async {
    if (key == failWriteKey) throw StateError('secure storage write failed');
    if (key == 'nas_server_identity' && pauseBinding) {
      pauseBinding = false;
      entered.complete();
      await release.future;
      if (failPausedBinding) throw StateError('late secure storage write failed');
    }
    if (value == null) {
      values.remove(key);
    } else {
      values[key] = value;
    }
  }
}
