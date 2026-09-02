import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/inventory/batch_consumption.dart';
import '../../domain/inventory/fefo.dart';
import '../../domain/models/inventory_models.dart';

class InventoryRepository {
  InventoryRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<List<InventoryItem>> watchInventory() {
    return _database.select(_database.products).watch().asyncMap(_loadInventory);
  }

  Future<List<InventoryItem>> loadInventory([List<ProductRecord>? source]) async {
    final products = source ?? await _database.select(_database.products).get();
    final items = await Future.wait(products.map(_toInventoryItem));
    items.sort((a, b) {
      final aDate = a.nearestDatedBatch?.expiryDate;
      final bDate = b.nearestDatedBatch?.expiryDate;
      if (aDate == null && bDate == null) return a.name.compareTo(b.name);
      if (aDate == null) return 1;
      if (bDate == null) return -1;
      return aDate.compareTo(bDate);
    });
    return items;
  }

  Future<InventoryItem> _toInventoryItem(ProductRecord product) async {
    final batches = await (_database.select(_database.productBatches)
          ..where((batch) => batch.productId.equals(product.id)))
        .get();
    return InventoryItem(
      id: product.id,
      name: product.name,
      category: product.category,
      brand: product.brand,
      specification: product.specification,
      barcode: product.barcode,
      location: product.location,
      unit: product.unit,
      lowStockThreshold: product.lowStockThreshold,
      batches: batches
          .map(
            (batch) => InventoryBatch(
              id: batch.id,
              productId: batch.productId,
              batchNo: batch.batchNo,
              initialQuantity: batch.initialQuantity,
              remainingQuantity: batch.remainingQuantity,
              isDiscarded: batch.isDiscarded,
              expiryDate: batch.expiryDate,
              productionDate: batch.productionDate,
            ),
          )
          .toList(growable: false),
    );
  }

  Future<List<StockMovement>> loadMovements(String productId) async {
    final rows = await (_database.select(_database.stockMovements)
          ..where((movement) => movement.productId.equals(productId))
          ..orderBy([(movement) => OrderingTerm.desc(movement.createdAt)]))
        .get();
    return rows
        .map(
          (row) => StockMovement(
            id: row.id,
            type: row.type,
            quantity: row.quantity,
            note: row.note,
            createdAt: row.createdAt,
          ),
        )
        .toList(growable: false);
  }

  Future<List<ProductMatchCandidate>> findMatchingProducts(IntakeDraft draft) async {
    final barcode = _trimToNull(draft.barcode);
    final products = await _database.select(_database.products).get();
    return products
        .where((product) {
          if (barcode != null) return _trimToNull(product.barcode) == barcode;
          return product.name.trim().toLowerCase() == draft.name.trim().toLowerCase() &&
              product.category == draft.category &&
              _sameText(product.brand, draft.brand) &&
              _sameText(product.specification, draft.specification);
        })
        .map(
          (product) => ProductMatchCandidate(
            id: product.id,
            name: product.name,
            category: product.category,
            brand: product.brand,
            specification: product.specification,
            barcode: product.barcode,
          ),
        )
        .toList(growable: false);
  }

