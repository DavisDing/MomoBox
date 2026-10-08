import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/backup_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/backup/backup_format.dart';

const _timestamp = '2026-10-03T00:00:00.000Z';

const _excludedSettings = <String, String>{
  'nas_server_url': 'https://old-nas.invalid',
  'nas_user_id': 'old-user',
  'nas_device_id': 'old-device',
  'nas_family_id': 'old-family',
  'nas_family_code': 'private-invite',
  'nas_last_checked_at': _timestamp,
  'nas_access_token': 'nas-secret',
  'nas_refresh_token': 'nas-refresh-secret',
  'nas_access_token_expires_at_ms': '1000',
  'sync_local_workspace_id': 'old-workspace',
  'sync_bootstrap:family:old-family': '{"status":"ready"}',
  'sync_aux:family:old-family:category:1': '{"name":"old"}',
  'sync_conflict_cursor:family:old-family:change': '100',
  'sync_future_internal_state': 'must-not-migrate',
  'reminder_sync_policy:family:old-family:1': '{"enabled":false}',
  'ha_access_token': 'ha-secret',
  'home_assistant_connection': '{"token":"ha-secret"}',
  'ai_api_key': 'ai-secret',
  'ai_api_key_profile_profile-1': 'profile-secret',
  'service_access_token': 'service-secret',
  'service_password': 'password-secret',
};

const _businessSettings = <String, String>{
  'theme': 'momo',
  'home_section_order': 'chores,inventory',
  'reminder_lead_days': '7',
  'recurring_chores_list': '[{"id":"chore-1","title":"清洗滤网"}]',
  'ai_conversations_v1':
      '{"currentId":"chat-1","sessions":[{"id":"chat-1","title":"采购建议"}]}',
  'ai_usage_logs': '[]',
  'ai_allow_inventory_writes': 'true',
  'ai_api_endpoint': 'https://ai.invalid/v1',
  'ai_model': 'model-1',
  'ai_secondary_endpoint': '',
  'ai_fallback_endpoint': '',
  'barcode_api_enabled': 'true',
  'custom_business_setting': 'preserved',
};

Map<String, Object?> _document(int version, Map<String, String> settings) => {
      'format': BackupFormat.formatName,
      'version': version,
      'products': [],
      'batches': [],
      'stock_movements': [],
      'shopping_entries': [],
      'settings': [
        for (final entry in settings.entries)
          {'key': entry.key, 'value': entry.value, 'updated_at': _timestamp},
      ],
      if (version == 3) 'reminder_acknowledgements': [],
      if (version == 3) 'barcode_lookup_cache': [],
    };

Map<String, Object?> _product() => {
      'id': 'product-new',
      'name': '备份物品',
      'category': '其他物品',
      'unit': '件',
      'low_stock_threshold': 1,
      'created_at': _timestamp,
      'updated_at': _timestamp,
    };

Future<void> _seed(AppDatabase database, Map<String, String> values) async {
  final settings = SettingsRepository(database);
  for (final entry in values.entries) {
    await settings.setValue(entry.key, entry.value);
  }
}

Future<Map<String, String>> _storedSettings(AppDatabase database) async => {
      for (final row in await database.select(database.appSettings).get())
        row.key: row.value,
    };

