import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/inventory/batch_consumption.dart';
import '../../domain/inventory/fefo.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/sync_models.dart';
import 'sync_outbox_repository.dart';

class InventoryRepository {
  InventoryRepository(
    this._database, {
    Uuid? uuid,
    SyncOutboxRepository? outbox,
    String? syncScopeId,
  })  : _uuid = uuid ?? const Uuid(),
        _outbox = outbox,
        _syncScopeId = syncScopeId;

  final AppDatabase _database;
  final Uuid _uuid;
  final SyncOutboxRepository? _outbox;
  final String? _syncScopeId;

  Stream<List<InventoryItem>> watchInventory() {
    return _database
        .customSelect(
          'SELECT 1',
          readsFrom: {_database.products, _database.productBatches},
        )
        .watch()
        .asyncMap((_) => loadInventory());
  }

  Future<List<InventoryItem>> loadInventory([List<ProductRecord>? source]) async {
    final products = source ??
        await (_database.select(_database.products)
              ..where((product) => product.deletedAt.isNull()))
            .get();
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
          ..where((batch) =>
              batch.productId.equals(product.id) & batch.deletedAt.isNull()))
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

  /// Returns the persisted product row, including a soft-deleted row.
  ///
  /// Sync composition uses this snapshot to build an outbox payload without
  /// reaching through the repository's database handle.
  Future<ProductRecord?> getProductRecord(String productId) {
    return (_database.select(_database.products)
          ..where((product) => product.id.equals(productId)))
        .getSingleOrNull();
  }

