import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';

import '../support/memory_settings_repository.dart';

void main() {
  for (final (address, base) in [
    (' http://192.168.1.20:18473 ', 'http://192.168.1.20:18473/api/v1/'),
    ('http://192.168.1.20:18473/', 'http://192.168.1.20:18473/api/v1/'),
    ('http://192.168.1.20:18473/api/v1/', 'http://192.168.1.20:18473/api/v1/'),
    ('https://nas.example/momo/', 'https://nas.example/momo/api/v1/'),
    ('https://nas.example/momo/api/v1', 'https://nas.example/momo/api/v1/'),
  ]) {
    test('health, account and sync use the same API base: $address', () async {
      final settings = MemorySettingsRepository();
      final requests = <http.Request>[];
      final client = MockClient((request) async {
        requests.add(request);
        return http.Response(
          '{"status":"ok","database":"ok","schema_version":1,"sync_protocol_version":1}',
          200,
        );
      });
      final connection = NasConnectionService(
        SettingsService(settings),
        client: client,
      );
      final account = NasApiClient(address, client: client)..setAccessToken('test-token');
      final sync = NasSyncApi(address, client: client, accessToken: 'test-token');
      addTearDown(settings.close);
      addTearDown(connection.close);
      addTearDown(account.close);
      addTearDown(sync.close);

      expect(
        (await connection.checkHealth(address)).status,
        NasConnectionStatus.connected,
      );
      await account.requestJson(method: 'GET', path: '/me');
      await sync.capabilities();
      expect(account.serverIdentity, base);
      expect(sync.matchesEndpoint(account.serverIdentity), isTrue);
      expect(requests.map((request) => request.url.toString()), [
        '${base}health',
        '${base}me',
        '${base}capabilities',
      ]);
      expect(requests.first.headers['Authorization'], isNull);
    });
  }

  test('wrong service and missing health route are not online', () async {
    final settings = MemorySettingsRepository();
    var status = 200;
    var body = '<html>Proxy login</html>';
    final service = NasConnectionService(
      SettingsService(settings),
      client: MockClient((_) async => http.Response(body, status)),
    );
    addTearDown(settings.close);
    addTearDown(service.close);

    for (final invalid in [body, '{}', '', '{"status":"degraded"}']) {
      body = invalid;
      final result = await service.checkHealth('https://nas.example');
      expect(result.status, NasConnectionStatus.failed);
      expect(result.message, contains('不是有效的 MomoBox 健康检查响应'));
    }
    status = 404;
    final result = await service.checkHealth('https://nas.example');
    expect(result.status, NasConnectionStatus.failed);
    expect(result.message, contains('HTTP 404'));
  });

  test(
    'rejects URL credentials, query and fragment before saving or probing',
    () async {
      final settings = MemorySettingsRepository();
      settings.values[nasServerUrlKey] = 'https://nas.example';
      final service = NasConnectionService(
        SettingsService(settings),
        client: MockClient(
          (_) async => throw StateError('must not send a request'),
        ),
      );
      addTearDown(settings.close);
      addTearDown(service.close);

      for (final address in [
        'https://user:pass@nas.example',
        'https://nas.example/?next=/momo',
        'https://nas.example/#app',
      ]) {
        final result = await service.saveAndCheck(
          serverUrl: address,
          familyCode: '',
        );
        expect(result.status, NasConnectionStatus.failed);
        expect(result.message, contains('请输入有效的 NAS 地址'));
        expect(settings.values[nasServerUrlKey], 'https://nas.example');
      }
    },
  );
}
