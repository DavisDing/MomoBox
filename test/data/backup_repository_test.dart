import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/backup_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/reminder_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

Map<String, Object?> validProduct() => {
      'id': 'product-1',
      'name': '维生素 C',
      'category': '药品保健',
      'brand': null,
      'specification': null,
      'barcode': null,
      'location': null,
      'unit': '件',
      'low_stock_threshold': 1,
      'created_at': '2026-09-02T08:00:00.000',
      'updated_at': '2026-09-02T08:00:00.000',
    };

Map<String, Object?> batchForUnknownProduct() => {
      'id': 'batch-1',
      'product_id': 'missing-product',
      'batch_no': 'B-001',
      'production_date': null,
      'expiry_date': null,
      'date_source': 'manual',
      'date_precision': 'day',
      'initial_quantity': 1,
      'remaining_quantity': 1,
      'is_opened': false,
      'is_discarded': false,
      'created_at': '2026-09-02T08:00:00.000',
      'updated_at': '2026-09-02T08:00:00.000',
    };

Map<String, Object?> backupWithInvalidReference() => {
      'format': 'momobox-backup',
      'version': 1,
      'products': [validProduct()],
      'batches': [batchForUnknownProduct()],
      'stock_movements': [],
      'shopping_entries': [],
      'settings': [],
    };