void main() {
  late AppDatabase source;
  late AppDatabase target;
  late BackupRepository backup;

  setUp(() {
    source = AppDatabase.forTesting(NativeDatabase.memory());
    target = AppDatabase.forTesting(NativeDatabase.memory());
    backup = BackupRepository(source);
  });

  tearDown(() async {
    await source.close();
    await target.close();
  });

  test('导出双向隔离设备身份与凭据，业务配置和源库原文保持不变', () async {
    final original = {..._excludedSettings, ..._businessSettings};
    await _seed(source, original);
    final content = await backup.exportJson();
    final parsed = BackupFormat.parse(content);
    final rows = BackupFormat.records(parsed, 'settings');
    expect({for (final row in rows) row['key']: row['value']}, _businessSettings);
    expect(await _storedSettings(source), original);

    final restored = await BackupRepository(target).importJson(content);
    expect(restored.imported, _businessSettings.length);
    expect(restored.excludedSettings, 0);
    expect(await _storedSettings(target), _businessSettings);
  });

  for (final version in [1, 2, 3]) {
    for (final hasTargetIdentity in [false, true]) {
      test('v$version 历史备份过滤源身份，目标已绑定=$hasTargetIdentity', () async {
        final targetIdentity = {
          for (final key in _excludedSettings.keys) key: 'target:$key',
        };
        if (hasTargetIdentity) await _seed(target, targetIdentity);
        final content = jsonEncode(_document(
          version,
          {..._excludedSettings, ..._businessSettings},
        ));
        final report = await BackupRepository(target).importJson(content);
        expect(report.imported, _businessSettings.length);
        expect(report.skipped, _excludedSettings.length);
        expect(report.excludedSettings, _excludedSettings.length);
        expect(await _storedSettings(target), {
          if (hasTargetIdentity) ...targetIdentity,
          ..._businessSettings,
        });
        final repeated = await BackupRepository(target).importJson(content);
        expect(repeated.imported, 0);
        expect(repeated.skipped,
            _businessSettings.length + _excludedSettings.length);
      });
    }
  }

  test('已有业务配置不覆盖，过滤计数与重复计数分别可读', () async {
    await _seed(target, {'theme': 'target-theme', 'nas_device_id': 'target-id'});
    final document = _document(3, {
      'theme': 'source-theme',
      'nas_device_id': 'source-id',
      'sync_local_workspace_id': 'source-workspace',
      'recurring_chores_list': _businessSettings['recurring_chores_list']!,
    });
    final report = await BackupRepository(target).importJson(jsonEncode(document));
    expect(report.imported, 1);
    expect(report.skipped, 3);
    expect(report.excludedSettings, 2);
    expect(await _storedSettings(target), {
      'theme': 'target-theme',
      'nas_device_id': 'target-id',
      'recurring_chores_list': _businessSettings['recurring_chores_list']!,
    });
  });

  test('历史服务配置导入与导出都剥离内嵌凭据而保留可用配置', () async {
    final profiles = jsonEncode([
      {
        'id': 'profile-1',
        'name': '主服务',
        'endpoint': 'https://user:url-secret@ai.invalid/v1?api_key=query-secret',
        'model': 'model-1',
        'endpointType': 'responses',
        'fallbackRole': 'primary',
        'apiKey': 'legacy-secret',
        '_apiKeyDraft': 'draft-secret',
        'hasApiKey': true,
        'headers': {'Authorization': 'Bearer nested-secret'},
      },
    ]);
    await _seed(source, {'ai_api_profiles': profiles});
    final exported = await backup.exportJson();
    for (final secret in [
      'url-secret', 'query-secret', 'legacy-secret', 'draft-secret', 'nested-secret',
    ]) {
      expect(exported, isNot(contains(secret)));
    }
    expect(await SettingsRepository(source).getValue('ai_api_profiles'), profiles);
    await BackupRepository(target).importJson(
        jsonEncode(_document(1, {'ai_api_profiles': profiles})));
    final restored = jsonDecode(
        (await SettingsRepository(target).getValue('ai_api_profiles'))!) as List;
    expect(restored.single, {
      'id': 'profile-1',
      'name': '主服务',
      'endpoint': 'https://ai.invalid/v1',
      'model': 'model-1',
      'endpointType': 'responses',
      'fallbackRole': 'primary',
    });
  });

  test('服务 URL 认证和签名在导出及历史导入均净化，源配置不改变', () async {
    const endpoint = 'https://service.invalid/{barcode}.json?auth=auth-secret'
        '&sig=sig-secret&signature=signature-secret&fields=name&region=local';
    final profiles = jsonEncode([{'id': 'barcode-signed', 'endpoint': endpoint}]);
    await _seed(source, {'barcode_api_profiles': profiles});
    final exported = await backup.exportJson();
    expect(exported, isNot(contains('secret')));
    expect(await SettingsRepository(source).getValue('barcode_api_profiles'), profiles);
    await BackupRepository(target).importJson(exported);
    final restoredExport = (jsonDecode(
      (await SettingsRepository(target).getValue('barcode_api_profiles'))!,
    ) as List).single['endpoint'] as String;
    expect(restoredExport, contains('{barcode}'));
    expect(Uri.parse(restoredExport).queryParameters,
        {'fields': 'name', 'region': 'local'});
    // Import the raw historical value into a different key so merge-only
    // behavior cannot mask whether import actually applies the sanitization.
    await BackupRepository(target).importJson(jsonEncode(_document(1, {
      'ai_api_profiles': profiles,
    })));
    final restoredLegacy = (jsonDecode(
      (await SettingsRepository(target).getValue('ai_api_profiles'))!,
    ) as List).single['endpoint'] as String;
    expect(restoredLegacy, restoredExport);
  });

  test('软删除商品、批次、采购恢复保留删除状态及流水引用，不迁移同步版本', () async {
    final timestamp = DateTime.parse(_timestamp);
    final deleted = DateTime.utc(2026, 10, 6);
    await source.into(source.products).insert(ProductsCompanion.insert(
      id: 'deleted-product', name: '已删除物品', category: '其他物品',
      createdAt: timestamp, updatedAt: timestamp,
      deletedAt: Value(deleted), serverVersion: const Value(99),
    ));
    await source.into(source.products).insert(ProductsCompanion.insert(
      id: 'active-product', name: '有效物品', category: '其他物品',
      createdAt: timestamp, updatedAt: timestamp,
    ));
    for (final entry in {
      'deleted-parent-batch': 'deleted-product',
      'deleted-active-batch': 'active-product',
    }.entries) {
      await source.into(source.productBatches).insert(ProductBatchesCompanion.insert(
        id: entry.key, productId: entry.value,
        initialQuantity: 3, remainingQuantity: 2,
        createdAt: timestamp, updatedAt: timestamp,
        deletedAt: Value(deleted), serverVersion: const Value(99),
      ));
    }
    await source.into(source.productBatches).insert(ProductBatchesCompanion.insert(
      id: 'active-batch', productId: 'active-product',
      initialQuantity: 4, remainingQuantity: 4,
      createdAt: timestamp, updatedAt: timestamp,
    ));
    await source.into(source.stockMovements).insert(StockMovementsCompanion.insert(
      id: 'deleted-product-movement', productId: 'deleted-product',
      batchId: const Value('deleted-parent-batch'), type: 'consume', quantity: -1,
      createdAt: timestamp,
    ));
    await source.into(source.shoppingEntries).insert(ShoppingEntriesCompanion.insert(
      id: 'deleted-shopping', productId: const Value('deleted-product'),
      itemName: '已删除采购', createdAt: timestamp, updatedAt: timestamp,
      deletedAt: Value(deleted), serverVersion: const Value(99),
    ));
    final exported = await backup.exportJson();
    final report = await BackupRepository(target).importJson(exported);
    expect(report.imported, 7);
    final products = await target.select(target.products).get();
    expect(products.singleWhere((row) => row.id == 'deleted-product').deletedAt,
        deleted);
    expect(products.every((row) => row.serverVersion == 0), isTrue);
    final batches = await target.select(target.productBatches).get();
    expect(batches.where((row) => row.deletedAt != null), hasLength(2));
    expect(batches.every((row) => row.serverVersion == 0), isTrue);
    final shopping = await target.select(target.shoppingEntries).get();
    expect(shopping.single.deletedAt, deleted);
    expect(shopping.single.serverVersion, 0);
    final movement = (await target.select(target.stockMovements).get()).single;
    expect(movement.productId, 'deleted-product');
    expect(movement.batchId, 'deleted-parent-batch');
    final inventory = await InventoryRepository(target).loadInventory();
    expect(inventory.single.id, 'active-product');
    expect(inventory.single.totalStock, 4);
    expect(inventory.single.batches, hasLength(1));
    expect(await ShoppingRepository(target).watchEntries().first, isEmpty);
    final repeated = await BackupRepository(target).importJson(exported);
    expect(repeated.imported, 0);
    expect(repeated.skipped, 7);
  });

  for (final version in [1, 2, 3]) {
    test('v$version 缺失删除标记保持旧兼容，显式删除标记仍可恢复', () async {
      final document = _document(version, {})..['products'] = [
        _product(),
        {..._product(), 'id': 'deleted-legacy', 'deleted_at': _timestamp},
      ];
      await BackupRepository(target).importJson(jsonEncode(document));
      final rows = await target.select(target.products).get();
      expect(rows.singleWhere((row) => row.id == 'product-new').deletedAt, isNull);
      expect(rows.singleWhere((row) => row.id == 'deleted-legacy').deletedAt,
          DateTime.parse(_timestamp));
    });
  }

  test('旧备份缺少删除标记不能覆盖目标已经软删除的记录', () async {
    final timestamp = DateTime.parse(_timestamp);
    await target.into(target.products).insert(ProductsCompanion.insert(
      id: 'product-new', name: '目标已删除物品', category: '其他物品',
      createdAt: timestamp, updatedAt: timestamp, deletedAt: Value(timestamp),
    ));
    final document = _document(1, {})..['products'] = [_product()];
    final report = await BackupRepository(target).importJson(jsonEncode(document));
    expect(report.imported, 0);
    expect(report.skipped, 1);
    final product = (await target.select(target.products).get()).single;
    expect(product.deletedAt, timestamp);
    expect(product.name, '目标已删除物品');
    expect(await InventoryRepository(target).loadInventory(), isEmpty);
  });

  for (final invalidDate in ['not-a-date', 123]) {
    test('非法 deleted_at ($invalidDate) 在写入前拒绝且保留目标数据', () async {
      await _seed(target, {'theme': 'target-theme'});
      final document = _document(3, {'custom_business_setting': 'new'})
        ..['products'] = [_product(), {
          ..._product(), 'id': 'invalid-deletion', 'deleted_at': invalidDate,
        }];
      await expectLater(BackupRepository(target).importJson(jsonEncode(document)),
          throwsA(isA<BackupImportException>()));
      expect(await target.select(target.products).get(), isEmpty);
      expect(await _storedSettings(target), {'theme': 'target-theme'});
    });
  }

  test('导出包含可选覆盖元数据但不伪造媒体或 OCR 迁移', () async {
    await source.into(source.mediaAssets).insert(MediaAssetsCompanion.insert(
      id: 'media-source',
      entityType: 'product',
      entityId: 'product-new',
      mediaType: 'manual',
      localPath: '/source-only/manual.jpg',
      mimeType: 'image/jpeg',
      sizeBytes: 128,
      sha256: 'source-file-hash',
      createdAt: DateTime.parse(_timestamp),
    ));
    await source.customStatement(
      "UPDATE media_assets SET ocr_text = 'source-only-ocr' WHERE id = 'media-source'",
    );
    final exported = await backup.exportJson();
    final document = BackupFormat.parse(exported);
    expect(document['coverage'], BackupFormat.coverage);
    final privacy = (document['coverage'] as Map)['privacy'] as Map;
    expect(privacy['may_contain_personal_information'], isTrue);
    expect(privacy['upload_required'], isFalse);
    expect(document['media_assets'], isNull);
    expect(exported, isNot(contains('/source-only/manual.jpg')));
    expect(exported, isNot(contains('source-only-ocr')));
    await BackupRepository(target).importJson(exported);
    expect(await target.select(target.mediaAssets).get(), isEmpty);
    expect(await source.select(source.mediaAssets).get(), hasLength(1));
  });

  test('核心业务段与缓存仍可恢复，同步版本和设备元数据不随业务记录迁移', () async {
    final document = _document(3, _businessSettings)
      ..['products'] = [
        {..._product(), 'server_version': 99, 'updated_by_device': 'source-device'},
      ]
      ..['batches'] = [
        {
          'id': 'batch-new',
          'product_id': 'product-new',
          'date_source': 'manual',
          'date_precision': 'day',
          'initial_quantity': 2,
          'remaining_quantity': 1,
          'is_opened': false,
          'is_discarded': false,
          'created_at': _timestamp,
          'updated_at': _timestamp,
        },
      ]
      ..['stock_movements'] = [
        {
          'id': 'movement-new',
          'product_id': 'product-new',
          'batch_id': 'batch-new',
          'type': 'consume',
          'quantity': -1,
          'created_at': _timestamp,
        },
      ]
      ..['shopping_entries'] = [
        {
          'id': 'shopping-new',
          'product_id': 'product-new',
          'item_name': '备份物品',
          'reason': '手动添加',
          'target_quantity': 1,
          'is_completed': false,
          'created_at': _timestamp,
          'updated_at': _timestamp,
        },
      ]
      ..['reminder_acknowledgements'] = [
        {
          'reminder_key': 'product-new:low-stock',
          'fingerprint': 'threshold:1',
          'acknowledged_at': _timestamp,
        },
      ]
      ..['barcode_lookup_cache'] = [
        {
          'barcode': '12345678',
          'payload_json': '{"name":"备份物品"}',
          'source': 'test-cache',
          'fetched_at': _timestamp,
          'expires_at': '2026-11-03T00:00:00.000Z',
        },
      ];
    final report = await BackupRepository(target).importJson(jsonEncode(document));
    expect(report.imported, 6 + _businessSettings.length);
    expect(report.skipped, 0);
    final products = await target.select(target.products).get();
    expect(products, hasLength(1));
    expect(products.single.serverVersion, 0);
    expect(products.single.updatedByDevice, isNull);
    expect(await target.select(target.productBatches).get(), hasLength(1));
    expect(await target.select(target.stockMovements).get(), hasLength(1));
    expect(await target.select(target.shoppingEntries).get(), hasLength(1));
    expect(await target.select(target.reminderAcknowledgments).get(), hasLength(1));
    expect(await target.select(target.barcodeLookupCache).get(), hasLength(1));
    final reexport = BackupFormat.parse(await BackupRepository(target).exportJson());
    expect(BackupFormat.records(reexport, 'products').single,
        isNot(contains('server_version')));
    expect(BackupFormat.records(reexport, 'products').single,
        isNot(contains('updated_by_device')));
  });

  test('不信任备份的覆盖声明或附加媒体段，不据此恢复身份或路径', () async {
    final document = _document(3, _excludedSettings)
      ..['coverage'] = {'kind': 'full', 'media_restore_supported': true}
      ..['media_assets'] = [{'local_path': '/untrusted/source.jpg'}];
    await BackupRepository(target).importJson(jsonEncode(document));
    expect(await _storedSettings(target), isEmpty);
    expect(await target.select(target.mediaAssets).get(), isEmpty);
  });

  for (final value in [
    '{"apiKey":"inline-secret"',
    '{"apiKey":"inline-secret"}',
    '["inline-secret"]',
    '[{"id":123,"apiKey":"inline-secret"}]',
  ]) {
    test('不安全服务配置先校验，拒绝导入后保留目标身份及既有数据：$value', () async {
      final before = {'nas_device_id': 'target-device', 'theme': 'target-theme'};
      await _seed(target, before);
      final document = _document(3, {
        'recurring_chores_list': '[]',
        'ai_api_profiles': value,
      })..['products'] = [_product()];
      await expectLater(
        BackupRepository(target).importJson(jsonEncode(document)),
        throwsA(isA<BackupImportException>()),
      );
      expect(await _storedSettings(target), before);
      expect(await target.select(target.products).get(), isEmpty);
    });
  }

  test('损坏服务配置导出失败，不回退泄露原文且不改写数据库', () async {
    const raw = '{"apiKey":"do-not-leak"';
    await _seed(source, {'ai_api_profiles': raw, 'nas_device_id': 'source-id'});
    await expectLater(backup.exportJson(), throwsFormatException);
    expect(await _storedSettings(source), {
      'ai_api_profiles': raw,
      'nas_device_id': 'source-id',
    });
  });

  test('排除项也必须符合记录格式，末尾非法条码段不得部分写入', () async {
    final before = {'nas_device_id': 'target-id', 'theme': 'target-theme'};
    await _seed(target, before);
    for (final invalidSetting in [false, true]) {
      final document = _document(3, {
        'recurring_chores_list': '[]',
        'nas_device_id': 'source-id',
      })..['products'] = [_product()];
      if (invalidSetting) {
        (document['settings'] as List).add({
          'key': 'sync_bootstrap:old',
          'value': 123,
          'updated_at': _timestamp,
        });
      } else {
        document['barcode_lookup_cache'] = [
          {'barcode': '123', 'source': 'test', 'fetched_at': 'bad-date'},
        ];
      }
      await expectLater(
        BackupRepository(target).importJson(jsonEncode(document)),
        throwsA(isA<BackupImportException>()),
      );
      expect(await target.select(target.products).get(), isEmpty);
      expect(await _storedSettings(target), before);
    }
  });

  test('写入阶段 SQL 失败整批回滚，已有身份、配置和同步记录均保留', () async {
    final before = {
      'nas_device_id': 'target-id',
      'sync_local_workspace_id': 'target-workspace',
      'sync_bootstrap:target': 'ready',
      'theme': 'target-theme',
    };
    await _seed(target, before);
    await target.into(target.syncStates).insert(SyncStatesCompanion.insert(
      scopeId: 'family:target',
    ));
    final syncBefore = await target.select(target.syncStates).get();
    // Inject a real write failure after products and an earlier setting insert.
    await target.customStatement('''
      CREATE TEMP TRIGGER fail_backup_setting BEFORE INSERT ON app_settings
      WHEN NEW.key = 'reject_on_write'
      BEGIN SELECT RAISE(ABORT, 'simulated backup failure'); END
    ''');
    final document = _document(3, {
      'recurring_chores_list': '[]',
      'reject_on_write': 'trigger-failure',
      'nas_device_id': 'source-id',
    })..['products'] = [_product()];
    await expectLater(
      BackupRepository(target).importJson(jsonEncode(document)),
      throwsA(predicate<Object>((error) =>
          error.toString().contains('simulated backup failure'))),
    );
    expect(await target.select(target.products).get(), isEmpty);
    expect(await _storedSettings(target), before);
    expect(await target.select(target.syncStates).get(), syncBefore);
  });
}
