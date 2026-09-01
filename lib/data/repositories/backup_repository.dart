import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';

class ImportReport {
  const ImportReport({required this.imported, required this.skipped});

  final int imported;
  final int skipped;
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

    return const JsonEncoder.withIndent('  ').convert({
      'format': 'momobox-backup',
      'version': 1,
      'exported_at': DateTime.now().toIso8601String(),
      'products': products.map(_productToJson).toList(),
      'batches': batches.map(_batchToJson).toList(),
      'stock_movements': movements.map(_movementToJson).toList(),
      'shopping_entries': shopping.map(_shoppingToJson).toList(),
      'settings': settings.map(_settingToJson).toList(),
    });
  }

  Future<ImportReport> importJson(String content) async {
    final decoded = jsonDecode(content);
    if (decoded is! Map<String, dynamic> || decoded['format'] != 'momobox-backup') {
      throw const FormatException('不是有效的 MomoBox JSON 备份文件。');
    }
    if (decoded['version'] != 1) {
      throw const FormatException('当前版本不支持该备份格式。');
    }

    final products = _asList(decoded['products']);
    final batches = _asList(decoded['batches']);
    final movements = _asList(decoded['stock_movements']);
    final shopping = _asList(decoded['shopping_entries']);
    final settings = _asList(decoded['settings']);
    var imported = 0;
    var skipped = 0;

    await _database.transaction(() async {
      for (final raw in products) {
        final row = _asMap(raw);
        if (await _exists(_database.products, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.products).insert(_productFromJson(row));
        imported++;
      }
      for (final raw in batches) {
        final row = _asMap(raw);
        if (await _exists(_database.productBatches, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.productBatches).insert(_batchFromJson(row));
        imported++;
      }
      for (final raw in movements) {
        final row = _asMap(raw);
        if (await _exists(_database.stockMovements, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.stockMovements).insert(_movementFromJson(row));
        imported++;
      }
      for (final raw in shopping) {
        final row = _asMap(raw);
        if (await _exists(_database.shoppingEntries, row['id'] as String)) {
          skipped++;
          continue;
        }
        await _database.into(_database.shoppingEntries).insert(_shoppingFromJson(row));
        imported++;
      }
      for (final raw in settings) {
        final row = _asMap(raw);
        if (await _exists(_database.appSettings, row['key'] as String, column: 'key')) {
          skipped++;
          continue;
        }
        await _database.into(_database.appSettings).insert(_settingFromJson(row));
        imported++;
      }
    });
    return ImportReport(imported: imported, skipped: skipped);
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

  List<dynamic> _asList(Object? value) => value is List ? value : const [];

  Map<String, dynamic> _asMap(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return value.cast<String, dynamic>();
    throw const FormatException('备份记录格式错误。');
  }

  DateTime? _date(Object? value) => value is String ? DateTime.parse(value) : null;
}
