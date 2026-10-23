import 'dart:convert';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/sync_business_adapter.dart';
import 'package:momo_box/application/sync_change_control.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_category_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/initial_import_models.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

const scope = 'family-a';

class _Api extends NasSyncApi {
  _Api() : super('https://nas.example');
  bool omitResults = false;
  final requests = <List<NasSyncChange>>[];

  @override
  Future<NasSyncVersions> capabilities() async =>
      const NasSyncVersions(schemaVersion: 1, syncProtocolVersion: 1);

  @override
  Future<NasSyncPushResponse> push({
    required String deviceId,
    required int baseCursor,
    required List<NasSyncChange> changes,
  }) async {
    requests.add(changes);
    return NasSyncPushResponse(
      accepted:
          omitResults
              ? []
              : [
                for (final change in changes)
                  NasSyncAcceptedChange(
                    changeId: change.changeId,
                    serverCursor: 10,
                    serverVersion: change.baseVersion + 1,
                  ),
              ],
      replayed: const [],
      conflicts: const [],
      rejected: const [],
      results: const [],
      cursor: 10,
    );
  }

  @override
  Future<NasSyncPullResponse> pull({
    required String deviceId,
    required int cursor,
    int limit = 100,
  }) async => NasSyncPullResponse(
    changes: const [],
    nextCursor: cursor,
    hasMore: false,
  );
}

