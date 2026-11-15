import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/services/local_network_permission_service.dart';

import '../support/memory_settings_repository.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const channel = LocalNetworkPermissionService.channel;
  late LocalNetworkPermissionService permission;

  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    permission = LocalNetworkPermissionService();
  });
  tearDown(() {
    messenger.setMockMethodCallHandler(channel, null);
    debugDefaultTargetPlatformOverride = null;
  });

  for (final status in ['not_required', 'granted', 'denied']) {
    test('Android状态$status只检查权限，不触发系统申请', () async {
      final methods = <String>[];
      messenger.setMockMethodCallHandler(channel, (call) async {
        methods.add(call.method);
        return status;
      });
      expect(await permission.status(), switch (status) {
        'not_required' => LocalNetworkPermissionStatus.notRequired,
        'granted' => LocalNetworkPermissionStatus.granted,
        _ => LocalNetworkPermissionStatus.denied,
      });
      expect(methods, ['status']);
    });
  }

  test('并发主动申请合并；拒绝后允许用户再次主动申请', () async {
    var requests = 0;
    final response = Completer<String>();
    messenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'request');
      requests++;
      return requests == 1 ? response.future : 'granted';
    });
    final first = permission.request();
    final second = permission.request();
    await Future<void>.delayed(Duration.zero);
    expect(requests, 1);
    response.complete('denied');
    expect(await first, LocalNetworkPermissionStatus.denied);
    expect(await second, LocalNetworkPermissionStatus.denied);
    expect(await permission.request(), LocalNetworkPermissionStatus.granted);
    expect(requests, 2);
  });

  test('iOS不调用Android权限通道', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    messenger.setMockMethodCallHandler(
      channel,
      (_) async => throw StateError('不应调用'),
    );
    expect(await permission.status(), LocalNetworkPermissionStatus.notRequired);
    expect(
      await permission.request(),
      LocalNetworkPermissionStatus.notRequired,
    );
  });

  for (final failure in ['missing', 'closed', 'unknown']) {
    test('原生通道$failure不伪装成已获权，不泄露原生异常', () async {
      if (failure != 'missing') {
        messenger.setMockMethodCallHandler(channel, (_) async {
          if (failure == 'closed') {
            throw PlatformException(
              code: 'ACTIVITY_CLOSED',
              message: 'private details',
            );
          }
          return 'unexpected-result';
        });
      }
      expect(
        await permission.status(),
        LocalNetworkPermissionStatus.unavailable,
      );
      expect(
        await permission.request(),
        LocalNetworkPermissionStatus.unavailable,
      );
    });
  }

  test('权限被拒绝仍能访问公网反代，HTTP200才确认NAS在线', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return 'denied';
    });
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    final service = NasConnectionService(
      SettingsService(settings),
      localNetworkPermission: permission,
      client: MockClient((request) async {
        expect(request.url.toString(), 'https://nas.example.com/api/v1/health');
        return http.Response('{"database":"ok","status":"ok"}', 200);
      }),
    );
    addTearDown(service.close);
    expect(
      await service.requestLocalNetworkAccess(),
      LocalNetworkPermissionStatus.denied,
    );
    final result = await service.saveAndCheck(
      serverUrl: 'https://nas.example.com',
      familyCode: '',
    );
    expect(result.isConnected, isTrue);
    expect(methods, ['request']);
    expect(settings.values[nasServerUrlKey], 'https://nas.example.com');
  });

  test('被动连接失败仅检查权限，未获权提示操作入口且保留原连接和身份', () async {
    final methods = <String>[];
    messenger.setMockMethodCallHandler(channel, (call) async {
      methods.add(call.method);
      return 'denied';
    });
    final settings = MemorySettingsRepository();
    settings.values.addAll({
      'nas_user_id': 'current-user',
      'sync_workspace_binding': 'existing-family',
    });
    addTearDown(settings.close);
    final service = NasConnectionService(
      SettingsService(settings),
      localNetworkPermission: permission,
      client: MockClient(
        (_) async => throw http.ClientException('private endpoint details'),
      ),
    );
    addTearDown(service.close);
    for (var i = 0; i < 2; i++) {
      final result = await service.saveAndCheck(
        serverUrl: 'https://nas.example.com',
        familyCode: '',
      );
      expect(result.status, NasConnectionStatus.failed);
      expect(result.message, contains('附近设备'));
      expect(result.message, isNot(contains('private endpoint')));
    }
    expect(methods, ['status', 'status']);
    expect(settings.values['nas_user_id'], 'current-user');
    expect(settings.values['sync_workspace_binding'], 'existing-family');
    expect(settings.values[nasServerUrlKey], 'https://nas.example.com');
  });

  test('获权后超时仍报告网络失败；数据库503不误判成权限问题', () async {
    var checks = 0;
    messenger.setMockMethodCallHandler(channel, (call) async {
      checks++;
      expect(call.method, 'status');
      return 'granted';
    });
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    var timeout = true;
    final service = NasConnectionService(
      SettingsService(settings),
      localNetworkPermission: permission,
      client: MockClient((_) async {
        if (timeout) throw TimeoutException('private endpoint');
        return http.Response('{"database":"unavailable"}', 503);
      }),
    );
    addTearDown(service.close);
    expect(
      (await service.checkHealth('https://nas.example.com')).message,
      '连接 NAS 超时。',
    );
    timeout = false;
    final failed = await service.checkHealth('https://nas.example.com');
    expect(failed.status, NasConnectionStatus.unavailable);
    expect(failed.message, contains('数据库'));
    expect(checks, 1);
  });
}
