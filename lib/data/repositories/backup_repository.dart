import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/backup/backup_format.dart';

class ImportFailure {
  const ImportFailure({
    required this.section,
    required this.index,
    required this.message,
  });

  final String section;
  final int index;
  final String message;

  @override
  String toString() => '$section 第 $index 条：$message';
}

class BackupImportException implements Exception {
  const BackupImportException(this.failures);

  final List<ImportFailure> failures;

  @override
  String toString() =>
      '备份导入失败：\n${failures.map((failure) => '• $failure').join('\n')}';
}

class ImportReport {
  const ImportReport({
    required this.imported,
    required this.skipped,
    this.failures = const [],
  });

  final int imported;
  final int skipped;
  final List<ImportFailure> failures;

  bool get hasFailures => failures.isNotEmpty;
}

class BackupRepository {
  BackupRepository(this._database);

  final AppDatabase _database;

  Future<String> exportJson() async {
    final products = await _database.select(_database.products).get();
    final batches = await _database.select(_database.productBatches).get();
    final movements = await _database.select(_database.stockMovements).get();
    final shopping = await _database.select(_database.shoppingEntries).get();
    final settings = await _database.select(_database.appSettings).get();
    final acknowledgements = await _database.select(_database.reminderAcknowledgments).get();
    final barcodeCache = await _database.select(_database.barcodeLookupCache).get();

    return const JsonEncoder.withIndent('  ').convert({
      'format': 'momobox-backup',
      'version': 3,
      'exported_at': DateTime.now().toIso8601String(),
      'products': products.map(_productToJson).toList(),
      'batches': batches.map(_batchToJson).toList(),
      'stock_movements': movements.map(_movementToJson).toList(),
      'shopping_entries': shopping.map(_shoppingToJson).toList(),
      'settings': settings.map(_settingToJson).toList(),
      'reminder_acknowledgements': acknowledgements.map(_acknowledgementToJson).toList(),
      'barcode_lookup_cache': barcodeCache.map(_barcodeCacheToJson).toList(),
    });
  }

