import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/sync_business_adapter.dart';
import 'package:momo_box/application/sync_change_control.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

const _scope = 'family';
final _now = DateTime.utc(2026, 10, 7);
final _deletedAt = _now.add(const Duration(hours: 1));

Map<String, dynamic> _snapshot({int version = 2, bool deleted = false}) => {
  'products': [
    {
      'id': 'product', 'version': version,
      if (deleted) 'deleted_at': _deletedAt.toIso8601String(),
      'name': 'NAS商品', 'category': 'NAS分类', 'brand': 'NAS品牌',
      'unit': '件', 'low_stock_threshold': 3,
    },
  ],
  'product_batches': [
    {
      'id': 'batch', 'version': version, 'product_id': 'product',
      if (deleted) 'deleted_at': _deletedAt.toIso8601String(),
      'quantity': 4, 'initial_quantity': 6, 'batch_no': 'NAS批次',
    },
  ],
  'shopping_items': [
    <String, dynamic>{
      'id': 'shopping', 'version': version, 'product_id': 'product',
      if (deleted) 'deleted_at': _deletedAt.toIso8601String(),
      'name': 'NAS采购', 'category': 'NAS分类', 'desired_quantity': 2,
      'checked': false, 'reason': 'NAS原因',
    },
  ],
};

void main() {
  late AppDatabase database;
  late SyncOutboxRepository outbox;
  late InventoryRepository inventory;
  late ShoppingRepository shopping;
  late SyncBusinessAdapter adapter;

  setUp(() async {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = SyncOutboxRepository(database);
    inventory = InventoryRepository(database);
    shopping = ShoppingRepository(database);
    adapter = SyncBusinessAdapter(
      inventoryRepository: inventory, shoppingRepository: shopping,
      outboxRepository: outbox, scopeId: _scope,
    );
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '原商品', 'category': '其他'},
      version: 2, updatedAt: _now,
    );
    await inventory.applyRemoteProductBatch(
      batchId: 'batch', payload: {'product_id': 'product', 'quantity': 3},
      version: 2, updatedAt: _now, applyQuantity: true,
    );
    await shopping.applyRemoteShoppingEntry(
      entryId: 'shopping', payload: {'name': '原采购', 'desired_quantity': 1},
      version: 2, updatedAt: _now,
    );
    // Real optimistic edits do not increment serverVersion. Model that state
    // without creating additional unrelated outbox writes during test setup.
    await (database.update(database.products)..where((row) => row.id.equals('product')))
        .write(const ProductsCompanion(
          name: Value('本地商品'), category: Value('本地分类'), brand: Value('本地品牌'),
          lowStockThreshold: Value(9),
        ));
    await (database.update(database.shoppingEntries)..where((row) => row.id.equals('shopping')))
        .write(const ShoppingEntriesCompanion(
          itemName: Value('本地采购'), category: Value('本地分类'), targetQuantity: Value(9),
          isCompleted: Value(true), reason: Value('本地原因'),
        ));
  });
  tearDown(() => database.close());

  Future<ShoppingEntryRecord> entry() =>
      (database.select(database.shoppingEntries)..where((row) => row.id.equals('shopping'))).getSingle();

  Future<String> settleKeepRemote({String entity = 'products', String entityId = 'product'}) async {
    await outbox.enqueue(SyncOutboxDraft(
      changeId: 'optimistic-edit', scopeId: _scope,
      operation: SyncOperation.entityUpsert, entity: entity, entityId: entityId,
      idempotencyKey: 'optimistic-edit-original-key', requestJson: jsonEncode({'name': '本地'}),
    ));
    await outbox.markConflict(changeId: 'optimistic-edit', conflict: SyncConflictDraft(
      scopeId: _scope, changeId: 'optimistic-edit', outboxChangeId: 'optimistic-edit',
      entity: entity, entityId: entityId, reason: 'VERSION_CONFLICT', serverVersion: 2,
    ));
    final id = (await outbox.getConflictByChangeId(scopeId: _scope, changeId: 'optimistic-edit'))!.id;
    await outbox.settleOutboxConflict(
      conflictId: id, scopeId: _scope, changeId: 'optimistic-edit',
      remoteConflictId: 'nas-conflict', action: 'keep_remote',
      response: NasSyncConflictResolveResponse(
        accepted: true,
        conflict: NasSyncConflictDetail(
          conflictId: 'nas-conflict', changeId: 'optimistic-edit', entity: entity, entityId: entityId,
          operation: 'entity_upsert', reason: 'VERSION_CONFLICT', status: 'resolved',
          resolution: const {'action': 'keep_remote'}, serverVersion: 2,
        ),
      ),
    );
    return (await outbox.getConflictResolutionRefreshToken(_scope))!;
  }

  for (final entity in ['products', 'shopping_items']) {
    test('keep_remote fresh snapshot repairs same-version $entity optimistic data', () async {
      final token = await settleKeepRemote(
        entity: entity, entityId: entity == 'products' ? 'product' : 'shopping',
      );
      var completed = false;
      await adapter.applyRemoteSnapshot(_snapshot(), 20, onApplied: () async {
        final product = (await inventory.getProductRecord('product'))!;
        final item = await entry();
        expect([product.name, product.category, product.brand, product.lowStockThreshold],
            ['NAS商品', 'NAS分类', 'NAS品牌', 3]);
        expect([item.itemName, item.category, item.targetQuantity, item.isCompleted, item.reason],
            ['NAS采购', 'NAS分类', 2, false, 'NAS原因']);
        expect(await outbox.clearConflictResolutionRefresh(scopeId: _scope, token: token), isTrue);
        completed = true;
      });
      expect(completed, isTrue);
      expect((await inventory.getProductRecord('product'))!.serverVersion, 2);
      expect((await entry()).serverVersion, 2);
      expect(await outbox.getConflictResolutionRefreshToken(_scope), isNull);
      expect((await outbox.getByChangeId('optimistic-edit'))!.status, SyncOutboxStatus.conflict);
      expect(await outbox.claimNext(scopeId: _scope), isNull);
      expect(await database.select(database.stockMovements).get(), isEmpty);
    });
  }

  test('authoritative explicit null clears optimistic shopping product link only in snapshot', () async {
    await database.update(database.shoppingEntries)
        .write(const ShoppingEntriesCompanion(productId: Value('product')));
    final snapshot = _snapshot();
    final payload = (snapshot['shopping_items'] as List).single as Map<String, dynamic>;
    payload['product_id'] = null;
    await adapter.applyRemoteChange(NasSyncPullChange(
      changeId: 'same-version-shopping', cursor: 20, operation: 'entity_upsert',
      entity: 'shopping_items', entityId: 'shopping', version: 2, payload: payload,
    ));
    expect((await entry()).productId, 'product');
    await adapter.applyRemoteSnapshot(snapshot, 20);
    expect((await entry()).productId, isNull);
  });

  test('same-version authoritative tombstones delete product, batch and shopping', () async {
    await adapter.applyRemoteSnapshot(_snapshot(deleted: true), 20);
    expect((await inventory.getProductRecord('product'))!.deletedAt?.toUtc(), _deletedAt);
    expect((await inventory.getBatchRecord('batch'))!.deletedAt?.toUtc(), _deletedAt);
    expect((await entry()).deletedAt?.toUtc(), _deletedAt);
    // Snapshot replay is not another logical mutation or stock movement.
    await adapter.applyRemoteSnapshot(_snapshot(deleted: true), 20);
    expect((await inventory.getProductRecord('product'))!.serverVersion, 2);
    expect((await inventory.getBatchRecord('batch'))!.serverVersion, 2);
    expect((await entry()).serverVersion, 2);
    expect(await database.select(database.stockMovements).get(), isEmpty);
    expect(await outbox.listOutbox(scopeId: _scope), isEmpty);
  });

  test('same-version snapshot restores optimistic local tombstones', () async {
    await database.update(database.products).write(ProductsCompanion(deletedAt: Value(_deletedAt)));
    await database.update(database.productBatches).write(ProductBatchesCompanion(deletedAt: Value(_deletedAt)));
    await database.update(database.shoppingEntries).write(ShoppingEntriesCompanion(deletedAt: Value(_deletedAt)));
    await adapter.applyRemoteSnapshot(_snapshot(), 20);
    expect((await inventory.getProductRecord('product'))!.deletedAt, isNull);
    expect((await inventory.getBatchRecord('batch'))!.deletedAt, isNull);
    expect((await entry()).deletedAt, isNull);
  });

  for (final deleted in [false, true]) {
    test('older snapshot ${deleted ? 'tombstones' : 'upserts'} never roll back version/data', () async {
      await adapter.applyRemoteSnapshot(_snapshot(version: 1, deleted: deleted), 20);
      final product = (await inventory.getProductRecord('product'))!;
      final batch = (await inventory.getBatchRecord('batch'))!;
      final item = await entry();
      expect([product.name, product.serverVersion, product.deletedAt], ['本地商品', 2, null]);
      expect([batch.remainingQuantity, batch.serverVersion, batch.deletedAt], [3, 2, null]);
      expect([item.itemName, item.serverVersion, item.deletedAt], ['本地采购', 2, null]);
    });
  }

  for (final deleted in [false, true]) {
    test('incremental ${deleted ? 'delete' : 'upsert'} still skips equal and older versions', () async {
      final payloads = _snapshot(deleted: deleted);
      for (final entity in ['products', 'product_batches', 'shopping_items']) {
        final payload = Map<String, dynamic>.from((payloads[entity] as List).single as Map);
        for (final version in [2, 1]) {
          await adapter.applyRemoteChange(NasSyncPullChange(
            changeId: '$entity-$version', cursor: 20,
            entity: entity, entityId: payload['id'] as String, version: version,
            operation: deleted ? 'entity_delete' : 'entity_upsert', payload: payload,
          ));
        }
      }
      expect((await inventory.getProductRecord('product'))!.name, '本地商品');
      expect((await inventory.getProductRecord('product'))!.deletedAt, isNull);
      expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 3);
      expect((await inventory.getBatchRecord('batch'))!.deletedAt, isNull);
      expect((await entry()).itemName, '本地采购');
      expect((await entry()).deletedAt, isNull);
    });
  }

  test('repository defaults do not enable same-version authoritative writes', () async {
    expect(await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': 'NAS商品'}, version: 2, updatedAt: _now,
    ), SyncRemoteApplyStatus.alreadyApplied);
    expect(await inventory.applyRemoteProductDelete(
      productId: 'product', version: 2, deletedAt: _deletedAt,
    ), SyncRemoteApplyStatus.alreadyApplied);
    expect(await inventory.applyRemoteProductBatchDelete(
      batchId: 'batch', version: 2, deletedAt: _deletedAt,
    ), SyncRemoteApplyStatus.alreadyApplied);
    expect(await shopping.applyRemoteShoppingEntry(
      entryId: 'shopping', payload: {'name': 'NAS采购'}, version: 2, updatedAt: _now,
    ), SyncRemoteApplyStatus.alreadyApplied);
    expect(await shopping.applyRemoteShoppingEntryDelete(
      entryId: 'shopping', version: 2, deletedAt: _deletedAt,
    ), SyncRemoteApplyStatus.alreadyApplied);
  });

  for (final status in [SyncOutboxStatus.pending, SyncOutboxStatus.inFlight,
    SyncOutboxStatus.blocked, SyncOutboxStatus.conflict, SyncOutboxStatus.rejected]) {
    test('unresolved $status still forbids equal-version snapshot/tombstone overwrite', () async {
      await outbox.enqueue(SyncOutboxDraft(
        changeId: 'unresolved', scopeId: _scope, status: status,
        operation: SyncOperation.inventoryCommand,
        idempotencyKey: 'unresolved-original-key', requestJson: '{}',
      ));
      var completed = false;
      for (final deleted in [false, true]) {
        await expectLater(adapter.applyRemoteSnapshot(_snapshot(deleted: deleted), 20,
          onApplied: () async { completed = true; }), throwsA(isA<SyncRemoteChangeDeferred>()));
      }
      expect(completed, isFalse);
      expect((await inventory.getProductRecord('product'))!.name, '本地商品');
      expect((await entry()).itemName, '本地采购');
      expect((await inventory.getBatchRecord('batch'))!.deletedAt, isNull);
    });
  }

  test('onApplied failure rolls back all same-version corrections and refresh clear', () async {
    final token = await settleKeepRemote();
    await expectLater(adapter.applyRemoteSnapshot(_snapshot(), 20, onApplied: () async {
      expect(await outbox.clearConflictResolutionRefresh(scopeId: _scope, token: token), isTrue);
      throw StateError('completion failed');
    }), throwsStateError);
    expect((await inventory.getProductRecord('product'))!.name, '本地商品');
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 3);
    expect((await entry()).itemName, '本地采购');
    expect(await outbox.getConflictResolutionRefreshToken(_scope), token);
  });

  test('new blocker during completion rolls back equal-version snapshot application', () async {
    await expectLater(adapter.applyRemoteSnapshot(_snapshot(), 20, onApplied: () async {
      await outbox.enqueue(const SyncOutboxDraft(
        changeId: 'racing-edit', scopeId: _scope, operation: SyncOperation.entityUpsert,
        idempotencyKey: 'racing-edit-original-key', requestJson: '{}',
      ));
    }), throwsA(isA<SyncRemoteChangeDeferred>()));
    expect((await inventory.getProductRecord('product'))!.name, '本地商品');
    expect((await entry()).itemName, '本地采购');
    expect(await outbox.getByChangeId('racing-edit'), isNull);
  });
}
