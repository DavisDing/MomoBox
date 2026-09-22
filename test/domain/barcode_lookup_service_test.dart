import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/barcode_lookup_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/barcode_cache_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';

void main() {
  test('独立接口测试绕过开关和缓存，404 未收录不是故障', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var calls = 0;
    final service = BarcodeLookupService(BarcodeCacheRepository(db),
      SettingsService(SettingsRepository(db)),
      client: MockClient((request) async {
        calls++;
        expect(request.url.queryParameters['fields'], contains('product_name_zh'));
        return http.Response(jsonEncode({'status': 0, 'status_verbose': 'product not found'}), 404);
      }),
    );
    expect(await service.lookup('3017620422003'), isNull);
    expect(calls, 0);
    expect(await service.testEndpoint(BarcodeLookupService.defaultFreeEndpoint, '3017620422003'), isNull);
    expect(calls, 1);
  });

  test('UTF-8 无 charset 商品名正常且优先中文，普通 404 仍失败', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    var missing = false;
    final service = BarcodeLookupService(BarcodeCacheRepository(db), SettingsService(SettingsRepository(db)),
      client: MockClient((_) async => missing ? http.Response('Not Found', 404)
        : http.Response.bytes(utf8.encode(jsonEncode({'product': {
          'product_name': 'Milk', 'product_name_zh': '牛奶'
        }})), 200)),
    );
    expect((await service.testEndpoint(BarcodeLookupService.defaultFreeEndpoint, '3017620422003'))?.name, '牛奶');
    missing = true;
    await expectLater(service.testEndpoint(BarcodeLookupService.defaultFreeEndpoint, '3017620422003'), throwsStateError);
  });

  Future<BarcodeLookupService> serviceWithProfiles({
    required AppDatabase database,
    required http.Client client,
    required List<Map<String, dynamic>> profiles,
  }) async {
    final settings = SettingsService(SettingsRepository(database));
    await settings.setValue(BarcodeLookupService.enabledKey, 'true');
    await settings.setValue(BarcodeLookupService.profilesKey, jsonEncode(profiles));
    return BarcodeLookupService(
      BarcodeCacheRepository(database),
      settings,
      client: client,
      clock: () => DateTime(2026, 9, 14),
    );
  }

  test('当前配置中的自定义主接口返回中文商品并写入缓存', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final settings = SettingsService(SettingsRepository(database));
    await settings.setValue(BarcodeLookupService.enabledKey, 'true');
    await settings.setValue(
      BarcodeLookupService.profilesKey,
      jsonEncode([
        {
          'id': 'custom',
          'name': '自定义接口',
          'endpoint': 'https://custom.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.primaryRole,
        },
      ]),
    );
    final requestedHosts = <String>[];
    final service = BarcodeLookupService(
      BarcodeCacheRepository(database),
      settings,
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        return http.Response(
          jsonEncode({
            'status': 1,
            'product': {
              'product_name': '自定义接口商品',
              'brands': '自定义接口品牌',
            },
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
      clock: () => DateTime(2026, 9, 14),
    );

    final result = await service.lookup('6901234567890');

    expect(result?.name, '自定义接口商品');
    expect(result?.brand, '自定义接口品牌');
    expect(requestedHosts, ['custom.example']);
    final cached = await service.lookup('6901234567890');
    expect(cached?.name, '自定义接口商品');
    expect(cached?.brand, '自定义接口品牌');
    expect(requestedHosts, ['custom.example']);
  });

  test('主服务返回无法识别的成功响应时继续使用副服务', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final requestedHosts = <String>[];
    final service = await serviceWithProfiles(
      database: database,
      profiles: [
        {
          'id': 'primary',
          'name': '主服务',
          'endpoint': 'https://primary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.primaryRole,
        },
        {
          'id': 'secondary',
          'name': '副服务',
          'endpoint': 'https://secondary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.secondaryRole,
        },
      ],
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'primary.example') {
          return http.Response(jsonEncode({'unexpected': true}), 200);
        }
        return http.Response(
          jsonEncode({
            'status': 1,
            'product': {'product_name': '副服务商品'},
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.lookup('6901234567890');

    expect(result?.name, '副服务商品');
    expect(requestedHosts, ['primary.example', 'secondary.example']);
  });

  test('主服务明确返回未找到时不继续调用副服务', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final requestedHosts = <String>[];
    final service = await serviceWithProfiles(
      database: database,
      profiles: [
        {
          'id': 'primary',
          'name': '主服务',
          'endpoint': 'https://primary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.primaryRole,
        },
        {
          'id': 'secondary',
          'name': '副服务',
          'endpoint': 'https://secondary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.secondaryRole,
        },
      ],
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        return http.Response(jsonEncode({'found': false}), 200);
      }),
    );

    final result = await service.lookup('6901234567890');

    expect(result, isNull);
    expect(requestedHosts, ['primary.example']);
  });

  test('规范配置时保留已选主服务且不启用仅保存的接口', () {
    final profiles = BarcodeLookupService.normalizeProfilesForRoles(
      [
        {
          'id': BarcodeLookupService.defaultFreeProfileId,
          'name': '免费公共条码库',
          'endpoint': BarcodeLookupService.defaultFreeEndpoint,
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.standbyRole,
        },
        {
          'id': 'custom',
          'name': '自定义接口',
          'endpoint': 'https://custom.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.primaryRole,
        },
      ],
    );

    final primaryProfiles = profiles
        .where(
          (profile) =>
              profile[BarcodeLookupService.profileRoleKey] ==
              BarcodeLookupService.primaryRole,
        )
        .toList();

    expect(primaryProfiles, hasLength(1));
    expect(primaryProfiles.single['id'], 'custom');
    expect(
      profiles.first[BarcodeLookupService.profileRoleKey],
      BarcodeLookupService.standbyRole,
    );
  });

  test('条码服务在主服务失败后使用可选副服务', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final requestedHosts = <String>[];
    final service = await serviceWithProfiles(
      database: database,
      profiles: [
        {
          'id': 'primary',
          'name': '主服务',
          'endpoint': 'https://primary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.primaryRole,
        },
        {
          'id': 'secondary',
          'name': '副服务',
          'endpoint': 'https://secondary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.secondaryRole,
        },
      ],
      client: MockClient((request) async {
        requestedHosts.add(request.url.host);
        if (request.url.host == 'primary.example') return http.Response('unavailable', 503);
        return http.Response(
          jsonEncode({
            'status': 1,
            'product': {'product_name': '副服务商品', 'brands': '测试品牌'},
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.lookup('6901234567890');

    expect(result?.name, '副服务商品');
    expect(requestedHosts, ['primary.example', 'secondary.example']);
  });

  test('副服务和兜底服务留空时，只调用主服务', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    var requestCount = 0;
    final service = await serviceWithProfiles(
      database: database,
      profiles: [
        {
          'id': 'primary',
          'name': '主服务',
          'endpoint': 'https://primary.example/{barcode}',
          BarcodeLookupService.profileRoleKey: BarcodeLookupService.primaryRole,
        },
      ],
      client: MockClient((request) async {
        requestCount++;
        return http.Response(
          jsonEncode({
            'status': 1,
            'product': {'product_name': '主服务商品'},
          }),
          200,
          headers: const {'content-type': 'application/json; charset=utf-8'},
        );
      }),
    );

    final result = await service.lookup('6901234567890');

    expect(result?.name, '主服务商品');
    expect(requestCount, 1);
  });

  test('条码配置损坏时报告错误且不向默认接口发送请求', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final settings = SettingsService(SettingsRepository(database));
    await settings.setValue(BarcodeLookupService.enabledKey, 'true');
    var requestCount = 0;
    final service = BarcodeLookupService(
      BarcodeCacheRepository(database),
      settings,
      client: MockClient((request) async {
        requestCount++;
        return http.Response('unexpected request', 500);
      }),
    );

    for (final raw in ['{broken', '{}', '[42]', '[{"name":"缺少地址"}]']) {
      await settings.setValue(BarcodeLookupService.profilesKey, raw);
      await expectLater(service.lookup('6901234567890'), throwsFormatException);
      expect(await settings.getValue(BarcodeLookupService.profilesKey), raw);
    }
    expect(requestCount, 0);
  });

  test('内置免费条码服务预配为主服务，未开启时不联网', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    final settings = SettingsService(SettingsRepository(database));
    var requested = false;
    final service = BarcodeLookupService(
      BarcodeCacheRepository(database),
      settings,
      client: MockClient((request) async {
        requested = true;
        return http.Response('unexpected request', 500);
      }),
    );

    final result = await service.lookup('6901234567890');
    final profile = BarcodeLookupService.defaultFreeProfile();

    expect(result, isNull);
    expect(requested, isFalse);
    expect(profile['endpoint'], BarcodeLookupService.defaultFreeEndpoint);
    expect(profile[BarcodeLookupService.profileRoleKey], BarcodeLookupService.primaryRole);
  });
}
