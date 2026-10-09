import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/sync_change_control.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

class FakeSyncApi extends NasSyncApi {
  FakeSyncApi() : super('http://127.0.0.1:8080');

  NasSyncPullResponse response = const NasSyncPullResponse(
    changes: [], nextCursor: 10, hasMore: false,
  );
  int pullCalls = 0;
  int? requestedCursor;
  final List<int> requestedCursors = [];
  final List<NasSyncPullResponse> pages = [];
  Future<void> Function()? beforePull;
  Future<void> Function()? beforePush;

  final events = <String>[];
  final pushedChanges = <List<NasSyncChange>>[];
  final confirmRequests = <Map<String, dynamic>>[];
  int bootstrapCalls = 0;
  NasSyncBootstrap fresh = NasSyncBootstrap(
    schemaVersion: 1, syncProtocolVersion: 1, serverCursor: 11,
    mergeRequired: true, availableModes: const ['join_and_merge', 'create_new_family', 'keep_local_only'],
    snapshot: bootstrapSnapshot(quantity: 8), checkpoint: 'fresh-checkpoint',
  );
  NasSyncPushResponse? pushResponse;
  NasSyncConfirmResult? confirmation;
  Object? bootstrapError;
  Object? confirmationError;
  bool replayPush = false;
  Future<void> Function()? beforeBootstrap;
  Future<void> Function()? beforeConfirm;

  NasSyncVersions versions = const NasSyncVersions(schemaVersion: 1, syncProtocolVersion: 1);
  int capabilityReads = 0;
  Object? capabilityError;

  @override
  Future<NasSyncVersions> capabilities() async {
    capabilityReads++;
    if (capabilityError != null) throw capabilityError!;
    return versions;
  }

  @override
  Future<NasSyncBootstrap> bootstrap({required String deviceId}) async {
    events.add('bootstrap');
    bootstrapCalls++;
    if (beforeBootstrap != null) await beforeBootstrap!();
    if (bootstrapError != null) throw bootstrapError!;
    return fresh;
  }

  @override
  Future<NasSyncConfirmResult> confirmBootstrap({
    required String mode, required String deviceId, String? localWorkspaceId,
    int? snapshotCursor, String? checkpoint,
  }) async {
    events.add('confirm:$mode');
    confirmRequests.add({'mode': mode, 'cursor': snapshotCursor, 'checkpoint': checkpoint});
    if (beforeConfirm != null) await beforeConfirm!();
    if (confirmationError != null) throw confirmationError!;
    return confirmation ?? NasSyncConfirmResult(
      accepted: true, serverCursor: fresh.serverCursor, checkpoint: checkpoint,
      nextAction: mode == 'join_and_merge' ? 'pull_snapshot'
          : mode == 'create_new_family' ? 'push_local_changes' : 'keep_local_only',
    );
  }

  @override
  Future<NasSyncPushResponse> push({
    required String deviceId, required int baseCursor, required List<NasSyncChange> changes,
  }) async {
    events.add('push');
    if (beforePush != null) await beforePush!();
    pushedChanges.add(changes);
    final accepted = changes.map((change) => NasSyncAcceptedChange(
      changeId: change.changeId, serverCursor: 11, serverVersion: 1,
    )).toList();
    return pushResponse ?? NasSyncPushResponse(
      accepted: replayPush ? [] : accepted,
      replayed: replayPush ? accepted.map((entry) => NasSyncReplayedChange(
        changeId: entry.changeId, originalStatus: 'accepted', accepted: entry,
      )).toList() : [],
      conflicts: const [], rejected: const [], results: const [], cursor: 11,
    );
  }

  @override
  Future<NasSyncPullResponse> pull({
    required String deviceId, required int cursor, int limit = 100,
  }) async {
    events.add('pull');
    pullCalls++;
    requestedCursor = cursor;
    requestedCursors.add(cursor);
    final hook = beforePull;
    if (hook != null) await hook();
    return pages.isNotEmpty ? pages.removeAt(0) : response;
  }
}

class FailingCompletionRepository extends SyncOutboxRepository {
  FailingCompletionRepository(super.database);

  @override
  Future<void> clearPendingBootstrap(String scopeId) async {
    await super.clearPendingBootstrap(scopeId);
    throw StateError('injected completion-marker failure');
  }
}

class FailingResolutionCompletionRepository extends SyncOutboxRepository {
  FailingResolutionCompletionRepository(super.database);

  @override
  Future<bool> clearConflictResolutionRefresh({
    required String scopeId, required String token,
  }) async {
    await super.clearConflictResolutionRefresh(scopeId: scopeId, token: token);
    throw StateError('injected resolution-refresh completion failure');
  }
}

// A second receipt write would throw after the first real SQL commit.
class SingleReceiptWriteRepository extends SyncOutboxRepository {
  SingleReceiptWriteRepository(super.database);

  int receiptWrites = 0;

  @override
  Future<void> recordAppliedChange({
    required String scopeId, required String changeId, required int cursor,
    DateTime? appliedAt,
  }) async {
    receiptWrites++;
    if (receiptWrites > 1) throw StateError('unexpected duplicate receipt write');
    await super.recordAppliedChange(
      scopeId: scopeId, changeId: changeId, cursor: cursor, appliedAt: appliedAt,
    );
  }
}

Map<String, dynamic> bootstrapSnapshot({
  int? expiryDays = 30, int quantity = 2, bool enabled = true, int? openedDays,
}) => {
      'categories': [{'id': 'category', 'name': '食品', 'version': 1}],
      'products': [{'id': 'product', 'name': '牛奶', 'category_id': 'category', 'version': 1}],
      'product_batches': [{'id': 'batch', 'product_id': 'product', 'quantity': quantity, 'initial_quantity': quantity, 'version': 1}],
      'reminder_settings': [{
        'id': 'policy', 'product_id': 'product', 'enabled': enabled,
        if (expiryDays != null) 'expiry_warning_days': expiryDays,
        'low_stock_threshold': 3, 'opened_warning_days': openedDays, 'version': 1,
      }],
    };