  /// Returns the persisted batch row, including a soft-deleted row.
  Future<BatchRecord?> getBatchRecord(String batchId) {
    return (_database.select(_database.productBatches)
          ..where((batch) => batch.id.equals(batchId)))
        .getSingleOrNull();
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
                unit: Value(draft.unit),
                lowStockThreshold: Value(draft.lowStockThreshold),
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
      if (existing == null) {
        await _enqueueEntityUpsert(
          entity: 'products',
          entityId: productId,
          baseVersion: 0,
          payload: _productPayload(
            name: draft.name.trim(),
            brand: _trimToNull(draft.brand),
            specification: _trimToNull(draft.specification),
            barcode: _trimToNull(draft.barcode),
          ),
          now: now,
        );
      }
      await _enqueueEntityUpsert(
        entity: 'product_batches',
        entityId: batchId,
        baseVersion: 0,
        payload: _batchPayload(
          productId: productId,
          productionDate: draft.productionDate,
          expiryDate: draft.expiryDate,
          dateSource: draft.dateSource,
          datePrecision: draft.datePrecision,
        ),
        now: now,
      );
      await _enqueueInventoryCommand(
        command: 'restock',
        operationId: _uuid.v4(),
        allocations: [
          {'batch_id': batchId, 'quantity': draft.quantity},
        ],
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
      await _enqueueEntityUpsert(
        entity: 'product_batches',
        entityId: batchId,
        baseVersion: 0,
        payload: _batchPayload(
          productId: productId,
          productionDate: productionDate,
          expiryDate: expiryDate,
          dateSource: dateSource,
          datePrecision: datePrecision,
        ),
        now: now,
      );
      await _enqueueInventoryCommand(
        command: 'restock',
        operationId: _uuid.v4(),
        allocations: [
          {'batch_id': batchId, 'quantity': quantity},
        ],
        now: now,
      );
    });
    return batchId;
  }

  Future<void> consumeByFefo(String productId, int quantity) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final records = await (_database.select(_database.productBatches)
            ..where((batch) =>
                batch.productId.equals(productId) & batch.deletedAt.isNull()))
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
      await _enqueueInventoryCommand(
        command: 'consume_allocated',
        operationId: _uuid.v4(),
        allocations: _allocationPayload(allocations),
        now: now,
      );
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
            ..where((batch) => batch.id.equals(batchId) & batch.deletedAt.isNull()))
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
      await _enqueueInventoryCommand(
        command: 'consume_allocated',
        operationId: _uuid.v4(),
        allocations: [
          {'batch_id': batchId, 'quantity': quantity},
        ],
        now: now,
      );
    });
  }

  Future<void> replenishBatch(String batchId, int quantity) async {
    if (quantity < 1) throw ArgumentError.value(quantity, 'quantity');
    final now = DateTime.now();
    await _database.transaction(() async {
      final batch = await (_database.select(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId) & entry.deletedAt.isNull()))
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
      await _enqueueInventoryCommand(
        command: 'restock',
        operationId: _uuid.v4(),
        allocations: [
          {'batch_id': batch.id, 'quantity': quantity},
        ],
        now: now,
      );
    });
  }

  Future<void> discardBatch(String batchId, {int? expectedRemainingQuantity}) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final batch = await (_database.select(_database.productBatches)
            ..where((entry) => entry.id.equals(batchId) & entry.deletedAt.isNull()))
          .getSingle();
      if (batch.isDiscarded) throw StateError('批次已经报废。');
      if (expectedRemainingQuantity != null && batch.remainingQuantity != expectedRemainingQuantity) {
        throw StateError('库存已变化，请重新确认。');
      }
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
        await _enqueueInventoryCommand(
          command: 'discard',
          operationId: _uuid.v4(),
          allocations: [
            {'batch_id': batch.id, 'quantity': batch.remainingQuantity},
          ],
          now: now,
        );
      }
    });
  }

  Future<SyncRemoteApplyStatus> applyRemoteProduct({
    required String productId,
    required Map<String, dynamic> payload,
    required int version,
    required DateTime updatedAt,
    String? updatedByDevice,
    DateTime? deletedAt,
  }) async {
    final now = updatedAt.toUtc();
    return _database.transaction(() async {
      final existing = await (_database.select(_database.products)
            ..where((product) => product.id.equals(productId)))
          .getSingleOrNull();
      if (_isStale(existing?.serverVersion, version)) {
        return SyncRemoteApplyStatus.ignoredStale;
      }
      if (_isSameVersion(existing?.serverVersion, version)) {
        return SyncRemoteApplyStatus.alreadyApplied;
      }

      final name = _stringValue(payload, 'name');
      final category = _firstString(payload, const ['category', 'category_name', 'category_id']);
      final brand = _nullableStringValue(payload, 'brand');
      final specification = _nullableStringValue(payload, 'specification');
      final barcode = _nullableStringValue(payload, 'barcode');
      final location = _firstNullableString(payload, const ['location', 'storage_location']);
      final unit = _firstString(payload, const ['unit']) ?? existing?.unit ?? '件';
      final threshold = _intValue(payload, const ['low_stock_threshold', 'lowStockThreshold']) ??
          existing?.lowStockThreshold ??
          1;
      if (threshold < 1) {
        throw const FormatException('products.low_stock_threshold must be positive');
      }
      if (existing == null && (name == null || category == null)) {
        throw const FormatException('products upsert requires name and category for a new local product');
      }

      if (existing == null) {
        await _database.into(_database.products).insert(
              ProductsCompanion.insert(
                id: productId,
                name: name!,
                category: category!,
                brand: Value(brand),
                specification: Value(specification),
                barcode: Value(barcode),
                location: Value(location),
                unit: Value(unit),
                lowStockThreshold: Value(threshold),
                createdAt: now,
                updatedAt: now,
                serverVersion: Value(version),
                deletedAt: Value(deletedAt),
                updatedByDevice: Value(updatedByDevice),
              ),
            );
      } else {
        await (_database.update(_database.products)
              ..where((product) => product.id.equals(productId)))
            .write(
          ProductsCompanion(
            name: name == null ? const Value.absent() : Value(name),
            category: category == null ? const Value.absent() : Value(category),
            brand: _nullableValue(payload, 'brand'),
            specification: _nullableValue(payload, 'specification'),
            barcode: _nullableValue(payload, 'barcode'),
            location: _firstNullableValue(payload, const ['location', 'storage_location']),
            unit: _requiredValue(payload, 'unit'),
            lowStockThreshold: threshold == existing.lowStockThreshold
                ? const Value.absent()
                : Value(threshold),
            updatedAt: Value(now),
            serverVersion: Value(version),
            deletedAt: Value(deletedAt),
            updatedByDevice: Value(updatedByDevice),
          ),
        );
      }
      return SyncRemoteApplyStatus.applied;
    });
  }

  Future<SyncRemoteApplyStatus> applyRemoteProductDelete({
    required String productId,
    required int version,
    required DateTime deletedAt,
    String? updatedByDevice,
  }) async {
    return _database.transaction(() async {
      final existing = await (_database.select(_database.products)
            ..where((product) => product.id.equals(productId)))
          .getSingleOrNull();
      if (existing == null) return SyncRemoteApplyStatus.alreadyApplied;
      if (_isStale(existing.serverVersion, version)) {
        return SyncRemoteApplyStatus.ignoredStale;
      }
      if (_isSameVersion(existing.serverVersion, version)) {
        return SyncRemoteApplyStatus.alreadyApplied;
      }
      await (_database.update(_database.products)
            ..where((product) => product.id.equals(productId)))
          .write(
        ProductsCompanion(
          deletedAt: Value(deletedAt.toUtc()),
          serverVersion: Value(version),
          updatedAt: Value(deletedAt.toUtc()),
          updatedByDevice: Value(updatedByDevice),
        ),
      );
      return SyncRemoteApplyStatus.applied;
    });
  }

  Future<SyncRemoteApplyStatus> applyRemoteProductBatch({
    required String batchId,
    required Map<String, dynamic> payload,
    required int version,
    required DateTime updatedAt,
    String? updatedByDevice,
    bool applyQuantity = false,
  }) async {
    final now = updatedAt.toUtc();
    return _database.transaction(() async {
      final existing = await (_database.select(_database.productBatches)
            ..where((batch) => batch.id.equals(batchId)))
          .getSingleOrNull();
      if (_isStale(existing?.serverVersion, version)) {
        return SyncRemoteApplyStatus.ignoredStale;
      }
      if (_isSameVersion(existing?.serverVersion, version)) {
        return SyncRemoteApplyStatus.alreadyApplied;
      }

      final productId = _firstString(payload, const ['product_id', 'productId']) ?? existing?.productId;
      if (productId == null) {
        throw const FormatException('product_batches upsert requires product_id');
      }
      final producedDate = _dateValue(payload, const ['produced_date', 'production_date', 'productionDate']);
      final expiryDate = _dateValue(payload, const ['expiry_date', 'expiryDate']);
      final batchNo = _firstNullableString(payload, const ['batch_no', 'batchNo']);
      final dateSource = _firstString(payload, const ['date_source', 'dateSource']) ??
          existing?.dateSource ??
          'manual';
      final datePrecision = _firstString(payload, const ['date_precision', 'datePrecision']) ??
          existing?.datePrecision ??
          'day';
      final isOpened = _boolValue(payload, const ['is_opened', 'opened']) ??
          (payload.containsKey('opened_date') || (existing?.isOpened ?? false));
      final isDiscarded = _boolValue(payload, const ['is_discarded', 'discarded']) ??
          existing?.isDiscarded ??
          false;
      final quantity = _intValue(payload, const ['quantity', 'current_quantity', 'remaining_quantity']);
      final initialQuantity = _intValue(payload, const ['initial_quantity', 'initialQuantity']);

      if (existing == null) {
        if (quantity == null || quantity < 0) {
          throw const FormatException(
            'product_batches upsert requires a non-negative quantity for a new local batch',
          );
        }
        await _database.into(_database.productBatches).insert(
              ProductBatchesCompanion.insert(
                id: batchId,
                productId: productId,
                batchNo: Value(batchNo),
                productionDate: Value(producedDate),
                expiryDate: Value(expiryDate),
                dateSource: Value(dateSource),
                datePrecision: Value(datePrecision),
                initialQuantity: initialQuantity ?? quantity,
                remainingQuantity: quantity,
                isOpened: Value(isOpened),
                isDiscarded: Value(isDiscarded),
                createdAt: now,
                updatedAt: now,
                serverVersion: Value(version),
                deletedAt: const Value(null),
                updatedByDevice: Value(updatedByDevice),
              ),
            );
      } else {
        final commandQuantity = applyQuantity ? quantity : null;
        final command = _stringValue(payload, 'command');
        final restockAmount = command == 'restock' ? _allocationTotal(payload) : 0;
        await (_database.update(_database.productBatches)
              ..where((batch) => batch.id.equals(batchId)))
            .write(
          ProductBatchesCompanion(
            productId: productId == existing.productId
                ? const Value.absent()
                : Value(productId),
            batchNo: _firstNullableValue(payload, const ['batch_no', 'batchNo']),
            productionDate: _dateCompanion(payload, const ['produced_date', 'production_date', 'productionDate']),
            expiryDate: _dateCompanion(payload, const ['expiry_date', 'expiryDate']),
            dateSource: _firstNullableValue(payload, const ['date_source', 'dateSource']),
            datePrecision: _firstNullableValue(payload, const ['date_precision', 'datePrecision']),
            remainingQuantity: commandQuantity == null ? const Value.absent() : Value(commandQuantity),
            initialQuantity: restockAmount > 0
                ? Value(existing.initialQuantity + restockAmount)
                : initialQuantity == null
                    ? const Value.absent()
                    : Value(initialQuantity),
            isOpened: _boolCompanion(payload, const ['is_opened', 'opened']),
            isDiscarded: applyQuantity && command == 'discard'
                ? const Value(true)
                : _boolCompanion(payload, const ['is_discarded', 'discarded']),
            updatedAt: Value(now),
            serverVersion: Value(version),
            deletedAt: const Value(null),
            updatedByDevice: Value(updatedByDevice),
          ),
        );
      }
      return SyncRemoteApplyStatus.applied;
    });
  }

  Future<SyncRemoteApplyStatus> applyRemoteProductBatchDelete({
    required String batchId,
    required int version,
    required DateTime deletedAt,
    String? updatedByDevice,
  }) async {
    return _database.transaction(() async {
      final existing = await (_database.select(_database.productBatches)
            ..where((batch) => batch.id.equals(batchId)))
          .getSingleOrNull();
      if (existing == null) return SyncRemoteApplyStatus.alreadyApplied;
      if (_isStale(existing.serverVersion, version)) {
        return SyncRemoteApplyStatus.ignoredStale;
      }
      if (_isSameVersion(existing.serverVersion, version)) {
        return SyncRemoteApplyStatus.alreadyApplied;
      }
      await (_database.update(_database.productBatches)
            ..where((batch) => batch.id.equals(batchId)))
          .write(
        ProductBatchesCompanion(
          deletedAt: Value(deletedAt.toUtc()),
          serverVersion: Value(version),
          updatedAt: Value(deletedAt.toUtc()),
          updatedByDevice: Value(updatedByDevice),
        ),
      );
      return SyncRemoteApplyStatus.applied;
    });
  }

  int _allocationTotal(Map<String, dynamic> payload) {
    final raw = payload['allocations'];
    if (raw is! List) return 0;
    return raw.fold<int>(0, (sum, item) {
      if (item is! Map) return sum;
      final value = item['quantity'];
      return sum + (value is num ? value.toInt() : 0);
    });
  }

  bool _isStale(int? localVersion, int remoteVersion) =>
      remoteVersion > 0 && localVersion != null && localVersion > remoteVersion;

  bool _isSameVersion(int? localVersion, int remoteVersion) =>
      remoteVersion > 0 && localVersion != null && localVersion == remoteVersion;

  String? _stringValue(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  String? _firstString(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      final value = _stringValue(payload, key);
      if (value != null) return value;
    }
    return null;
  }

  String? _nullableStringValue(Map<String, dynamic> payload, String key) {
    if (!payload.containsKey(key)) return null;
    final value = payload[key];
    if (value == null) return null;
    if (value is String) return value.trim().isEmpty ? null : value.trim();
    throw FormatException('$key must be a string or null');
  }

  Value<String?> _nullableValue(Map<String, dynamic> payload, String key) {
    if (!payload.containsKey(key)) return const Value.absent();
    return Value(_nullableStringValue(payload, key));
  }

  Value<String> _requiredValue(Map<String, dynamic> payload, String key) {
    if (!payload.containsKey(key)) return const Value.absent();
    final value = _stringValue(payload, key);
    if (value == null) throw FormatException('$key must be a non-empty string');
    return Value(value);
  }

  Value<String?> _firstNullableValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (payload.containsKey(key)) return Value(_nullableStringValue(payload, key));
    }
    return const Value.absent();
  }

  String? _firstNullableString(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (payload.containsKey(key)) return _nullableStringValue(payload, key);
    }
    return null;
  }

  int? _intValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value is int) return value;
      if (value is num && value == value.toInt()) return value.toInt();
      throw FormatException('$key must be an integer');
    }
    return null;
  }

  bool? _boolValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value is bool) return value;
      throw FormatException('$key must be a boolean');
    }
    return null;
  }

  Value<bool> _boolCompanion(Map<String, dynamic> payload, List<String> keys) {
    final value = _boolValue(payload, keys);
    return value == null ? const Value.absent() : Value(value);
  }

  DateTime? _dateValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value == null) return null;
      if (value is String) return DateTime.parse(value).toUtc();
      throw FormatException('$key must be an RFC3339 date or null');
    }
    return null;
  }

  Value<DateTime?> _dateCompanion(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (payload.containsKey(key)) return Value(_dateValue(payload, [key]));
    }
    return const Value.absent();
  }

  bool _sameText(String? left, String? right) =>
      _trimToNull(left)?.toLowerCase() == _trimToNull(right)?.toLowerCase();

  Future<void> _enqueueEntityUpsert({
    required String entity,
    required String entityId,
    required int baseVersion,
    required Map<String, dynamic> payload,
    required DateTime now,
  }) async {
    final scopeId = _syncScopeId;
    final outbox = _outbox;
    if (scopeId == null || scopeId.trim().isEmpty || outbox == null) return;
    final changeId = _uuid.v4();
    await outbox.enqueueInCurrentTransaction(
      SyncOutboxDraft(
        changeId: changeId,
        scopeId: scopeId,
        operation: SyncOperation.entityUpsert,
        entity: entity,
        entityId: entityId,
        baseVersion: baseVersion,
        idempotencyKey: '$scopeId:$changeId',
        requestJson: jsonEncode({
          'change_id': changeId,
          'operation': SyncOperation.entityUpsert.wireValue,
          'entity': entity,
          'entity_id': entityId,
          'base_version': baseVersion,
          'payload': payload,
          'idempotency_key': '$scopeId:$changeId',
          'client_updated_at': now.toUtc().toIso8601String(),
        }),
        createdAt: now.toUtc(),
      ),
    );
  }

  Future<void> _enqueueInventoryCommand({
    required String command,
    required String operationId,
    required List<Map<String, dynamic>> allocations,
    required DateTime now,
  }) async {
    final scopeId = _syncScopeId;
    final outbox = _outbox;
    if (scopeId == null || scopeId.trim().isEmpty || outbox == null) return;
    final changeId = _uuid.v4();
    final idempotencyKey = '$scopeId:$operationId';
    await outbox.enqueueInCurrentTransaction(
      SyncOutboxDraft(
        changeId: changeId,
        scopeId: scopeId,
        operation: SyncOperation.inventoryCommand,
        operationId: operationId,
        command: command,
        idempotencyKey: idempotencyKey,
        requestJson: jsonEncode({
          'change_id': changeId,
          'operation': SyncOperation.inventoryCommand.wireValue,
          'command': command,
          'operation_id': operationId,
          'allocations': allocations,
          'idempotency_key': idempotencyKey,
          'client_updated_at': now.toUtc().toIso8601String(),
        }),
        createdAt: now.toUtc(),
      ),
    );
  }

  Map<String, dynamic> _productPayload({
    required String name,
    String? brand,
    String? specification,
    String? barcode,
  }) {
    return <String, dynamic>{
      'name': name,
      if (barcode != null) 'barcode': barcode,
      if (brand != null) 'brand': brand,
      if (specification != null) 'specification': specification,
    };
  }

  Map<String, dynamic> _batchPayload({
    required String productId,
    required DateTime? productionDate,
    required DateTime? expiryDate,
    required String dateSource,
    required String datePrecision,
  }) {
    return <String, dynamic>{
      'product_id': productId,
      if (productionDate != null) 'produced_date': _dateOnly(productionDate),
      if (expiryDate != null) 'expiry_date': _dateOnly(expiryDate),
      // The local intake flow also uses "calculated" and "ai". The NAS
      // contract stores those as the closest supported source values.
      'date_source': _wireDateSource(dateSource),
      'date_precision': datePrecision,
    };
  }

  List<Map<String, dynamic>> _allocationPayload(
    Iterable<BatchAllocation> allocations,
  ) {
    return allocations
        .map<Map<String, dynamic>>(
          (allocation) => <String, dynamic>{
            'batch_id': allocation.batchId,
            'quantity': allocation.quantity,
          },
        )
        .toList(growable: false);
  }

  String _wireDateSource(String value) {
    switch (value) {
      case 'ai':
        return 'ai_draft';
      case 'calculated':
        return 'manual';
      default:
        return value;
    }
  }

  String _dateOnly(DateTime value) {
    final local = value.toLocal();
    final month = local.month.toString().padLeft(2, '0');
    final day = local.day.toString().padLeft(2, '0');
    return '${local.year.toString().padLeft(4, '0')}-$month-$day';
  }

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
            dateSource: Value(dateSource),
            datePrecision: Value(datePrecision),
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