  Future<String> createProductWithBatch(
    IntakeDraft draft, {
    String? existingProductId,
  }) async {
    if (draft.quantity < 1) throw ArgumentError.value(draft.quantity, 'quantity');
    if (draft.lowStockThreshold < 1) {
      throw ArgumentError.value(draft.lowStockThreshold, 'lowStockThreshold');
    }
    final now = DateTime.now();
    final batchId = _uuid.v4();

    return _database.transaction(() async {
      final productId = existingProductId ?? _uuid.v4();
      final existing = existingProductId == null
          ? null
          : await (_database.select(_database.products)
                ..where((product) => product.id.equals(existingProductId)))
              .getSingleOrNull();
      if (existingProductId != null && existing == null) {
        throw StateError('要合并的商品不存在，可能已被删除。');
      }
      if (existing == null) {
        await _database.into(_database.products).insert(
              ProductsCompanion.insert(
                id: productId,
                name: draft.name.trim(),
                category: draft.category,
                brand: Value(_trimToNull(draft.brand)),
                specification: Value(_trimToNull(draft.specification)),
                barcode: Value(_trimToNull(draft.barcode)),
                location: Value(_trimToNull(draft.location)),
                unit: draft.unit,
                lowStockThreshold: draft.lowStockThreshold,
                createdAt: now,
                updatedAt: now,
              ),
            );
      } else {
        await (_database.update(_database.products)
              ..where((product) => product.id.equals(productId)))
            .write(ProductsCompanion(updatedAt: Value(now)));
      }
      await _insertBatch(
        batchId: batchId,
        productId: productId,
        batchNo: draft.batchNo,
        productionDate: draft.productionDate,
        expiryDate: draft.expiryDate,
        dateSource: draft.dateSource,
        datePrecision: draft.datePrecision,
        quantity: draft.quantity,
        now: now,
      );
      await _insertMovement(
        productId: productId,
        batchId: batchId,
        type: 'intake',
        quantity: draft.quantity,
        note: '手动入库',
        now: now,
      );
      return productId;
    });
  }

  Future<String> addBatch({
    required String productId,
    required int quantity,
    String? batchNo,
    DateTime? productionDate,
    DateTime? expiryDate,
    String dateSource = 'manual',
    String datePrecision = 'day',
  }) async {
    if (quantity < 1) throw ArgumentError.value(quantity, 'quantity');
    final now = DateTime.now();
    final batchId = _uuid.v4();
    await _database.transaction(() async {
      await _insertBatch(
        batchId: batchId,
        productId: productId,
        batchNo: batchNo,
        productionDate: productionDate,
        expiryDate: expiryDate,
        dateSource: dateSource,
        datePrecision: datePrecision,
        quantity: quantity,
        now: now,
      );
      await _insertMovement(
        productId: productId,
        batchId: batchId,
        type: 'intake',
        quantity: quantity,
        note: '补充批次',
        now: now,
      );
      await (_database.update(_database.products)
            ..where((product) => product.id.equals(productId)))
          .write(ProductsCompanion(updatedAt: Value(now)));
    });
    return batchId;
  }