void main() {
  const scope = 'family';
  late AppDatabase database;
  late FakeSyncApi api;
  late SyncOutboxRepository outbox;
  late InventoryRepository inventory;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    api = FakeSyncApi();
    outbox = SyncOutboxRepository(database);
    inventory = InventoryRepository(database, syncScopeId: scope);
  });
  tearDown(() async {
    api.close();
    await database.close();
  });

  SyncEngine engineWithBusinessAdapter(SyncOutboxRepository repository) =>
      SyncEngine.withBusinessAdapter(
        api: api, repository: repository,
        inventoryRepository: inventory, shoppingRepository: ShoppingRepository(database),
        scopeId: scope, deviceId: 'device',
      );

  Future<void> ready(SyncOutboxRepository repository) async {
    final state = await repository.ensureState(scopeId: scope, deviceId: 'device');
    await repository.saveState(state.copyWith(bootstrapStatus: SyncBootstrapStatus.ready));
  }

  Future<void> pendingSnapshot({String? mode = 'join_and_merge', bool refreshRequired = false}) =>
      outbox.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(),
        serverCursor: 10, checkpoint: 'old-checkpoint', mode: mode, refreshRequired: refreshRequired);

  Future<void> enqueueStock({String id = 'local-stock', SyncOutboxStatus status = SyncOutboxStatus.pending}) =>
      outbox.enqueue(SyncOutboxDraft(
        changeId: id, scopeId: scope, operation: SyncOperation.inventoryCommand,
        status: status, command: 'consume_allocated', operationId: 'operation-$id',
        idempotencyKey: 'idempotency-$id-stock-key', requestJson: jsonEncode({
          'command': 'consume_allocated', 'operation_id': 'operation-$id',
          'allocations': [{'batch_id': 'batch', 'quantity': 1, 'base_version': 1}],
        }),
      )).then((_) {});

  Future<void> completedRemoteMode({String mode = 'join_and_merge'}) async {
    await ready(outbox);
    await pendingSnapshot(mode: mode);
    await outbox.clearPendingBootstrap(scope);
  }

  Future<void> settleConflict({
    String id = 'resolved-stock', String action = 'keep_remote',
    bool stock = true,
  }) async {
    final operation = stock ? SyncOperation.inventoryCommand : SyncOperation.entityUpsert;
    final entity = stock ? 'product_batches' : 'products';
    final entityId = stock ? 'batch' : 'product';
    await outbox.enqueue(SyncOutboxDraft(
      changeId: id, scopeId: scope, operation: operation,
      entity: entity, entityId: entityId,
      operationId: stock ? 'operation-$id' : null,
      command: stock ? 'consume_allocated' : null,
      idempotencyKey: 'idempotency-$id-original-key', requestJson: jsonEncode({
        'operation': operation.wireValue, 'entity': entity, 'entity_id': entityId,
        if (stock) 'command': 'consume_allocated',
        if (stock) 'operation_id': 'operation-$id',
        if (stock) 'allocations': [{'batch_id': 'batch', 'quantity': 1, 'base_version': 1}],
        if (!stock) 'payload': {'name': '本地名称'},
      }),
    ));
    await outbox.markConflict(changeId: id, conflict: SyncConflictDraft(
      scopeId: scope, changeId: id, outboxChangeId: id,
      entity: entity, entityId: entityId, reason: 'VERSION_MISMATCH',
    ));
    final conflict = (await outbox.getConflictByChangeId(scopeId: scope, changeId: id))!;
    await outbox.settleOutboxConflict(
      conflictId: conflict.id, scopeId: scope, changeId: id,
      remoteConflictId: 'remote-$id', action: action,
      response: NasSyncConflictResolveResponse(accepted: true,
        conflict: NasSyncConflictDetail(
          conflictId: 'remote-$id', changeId: id, operation: operation.wireValue,
          entity: entity, entityId: entityId, reason: 'VERSION_MISMATCH',
          status: 'resolved', resolution: {'action': action},
        ),
      ),
    );
  }

  Future<void> expireBackoff() async {
    final state = (await outbox.getState(scope))!;
    await outbox.saveState(state.copyWith(nextRetryAt: DateTime.utc(2000)));
  }

  Future<void> seedCommandBatches() async {
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '牛奶', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    for (final entry in {'batch-a': 10, 'batch-b': 8}.entries) {
      await inventory.applyRemoteProductBatch(
        batchId: entry.key,
        payload: {'product_id': 'product', 'quantity': entry.value},
        version: 1, updatedAt: DateTime.utc(2026),
      );
    }
  }

  NasSyncPullChange remoteCommand({
    String id = 'inventory-command', int cursor = 2, int version = 2,
    String secondBatch = 'batch-b', String command = 'consume_allocated',
  }) => NasSyncPullChange(
    changeId: id, cursor: cursor, operation: 'inventory_command',
    entity: 'product_batches', entityId: 'batch-a', command: command,
    version: version,
    payload: {
      'command': command, 'operation_id': 'operation-$id',
      'allocations': [
        {'batch_id': 'batch-a', 'quantity': 3,
          'final_quantity': command == 'restock' ? 13 : 7, 'after_version': version},
        if (command != 'restock') {'batch_id': secondBatch, 'quantity': 2,
          'final_quantity': 6, 'after_version': version},
      ],
    },
  );

  test('成功快照与完成标记一起提交，之后才拉增量且可重复运行', () async {
    await ready(outbox);
    await outbox.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(), serverCursor: 10);
    final engine = engineWithBusinessAdapter(outbox);
    final result = await engine.runOnce();
    expect(result.skipped, isFalse);
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect((await inventory.loadInventory()).single.lowStockThreshold, 3);
    expect((await outbox.getState(scope))!.pullCursor, 10);
    await engine.runOnce();
    expect(await database.select(database.productBatches).get(), hasLength(1));
    expect(api.pullCalls, 2);
  });

  test('后端七天及关闭策略快照兼容，原子提交快照游标后再 pull', () async {
    await ready(outbox);
    await outbox.savePendingBootstrap(scopeId: scope,
      snapshot: bootstrapSnapshot(expiryDays: 7, enabled: false), serverCursor: 10);
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 0);
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect((await outbox.getState(scope))!.pullCursor, 10);
    expect(api.requestedCursor, 10);
    final policy = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'policy',
    );
    expect((policy!['payload'] as Map)['expiry_warning_days'], 7);
    expect((policy['payload'] as Map)['enabled'], isFalse);
    expect(api.pushedChanges, isEmpty);
  });

  test('开封提醒仍 unsupported，快照全部回滚并保留待恢复标记', () async {
    await ready(outbox);
    await outbox.savePendingBootstrap(scopeId: scope,
      snapshot: bootstrapSnapshot(expiryDays: 7, openedDays: 3), serverCursor: 10);
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsFormatException);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect((await outbox.getState(scope))!.lastSuccessAt, isNull);
    expect(await outbox.getPendingBootstrap(scope), isNotNull);
    expect(await database.select(database.products).get(), isEmpty);
    expect(api.pullCalls, 0);
  });

  test('没有业务 snapshot 回调不能默默继续 pull 并报告成功', () async {
    await ready(outbox);
    await outbox.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(), serverCursor: 10);
    final engine = SyncEngine(
      api: api, repository: outbox, scopeId: scope, deviceId: 'device',
      applyRemoteChange: (_) async {},
    );
    await expectLater(engine.runOnce(), throwsFormatException);
    expect(api.pullCalls, 0);
    expect((await outbox.getState(scope))!.lastSuccessAt, isNull);
    expect(await outbox.getPendingBootstrap(scope), isNotNull);
  });

  test('具体 adapter 完成标记失败：数据与标记删除均回滚', () async {
    final failing = FailingCompletionRepository(database);
    await ready(failing);
    await failing.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(), serverCursor: 10);
    await expectLater(engineWithBusinessAdapter(failing).runOnce(), throwsStateError);
    expect(await failing.getPendingBootstrap(scope), isNotNull);
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
    expect(api.pullCalls, 0);
    expect((await failing.getState(scope))!.pullCursor, 0);
  });

  test('初始 ready 无已确认 mode 但有 pending，不盲推或自动选择模式', () async {
    await ready(outbox);
    await outbox.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(), serverCursor: 10);
    await outbox.enqueue(const SyncOutboxDraft(
      changeId: 'pending-product', scopeId: scope,
      operation: SyncOperation.entityUpsert, entity: 'products', entityId: 'product',
      idempotencyKey: 'pending-product-idempotency-key', requestJson: '{}',
    ));
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.skipped, isTrue);
    expect(report.deferred, 1);
    expect(await outbox.listOpenConflicts(scopeId: scope), isEmpty);
    expect(api.pushedChanges, isEmpty);
    expect(api.confirmRequests, isEmpty);
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.awaitingConfirmation);
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.pending);
    expect(await outbox.getPendingBootstrap(scope), isNotNull);
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect(api.pullCalls, 0);
  });

  test('categories/reminder_settings 支持的增量应用之后记录 applied 和游标', () async {
    await ready(outbox);
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '牛奶', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    api.response = const NasSyncPullResponse(changes: [
      NasSyncPullChange(changeId: 'category-change', cursor: 1,
        operation: 'entity_upsert', entity: 'categories', entityId: 'category',
        version: 1, payload: {'name': '食品'}),
      NasSyncPullChange(changeId: 'policy-change', cursor: 2,
        operation: 'entity_upsert', entity: 'reminder_settings', entityId: 'policy',
        version: 1, payload: {'product_id': 'product', 'enabled': true,
          'expiry_warning_days': 30, 'low_stock_threshold': 3}),
    ], nextCursor: 2, hasMore: false);
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.pulled, 2);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'policy-change'), isTrue);
    expect((await outbox.getState(scope))!.pullCursor, 2);
    expect((await inventory.loadInventory()).single.lowStockThreshold, 3);
  });

  test('七天 enabled=false 增量业务生效后才记录 applied 与游标', () async {
    await ready(outbox);
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '牛奶', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    api.response = const NasSyncPullResponse(changes: [
      NasSyncPullChange(changeId: 'seven-day-policy', cursor: 1,
        operation: 'entity_upsert', entity: 'reminder_settings', entityId: 'policy',
        version: 1, payload: {'product_id': 'product', 'enabled': false,
          'expiry_warning_days': 7, 'low_stock_threshold': 3}),
    ], nextCursor: 1, hasMore: false);
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.pulled, 1);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'seven-day-policy'), isTrue);
    expect((await outbox.getState(scope))!.pullCursor, 1);
  });

  test('真实 adapter 已原子写 receipt 时 engine 不重复写，回放不再补充库存', () async {
    await seedCommandBatches();
    final once = SingleReceiptWriteRepository(database);
    await ready(once);
    final command = remoteCommand(command: 'restock');
    api.response = NasSyncPullResponse(
      changes: [command], nextCursor: 2, hasMore: false,
    );
    final engine = engineWithBusinessAdapter(once);
    final report = await engine.runOnce();
    expect(report.pulled, 1);
    expect(report.deferred, 0);
    expect(once.receiptWrites, 1);
    final receipt = (await once.listAppliedChanges(scopeId: scope)).single;
    expect((await once.getState(scope))!.lastSuccessAt, isNotNull);
    expect((await once.getState(scope))!.pullCursor, 2);
    // Replay the exact page; do not fake an empty response to avoid the replay path.
    final replay = await engine.runOnce();
    expect(replay.pulled, 0);
    expect(once.receiptWrites, 1);
    expect(api.requestedCursors, [0, 2]);
    expect((await once.listAppliedChanges(scopeId: scope)).single.appliedAt, receipt.appliedAt);
    final a = (await inventory.getBatchRecord('batch-a'))!;
    final b = (await inventory.getBatchRecord('batch-b'))!;
    expect([a.remainingQuantity, a.initialQuantity], [13, 13]);
    expect([b.remainingQuantity, b.initialQuantity], [8, 8]);
  });

  test('库存命令失败后只保留前一条安全游标，重试从失败命令继续而非伪成功', () async {
    await seedCommandBatches();
    await ready(outbox);
    const first = NasSyncPullChange(
      changeId: 'first-category', cursor: 1, operation: 'entity_upsert',
      entity: 'categories', entityId: 'first-category', version: 1,
      payload: {'name': '食品'},
    );
    const later = NasSyncPullChange(
      changeId: 'later-category', cursor: 3, operation: 'entity_upsert',
      entity: 'categories', entityId: 'later-category', version: 1,
      payload: {'name': '饮品'},
    );
    api.response = NasSyncPullResponse(
      changes: [first, remoteCommand(secondBatch: 'missing'), later],
      nextCursor: 3, hasMore: false,
    );
    final engine = engineWithBusinessAdapter(outbox);
    await expectLater(engine.runOnce(), throwsFormatException);
    final failed = (await outbox.getState(scope))!;
    expect(failed.pullCursor, 1);
    expect(failed.lastSuccessAt, isNull);
    expect(failed.lastErrorCode, 'sync_failed');
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'first-category'), isTrue);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'inventory-command'), isFalse);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'later-category'), isFalse);
    expect(await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'categories', entityId: 'later-category',
    ), isNull);
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 10);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 8);

    // Simulate the documented retry delay expiring, not a successful engine result.
    await outbox.saveState(failed.copyWith(nextRetryAt: DateTime.utc(2000)));
    api.response = NasSyncPullResponse(
      changes: [remoteCommand(), later], nextCursor: 3, hasMore: false,
    );
    final retried = await engine.runOnce();
    expect(retried.pulled, 2);
    expect(api.requestedCursors, [0, 1]);
    expect((await outbox.getState(scope))!.pullCursor, 3);
    expect((await outbox.getState(scope))!.lastErrorCode, isNull);
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 7);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 6);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(3));
    final replay = await engine.runOnce();
    expect(replay.pulled, 0);
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 7);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(3));
  });

  test('分页网络请求中出现真实 pending，保留已提交游标但不越过库存冲突', () async {
    await seedCommandBatches();
    await ready(outbox);
    api.pages.addAll([
      NasSyncPullResponse(
        changes: [remoteCommand(id: 'first-command', cursor: 1)],
        nextCursor: 1, hasMore: true,
      ),
      NasSyncPullResponse(
        changes: [
          remoteCommand(id: 'blocked-command', cursor: 2, version: 3),
          const NasSyncPullChange(
            changeId: 'after-conflict', cursor: 3, operation: 'entity_upsert',
            entity: 'categories', entityId: 'after-conflict', version: 1,
            payload: {'name': '不应应用'},
          ),
        ], nextCursor: 3, hasMore: false,
      ),
    ]);
    api.beforePull = () async {
      if (api.pullCalls != 2) return;
      await outbox.enqueue(const SyncOutboxDraft(
        changeId: 'pending-during-pull', scopeId: scope,
        operation: SyncOperation.inventoryCommand,
        idempotencyKey: 'pending-during-pull-key', requestJson: '{}',
      ));
    };
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.pulled, 1);
    expect(report.deferred, 1);
    expect(api.requestedCursors, [0, 1]);
    final state = (await outbox.getState(scope))!;
    expect(state.pullCursor, 1);
    expect(state.lastSuccessAt, isNull);
    expect(state.lastErrorCode, 'sync_conflict_deferred');
    expect((await inventory.getBatchRecord('batch-a'))!.serverVersion, 2);
    expect((await inventory.getBatchRecord('batch-b'))!.serverVersion, 2);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'blocked-command'), isFalse);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'after-conflict'), isFalse);
    expect((await outbox.listOpenConflicts(scopeId: scope)).single.outboxChangeId, 'pending-during-pull');
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.pending);
  });

  test('回放旧页面 nextCursor 不得回退已提交的安全游标', () async {
    await seedCommandBatches();
    await ready(outbox);
    final engine = engineWithBusinessAdapter(outbox);
    api.response = NasSyncPullResponse(
      changes: [remoteCommand(cursor: 2)], nextCursor: 2, hasMore: false,
    );
    await engine.runOnce();
    api.response = const NasSyncPullResponse(changes: [], nextCursor: 1, hasMore: false);
    final replay = await engine.runOnce();
    expect(replay.pulled, 0);
    expect((await outbox.getState(scope))!.pullCursor, 2);
    expect((await outbox.listAppliedChanges(scopeId: scope)).single.cursor, 2);
  });

  for (final mode in <String?>[null, 'unsupported_mode']) {
    for (final hasPendingCommand in [false, true]) {
      test('refresh 的空值/非法模式不推送、不确认、不覆盖快照：'
          '$mode，pending=$hasPendingCommand', () async {
        await ready(outbox);
        await pendingSnapshot(mode: mode, refreshRequired: true);
        if (hasPendingCommand) {
          await enqueueStock();
        }
        final pendingBefore = await outbox.getPendingBootstrap(scope);
        final stateBefore = (await outbox.getState(scope))!;
        final entryBefore = await outbox.getByChangeId('local-stock');

        final report = await engineWithBusinessAdapter(outbox).runOnce();

        expect(report.pushed, 0);
        expect(report.pulled, 0);
        expect(report.deferred, 1);
        expect(report.hasMorePending, isFalse);
        expect(report.hasMoreRemote, isFalse);
        expect(api.capabilityReads, 1);
        expect(api.events, isEmpty);
        expect(api.pushedChanges, isEmpty);
        expect(api.confirmRequests, isEmpty);
        expect(await outbox.getPendingBootstrap(scope), pendingBefore);
        expect(await outbox.getConfirmedBootstrapMode(scope), mode);
        expect(await inventory.getProductRecord('product'), isNull);
        expect(await inventory.getBatchRecord('batch'), isNull);
        final stateAfter = (await outbox.getState(scope))!;
        expect(stateAfter.pullCursor, stateBefore.pullCursor);
        expect(stateAfter.pushAckCursor, stateBefore.pushAckCursor);
        expect(stateAfter.lastSuccessAt, stateBefore.lastSuccessAt);
        if (hasPendingCommand) {
          final entryAfter = (await outbox.getByChangeId('local-stock'))!;
          final expectedEntry = entryBefore!;
          expect(entryAfter.status, SyncOutboxStatus.pending);
          expect(entryAfter.attemptCount, expectedEntry.attemptCount);
          expect(entryAfter.idempotencyKey, expectedEntry.idempotencyKey);
          expect(entryAfter.requestJson, expectedEntry.requestJson);
        } else {
          expect(await outbox.listOutbox(scopeId: scope), isEmpty);
        }
      });
    }
  }

  test('join 推送原幂等操作后 refresh/confirm 新 checkpoint，不能套旧快照', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    // Pre-existing same-version difference must converge with fresh authority.
    await inventory.applyRemoteProduct(productId: 'product',
      payload: {'name': '牛奶', 'category': '食品'}, version: 1, updatedAt: DateTime.utc(2026));
    await inventory.applyRemoteProductBatch(batchId: 'batch',
      payload: {'product_id': 'product', 'quantity': 4}, version: 1, updatedAt: DateTime.utc(2026));
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.pushed, 1);
    expect(report.deferred, 0);
    expect(api.events, ['push', 'bootstrap', 'confirm:join_and_merge', 'pull']);
    expect(api.pushedChanges.single.single.idempotencyKey, 'idempotency-local-stock-stock-key');
    expect(api.confirmRequests.single, {'mode': 'join_and_merge', 'cursor': 11, 'checkpoint': 'fresh-checkpoint'});
    expect(api.requestedCursor, 11);
    final batch = (await inventory.getBatchRecord('batch'))!;
    expect([batch.remainingQuantity, batch.initialQuantity, batch.serverVersion], [8, 8, 1]);
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect(await outbox.getConfirmedBootstrapMode(scope), 'join_and_merge');
    expect(await database.select(database.stockMovements).get(), isEmpty);
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.bootstrapCalls, 1);
    expect(api.pushedChanges, hasLength(1));
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
  });

  test('create_new_family refresh 重确认原 create 模式，不能改成 join', () async {
    await ready(outbox);
    await pendingSnapshot(mode: 'create_new_family');
    await enqueueStock();
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.events, ['push', 'bootstrap', 'confirm:create_new_family', 'pull']);
    expect(await outbox.getConfirmedBootstrapMode(scope), 'create_new_family');
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
    // User-visible later bootstrap preserves the chosen mode, but a fetched
    // snapshot cannot leave the old ready state silently enabled.
    await engineWithBusinessAdapter(outbox).bootstrap();
    expect((await outbox.getPendingBootstrap(scope))!['mode'], 'create_new_family');
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.awaitingConfirmation);
  });

  test('create 模式没有 outbox 也重新取快照，不应用选择前旧家庭数量', () async {
    await ready(outbox);
    await pendingSnapshot(mode: 'create_new_family');
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.pushedChanges, isEmpty);
    expect(api.events, ['bootstrap', 'confirm:create_new_family', 'pull']);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
  });

  test('keep_local_only 不依赖 checkpoint，重启仍禁止 push/pull/快照覆盖', () async {
    await ready(outbox);
    await pendingSnapshot(mode: null);
    await enqueueStock();
    await engineWithBusinessAdapter(outbox).confirmBootstrap(mode: 'keep_local_only');
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.skipped, isTrue);
    expect(api.pushedChanges, isEmpty);
    expect(api.pullCalls, 0);
    expect(await outbox.getConfirmedBootstrapMode(scope), 'keep_local_only');
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.pending);
    expect(await database.select(database.productBatches).get(), isEmpty);
  });

  test('已完成旧客户端 ready 无 pending 与无 mode，保留普通幂等 push/pull', () async {
    await ready(outbox);
    await enqueueStock();
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.pushed, 1);
    expect(api.events, ['push', 'pull']);
    expect(api.bootstrapCalls, 0);
    expect(api.confirmRequests, isEmpty);
    expect(await outbox.getConfirmedBootstrapMode(scope), isNull);
  });

  test('有 pending 未确认首次 bootstrap，不发送任何本地操作', () async {
    api.fresh = NasSyncBootstrap(schemaVersion: 1, syncProtocolVersion: 1,
      serverCursor: 10, mergeRequired: true,
      availableModes: const ['join_and_merge'], snapshot: bootstrapSnapshot(), checkpoint: 'initial-checkpoint');
    final engine = engineWithBusinessAdapter(outbox);
    await engine.bootstrap();
    await enqueueStock();
    final report = await engine.runOnce();
    expect(report.skipped, isTrue);
    expect(api.events, ['bootstrap']);
    expect(await outbox.getConfirmedBootstrapMode(scope), isNull);
  });

  test('mergeRequired=false 的 initial ready 仍不是自动选择模式', () async {
    api.fresh = NasSyncBootstrap(schemaVersion: 1, syncProtocolVersion: 1,
      serverCursor: 0, mergeRequired: false, availableModes: const ['join_and_merge'],
      snapshot: bootstrapSnapshot(), checkpoint: 'empty-family-checkpoint');
    final engine = engineWithBusinessAdapter(outbox);
    await engine.bootstrap();
    await enqueueStock();
    final report = await engine.runOnce();
    expect(report.deferred, 1);
    expect(api.events, ['bootstrap']);
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.pending);
    expect(await database.select(database.products).get(), isEmpty);
  });

  test('库存不足被拒保留 outbox/快照/游标，不能以 terminal 为由覆盖', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    api.pushResponse = const NasSyncPushResponse(accepted: [], replayed: [], conflicts: [],
      rejected: [NasSyncRejectedChange(changeId: 'local-stock', code: 'INSUFFICIENT_STOCK', message: '库存不足')],
      results: [], cursor: 10);
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.rejected);
    expect(api.events, ['push']);
    expect((await outbox.getPendingBootstrap(scope))!['refresh_required'], isTrue);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect((await outbox.getState(scope))!.lastSuccessAt, isNull);
    expect(await database.select(database.products).get(), isEmpty);
    final retry = await engineWithBusinessAdapter(outbox).runOnce();
    expect(retry.deferred, 1);
    expect(api.pushedChanges, hasLength(1));
    expect(api.bootstrapCalls, 0);
  });

  test('open conflict 或未超时 inFlight 不完成快照，保留原记录', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock(status: SyncOutboxStatus.inFlight);
    final id = await outbox.recordConflict(const SyncConflictDraft(
      scopeId: scope, changeId: 'remote-conflict', entity: 'product_batches', reason: 'VERSION_CONFLICT'));
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect((await outbox.getConflict(id))!.status, SyncConflictStatus.open);
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.inFlight);
    expect(api.events, isEmpty);
    expect(await outbox.getPendingBootstrap(scope), isNotNull);
  });

  test('maxPush 分界：尚有 pending 时不 refresh；全部 accepted 后重新取快照', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock(id: 'first');
    await enqueueStock(id: 'second');
    final first = await engineWithBusinessAdapter(outbox).runOnce(maxPush: 1);
    expect(first.pushed, 1);
    expect(first.deferred, 1);
    expect(first.hasMorePending, isTrue);
    expect(api.bootstrapCalls, 0);
    final second = await engineWithBusinessAdapter(outbox).runOnce(maxPush: 1);
    expect(second.pushed, 1);
    expect(second.deferred, 0);
    expect(second.hasMorePending, isFalse);
    expect(api.events, ['push', 'push', 'bootstrap', 'confirm:join_and_merge', 'pull']);
    expect(await outbox.getPendingBootstrap(scope), isNull);
  });

  test('推送 accepted 后 refresh 网络失败，重启不能套旧快照且不重推新操作', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    api.bootstrapError = StateError('injected refresh failure');
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsStateError);
    expect((await outbox.getPendingBootstrap(scope))!['refresh_required'], isTrue);
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.accepted);
    expect(await database.select(database.products).get(), isEmpty);
    api.bootstrapError = null;
    await expireBackoff();
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.pushedChanges, hasLength(1));
    expect(api.bootstrapCalls, 2);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
  });

  test('原幂等请求 replayed accepted 后仅按 fresh 数量收敛，不重复扣减', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    api.replayPush = true;
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.pushed, 1);
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.replayed);
    expect(api.pushedChanges.single.single.changeId, 'local-stock');
    expect(api.pushedChanges.single.single.operationId, 'operation-local-stock');
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
    expect(await database.select(database.stockMovements).get(), isEmpty);
  });

  test('fresh checkpoint rejected 不应用 fresh/旧快照且保留用户 mode', () async {
    await ready(outbox);
    await pendingSnapshot(mode: 'create_new_family');
    await enqueueStock();
    api.confirmation = const NasSyncConfirmResult(accepted: false,
      nextAction: 'push_local_changes', serverCursor: 11, checkpoint: 'fresh-checkpoint');
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.blocked);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    final pending = (await outbox.getPendingBootstrap(scope))!;
    expect(pending['checkpoint'], 'fresh-checkpoint');
    expect(pending['mode'], 'create_new_family');
    expect(pending['refresh_required'], isTrue);
    expect(await database.select(database.products).get(), isEmpty);
    expect(api.pullCalls, 0);
  });

  test('fresh confirm HTTP stale checkpoint：失败后仍能按原 mode 重新 fetch/confirm', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    api.confirmationError = NasApiError(kind: NasApiErrorKind.conflict,
      message: 'stale', code: 'BOOTSTRAP_CHECKPOINT_STALE', statusCode: 409);
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsA(isA<NasApiError>()));
    expect((await outbox.getPendingBootstrap(scope))!['refresh_required'], isTrue);
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.awaitingConfirmation);
    expect(await database.select(database.productBatches).get(), isEmpty);
    api.confirmationError = null;
    await expireBackoff();
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.pushedChanges, hasLength(1));
    expect(api.bootstrapCalls, 2);
    expect(api.confirmRequests.map((row) => row['mode']), ['join_and_merge', 'join_and_merge']);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
  });

  for (final invalid in [
    const NasSyncConfirmResult(accepted: true, nextAction: 'pull_snapshot', serverCursor: 999, checkpoint: 'wrong-token'),
    const NasSyncConfirmResult(accepted: true, nextAction: 'push_local_changes', serverCursor: 11, checkpoint: 'fresh-checkpoint'),
    const NasSyncConfirmResult(accepted: true, nextAction: 'pull_snapshot', serverCursor: 10, checkpoint: 'fresh-checkpoint'),
  ]) {
    test('accepted 但 checkpoint/mode/cursor 回执不匹配时 fail closed: ${invalid.nextAction}/${invalid.checkpoint}/${invalid.serverCursor}', () async {
      await ready(outbox);
      await pendingSnapshot();
      await enqueueStock();
      api.confirmation = invalid;
      await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsFormatException);
      expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.blocked);
      expect(await outbox.getPendingBootstrap(scope), isNotNull);
      expect((await outbox.getState(scope))!.pushAckCursor, 11);
      expect(await database.select(database.products).get(), isEmpty);
      expect(api.pullCalls, 0);
    });
  }

  test('fresh 快照游标早于 push ack 时拒绝，保留原 pending 而非清掉', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    api.fresh = NasSyncBootstrap(schemaVersion: 1, syncProtocolVersion: 1,
      serverCursor: 9, mergeRequired: true, availableModes: const ['join_and_merge'],
      snapshot: bootstrapSnapshot(quantity: 99), checkpoint: 'too-old');
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsFormatException);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'old-checkpoint');
    expect((await outbox.getPendingBootstrap(scope))!['refresh_required'], isTrue);
    expect(api.confirmRequests, isEmpty);
    expect(await database.select(database.products).get(), isEmpty);
  });

  test('push 后 fresh 缺 snapshot 不能以旧快照完成；缺 token 同样拒绝', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock();
    api.fresh = const NasSyncBootstrap(schemaVersion: 1, syncProtocolVersion: 1,
      serverCursor: 11, mergeRequired: true, availableModes: ['join_and_merge'], checkpoint: 'no-snapshot');
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsFormatException);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'old-checkpoint');
    await expireBackoff();
    api.fresh = NasSyncBootstrap(schemaVersion: 1, syncProtocolVersion: 1,
      serverCursor: 11, mergeRequired: true, availableModes: const ['join_and_merge'], snapshot: bootstrapSnapshot());
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsFormatException);
    expect(api.confirmRequests, isEmpty);
    expect(api.pushedChanges, hasLength(1));
    expect(await database.select(database.products).get(), isEmpty);
  });

  test('网络 refresh/confirm 期间到达 pending，复检不覆盖本地操作', () async {
    await ready(outbox);
    await pendingSnapshot();
    await enqueueStock(id: 'original');
    api.beforeConfirm = () => enqueueStock(id: 'arrived-during-confirm');
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'fresh-checkpoint');
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect((await outbox.listOutbox(scopeId: scope)).where((row) => row.status == SyncOutboxStatus.pending).single.changeId,
      'arrived-during-confirm');
    expect(api.pullCalls, 0);
  });

  test('自定义快照 callback 中新 edit 导致业务/游标/完成标记同事务回滚', () async {
    await ready(outbox);
    await pendingSnapshot();
    final engine = SyncEngine(api: api, repository: outbox, scopeId: scope, deviceId: 'device',
      applyRemoteChange: (_) async {}, applyRemoteSnapshot: (_, __) async {
        await inventory.applyRemoteProduct(productId: 'partial', payload: {'name': '部分', 'category': '食品'},
          version: 1, updatedAt: DateTime.utc(2026));
        await enqueueStock(id: 'during-apply');
      });
    final report = await engine.runOnce();
    expect(report.deferred, 1);
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'old-checkpoint');
    expect(await outbox.listOutbox(scopeId: scope), isEmpty);
    expect(api.pullCalls, 0);
  });

  test('refresh 请求期间选择 keep_local_only，迟到快照不能覆盖用户选择', () async {
    await ready(outbox);
    await pendingSnapshot(refreshRequired: true);
    final engine = engineWithBusinessAdapter(outbox);
    api.beforeBootstrap = () => engine.confirmBootstrap(mode: 'keep_local_only').then((_) {});
    final report = await engine.runOnce();
    expect(report.deferred, 1);
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.keepLocalOnly);
    expect(await outbox.getConfirmedBootstrapMode(scope), 'keep_local_only');
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect(await database.select(database.products).get(), isEmpty);
    expect(api.confirmRequests.single['mode'], 'keep_local_only');
    expect(api.pullCalls, 0);
  });

  test('手动 bootstrap 期间改变用户模式，迟到响应不能恢复远端同步', () async {
    await ready(outbox);
    await pendingSnapshot();
    final engine = engineWithBusinessAdapter(outbox);
    api.beforeBootstrap = () => engine.confirmBootstrap(mode: 'keep_local_only').then((_) {});
    await expectLater(engine.bootstrap(), throwsA(isA<SyncRemoteChangeDeferred>()));
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.keepLocalOnly);
    expect(await outbox.getConfirmedBootstrapMode(scope), 'keep_local_only');
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect(api.pullCalls, 0);
  });

  test('手动 bootstrap 保留已持久化的推送后 refresh 标记', () async {
    await ready(outbox);
    await pendingSnapshot(refreshRequired: true);
    final engine = engineWithBusinessAdapter(outbox);
    await engine.bootstrap();
    expect((await outbox.getPendingBootstrap(scope))!['refresh_required'], isTrue);
    await engine.confirmBootstrap(mode: 'join_and_merge');
    await engine.runOnce();
    expect(api.bootstrapCalls, 2);
    expect(api.confirmRequests, hasLength(2));
    expect(await outbox.getPendingBootstrap(scope), isNull);
  });

  test('推送后手动 bootstrap 缺快照，不能清除持久化 refresh 保护', () async {
    await ready(outbox);
    await pendingSnapshot(refreshRequired: true);
    api.fresh = const NasSyncBootstrap(schemaVersion: 1, syncProtocolVersion: 1,
      serverCursor: 11, mergeRequired: true, availableModes: ['join_and_merge'], checkpoint: 'no-snapshot');
    await expectLater(engineWithBusinessAdapter(outbox).bootstrap(), throwsFormatException);
    final pending = (await outbox.getPendingBootstrap(scope))!;
    expect(pending['checkpoint'], 'old-checkpoint');
    expect(pending['refresh_required'], isTrue);
    expect((await outbox.getState(scope))!.pullCursor, 0);
  });

  test('apply callback 内 checkpoint 被换，不能完成新 checkpoint 或部分提交', () async {
    await ready(outbox);
    await pendingSnapshot();
    final engine = SyncEngine(api: api, repository: outbox, scopeId: scope, deviceId: 'device',
      applyRemoteChange: (_) async {}, applyRemoteSnapshot: (_, __) async {
        await inventory.applyRemoteProduct(productId: 'partial', payload: {'name': '部分', 'category': '食品'},
          version: 1, updatedAt: DateTime.utc(2026));
        await outbox.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(),
          serverCursor: 10, checkpoint: 'rotated-during-apply', mode: 'join_and_merge');
      });
    await expectLater(engine.runOnce(), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'old-checkpoint');
    expect((await outbox.getState(scope))!.pullCursor, 0);
  });

  test('快照 cursor 提交失败，数据与 pending 完成状态都不提交', () async {
    await ready(outbox);
    await pendingSnapshot();
    await database.customStatement("""
      CREATE TRIGGER fail_snapshot_cursor BEFORE UPDATE ON sync_states
      WHEN NEW.pull_cursor > OLD.pull_cursor
      BEGIN SELECT RAISE(ABORT, 'snapshot cursor failure'); END
    """);
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsA(isA<Exception>()));
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect(await outbox.getPendingBootstrap(scope), isNotNull);
  });

  test('远端 confirm 无 token 的旧 pending fail closed，本地模式不受限制', () async {
    await ready(outbox);
    await outbox.savePendingBootstrap(scopeId: scope, snapshot: bootstrapSnapshot(), serverCursor: 10);
    await expectLater(engineWithBusinessAdapter(outbox).confirmBootstrap(mode: 'join_and_merge'), throwsFormatException);
    expect(api.confirmRequests, isEmpty);
    await engineWithBusinessAdapter(outbox).confirmBootstrap(mode: 'keep_local_only');
    expect(api.confirmRequests.single['mode'], 'keep_local_only');
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.keepLocalOnly);
  });


  test('已完成bootstrap的keep_remote库存冲突仍fetch全新快照，不重发原命令', () async {
    await completedRemoteMode();
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '牛奶', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    await inventory.applyRemoteProductBatch(
      batchId: 'batch', payload: {'product_id': 'product', 'quantity': 2, 'initial_quantity': 8},
      version: 1, updatedAt: DateTime.utc(2026), applyQuantity: true, authoritativeSnapshot: true,
    );
    await settleConflict();
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect(await outbox.hasSnapshotBlockingChanges(scopeId: scope), isFalse);
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 0);
    expect(report.pushed, 0);
    expect(api.pushedChanges, isEmpty);
    expect(api.events, ['bootstrap', 'confirm:join_and_merge', 'pull']);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
    expect((await outbox.getByChangeId('resolved-stock'))!.status, SyncOutboxStatus.conflict);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
    expect((await outbox.getState(scope))!.pullCursor, 11);
  });

  test('keep_local实体已由NAS执行：原幂等键不重排，空pull也完成权威刷新', () async {
    await completedRemoteMode();
    await settleConflict(id: 'resolved-product', action: 'keep_local', stock: false);
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.bootstrapCalls, 1);
    expect(api.pushedChanges, isEmpty);
    expect((await outbox.getByChangeId('resolved-product'))!.status, SyncOutboxStatus.conflict);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
    expect(await inventory.getProductRecord('product'), isNotNull);
  });

  test('冲突刷新离线失败保留revision，重建engine后先fetch再完成', () async {
    await completedRemoteMode();
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    api.bootstrapError = StateError('offline');
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsStateError);
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect(api.pullCalls, 0);
    api.bootstrapError = null;
    await expireBackoff();
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.bootstrapCalls, 2);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
    expect(api.pushedChanges, isEmpty);
  });

  test('冲突刷新确认失败后重启不能使用旧快照完成', () async {
    await completedRemoteMode();
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    api.confirmationError = StateError('confirmation offline');
    await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsStateError);
    expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.awaitingConfirmation);
    expect((await outbox.getPendingBootstrap(scope))!['refresh_required'], isTrue);
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
    api.confirmationError = null;
    await expireBackoff();
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.bootstrapCalls, 2);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
  });

  test('fresh fetch期间新增冲突解决不能被旧revision清除', () async {
    await completedRemoteMode();
    await settleConflict();
    final first = await outbox.getConflictResolutionRefreshToken(scope);
    api.beforeBootstrap = () => settleConflict(id: 'second-stock');
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNot(first));
    expect(await outbox.getPendingBootstrap(scope), isNull);
    expect(await database.select(database.products).get(), isEmpty);
    expect(api.pullCalls, 0);
    api.beforeBootstrap = null;
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
  });

  test('完成事务期间revision轮换回滚业务/游标且不清理原刷新请求', () async {
    await completedRemoteMode();
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    final engine = SyncEngine(
      api: api, repository: outbox, scopeId: scope, deviceId: 'device',
      applyRemoteChange: (_) async {},
      applyRemoteSnapshot: (_, __) async {
        await settleConflict(id: 'during-apply');
        await inventory.applyRemoteProduct(
          productId: 'temporary', payload: {'name': '不可提交', 'category': '食品'},
          version: 1, updatedAt: DateTime.utc(2026),
        );
      },
    );
    expect((await engine.runOnce()).deferred, 1);
    expect(await inventory.getProductRecord('temporary'), isNull);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'fresh-checkpoint');
  });

  test('keep_local_only不被冲突刷新自动重新启用，legacy缺mode要求确认', () async {
    await completedRemoteMode(mode: 'keep_local_only');
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    final current = (await outbox.getState(scope))!;
    await outbox.saveState(current.copyWith(bootstrapStatus: SyncBootstrapStatus.keepLocalOnly));
    expect((await engineWithBusinessAdapter(outbox).runOnce()).skipped, isTrue);
    expect(api.bootstrapCalls, 0);
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
    await database.customStatement("DELETE FROM app_settings WHERE key = 'sync_bootstrap:family'");
    await ready(outbox);
    expect((await engineWithBusinessAdapter(outbox).runOnce()).deferred, 1);
    expect(api.bootstrapCalls, 0);
    expect(api.pullCalls, 0);
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
  });


  test('另一个未解决conflict/rejected保护不因已有结算凭据被解除', () async {
    await completedRemoteMode();
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    await enqueueStock(id: 'still-rejected', status: SyncOutboxStatus.rejected);
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect(api.bootstrapCalls, 0);
    expect(api.pullCalls, 0);
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
    expect(await outbox.hasSnapshotBlockingChanges(scopeId: scope), isTrue);
  });

  test('NAS确认期间新增resolution：旧快照不提交，下一轮重新fetch', () async {
    await completedRemoteMode();
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    api.beforeConfirm = () => settleConflict(id: 'during-confirm');
    expect((await engineWithBusinessAdapter(outbox).runOnce()).deferred, 1);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNot(token));
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    api.beforeConfirm = null;
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.bootstrapCalls, 2);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
  });


  test('ordinary pull在途收到resolution不应用旧page或推进游标', () async {
    await completedRemoteMode();
    api.beforePull = () => settleConflict();
    final report = await engineWithBusinessAdapter(outbox).runOnce();
    expect(report.deferred, 1);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNotNull);
    expect(await database.select(database.products).get(), isEmpty);
    api.beforePull = null;
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(api.bootstrapCalls, 1);
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
  });


  test('revision清理失败时业务/cursor/pending和revision同事务整体回滚', () async {
    await completedRemoteMode();
    await settleConflict();
    final token = await outbox.getConflictResolutionRefreshToken(scope);
    final failing = FailingResolutionCompletionRepository(database);
    await expectLater(engineWithBusinessAdapter(failing).runOnce(), throwsStateError);
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect((await outbox.getPendingBootstrap(scope))!['checkpoint'], 'fresh-checkpoint');
    expect(await outbox.getConflictResolutionRefreshToken(scope), token);
    expect(api.pullCalls, 0);
    await expireBackoff();
    await engineWithBusinessAdapter(outbox).runOnce();
    expect(await outbox.getConflictResolutionRefreshToken(scope), isNull);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 8);
  });

  group('bounded remote pull and page integrity', () {
    NasSyncPullChange category(String id, int cursor) => NasSyncPullChange(
      changeId: id, cursor: cursor, operation: 'entity_upsert', entity: 'categories',
      entityId: id, version: 1, payload: {'name': id},
    );

    test('100-page boundary retains continuation and does not claim complete success', () async {
      await ready(outbox);
      final previousSuccess = DateTime.utc(2026, 10, 1);
      await outbox.saveState((await outbox.getState(scope))!.copyWith(lastSuccessAt: previousSuccess));
      for (var i = 1; i <= 101; i++) {
        api.pages.add(NasSyncPullResponse(
          changes: [category('remote-$i', i)], nextCursor: i, hasMore: i < 101,
        ));
      }
      final engine = engineWithBusinessAdapter(outbox);
      final first = await engine.runOnce();
      expect(first.pulled, 100);
      expect(first.hasMoreRemote, isTrue);
      expect(first.hasMorePending, isFalse);
      expect(first.deferred, 0);
      expect(api.pullCalls, 100);
      expect((await outbox.getState(scope))!.pullCursor, 100);
      expect((await outbox.getState(scope))!.lastSuccessAt, previousSuccess);
      final last = await engine.runOnce();
      expect(last.pulled, 1);
      expect(last.hasMoreRemote, isFalse);
      expect(api.requestedCursors.last, 100);
      expect((await outbox.getState(scope))!.pullCursor, 101);
      expect((await outbox.getState(scope))!.lastSuccessAt, isNot(previousSuccess));
    });

    for (final scenario in ['empty continuation', 'stationary continuation',
        'change beyond cursor', 'unordered changes', 'duplicate change id']) {
      test('invalid page $scenario is rejected before any business application', () async {
        await ready(outbox);
        await outbox.saveState((await outbox.getState(scope))!.copyWith(pullCursor: 5));
        api.response = switch (scenario) {
          'empty continuation' => const NasSyncPullResponse(
            changes: [], nextCursor: 6, hasMore: true),
          'stationary continuation' => NasSyncPullResponse(
            changes: [category('stale', 5)], nextCursor: 5, hasMore: true),
          'change beyond cursor' => NasSyncPullResponse(
            changes: [category('unsafe', 7)], nextCursor: 6, hasMore: false),
          'unordered changes' => NasSyncPullResponse(
            changes: [category('second', 7), category('first', 6)], nextCursor: 7, hasMore: false),
          _ => NasSyncPullResponse(
            changes: [category('same', 6), category('same', 7)], nextCursor: 7, hasMore: false),
        };
        var applications = 0;
        final engine = SyncEngine(api: api, repository: outbox, scopeId: scope,
          deviceId: 'device', applyRemoteChange: (_) async { applications++; });
        await expectLater(engine.runOnce(), throwsA(isA<NasApiError>().having(
          (error) => error.kind, 'kind', NasApiErrorKind.invalidResponse)));
        expect(applications, 0);
        expect(api.pullCalls, 1);
        expect((await outbox.getState(scope))!.pullCursor, 5);
        expect(await outbox.listAppliedChanges(scopeId: scope), isEmpty);
      });
    }

    test('a malformed later page preserves the earlier committed cursor and receipt', () async {
      await ready(outbox);
      api.pages.addAll([
        NasSyncPullResponse(changes: [category('committed', 1)], nextCursor: 1, hasMore: true),
        NasSyncPullResponse(changes: [category('invalid-late', 1)], nextCursor: 1, hasMore: true),
      ]);
      final applied = <String>[];
      final engine = SyncEngine(api: api, repository: outbox, scopeId: scope,
        deviceId: 'device', applyRemoteChange: (change) async { applied.add(change.changeId); });
      await expectLater(engine.runOnce(), throwsA(isA<NasApiError>()));
      expect(applied, ['committed']);
      expect(api.pullCalls, 2);
      expect((await outbox.getState(scope))!.pullCursor, 1);
      expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'committed'), isTrue);
      expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'invalid-late'), isFalse);
      expect((await outbox.getState(scope))!.lastSuccessAt, isNull);
    });

    test('deferred page never advertises automatic remote continuation', () async {
      await ready(outbox);
      api.response = NasSyncPullResponse(
        changes: [category('blocked', 1)], nextCursor: 1, hasMore: true,
      );
      final engine = SyncEngine(api: api, repository: outbox, scopeId: scope,
        deviceId: 'device', applyRemoteChange: (_) async {
          throw const SyncRemoteChangeDeferred('requires local review');
        });
      final report = await engine.runOnce();
      expect(report.deferred, 1);
      expect(report.hasMoreRemote, isFalse);
      expect(api.pullCalls, 1);
      expect((await outbox.getState(scope))!.pullCursor, 0);
    });
  });

  group('协议版本和同步执行协调', () {
    test('legacy ready state probes current capabilities before claiming outbox', () async {
      await ready(outbox);
      await enqueueStock();
      api.versions = const NasSyncVersions(schemaVersion: 1, syncProtocolVersion: 2);
      final before = (await outbox.getByChangeId('local-stock'))!;
      await expectLater(engineWithBusinessAdapter(outbox).runOnce(),
        throwsA(isA<NasApiError>().having((e) => e.code, 'code', 'SYNC_VERSION_INCOMPATIBLE')));
      final after = (await outbox.getByChangeId('local-stock'))!;
      expect(after.status, before.status);
      expect(after.attemptCount, before.attemptCount);
      expect(after.idempotencyKey, before.idempotencyKey);
      expect(api.events, isEmpty);
      final state = (await outbox.getState(scope))!;
      expect(state.pullCursor, 0);
      expect(state.pushAckCursor, 0);
      expect(state.lastErrorCode, 'SYNC_VERSION_INCOMPATIBLE');
      expect(state.lastErrorMessage, contains('版本不兼容'));
      expect(state.nextRetryAt, isNull);
    });

    for (final version in [0, -1, 2, 6]) {
      test('wire schema $version is not inferred from migration numbering', () async {
        await ready(outbox);
        api.versions = NasSyncVersions(schemaVersion: version, syncProtocolVersion: 1);
        await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsA(isA<NasApiError>()));
        expect(api.events, isEmpty);
        expect((await outbox.getState(scope))!.pullCursor, 0);
      });
    }

    test('incompatible bootstrap response cannot replace a retained snapshot/cursor', () async {
      await ready(outbox);
      await pendingSnapshot();
      final original = jsonEncode(await outbox.getPendingBootstrap(scope));
      api.fresh = const NasSyncBootstrap(schemaVersion: 2, syncProtocolVersion: 1,
        serverCursor: 99, mergeRequired: true, availableModes: ['join_and_merge'],
        checkpoint: 'incompatible', snapshot: {'products': []});
      await expectLater(engineWithBusinessAdapter(outbox).bootstrap(), throwsA(isA<NasApiError>()));
      expect(jsonEncode(await outbox.getPendingBootstrap(scope)), original);
      expect((await outbox.getState(scope))!.pushAckCursor, 0);
      expect(api.confirmRequests, isEmpty);
    });

    test('post-push incompatible snapshot retains acknowledged intent and old cursor', () async {
      await ready(outbox);
      await pendingSnapshot();
      await enqueueStock();
      api.fresh = const NasSyncBootstrap(
        schemaVersion: 1, syncProtocolVersion: 2, serverCursor: 99,
        mergeRequired: true, availableModes: ['join_and_merge'],
        checkpoint: 'unsupported', snapshot: {'products': []},
      );
      await expectLater(engineWithBusinessAdapter(outbox).runOnce(),
        throwsA(isA<NasApiError>().having((e) => e.code, 'code', 'SYNC_VERSION_INCOMPATIBLE')));
      final retained = (await outbox.getPendingBootstrap(scope))!;
      expect(retained['checkpoint'], 'old-checkpoint');
      expect(retained['server_cursor'], 10);
      expect(retained['refresh_required'], isTrue);
      final state = (await outbox.getState(scope))!;
      expect(state.pullCursor, 0);
      expect(state.pushAckCursor, 11);
      final original = (await outbox.getByChangeId('local-stock'))!;
      expect(original.status, SyncOutboxStatus.accepted);
      expect(original.idempotencyKey, 'idempotency-local-stock-stock-key');
      expect(api.confirmRequests, isEmpty);
      expect(api.pullCalls, 0);
    });

    test('invalid batch limits do not enter the network or alter outbox', () async {
      await ready(outbox);
      await enqueueStock();
      final engine = engineWithBusinessAdapter(outbox);
      for (final limits in [(0, 100), (101, 100), (100, 0), (100, 501)]) {
        await expectLater(engine.runOnce(maxPush: limits.$1, pullLimit: limits.$2),
          throwsArgumentError);
      }
      expect(api.capabilityReads, 0);
      expect(api.events, isEmpty);
      expect((await outbox.getByChangeId('local-stock'))!.attemptCount, 0);
    });

    test('fresh explicit bootstrap can recover incompatible recorded versions', () async {
      await ready(outbox);
      final state = (await outbox.getState(scope))!;
      await outbox.saveState(state.copyWith(serverSchemaVersion: 2, syncProtocolVersion: 2));
      await engineWithBusinessAdapter(outbox).bootstrap();
      final updated = (await outbox.getState(scope))!;
      expect(updated.serverSchemaVersion, 1);
      expect(updated.syncProtocolVersion, 1);
      expect(updated.lastErrorCode, isNull);
      expect(updated.bootstrapStatus, SyncBootstrapStatus.awaitingConfirmation);
    });

    test('recorded incompatible snapshot cannot confirm on a currently compatible server', () async {
      await ready(outbox);
      await pendingSnapshot();
      final original = jsonEncode(await outbox.getPendingBootstrap(scope));
      await outbox.saveState((await outbox.getState(scope))!.copyWith(syncProtocolVersion: 2));
      await expectLater(engineWithBusinessAdapter(outbox).confirmBootstrap(mode: 'join_and_merge'),
        throwsA(isA<NasApiError>()));
      expect(api.confirmRequests, isEmpty);
      expect(jsonEncode(await outbox.getPendingBootstrap(scope)), original);
    });

    test('version probe failure preserves pending operations without claiming them', () async {
      await ready(outbox);
      await enqueueStock();
      api.capabilityError = NasApiError.timeout(TimeoutException('NAS'));
      await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsA(isA<NasApiError>()));
      expect((await outbox.getByChangeId('local-stock'))!.status, SyncOutboxStatus.pending);
      expect((await outbox.getByChangeId('local-stock'))!.attemptCount, 0);
      expect(api.events, isEmpty);
    });

    test('incompatible server becoming compatible can retry without version backoff', () async {
      await ready(outbox);
      final engine = engineWithBusinessAdapter(outbox);
      api.versions = const NasSyncVersions(schemaVersion: 1, syncProtocolVersion: 2);
      await expectLater(engine.runOnce(), throwsA(isA<NasApiError>()));
      api.versions = const NasSyncVersions(schemaVersion: 1, syncProtocolVersion: 1);
      final report = await engine.runOnce();
      expect(report.skipped, isFalse);
      expect((await outbox.getState(scope))!.lastErrorCode, isNull);
    });

    test('concurrent runs of the same engine share a single network attempt', () async {
      await ready(outbox);
      final entered = Completer<void>();
      final release = Completer<void>();
      api.beforePull = () async { entered.complete(); await release.future; };
      final engine = engineWithBusinessAdapter(outbox);
      final first = engine.runOnce();
      await entered.future;
      final second = engine.runOnce();
      release.complete();
      final reports = await Future.wait([first, second]);
      expect(api.pullCalls, 1);
      expect(api.capabilityReads, 1);
      expect(identical(reports[0], reports[1]), isTrue);
    });

    test('provider-rebuilt engines with the same database/scope cannot overlap', () async {
      await ready(outbox);
      final entered = Completer<void>();
      final release = Completer<void>();
      api.beforePull = () async {
        if (api.pullCalls == 1) { entered.complete(); await release.future; }
      };
      final first = engineWithBusinessAdapter(outbox).runOnce();
      await entered.future;
      final rebuilt = engineWithBusinessAdapter(SyncOutboxRepository(database)).runOnce();
      await Future<void>.delayed(Duration.zero);
      expect(api.capabilityReads, 1);
      expect(api.pullCalls, 1);
      release.complete();
      await Future.wait([first, rebuilt]);
      expect(api.pullCalls, 2);
    });

    test('manual bootstrap waits for a running sync rather than replacing its snapshot', () async {
      await ready(outbox);
      final entered = Completer<void>();
      final release = Completer<void>();
      api.beforePull = () async { entered.complete(); await release.future; };
      final engine = engineWithBusinessAdapter(outbox);
      final running = engine.runOnce();
      await entered.future;
      final bootstrap = engine.bootstrap();
      await Future<void>.delayed(Duration.zero);
      expect(api.bootstrapCalls, 0);
      release.complete();
      await running;
      await bootstrap;
      expect(api.bootstrapCalls, 1);
    });

    test('different scopes can execute without waiting on an unrelated family', () async {
      await ready(outbox);
      final entered = Completer<void>();
      final release = Completer<void>();
      api.beforePull = () async { entered.complete(); await release.future; };
      final first = engineWithBusinessAdapter(outbox).runOnce();
      await entered.future;
      final otherState = await outbox.ensureState(scopeId: 'other', deviceId: 'other-device');
      await outbox.saveState(otherState.copyWith(bootstrapStatus: SyncBootstrapStatus.ready));
      final otherApi = FakeSyncApi();
      addTearDown(otherApi.close);
      final other = SyncEngine(api: otherApi, repository: outbox,
        scopeId: 'other', deviceId: 'other-device', applyRemoteChange: (_) async {});
      final report = await other.runOnce();
      expect(report.skipped, isFalse);
      expect(otherApi.pullCalls, 1);
      release.complete();
      await first;
    });

    test('a failed coordinated attempt releases the queue for a rebuilt engine', () async {
      await ready(outbox);
      api.capabilityError = StateError('injected failure');
      await expectLater(engineWithBusinessAdapter(outbox).runOnce(), throwsStateError);
      api.capabilityError = null;
      await expireBackoff();
      expect((await engineWithBusinessAdapter(SyncOutboxRepository(database)).runOnce()).skipped, isFalse);
    });

    test('choosing local-only during ordinary pull does not apply a late page', () async {
      await completedRemoteMode();
      final engine = engineWithBusinessAdapter(outbox);
      api.response = const NasSyncPullResponse(
        changes: [NasSyncPullChange(
          changeId: 'late-category', cursor: 12, operation: 'entity_upsert',
          entity: 'categories', entityId: 'late', version: 1,
          payload: {'name': 'late'},
        )], nextCursor: 12, hasMore: false,
      );
      api.beforePull = () => engine.confirmBootstrap(mode: 'keep_local_only').then((_) {});
      final report = await engine.runOnce();
      expect(report.deferred, 1);
      expect(report.hasMorePending, isFalse);
      expect((await outbox.getState(scope))!.pullCursor, 0);
      expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.keepLocalOnly);
      expect(await outbox.hasAppliedChange(scopeId: scope, changeId: 'late-category'), isFalse);
    });

    test('choosing local-only during a bounded push prevents automatic drain', () async {
      await ready(outbox);
      await pendingSnapshot();
      await enqueueStock(id: 'first');
      await enqueueStock(id: 'second');
      final engine = engineWithBusinessAdapter(outbox);
      api.beforePush = () => engine.confirmBootstrap(mode: 'keep_local_only').then((_) {});
      final report = await engine.runOnce(maxPush: 1);
      expect(report.pushed, 1);
      expect(report.hasMorePending, isFalse);
      expect((await outbox.getByChangeId('second'))!.status, SyncOutboxStatus.pending);
      expect((await outbox.getState(scope))!.bootstrapStatus, SyncBootstrapStatus.keepLocalOnly);
      expect(api.bootstrapCalls, 0);
      expect(api.pullCalls, 0);
    });

    test('maxPush continuation stops for unresolved rejected operations', () async {
      await ready(outbox);
      await pendingSnapshot();
      await enqueueStock(id: 'first');
      await enqueueStock(id: 'second');
      await enqueueStock(id: 'rejected', status: SyncOutboxStatus.rejected);
      final report = await engineWithBusinessAdapter(outbox).runOnce(maxPush: 1);
      expect(report.pushed, 1);
      expect(report.deferred, 1);
      expect(report.hasMorePending, isFalse);
      expect(api.bootstrapCalls, 0);
    });
  });

}