void main() {
  late AppDatabase database;
  late SyncOutboxRepository outbox;
  late InventoryRepository inventory;
  late ShoppingRepository shopping;
  late SyncBusinessAdapter adapter;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = SyncOutboxRepository(database);
    inventory = InventoryRepository(database);
    shopping = ShoppingRepository(database);
    adapter = SyncBusinessAdapter(
      inventoryRepository: inventory,
      shoppingRepository: shopping,
      outboxRepository: outbox,
      scopeId: scope,
    );
  });
  tearDown(() => database.close());

  Future<SyncOutboxEntry> enqueue(
    String id, {
    String entity = 'products',
    String entityId = 'product',
    int base = 0,
    SyncOperation operation = SyncOperation.entityUpsert,
  }) => outbox.enqueue(
    SyncOutboxDraft(
      changeId: id,
      scopeId: scope,
      operation: operation,
      entity: entity,
      entityId: entityId,
      baseVersion: base,
      idempotencyKey: '$id-original-idempotency-key',
      requestJson: jsonEncode({
        'change_id': id,
        'operation': operation.wireValue,
        'entity': entity,
        'entity_id': entityId,
        'base_version': base,
        'idempotency_key': '$id-original-idempotency-key',
        'client_updated_at': '2026-10-23T00:00:00Z',
        'payload': {'name': id},
      }),
    ),
  );

  Future<void> ready() async {
    final state = await outbox.ensureState(scopeId: scope);
    await outbox.saveState(
      state.copyWith(bootstrapStatus: SyncBootstrapStatus.ready),
    );
    await outbox.savePendingBootstrap(
      scopeId: scope,
      snapshot: {},
      serverCursor: 0,
      mode: 'join_and_merge',
    );
    await outbox.clearPendingBootstrap(scope);
  }

  test(
    'definitive rejection can be explicitly abandoned after restart without requeue',
    () async {
      final original = await enqueue('rejected');
      await outbox.claimNext(scopeId: scope);
      await outbox.markRejected(
        changeId: original.changeId,
        errorCode: 'VALIDATION_ERROR',
        errorMessage: 'not applied',
        confirmedByNas: true,
      );
      final restarted = SyncOutboxRepository(database);
      final rejected = (await restarted.getByChangeId(original.changeId))!;
      expect(await restarted.canAbandonRejected(rejected), isTrue);
      await restarted.abandonRejected(
        scopeId: scope,
        changeId: rejected.changeId,
      );
      expect(
        await restarted.hasSnapshotBlockingChanges(scopeId: scope),
        isFalse,
      );
      expect(await restarted.claimNext(scopeId: scope), isNull);
      expect(
        (await restarted.getByChangeId(rejected.changeId))!.requestJson,
        original.requestJson,
      );
      expect(
        (await restarted.getByChangeId(rejected.changeId))!.status,
        SyncOutboxStatus.rejected,
      );
      expect(
        await restarted.getConflictResolutionRefreshToken(scope),
        isNotNull,
      );
      expect(await restarted.listUnsettledRejected(scopeId: scope), isEmpty);
    },
  );

  test(
    'unknown send, legacy refusal, and mismatched evidence cannot be abandoned',
    () async {
      await enqueue('unknown');
      await outbox.claimNext(scopeId: scope);
      await expectLater(
        outbox.abandonRejected(scopeId: scope, changeId: 'unknown'),
        throwsStateError,
      );
      await outbox.markRejected(
        changeId: 'unknown',
        errorCode: 'refused',
        errorMessage: 'legacy',
      );
      expect(
        await outbox.canAbandonRejected(
          (await outbox.getByChangeId('unknown'))!,
        ),
        isFalse,
      );
      await outbox.markRejected(
        changeId: 'unknown',
        errorCode: 'refused',
        errorMessage: 'proof',
        confirmedByNas: true,
      );
      await (database.update(database.syncOutbox)
        ..where((row) => row.changeId.equals('unknown'))).write(
        const SyncOutboxCompanion(requestJson: Value('{"changed":true}')),
      );
      await expectLater(
        outbox.abandonRejected(scopeId: scope, changeId: 'unknown'),
        throwsStateError,
      );
    },
  );

  test(
    'HA unknown or legacy post-effect failures never become abandonment evidence',
    () async {
      for (final code in [
        'HA_COMMAND_RESULT_UNKNOWN',
        'HA_UNAVAILABLE',
        'HA_AUDIT_FAILURE',
        'IDEMPOTENCY_KEY_REUSE',
      ]) {
        final entry = await enqueue(
          'ha-$code',
          entityId: code,
          operation: SyncOperation.homeAssistantCommand,
        );
        await outbox.markRejected(
          changeId: entry.changeId,
          errorCode: code,
          errorMessage: 'unconfirmed',
          confirmedByNas: true,
        );
        expect(
          await outbox.canAbandonRejected(
            (await outbox.getByChangeId(entry.changeId))!,
          ),
          isFalse,
        );
        await expectLater(
          outbox.abandonRejected(scopeId: scope, changeId: entry.changeId),
          throwsStateError,
        );
      }
    },
  );

  test(
    'only the first proven pre-send parse failure can be abandoned locally',
    () async {
      await enqueue('first');
      await outbox.claimNext(scopeId: scope);
      await outbox.markRejected(
        changeId: 'first',
        errorCode: 'INVALID_LOCAL_CHANGE',
        errorMessage: 'invalid',
        failedBeforeFirstSend: true,
      );
      expect(
        await outbox.canAbandonRejected((await outbox.getByChangeId('first'))!),
        isTrue,
      );
      await enqueue('retried', entityId: 'another');
      await outbox.claimNext(scopeId: scope);
      await outbox.releaseInFlight(changeId: 'retried');
      await outbox.claimNext(scopeId: scope);
      await outbox.markRejected(
        changeId: 'retried',
        errorCode: 'INVALID_LOCAL_CHANGE',
        errorMessage: 'invalid',
        failedBeforeFirstSend: true,
      );
      expect(
        await outbox.canAbandonRejected(
          (await outbox.getByChangeId('retried'))!,
        ),
        isFalse,
      );
    },
  );

  test(
    'NAS settlement retires exact local guards while newer remote data awaits a fresh snapshot',
    () async {
      final entry = await enqueue('edit');
      await outbox.claimNext(scopeId: scope);
      final pull = await outbox.recordConflict(
        SyncConflictDraft(
          scopeId: scope,
          changeId: 'remote-before',
          outboxChangeId: 'edit',
          entity: 'products',
          entityId: 'product',
          serverVersion: 2,
          reason: 'REMOTE_CHANGE_WITH_PENDING_LOCAL_CHANGE',
          clientPayloadJson: entry.requestJson,
        ),
      );
      final later = await outbox.recordConflict(
        SyncConflictDraft(
          scopeId: scope,
          changeId: 'remote-later',
          outboxChangeId: 'edit',
          entity: 'products',
          entityId: 'product',
          serverVersion: 9,
          reason: 'REMOTE_CHANGE_WITH_PENDING_LOCAL_CHANGE',
          clientPayloadJson: entry.requestJson,
        ),
      );
      await outbox.markConflict(
        changeId: 'edit',
        conflict: const SyncConflictDraft(
          scopeId: scope,
          changeId: 'edit',
          outboxChangeId: 'edit',
          entity: 'products',
          entityId: 'product',
          reason: 'VERSION_CONFLICT',
          serverVersion: 2,
        ),
      );
      final push =
          (await outbox.getConflictByChangeId(
            scopeId: scope,
            changeId: 'edit',
          ))!;
      await outbox.settleOutboxConflict(
        conflictId: push.id,
        scopeId: scope,
        changeId: 'edit',
        remoteConflictId: 'nas-conflict',
        action: 'keep_remote',
        response: const NasSyncConflictResolveResponse(
          accepted: true,
          conflict: NasSyncConflictDetail(
            conflictId: 'nas-conflict',
            changeId: 'edit',
            entity: 'products',
            entityId: 'product',
            operation: 'entity_upsert',
            reason: 'VERSION_CONFLICT',
            status: 'resolved',
            serverVersion: 2,
            resolution: {'action': 'keep_remote'},
          ),
        ),
      );
      expect(
        (await outbox.getConflict(pull))!.resolution,
        'protection_retired_after_intent_settlement',
      );
      expect(
        (await outbox.getConflict(push.id))!.resolution,
        'remote_keep_remote',
      );
      expect(
        (await outbox.getConflict(later))!.resolution,
        'protection_retired_after_intent_settlement',
      );
      expect(await outbox.hasSnapshotBlockingChanges(scopeId: scope), isFalse);
      expect(await outbox.getConflictResolutionRefreshToken(scope), isNotNull);
      Map<String, dynamic> snapshot(int version) => {
        'products': [
          {
            'id': 'product',
            'name': 'newer remote',
            'category': '食品',
            'version': version,
          },
        ],
      };
      await expectLater(
        adapter.applyRemoteSnapshot(snapshot(8), 20),
        throwsFormatException,
      );
      expect(await inventory.getProductRecord('product'), isNull);
      expect(await outbox.getConflictResolutionRefreshToken(scope), isNotNull);
      await expectLater(
        adapter.applyRemoteSnapshot(
          snapshot(10),
          21,
          onApplied: () async {
            throw StateError('receipt commit failed');
          },
        ),
        throwsStateError,
      );
      // A failed business/cursor commit cannot consume the guard's lower bound.
      await expectLater(
        adapter.applyRemoteSnapshot(snapshot(8), 22),
        throwsFormatException,
      );
      await adapter.applyRemoteSnapshot(snapshot(10), 23);
      expect((await inventory.getProductRecord('product'))!.serverVersion, 10);
      expect(
        (await inventory.getProductRecord('product'))!.name,
        'newer remote',
      );
      await adapter.applyRemoteSnapshot({'products': []}, 24);
    },
  );

  test(
    'composite inventory protection records the affected allocation version',
    () async {
      await inventory.applyRemoteProduct(
        productId: 'product',
        payload: {'name': '米', 'category': '食品'},
        version: 1,
        updatedAt: DateTime.utc(2026),
      );
      for (final batch in ['batch-one', 'batch-two']) {
        await inventory.applyRemoteProductBatch(
          batchId: batch,
          payload: {'product_id': 'product', 'quantity': 3},
          version: 1,
          updatedAt: DateTime.utc(2026),
          applyQuantity: true,
        );
      }
      final entry = await outbox.enqueue(
        SyncOutboxDraft(
          changeId: 'secondary-intent',
          scopeId: scope,
          operation: SyncOperation.inventoryCommand,
          operationId: 'secondary-operation',
          command: 'consume_allocated',
          idempotencyKey: 'secondary-original-key',
          requestJson: jsonEncode({
            'operation': 'inventory_command',
            'operation_id': 'secondary-operation',
            'command': 'consume_allocated',
            'allocations': [
              {'batch_id': 'batch-two', 'quantity': 1},
            ],
          }),
        ),
      );
      await expectLater(
        adapter.applyRemoteChange(
          const NasSyncPullChange(
            changeId: 'composite',
            cursor: 20,
            operation: 'inventory_command',
            command: 'consume_allocated',
            entity: 'product_batches',
            entityId: 'batch-one',
            version: 2,
            payload: {
              'allocations': [
                {
                  'batch_id': 'batch-one',
                  'quantity': 1,
                  'after_quantity': 2,
                  'after_version': 2,
                },
                {
                  'batch_id': 'batch-two',
                  'quantity': 1,
                  'after_quantity': 2,
                  'after_version': 9,
                },
              ],
            },
          ),
        ),
        throwsA(isA<SyncRemoteChangeDeferred>()),
      );
      final guard = (await outbox.listOpenConflicts(scopeId: scope)).single;
      expect(guard.entityId, 'batch-two');
      expect(guard.serverVersion, 9);
      await outbox.markRejected(
        changeId: entry.changeId,
        errorCode: 'DENIED',
        errorMessage: 'not applied',
        confirmedByNas: true,
      );
      await outbox.abandonRejected(scopeId: scope, changeId: entry.changeId);
      Map<String, dynamic> snapshot(int secondaryVersion) => {
        'product_batches': [
          {
            'id': 'batch-one',
            'product_id': 'product',
            'quantity': 2,
            'version': 2,
          },
          {
            'id': 'batch-two',
            'product_id': 'product',
            'quantity': 2,
            'version': secondaryVersion,
          },
        ],
      };
      await expectLater(
        adapter.applyRemoteSnapshot(snapshot(8), 21),
        throwsFormatException,
      );
      expect((await inventory.getBatchRecord('batch-one'))!.serverVersion, 1);
      await adapter.applyRemoteSnapshot(snapshot(10), 22);
      expect((await inventory.getBatchRecord('batch-two'))!.serverVersion, 10);
    },
  );

  test(
    'reminder guard freshness checks its policy instead of product version',
    () async {
      final scopedInventory = InventoryRepository(database, syncScopeId: scope);
      final scopedAdapter = SyncBusinessAdapter(
        inventoryRepository: scopedInventory,
        shoppingRepository: shopping,
        outboxRepository: outbox,
        scopeId: scope,
      );
      await inventory.applyRemoteProduct(
        productId: 'product',
        payload: {'name': '米', 'category': '食品'},
        version: 4,
        updatedAt: DateTime.utc(2026),
      );
      final entry = await enqueue('product-edit', base: 4);
      await expectLater(
        scopedAdapter.applyRemoteChange(
          const NasSyncPullChange(
            changeId: 'remote-policy',
            cursor: 20,
            operation: 'entity_upsert',
            entity: 'reminder_settings',
            entityId: 'policy',
            version: 9,
            payload: {
              'product_id': 'product',
              'enabled': true,
              'low_stock_threshold': 3,
            },
          ),
        ),
        throwsA(isA<SyncRemoteChangeDeferred>()),
      );
      await outbox.markRejected(
        changeId: entry.changeId,
        errorCode: 'DENIED',
        errorMessage: 'not applied',
        confirmedByNas: true,
      );
      await outbox.abandonRejected(scopeId: scope, changeId: entry.changeId);
      Map<String, dynamic> snapshot(int policyVersion) => {
        'products': [
          {'id': 'product', 'name': '米', 'category': '食品', 'version': 4},
        ],
        'reminder_settings': [
          {
            'id': 'policy',
            'product_id': 'product',
            'enabled': true,
            'low_stock_threshold': 3,
            'version': policyVersion,
          },
        ],
      };
      await expectLater(
        scopedAdapter.applyRemoteSnapshot(snapshot(8), 21),
        throwsFormatException,
      );
      await scopedAdapter.applyRemoteSnapshot(snapshot(10), 22);
      expect((await inventory.getProductRecord('product'))!.serverVersion, 4);
      final policy = await outbox.getRemoteAuxiliaryEntity(
        scopeId: scope,
        entity: 'reminder_settings',
        entityId: 'policy',
      );
      expect(policy!['version'], 10);
    },
  );

  test(
    'inventory guard retirement verifies every target against the original allocations',
    () async {
      final entry = await outbox.enqueue(
        SyncOutboxDraft(
          changeId: 'stock-intent',
          scopeId: scope,
          operation: SyncOperation.inventoryCommand,
          operationId: 'stock-operation',
          command: 'consume_allocated',
          idempotencyKey: 'stock-intent-idempotency-key',
          requestJson: jsonEncode({
            'operation': 'inventory_command',
            'operation_id': 'stock-operation',
            'command': 'consume_allocated',
            'allocations': [
              {'batch_id': 'batch-one', 'quantity': 1},
              {'batch_id': 'batch-two', 'quantity': 2},
            ],
          }),
        ),
      );
      final guardIds = <String, int>{};
      for (final batch in ['batch-one', 'batch-two', 'unrelated-batch']) {
        guardIds[batch] = await outbox.recordConflict(
          SyncConflictDraft(
            scopeId: scope,
            changeId: 'remote-$batch',
            outboxChangeId: entry.changeId,
            entity: 'product_batches',
            entityId: batch,
            reason: 'REMOTE_INVENTORY_COMMAND_WITH_PENDING_LOCAL_CHANGE',
            serverVersion: 9,
            clientPayloadJson: entry.requestJson,
          ),
        );
      }
      await outbox.markConflict(
        changeId: entry.changeId,
        conflict: SyncConflictDraft(
          scopeId: scope,
          changeId: entry.changeId,
          outboxChangeId: entry.changeId,
          entity: 'product_batches',
          entityId: 'batch-one',
          reason: 'VERSION_CONFLICT',
          serverVersion: 2,
        ),
      );
      final primary =
          (await outbox.getConflictByChangeId(
            scopeId: scope,
            changeId: entry.changeId,
          ))!;
      await outbox.settleOutboxConflict(
        conflictId: primary.id,
        scopeId: scope,
        changeId: entry.changeId,
        remoteConflictId: 'nas-stock',
        action: 'keep_remote',
        response: const NasSyncConflictResolveResponse(
          accepted: true,
          conflict: NasSyncConflictDetail(
            conflictId: 'nas-stock',
            changeId: 'stock-intent',
            entity: 'product_batches',
            entityId: 'batch-one',
            operation: 'inventory_command',
            reason: 'VERSION_CONFLICT',
            status: 'resolved',
            serverVersion: 2,
            resolution: {'action': 'keep_remote'},
          ),
        ),
      );
      for (final batch in ['batch-one', 'batch-two']) {
        expect(
          (await outbox.getConflict(guardIds[batch]!))!.resolution,
          'protection_retired_after_intent_settlement',
        );
      }
      expect(
        (await outbox.getConflict(guardIds['unrelated-batch']!))!.status,
        SyncConflictStatus.open,
      );
      expect(await outbox.hasSnapshotBlockingChanges(scopeId: scope), isTrue);
    },
  );

  test(
    'new requests reserve sequential entity versions and failed predecessors block successors',
    () async {
      await enqueue('one', base: 4);
      expect(
        await outbox.nextEntityBaseVersion(
          scopeId: scope,
          entity: 'products',
          entityId: 'product',
          serverVersion: 4,
        ),
        5,
      );
      await enqueue('two', base: 5);
      expect((await outbox.claimNext(scopeId: scope))!.changeId, 'one');
      expect(await outbox.claimNext(scopeId: scope), isNull);
      await outbox.markRejected(
        changeId: 'one',
        errorCode: 'VALIDATION',
        errorMessage: 'denied',
        confirmedByNas: true,
      );
      expect(await outbox.claimNext(scopeId: scope), isNull);
      expect(
        (await outbox.getByChangeId('two'))!.status,
        SyncOutboxStatus.blocked,
      );
      final original = (await outbox.getByChangeId('two'))!.requestJson;
      await outbox.abandonRejected(scopeId: scope, changeId: 'one');
      expect((await outbox.claimNext(scopeId: scope))!.requestJson, original);
    },
  );

  test(
    'identical persisted timestamps retain insertion order across restart and rejection',
    () async {
      await enqueue('z-first', base: 4);
      await enqueue('a-second', base: 5);
      await (database.update(database.syncOutbox)
        ..where((row) => row.scopeId.equals(scope))).write(
        SyncOutboxCompanion(createdAt: Value(DateTime.utc(2026, 10, 23))),
      );
      final restarted = SyncOutboxRepository(database);
      expect((await restarted.claimNext(scopeId: scope))!.changeId, 'z-first');
      expect(await restarted.claimNext(scopeId: scope), isNull);
      await restarted.markRejected(
        changeId: 'z-first',
        errorCode: 'DENIED',
        errorMessage: 'not applied',
        confirmedByNas: true,
      );
      expect(await restarted.claimNext(scopeId: scope), isNull);
      expect(
        (await restarted.getByChangeId('a-second'))!.status,
        SyncOutboxStatus.blocked,
      );
    },
  );

  test(
    'accepted receipt advances only entity metadata before the next local edit',
    () async {
      await inventory.applyRemoteProduct(
        productId: 'product',
        payload: {'name': 'optimistic', 'category': '食品'},
        version: 4,
        updatedAt: DateTime.utc(2026),
      );
      await enqueue('accepted', base: 4);
      await ready();
      final api = _Api();
      addTearDown(api.close);
      final engine = SyncEngine.withBusinessAdapter(
        api: api,
        repository: outbox,
        inventoryRepository: inventory,
        shoppingRepository: shopping,
        scopeId: scope,
        deviceId: 'device',
      );
      await engine.runOnce();
      final product = (await inventory.getProductRecord('product'))!;
      expect(product.serverVersion, 5);
      expect(product.name, 'optimistic');
      expect(
        await outbox.nextEntityBaseVersion(
          scopeId: scope,
          entity: 'products',
          entityId: 'product',
          serverVersion: product.serverVersion,
        ),
        5,
      );
    },
  );

  test(
    'missing individual push results increase per-request retry delay',
    () async {
      await enqueue('missing');
      await ready();
      final api = _Api()..omitResults = true;
      addTearDown(api.close);
      final engine = SyncEngine(
        api: api,
        repository: outbox,
        scopeId: scope,
        deviceId: 'device',
        applyRemoteChange: (_) async {},
      );
      await engine.runOnce();
      final first = (await outbox.getByChangeId('missing'))!;
      expect(first.lastErrorCode, 'missing_push_result');
      await (database.update(database.syncOutbox)..where(
        (row) => row.changeId.equals('missing'),
      )).write(const SyncOutboxCompanion(nextAttemptAt: Value(null)));
      await engine.runOnce();
      final second = (await outbox.getByChangeId('missing'))!;
      expect(second.attemptCount, 2);
      expect(
        second.nextAttemptAt!.difference(second.updatedAt).inMilliseconds,
        greaterThan(
          first.nextAttemptAt!.difference(first.updatedAt).inMilliseconds +
              1000,
        ),
      );
      expect(api.requests[0].single.toJson(), api.requests[1].single.toJson());
    },
  );

  test('wire permits only discard to carry a zero-quantity allocation', () {
    for (final command in [
      'discard',
      'consume_fefo',
      'consume_allocated',
      'restock',
    ]) {
      final change = NasSyncChange(
        changeId: 'zero',
        idempotencyKey: 'zero-original-idempotency-key',
        operation: 'inventory_command',
        command: command,
        operationId: 'stock-op',
        allocations: const [
          NasSyncInventoryAllocation(batchId: 'batch', quantity: 0),
        ],
      );
      if (command == 'discard') {
        expect(change.validateForPush, returnsNormally);
      } else {
        expect(change.validateForPush, throwsFormatException);
      }
    }
  });

  test(
    'deleted category binding cannot be reused by outbound inventory or initial import',
    () async {
      final categories = SyncCategoryRepository(database);
      await categories.save(
        scope,
        const InitialImportCategory(
          sourceName: '食品',
          categoryId: 'deleted',
          action: InitialImportCategoryAction.reuse,
        ),
      );
      await outbox.applyRemoteAuxiliaryEntity(
        scopeId: scope,
        entity: 'categories',
        entityId: 'deleted',
        payload: {'name': '食品'},
        version: 2,
        updatedAt: DateTime.utc(2026),
        deletedAt: DateTime.utc(2026),
      );
      expect(await categories.readId(scope, '食品'), isNull);
      expect(await categories.remoteCategories(scope), isEmpty);
    },
  );

  test(
    'fresh snapshot retires only explicitly abandoned new children before their parent',
    () async {
      final productId = await inventory.createProductWithBatch(
        const IntakeDraft(name: '米', category: '食品', quantity: 3),
      );
      final batch =
          (await database.select(database.productBatches).get()).single;
      for (final target in [
        ('product_batches', batch.id),
        ('products', productId),
      ]) {
        final entry = await enqueue(
          'new-${target.$1}',
          entity: target.$1,
          entityId: target.$2,
        );
        await outbox.markRejected(
          changeId: entry.changeId,
          errorCode: 'DENIED',
          errorMessage: 'not applied',
          confirmedByNas: true,
        );
        await outbox.abandonRejected(scopeId: scope, changeId: entry.changeId);
      }
      final empty = <String, dynamic>{
        'categories': [],
        'products': [],
        'product_batches': [],
        'shopping_items': [],
      };
      await expectLater(
        adapter.applyRemoteSnapshot(
          empty,
          10,
          onApplied: () async {
            throw StateError('receipt commit failed');
          },
        ),
        throwsStateError,
      );
      expect((await inventory.getProductRecord(productId))!.deletedAt, isNull);
      expect(await outbox.listAbandonedRejected(scopeId: scope), hasLength(2));
      await adapter.applyRemoteSnapshot(empty, 10);
      expect(
        await SyncOutboxRepository(
          database,
        ).listAbandonedRejected(scopeId: scope),
        isEmpty,
      );
      // A later snapshot must not re-evaluate already restored old refusals.
      await adapter.applyRemoteSnapshot(empty, 11);
      expect(
        (await inventory.getProductRecord(productId))!.deletedAt,
        isNotNull,
      );
      expect((await inventory.getBatchRecord(batch.id))!.deletedAt, isNotNull);
      expect(await database.select(database.stockMovements).get(), isNotEmpty);
    },
  );

  test(
    'missing rejected parent cannot hide a live child without explicit abandonment',
    () async {
      final productId = await inventory.createProductWithBatch(
        const IntakeDraft(name: '米', category: '食品', quantity: 3),
      );
      final entry = await enqueue('parent-only', entityId: productId);
      await outbox.markRejected(
        changeId: entry.changeId,
        errorCode: 'DENIED',
        errorMessage: 'not applied',
        confirmedByNas: true,
      );
      await outbox.abandonRejected(scopeId: scope, changeId: entry.changeId);
      await expectLater(
        adapter.applyRemoteSnapshot({
          'products': [],
          'product_batches': [],
        }, 10),
        throwsStateError,
      );
      expect((await inventory.getProductRecord(productId))!.deletedAt, isNull);
      expect(await outbox.getConflictResolutionRefreshToken(scope), isNotNull);
    },
  );
}