  Future<void> consumeByFefo(String productId, int quantity) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final records = await (_database.select(_database.productBatches)
            ..where((batch) => batch.productId.equals(productId)))
          .get();
      final batches = records
          .map(
            (batch) => InventoryBatch(
              id: batch.id,
              productId: batch.productId,
              batchNo: batch.batchNo,
              initialQuantity: batch.initialQuantity,
              remainingQuantity: batch.remainingQuantity,
              isDiscarded: batch.isDiscarded,
              expiryDate: batch.expiryDate,
              productionDate: batch.productionDate,
            ),
          )
          .toList(growable: false);
      final allocations = Fefo.allocate(batches, quantity, today: now);
      for (final allocation in allocations) {
        final current = records.firstWhere((record) => record.id == allocation.batchId);
        await (_database.update(_database.productBatches)
              ..where((batch) => batch.id.equals(allocation.batchId)))
            .write(
          ProductBatchesCompanion(
            remainingQuantity: Value(current.remainingQuantity - allocation.quantity),
            updatedAt: Value(now),
          ),
        );
        await _insertMovement(
          productId: productId,
          batchId: allocation.batchId,
          type: 'consume',
          quantity: -allocation.quantity,
          note: '按最早到期优先消耗',
          now: now,
        );
      }
      await (_database.update(_database.products)
            ..where((product) => product.id.equals(productId)))
          .write(ProductsCompanion(updatedAt: Value(now)));
    });
  }

  Future<void> consumeBatch(
    String productId,
    String batchId,
    int quantity,
  ) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final records = await (_database.select(_database.productBatches)
            ..where((batch) => batch.id.equals(batchId)))
          .get();
      if (records.isEmpty || records.single.productId != productId) {
        throw StateError('找不到要消耗的批次。');
      }
      final record = records.single;
      final batch = InventoryBatch(
        id: record.id,
        productId: record.productId,
        batchNo: record.batchNo,
        initialQuantity: record.initialQuantity,
        remainingQuantity: record.remainingQuantity,
        isDiscarded: record.isDiscarded,
        expiryDate: record.expiryDate,
        productionDate: record.productionDate,
      );
      BatchConsumption.validate(batch, quantity, today: now);
      await (_database.update(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId)))
          .write(
        ProductBatchesCompanion(
          remainingQuantity: Value(record.remainingQuantity - quantity),
          updatedAt: Value(now),
        ),
      );
      await (_database.update(_database.products)
            ..where((product) => product.id.equals(productId)))
          .write(ProductsCompanion(updatedAt: Value(now)));
      await _insertMovement(
        productId: productId,
        batchId: batchId,
        type: 'consume',
        quantity: -quantity,
        note: '指定批次消耗',
        now: now,
      );
    });
  }

  Future<void> replenishBatch(String batchId, int quantity) async {
    if (quantity < 1) throw ArgumentError.value(quantity, 'quantity');
    final now = DateTime.now();
    await _database.transaction(() async {
      final batch = await (_database.select(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId)))
          .getSingle();
      if (batch.isDiscarded) throw StateError('已报废批次不能补充。');
      await (_database.update(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId)))
          .write(
        ProductBatchesCompanion(
          remainingQuantity: Value(batch.remainingQuantity + quantity),
          initialQuantity: Value(batch.initialQuantity + quantity),
          updatedAt: Value(now),
        ),
      );
      await (_database.update(_database.products)
            ..where((product) => product.id.equals(batch.productId)))
          .write(ProductsCompanion(updatedAt: Value(now)));
      await _insertMovement(
        productId: batch.productId,
        batchId: batch.id,
        type: 'adjustment',
        quantity: quantity,
        note: '批次补充',
        now: now,
      );
    });
  }

  Future<void> discardBatch(String batchId) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final batch = await (_database.select(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId)))
          .getSingle();
      if (batch.isDiscarded) throw StateError('批次已经报废。');
      await (_database.update(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId)))
          .write(
        ProductBatchesCompanion(
          remainingQuantity: const Value(0),
          isDiscarded: const Value(true),
          updatedAt: Value(now),
        ),
      );
      await (_database.update(_database.products)
            ..where((product) => product.id.equals(batch.productId)))
          .write(ProductsCompanion(updatedAt: Value(now)));
      // 已经耗尽的批次没有实际库存变动；不要写入 quantity = 0，
      // 因为备份格式和库存流水约束都明确禁止零数量 movement。
      if (batch.remainingQuantity > 0) {
        await _insertMovement(
          productId: batch.productId,
          batchId: batch.id,
          type: 'discard',
          quantity: -batch.remainingQuantity,
          note: '批次报废',
          now: now,
        );
      }
    });
  }

  bool _sameText(String? left, String? right) =>
      _trimToNull(left)?.toLowerCase() == _trimToNull(right)?.toLowerCase();

  Future<void> _insertBatch({
    required String batchId,
    required String productId,
    required String? batchNo,
    required DateTime? productionDate,
    required DateTime? expiryDate,
    required String dateSource,
    required String datePrecision,
    required int quantity,
    required DateTime now,
  }) async {
    await _database.into(_database.productBatches).insert(
          ProductBatchesCompanion.insert(
            id: batchId,
            productId: productId,
            batchNo: Value(_trimToNull(batchNo)),
            productionDate: Value(productionDate),
            expiryDate: Value(expiryDate),
            dateSource: dateSource,
            datePrecision: datePrecision,
            initialQuantity: quantity,
            remainingQuantity: quantity,
            createdAt: now,
            updatedAt: now,
          ),
        );
  }

  Future<void> _insertMovement({
    required String productId,
    required String? batchId,
    required String type,
    required int quantity,
    required String note,
    required DateTime now,
  }) async {
    await _database.into(_database.stockMovements).insert(
          StockMovementsCompanion.insert(
            id: _uuid.v4(),
            productId: productId,
            batchId: Value(batchId),
            type: type,
            quantity: quantity,
            note: Value(note),
            createdAt: now,
          ),
        );
  }

  String? _trimToNull(String? value) {
    final normalized = value?.trim();
    return normalized == null || normalized.isEmpty ? null : normalized;
  }
}