void main() {
  late AppDatabase database;
  late BackupRepository repository;
  final extraDatabases = <AppDatabase>[];

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = BackupRepository(database);
  });

  tearDown(() async {
    await database.close();
    for (final extraDatabase in extraDatabases) {
      await extraDatabase.close();
    }
    extraDatabases.clear();
  });

  test('仅配置主 AI 时，空副服务和兜底设置可导出恢复', () async {
    final settings = SettingsRepository(database);
    final values = {
      'ai_api_endpoint': 'https://example.invalid/v1',
      'ai_model': 'primary-model',
      'ai_secondary_endpoint': '',
      'ai_secondary_model': '',
      'ai_fallback_endpoint': '',
      'ai_fallback_model': '',
      'ai_secondary_profile_id': '',
      'ai_fallback_profile_id': '',
    };
    for (final entry in values.entries) {
      await settings.setValue(entry.key, entry.value);
    }
    final target = AppDatabase.forTesting(NativeDatabase.memory());
    extraDatabases.add(target);
    final restore = BackupRepository(target);
    final backup = await repository.exportJson();
    final report = await restore.importJson(backup);
    expect(report.imported, values.length);
    final rows = await target.select(target.appSettings).get();
    expect({for (final row in rows) row.key: row.value}, values);
    final repeated = await restore.importJson(backup);
    expect(repeated.imported, 0);
    expect(repeated.skipped, values.length);
  });

  for (final matchesLocalBatch in [false, true]) {
    test('重复批次保留本地商品关系：新流水匹配本地=$matchesLocalBatch', () async {
      final local = backupWithInvalidReference()
        ..['batches'] = [{...batchForUnknownProduct(), 'product_id': 'product-1'}];
      await repository.importJson(jsonEncode(local));
      final incoming = backupWithInvalidReference()
        ..['products'] = [{...validProduct(), 'id': 'product-2'}]
        ..['batches'] = [{...batchForUnknownProduct(), 'product_id': 'product-2'}]
        ..['stock_movements'] = [
          {
            'id': 'movement-new',
            'product_id': matchesLocalBatch ? 'product-1' : 'product-2',
            'batch_id': 'batch-1',
            'type': 'intake',
            'quantity': 1,
            'note': null,
            'created_at': '2026-09-15T00:00:00.000',
          },
        ];
      if (matchesLocalBatch) {
        final report = await repository.importJson(jsonEncode(incoming));
        expect(report.imported, 2);
        expect(report.skipped, 1);
        final movement = await database.select(database.stockMovements).getSingle();
        expect(movement.productId, 'product-1');
      } else {
        await expectLater(
          repository.importJson(jsonEncode(incoming)),
          throwsA(isA<BackupImportException>()),
        );
        expect(await database.select(database.stockMovements).get(), isEmpty);
        expect(await database.select(database.products).get(), hasLength(1));
      }
      final batch = await database.select(database.productBatches).getSingle();
      expect(batch.productId, 'product-1');
    });
  }

  test('跳过的批次、流水和采购记录不参与新引用校验', () async {
    final inventory = InventoryRepository(database);
    await inventory.createProductWithBatch(const IntakeDraft(
      name: '本地物品', category: '其他物品', quantity: 1,
    ));
    await database.into(database.shoppingEntries).insert(ShoppingEntriesCompanion.insert(
      id: 'shopping-existing', itemName: '本地采购项',
      createdAt: DateTime(2026, 9, 15), updatedAt: DateTime(2026, 9, 15),
    ));
    final backup = jsonDecode(await repository.exportJson()) as Map<String, dynamic>;
    for (final row in backup['batches'] as List) {
      (row as Map<String, dynamic>)['product_id'] = 'missing-product';
    }
    for (final row in backup['stock_movements'] as List) {
      (row as Map<String, dynamic>)['product_id'] = 'missing-product';
      row['batch_id'] = 'missing-batch';
    }
    for (final row in backup['shopping_entries'] as List) {
      (row as Map<String, dynamic>)['product_id'] = 'missing-product';
    }
    final report = await repository.importJson(jsonEncode(backup));
    expect(report.imported, 0);
    expect(report.skipped, 4);
  });

  test('引用不存在时返回带 section/index/message 的失败明细并保持空库', () async {
    try {
      await repository.importJson(jsonEncode(backupWithInvalidReference()));
      fail('应拒绝不存在的商品引用');
    } on BackupImportException catch (error) {
      expect(error.failures, hasLength(1));
      expect(error.failures.single.section, 'batches');
      expect(error.failures.single.index, 1);
      expect(error.failures.single.message, contains('missing-product'));
    }

    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
  });

  test('已耗尽批次报废后仍可完成导出导入往返', () async {
    final inventory = InventoryRepository(database);
    final productId = await inventory.createProductWithBatch(
      const IntakeDraft(
        name: '往返测试物品',
        category: '其他物品',
        quantity: 1,
      ),
    );
    final batch = (await database.select(database.productBatches).get()).single;
    await inventory.consumeBatch(productId, batch.id, 1);
    await inventory.discardBatch(batch.id);

    final content = await repository.exportJson();
    final importedDatabase = AppDatabase.forTesting(NativeDatabase.memory());
    extraDatabases.add(importedDatabase);
    final imported = await BackupRepository(importedDatabase).importJson(content);

    expect(imported.imported, 4);
    expect(await importedDatabase.select(importedDatabase.products).get(), hasLength(1));
    expect(await importedDatabase.select(importedDatabase.productBatches).get(), hasLength(1));
    expect(await importedDatabase.select(importedDatabase.stockMovements).get(), hasLength(2));
  });

  test('AI 配置备份和导入不会保留 API Key', () async {
    await database.into(database.appSettings).insert(
          AppSettingsCompanion.insert(
            key: 'ai_api_profiles',
            value: jsonEncode([
              {'id': 'profile-1', 'name': '测试', 'apiKey': 'secret-value'},
            ]),
            updatedAt: DateTime(2026, 9, 11),
          ),
        );

    final exported = jsonDecode(await repository.exportJson()) as Map<String, dynamic>;
    final settings = (exported['settings'] as List).cast<Map<String, dynamic>>();
    final profileSetting = settings.singleWhere((row) => row['key'] == 'ai_api_profiles');
    expect(profileSetting['value'], isNot(contains('secret-value')));

    final target = AppDatabase.forTesting(NativeDatabase.memory());
    extraDatabases.add(target);
    await BackupRepository(target).importJson(jsonEncode({
      'format': 'momobox-backup',
      'version': 3,
      'products': [],
      'batches': [],
      'stock_movements': [],
      'shopping_entries': [],
      'settings': [
        {
          'key': 'ai_api_profiles',
          'value': jsonEncode([
            {'id': 'profile-1', 'apiKey': 'must-not-import'},
          ]),
          'updated_at': '2026-09-11T00:00:00.000',
        },
      ],
      'reminder_acknowledgements': [],
      'barcode_lookup_cache': [],
    }));
    final stored = (await target.select(target.appSettings).getSingle()).value;
    expect(stored, isNot(contains('must-not-import')));
  });

  test('备份会导出并恢复提醒已处理记录', () async {
    final reminderRepository = ReminderRepository(database);
    await reminderRepository.acknowledge(
      reminderKey: 'product-1:low-stock',
      fingerprint: 'threshold:1',
    );
    final backup = await repository.exportJson();
    expect(backup, contains('reminder_acknowledgements'));

    final restoreDatabase = AppDatabase.forTesting(NativeDatabase.memory());
    extraDatabases.add(restoreDatabase);
    final restoreRepository = BackupRepository(restoreDatabase);
    await restoreRepository.importJson(backup);
    final records =
        await restoreDatabase.select(restoreDatabase.reminderAcknowledgments).get();
    expect(records, hasLength(1));
    expect(records.single.reminderKey, 'product-1:low-stock');
  });
}