  Future<ImportReport> importJson(String content) async {
    final document = BackupFormat.parse(content);
    final products = _records(document, 'products');
    final batches = _records(document, 'batches');
    final movements = _records(document, 'stock_movements');
    final shopping = _records(document, 'shopping_entries');
    final settings = _records(document, 'settings');
    final acknowledgements = _records(document, 'reminder_acknowledgements');
    final barcodeCache = _records(document, 'barcode_lookup_cache');
    final failures = await _validateReferences(
      products: products,
      batches: batches,
      movements: movements,
      shopping: shopping,
      settings: settings,
      acknowledgements: acknowledgements,
      barcodeCache: barcodeCache,
    );
    if (failures.isNotEmpty) {
      throw BackupImportException(List.unmodifiable(failures));
    }

    var imported = 0;
    var skipped = 0;

    await _database.transaction(() async {
      for (final raw in products) {
        final row = raw;
        if (await _exists(_database.products, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.products).insert(_productFromJson(row));
        imported++;
      }
      for (final raw in batches) {
        final row = raw;
        if (await _exists(_database.productBatches, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.productBatches).insert(_batchFromJson(row));
        imported++;
      }
      for (final raw in movements) {
        final row = raw;
        if (await _exists(_database.stockMovements, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.stockMovements).insert(_movementFromJson(row));
        imported++;
      }
      for (final raw in shopping) {
        final row = raw;
        if (await _exists(_database.shoppingEntries, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.shoppingEntries).insert(_shoppingFromJson(row));
        imported++;
      }
      for (final raw in settings) {
        final row = raw;
        if (await _exists(_database.appSettings, row['key'] as String, column: 'key')) {
          skipped++;
          continue;
        }
        await _database.into(_database.appSettings).insert(_settingFromJson(row));
        imported++;
      }
      for (final raw in acknowledgements) {
        final row = raw;
        if (await _exists(
          _database.reminderAcknowledgments,
          row['reminder_key'] as String,
          column: 'reminder_key',
        )) {
          skipped++;
          continue;
        }
        await _database.into(_database.reminderAcknowledgments).insert(_acknowledgementFromJson(row));
        imported++;
      }
      for (final raw in barcodeCache) {
        final row = raw;
        if (await _exists(_database.barcodeLookupCache, row['barcode'] as String, column: 'barcode')) {
          skipped++;
          continue;
        }
        await _database.into(_database.barcodeLookupCache).insert(_barcodeCacheFromJson(row));
        imported++;
      }
    });
    return ImportReport(imported: imported, skipped: skipped);
  }

  List<Map<String, dynamic>> _records(
    Map<String, dynamic> document,
    String section,
  ) {
    try {
      return BackupFormat.records(document, section);
    } on FormatException catch (error) {
      throw BackupImportException([
        ImportFailure(section: section, index: 0, message: error.message),
      ]);
    }
  }

  Future<List<ImportFailure>> _validateReferences({
    required List<Map<String, dynamic>> products,
    required List<Map<String, dynamic>> batches,
    required List<Map<String, dynamic>> movements,
    required List<Map<String, dynamic>> shopping,
    required List<Map<String, dynamic>> settings,
    required List<Map<String, dynamic>> acknowledgements,
    required List<Map<String, dynamic>> barcodeCache,
  }) async {
    final existingProducts =
        (await _database.select(_database.products).get()).map((row) => row.id).toSet();
    final existingBatches = await _database.select(_database.productBatches).get();
    final existingBatchProductById = {
      for (final row in existingBatches) row.id: row.productId,
    };
    final failures = <ImportFailure>[];

    void checkUnique(String section, List<Map<String, dynamic>> rows, String field) {
      final seen = <String>{};
      for (var i = 0; i < rows.length; i++) {
        final value = rows[i][field] as String;
        if (!seen.add(value)) {
          failures.add(ImportFailure(
            section: section,
            index: i + 1,
            message: '备份内部存在重复的 $field：$value。',
          ));
        }
      }
    }

    checkUnique('products', products, 'id');
    checkUnique('batches', batches, 'id');
    checkUnique('stock_movements', movements, 'id');
    checkUnique('shopping_entries', shopping, 'id');
    checkUnique('settings', settings, 'key');
    checkUnique('reminder_acknowledgements', acknowledgements, 'reminder_key');
    checkUnique('barcode_lookup_cache', barcodeCache, 'barcode');

    final incomingProducts = products.map((row) => row['id'] as String).toSet();
    final allProductIds = {...existingProducts, ...incomingProducts};
    final incomingBatchById = {
      for (final row in batches) row['id'] as String: row,
    };
    final allBatchIds = {...existingBatchProductById.keys, ...incomingBatchById.keys};

    for (var i = 0; i < batches.length; i++) {
      final row = batches[i];
      final productId = row['product_id'] as String;
      if (!allProductIds.contains(productId)) {
        failures.add(ImportFailure(
          section: 'batches',
          index: i + 1,
          message: '引用的商品不存在：$productId。',
        ));
      }
    }

    for (var i = 0; i < movements.length; i++) {
      final row = movements[i];
      final productId = row['product_id'] as String;
      if (!allProductIds.contains(productId)) {
        failures.add(ImportFailure(
          section: 'stock_movements',
          index: i + 1,
          message: '引用的商品不存在：$productId。',
        ));
      }
      final batchId = row['batch_id'] as String?;
      if (batchId != null) {
        if (!allBatchIds.contains(batchId)) {
          failures.add(ImportFailure(
            section: 'stock_movements',
            index: i + 1,
            message: '引用的批次不存在：$batchId。',
          ));
        } else {
          final batchProductId =
              incomingBatchById[batchId]?['product_id'] as String? ??
              existingBatchProductById[batchId];
          if (batchProductId != null && batchProductId != productId) {
            failures.add(ImportFailure(
              section: 'stock_movements',
              index: i + 1,
              message: '流水引用的批次不属于商品：$productId。',
            ));
          }
        }
      }
    }

    for (var i = 0; i < shopping.length; i++) {
      final productId = shopping[i]['product_id'] as String?;
      if (productId != null && !allProductIds.contains(productId)) {
        failures.add(ImportFailure(
          section: 'shopping_entries',
          index: i + 1,
          message: '引用的商品不存在：$productId。',
        ));
      }
    }
    return failures;
  }

  Future<bool> _exists<T extends Table>(
    TableInfo<T, dynamic> table,
    String value, {
    String column = 'id',
  }) async {
    // 所有 P0 表均以稳定 UUID/setting key 为主键；导入默认不覆盖已有记录。
    final result = await _database.customSelect(
      'SELECT 1 FROM ${table.actualTableName} WHERE $column = ? LIMIT 1',
      variables: [Variable<String>(value)],
    ).get();
    return result.isNotEmpty;
  }

  Map<String, Object?> _productToJson(ProductRecord row) => {
        'id': row.id,
        'name': row.name,
        'category': row.category,
        'brand': row.brand,
        'specification': row.specification,
        'barcode': row.barcode,
        'location': row.location,
        'unit': row.unit,
        'low_stock_threshold': row.lowStockThreshold,
        'created_at': row.createdAt.toIso8601String(),
        'updated_at': row.updatedAt.toIso8601String(),
      };

  Map<String, Object?> _batchToJson(BatchRecord row) => {
        'id': row.id,
        'product_id': row.productId,
        'batch_no': row.batchNo,
        'production_date': row.productionDate?.toIso8601String(),
        'expiry_date': row.expiryDate?.toIso8601String(),
        'date_source': row.dateSource,
        'date_precision': row.datePrecision,
        'initial_quantity': row.initialQuantity,
        'remaining_quantity': row.remainingQuantity,
        'is_opened': row.isOpened,
        'is_discarded': row.isDiscarded,
        'created_at': row.createdAt.toIso8601String(),
        'updated_at': row.updatedAt.toIso8601String(),
      };

  Map<String, Object?> _movementToJson(StockMovementRecord row) => {
        'id': row.id,
        'product_id': row.productId,
        'batch_id': row.batchId,
        'type': row.type,
        'quantity': row.quantity,
        'note': row.note,
        'created_at': row.createdAt.toIso8601String(),
      };

  Map<String, Object?> _shoppingToJson(ShoppingEntryRecord row) => {
        'id': row.id,
        'product_id': row.productId,
        'item_name': row.itemName,
        'category': row.category,
        'target_quantity': row.targetQuantity,
        'reason': row.reason,
        'is_completed': row.isCompleted,
        'created_at': row.createdAt.toIso8601String(),
        'updated_at': row.updatedAt.toIso8601String(),
      };

  Map<String, Object?> _settingToJson(AppSettingRecord row) => {
        'key': row.key,
        'value': row.value,
        'updated_at': row.updatedAt.toIso8601String(),
      };

  Map<String, Object?> _acknowledgementToJson(ReminderAcknowledgmentRecord row) => {
        'reminder_key': row.reminderKey,
        'fingerprint': row.fingerprint,
        'acknowledged_at': row.acknowledgedAt.toIso8601String(),
      };

  ProductsCompanion _productFromJson(Map<String, dynamic> row) => ProductsCompanion.insert(
        id: row['id'] as String,
        name: row['name'] as String,
        category: row['category'] as String,
        brand: Value(row['brand'] as String?),
        specification: Value(row['specification'] as String?),
        barcode: Value(row['barcode'] as String?),
        location: Value(row['location'] as String?),
        unit: row['unit'] as String,
        lowStockThreshold: row['low_stock_threshold'] as int,
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  ProductBatchesCompanion _batchFromJson(Map<String, dynamic> row) =>
      ProductBatchesCompanion.insert(
        id: row['id'] as String,
        productId: row['product_id'] as String,
        batchNo: Value(row['batch_no'] as String?),
        productionDate: Value(_date(row['production_date'])),
        expiryDate: Value(_date(row['expiry_date'])),
        dateSource: row['date_source'] as String,
        datePrecision: row['date_precision'] as String,
        initialQuantity: row['initial_quantity'] as int,
        remainingQuantity: row['remaining_quantity'] as int,
        isOpened: Value(row['is_opened'] as bool),
        isDiscarded: Value(row['is_discarded'] as bool),
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  StockMovementsCompanion _movementFromJson(Map<String, dynamic> row) =>
      StockMovementsCompanion.insert(
        id: row['id'] as String,
        productId: row['product_id'] as String,
        batchId: Value(row['batch_id'] as String?),
        type: row['type'] as String,
        quantity: row['quantity'] as int,
        note: Value(row['note'] as String?),
        createdAt: DateTime.parse(row['created_at'] as String),
      );

  ShoppingEntriesCompanion _shoppingFromJson(Map<String, dynamic> row) =>
      ShoppingEntriesCompanion.insert(
        id: row['id'] as String,
        productId: Value(row['product_id'] as String?),
        itemName: row['item_name'] as String,
        category: Value(row['category'] as String?),
        targetQuantity: Value(row['target_quantity'] as int),
        reason: Value(row['reason'] as String),
        isCompleted: Value(row['is_completed'] as bool),
        createdAt: DateTime.parse(row['created_at'] as String),
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  AppSettingsCompanion _settingFromJson(Map<String, dynamic> row) =>
      AppSettingsCompanion.insert(
        key: row['key'] as String,
        value: row['value'] as String,
        updatedAt: DateTime.parse(row['updated_at'] as String),
      );

  ReminderAcknowledgmentsCompanion _acknowledgementFromJson(
    Map<String, dynamic> row,
  ) =>
      ReminderAcknowledgmentsCompanion.insert(
        reminderKey: row['reminder_key'] as String,
        fingerprint: row['fingerprint'] as String,
        acknowledgedAt: DateTime.parse(row['acknowledged_at'] as String),
      );

  Map<String, Object?> _barcodeCacheToJson(BarcodeCacheRecord row) => {
        'barcode': row.barcode,
        'payload_json': row.payloadJson,
        'source': row.source,
        'fetched_at': row.fetchedAt.toIso8601String(),
        'expires_at': row.expiresAt.toIso8601String(),
      };

  BarcodeLookupCacheCompanion _barcodeCacheFromJson(Map<String, dynamic> row) => BarcodeLookupCacheCompanion.insert(
        barcode: row['barcode'] as String,
        payloadJson: Value(row['payload_json'] as String?),
        source: row['source'] as String,
        fetchedAt: DateTime.parse(row['fetched_at'] as String),
        expiresAt: DateTime.parse(row['expires_at'] as String),
      );

  DateTime? _date(Object? value) => value is String ? DateTime.parse(value) : null;
}
