import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/backup_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
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
}
