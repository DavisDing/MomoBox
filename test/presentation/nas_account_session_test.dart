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

http.Response _auth() => http.Response(jsonEncode({
  'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
  'access_token': 'access', 'refresh_token': 'refresh', 'expires_in': 900,
}), 200);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  test('same-endpoint re-login hides old account before reading configuration', () async {
    final repository = _GatedSettingsRepository();
    repository.values[nasServerUrlKey] = 'https://a.example';
    final settings = SettingsService(repository);
    final connection = NasConnectionService(settings);
    final credentials = NasCredentialsService();
    var clients = 0;
    var loginCalls = 0;
    var refreshCalls = 0;
    final controller = NasAccountController(
      settings: settings,
      connection: connection,
      credentials: credentials,
      apiClientFactory: (url) {
        clients++;
        return NasApiClient(url, client: MockClient((request) async {
          if (request.url.path.endsWith('/login')) {
            loginCalls++;
            return _auth();
          }
          if (request.url.path.endsWith('/refresh')) {
            refreshCalls++;
            return _auth();
          }
          return http.Response('{}', 404);
        }));
      },
    );
    addTearDown(controller.dispose);
    addTearDown(connection.close);
    addTearDown(repository.close);
    const request = NasLoginRequest(email: 'user@example.com', password: 'valid-password');
    await controller.login(request);
    final oldSync = controller.createSyncApi()!;
    addTearDown(oldSync.close);
    repository.pauseServerRead = true;
    final pending = controller.login(request);
    expect(controller.state.status, NasAccountStatus.signingIn);
    expect(controller.state.isAuthenticated, isFalse);
    expect(controller.createSyncApi(), isNull);
    await repository.entered.future;
    await controller.refreshSession();
    expect(refreshCalls, 0);
    expect(loginCalls, 1);
    // The old transport is invalid even though the endpoint/client is reused.
    await expectLater(oldSync.capabilities(), throwsA(isA<NasApiError>().having(
      (error) => error.kind, 'kind', NasApiErrorKind.unauthorized,
    )));
    repository.release.complete();
    await pending;
    expect(controller.state.isAuthenticated, isTrue);
    expect(loginCalls, 2);
    expect(clients, 1);
    expect((await credentials.read())!.accessToken, 'access');
  });

  test('controller stays signed out when refresh completes after logout', () async {
    final repository = MemorySettingsRepository();
    repository.values[nasServerUrlKey] = 'https://a.example';
    final settings = SettingsService(repository);
    final connection = NasConnectionService(settings);
    final credentials = NasCredentialsService();
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final controller = NasAccountController(
      settings: settings, connection: connection, credentials: credentials,
      apiClientFactory: (url) => NasApiClient(url, client: MockClient((request) async {
        if (request.url.path.endsWith('/login')) return _auth();
        if (request.url.path.endsWith('/refresh')) {
          entered.complete();
          return release.future;
        }
        if (request.url.path.endsWith('/logout')) return http.Response('', 204);
        return http.Response('{}', 404); // A logged-in user may have no family.
      })),
    );
    addTearDown(controller.dispose);
    addTearDown(connection.close);
    addTearDown(repository.close);
    await controller.login(const NasLoginRequest(
      email: 'user@example.com', password: 'valid-password',
    ));
    expect(controller.state.isAuthenticated, isTrue);
    final refreshing = controller.refreshSession();
    await entered.future;
    await controller.logout();
    release.complete(_auth());
    await refreshing;
    expect(controller.state.status, NasAccountStatus.signedOut);
    expect(await credentials.read(), isNull);
  });

  test('new endpoint restore supersedes an old restore already in flight', () async {
    final repository = MemorySettingsRepository();
    repository.values[nasServerUrlKey] = 'https://a.example';
    final settings = SettingsService(repository);
    final connection = NasConnectionService(settings);
    final credentials = NasCredentialsService();
    final identity = NasApiClient('https://a.example');
    await credentials.save(const NasAuthResponse(
      user: NasUser(id: 'user', email: 'user@example.com', nickname: '家人'),
      accessToken: 'access-a', refreshToken: 'refresh-a', expiresIn: 900,
    ), serverIdentity: identity.serverIdentity);
    identity.close();
    final entered = Completer<void>();
    final release = Completer<http.Response>();
    final bRequests = <http.Request>[];
    final controller = NasAccountController(
      settings: settings, connection: connection, credentials: credentials,
      apiClientFactory: (url) => NasApiClient(url, client: MockClient((request) async {
        if (request.url.host == 'b.example') {
          bRequests.add(request);
          return http.Response('{}', 401);
        }
        entered.complete();
        return release.future;
      })),
    );
    addTearDown(controller.dispose);
    addTearDown(connection.close);
    addTearDown(repository.close);
    final oldRestore = controller.restore();
    await entered.future;
    await settings.setValue(nasServerUrlKey, 'https://b.example');
    await controller.restore();
    release.complete(http.Response(jsonEncode({
      'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
      'families': [], 'devices': [],
    }), 200));
    await oldRestore;
    expect(controller.state.status, NasAccountStatus.signedOut);
    expect(bRequests, isEmpty);
    expect((await credentials.read())!.accessToken, 'access-a');
  });
}

class _GatedSettingsRepository extends MemorySettingsRepository {
  bool pauseServerRead = false;
  final entered = Completer<void>();
  final release = Completer<void>();

  @override
  Future<String?> getValue(String key) async {
    if (key == nasServerUrlKey && pauseServerRead) {
      pauseServerRead = false;
      entered.complete();
      await release.future;
    }
    return super.getValue(key);
  }
}
