import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

const _scope = 'family-a';

NasSyncConflictResolveResponse _receipt({
  String action = 'keep_remote',
  String changeId = 'edit',
  String remoteId = 'nas-conflict',
  String entity = 'products',
  String entityId = 'product',
  String operation = 'entity_upsert',
  bool accepted = true,
  String status = 'resolved',
}) => NasSyncConflictResolveResponse(
  accepted: accepted,
  conflict: NasSyncConflictDetail(
    conflictId: remoteId,
    changeId: changeId,
    entity: entity,
    entityId: entityId,
    operation: operation,
    reason: 'VERSION_CONFLICT',
    status: status,
    resolution: {'action': action},
    serverVersion: 2,
  ),
  // Resolution success is NOT a receipt for the original outbox command.
  result: const NasSyncConflictResolveResult(serverVersion: 2, serverCursor: 20),
);

void main() {
  late AppDatabase database;
  late SyncOutboxRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = SyncOutboxRepository(database);
  });
  tearDown(() => database.close());

  Future<int> conflicted({
    String changeId = 'edit',
    String scopeId = _scope,
    String entity = 'products',
    String entityId = 'product',
    SyncOperation operation = SyncOperation.entityUpsert,
    SyncOutboxStatus status = SyncOutboxStatus.conflict,
    bool explicitLink = true,
  }) async {
    await repository.enqueue(SyncOutboxDraft(
      changeId: changeId,
      scopeId: scopeId,
      entity: entity,
      entityId: entityId,
      operation: operation,
      operationId: operation == SyncOperation.inventoryCommand ? 'stock-operation' : null,
      idempotencyKey: '$changeId-original-idempotency-key',
      requestJson: jsonEncode({
        'change_id': changeId,
        'operation': operation.wireValue,
        'entity': entity,
        'entity_id': entityId,
        'payload': {'name': 'optimistic local edit'},
      }),
    ));
    await repository.claimNext(scopeId: scopeId);
    await repository.markConflict(
      changeId: changeId,
      conflict: SyncConflictDraft(
        scopeId: scopeId,
        changeId: changeId,
        outboxChangeId: explicitLink ? changeId : null,
        entity: entity,
        entityId: entityId,
        reason: 'VERSION_CONFLICT',
        serverVersion: 1,
        clientPayloadJson: '{"name":"optimistic local edit"}',
      ),
    );
    if (status == SyncOutboxStatus.rejected) {
      await repository.markRejected(
        changeId: changeId,
        errorCode: 'INSUFFICIENT_STOCK',
        errorMessage: 'Original command refused by NAS',
      );
    }
    return (await repository.getConflictByChangeId(scopeId: scopeId, changeId: changeId))!.id;
  }

  Future<void> settle(int id, {
    String action = 'keep_remote',
    String changeId = 'edit',
    String scopeId = _scope,
    String remoteId = 'nas-conflict',
    NasSyncConflictResolveResponse? response,
  }) => repository.settleOutboxConflict(
    conflictId: id,
    scopeId: scopeId,
    changeId: changeId,
    remoteConflictId: remoteId,
    action: action,
    response: response ?? _receipt(action: action, changeId: changeId, remoteId: remoteId),
  );

  for (final action in ['keep_remote', 'keep_local']) {
    for (final operation in [SyncOperation.entityUpsert, SyncOperation.entityDelete]) {
      test('$action settles ${operation.wireValue} atomically without retry or fake accepted', () async {
        final id = await conflicted(operation: operation);
        await repository.ensureState(scopeId: _scope);
        final before = (await repository.getByChangeId('edit'))!;
        expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
        await settle(id, action: action, response: _receipt(
          action: action, operation: operation.wireValue,
        ));
        final after = (await repository.getByChangeId('edit'))!;
        expect(after.status, SyncOutboxStatus.conflict);
        expect(after.requestJson, before.requestJson);
        expect(after.idempotencyKey, before.idempotencyKey);
        expect(after.attemptCount, before.attemptCount);
        expect(after.completedAt, before.completedAt);
        expect(after.serverCursor, before.serverCursor);
        expect(after.serverVersion, before.serverVersion);
        expect((await repository.listOutbox(scopeId: _scope)).length, 1);
        expect(await repository.claimNext(scopeId: _scope), isNull);
        expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isFalse);
        expect(await repository.getConflictResolutionRefreshToken(_scope), isNotNull);
        final conflict = (await repository.getConflict(id))!;
        expect(conflict.status, action == 'keep_local'
            ? SyncConflictStatus.resolved : SyncConflictStatus.rejected);
        expect(conflict.resolution, 'remote_$action');
        expect(conflict.resolvedAt, isNotNull);
        expect((await repository.getState(_scope))!.pullCursor, 0);
        expect((await repository.getState(_scope))!.pushAckCursor, 0);
      });
    }
  }

  for (final status in [SyncOutboxStatus.conflict, SyncOutboxStatus.rejected]) {
    test('keep_remote preserves $status inventory command audit, never retries', () async {
      final id = await conflicted(operation: SyncOperation.inventoryCommand, status: status);
      final before = (await repository.getByChangeId('edit'))!;
      await settle(id, response: _receipt(operation: 'inventory_command'));
      final after = (await repository.getByChangeId('edit'))!;
      expect(after.status, status);
      expect(after.operationId, before.operationId);
      expect(after.lastErrorCode, before.lastErrorCode);
      expect(after.lastErrorMessage, before.lastErrorMessage);
      expect(await repository.claimNext(scopeId: _scope), isNull);
      expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isFalse);
    });
  }

  for (final operation in [SyncOperation.inventoryCommand, SyncOperation.homeAssistantCommand]) {
    test('keep_local fails closed for ${operation.wireValue}', () async {
      final id = await conflicted(operation: operation);
      await expectLater(settle(id, action: 'keep_local', response: _receipt(
        action: 'keep_local', operation: operation.wireValue,
      )), throwsStateError);
      expect((await repository.getConflict(id))!.status, SyncConflictStatus.open);
      expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
      expect(await repository.getConflictResolutionRefreshToken(_scope), isNull);
    });
  }

  test('legacy link by changeId and remote-only resolution both request refresh', () async {
    final id = await conflicted(explicitLink: false);
    await settle(id);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isFalse);
    final remoteOnlyId = await repository.recordConflict(const SyncConflictDraft(
      scopeId: _scope, changeId: 'remote-only', entity: 'products',
      entityId: 'product', reason: 'VERSION_CONFLICT',
    ));
    final oldToken = await repository.getConflictResolutionRefreshToken(_scope);
    await settle(remoteOnlyId, changeId: 'remote-only', remoteId: 'remote-only-conflict');
    expect(await repository.getConflictResolutionRefreshToken(_scope), isNot(oldToken));
    expect((await repository.listOutbox(scopeId: _scope)).length, 1);
  });

  test('scope/change/conflict ID/action/receipt mismatches leave conflict open', () async {
    final id = await conflicted();
    final failures = <Future<void> Function()>[
      () => settle(id, scopeId: 'family-b'),
      () => settle(id, changeId: 'wrong-change'),
      () => settle(id, response: _receipt(remoteId: 'wrong-conflict')),
      () => settle(id, response: _receipt(accepted: false)),
      () => settle(id, response: _receipt(status: 'open')),
      () => settle(id, response: _receipt(action: 'keep_local')),
      () => settle(id, response: _receipt(entity: 'shopping_items')),
      () => settle(id, response: _receipt(entityId: 'wrong-product')),
      () => settle(id, response: _receipt(operation: 'inventory_command')),
      () => settle(id, action: 'manual_merge'),
      () => settle(id, remoteId: ''),
      () => settle(id, response: NasSyncConflictResolveResponse(
        accepted: true,
        conflict: const NasSyncConflictDetail(
          conflictId: 'nas-conflict', changeId: 'edit', entity: 'products',
          entityId: 'product', reason: 'VERSION_CONFLICT', status: 'resolved',
        ),
      )),
    ];
    for (final fail in failures) {
      await expectLater(fail(), throwsStateError);
      expect((await repository.getConflict(id))!.status, SyncConflictStatus.open);
      expect(await repository.getConflictResolutionRefreshToken(_scope), isNull);
      expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    }
  });

  test('missing explicit linked outbox cannot silently close a conflict', () async {
    final id = await repository.recordConflict(const SyncConflictDraft(
      scopeId: _scope, changeId: 'edit', outboxChangeId: 'missing-outbox',
      entity: 'products', entityId: 'product', reason: 'VERSION_CONFLICT',
    ));
    await expectLater(settle(id), throwsStateError);
    expect((await repository.getConflict(id))!.status, SyncConflictStatus.open);
  });

  test('repeated settlement is idempotent before and after refresh consumption', () async {
    final id = await conflicted();
    await settle(id);
    final first = (await repository.getConflictResolutionRefreshToken(_scope))!;
    final audit = await database.select(database.appSettings).get();
    final conflict = (await repository.getConflict(id))!;
    await settle(id);
    expect(await repository.getConflictResolutionRefreshToken(_scope), first);
    expect((await repository.getConflict(id))!.resolvedAt, conflict.resolvedAt);
    expect(await database.select(database.appSettings).get(), audit);
    await expectLater(settle(id, action: 'keep_local'), throwsStateError);
    await expectLater(settle(id, remoteId: 'different-remote-conflict'), throwsStateError);
    expect(await repository.clearConflictResolutionRefresh(scopeId: _scope, token: first), isTrue);
    await settle(id);
    expect(await repository.getConflictResolutionRefreshToken(_scope), isNull);
    expect(await repository.clearConflictResolutionRefresh(scopeId: _scope, token: first), isFalse);
  });

  test('new resolution during snapshot fetch keeps its newer generation', () async {
    final id = await conflicted();
    await settle(id);
    final oldToken = (await repository.getConflictResolutionRefreshToken(_scope))!;
    final second = await conflicted(changeId: 'second');
    await settle(second, changeId: 'second', remoteId: 'second-conflict');
    final newToken = (await repository.getConflictResolutionRefreshToken(_scope))!;
    expect(newToken, isNot(oldToken));
    expect(await repository.clearConflictResolutionRefresh(scopeId: _scope, token: oldToken), isFalse);
    expect(await repository.getConflictResolutionRefreshToken(_scope), newToken);
    expect(await repository.clearConflictResolutionRefresh(scopeId: _scope, token: newToken), isTrue);
  });

  test('generation survives repository recreation and rolled-back snapshot completion', () async {
    final id = await conflicted();
    await settle(id);
    final token = (await repository.getConflictResolutionRefreshToken(_scope))!;
    final reopened = SyncOutboxRepository(database);
    expect(await reopened.getConflictResolutionRefreshToken(_scope), token);
    await expectLater(reopened.transaction(() async {
      expect(await reopened.clearConflictResolutionRefresh(scopeId: _scope, token: token), isTrue);
      throw StateError('snapshot transaction failed after onApplied');
    }), throwsStateError);
    expect(await reopened.getConflictResolutionRefreshToken(_scope), token);
    expect(await reopened.hasSnapshotBlockingChanges(scopeId: _scope), isFalse);
  });

  test('refresh write failure rolls back conflict, markers and dependency unblocking', () async {
    final id = await conflicted();
    await database.customStatement('''
      CREATE TRIGGER fail_resolution_refresh BEFORE INSERT ON app_settings
      WHEN NEW.key LIKE 'sync_resolution_refresh:%'
      BEGIN SELECT RAISE(ABORT, 'injected persistence failure'); END
    ''');
    await expectLater(settle(id), throwsA(isA<Exception>()));
    expect((await repository.getConflict(id))!.status, SyncConflictStatus.open);
    expect((await repository.getConflict(id))!.resolvedAt, isNull);
    expect((await repository.getByChangeId('edit'))!.status, SyncOutboxStatus.conflict);
    expect(await database.select(database.appSettings).get(), isEmpty);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
  });

  test('dependency blockers ignore only settled failures, not other rejected edits', () async {
    final id = await conflicted(entity: 'categories', entityId: 'category');
    await repository.enqueue(SyncOutboxDraft(
      changeId: 'dependent-product', scopeId: _scope,
      operation: SyncOperation.entityUpsert,
      entity: 'products', entityId: 'dependent-product',
      idempotencyKey: 'dependent-product-key',
      requestJson: jsonEncode({'payload': {'category_id': 'category'}}),
    ));
    await repository.refreshDependencyBlocks(scopeId: _scope);
    expect((await repository.getByChangeId('dependent-product'))!.status, SyncOutboxStatus.blocked);
    await settle(id, response: _receipt(entity: 'categories', entityId: 'category'));
    expect((await repository.getByChangeId('dependent-product'))!.status, SyncOutboxStatus.pending);
    final token = (await repository.getConflictResolutionRefreshToken(_scope))!;
    expect(await repository.clearConflictResolutionRefresh(scopeId: _scope, token: token), isFalse);
    expect((await repository.claimNext(scopeId: _scope))!.changeId, 'dependent-product');
    await repository.markRejected(changeId: 'dependent-product', errorCode: 'DENIED', errorMessage: 'unresolved');
    await repository.enqueue(SyncOutboxDraft(
      changeId: 'dependent-batch', scopeId: _scope,
      operation: SyncOperation.entityUpsert,
      entity: 'product_batches', entityId: 'batch',
      idempotencyKey: 'dependent-batch-key',
      requestJson: jsonEncode({'payload': {'product_id': 'dependent-product'}}),
    ));
    await repository.refreshDependencyBlocks(scopeId: _scope);
    expect((await repository.getByChangeId('dependent-batch'))!.status, SyncOutboxStatus.blocked);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
  });

  test('plain resolved record without settlement evidence still blocks snapshots', () async {
    final id = await conflicted();
    await repository.resolveConflict(id: id, status: SyncConflictStatus.rejected, resolution: 'remote_keep_remote');
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    // A verified receipt can repair this legacy half-completed resolution.
    await settle(id);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isFalse);
  });

  test('recovery query includes legacy half-settlements but excludes settled audit rows', () async {
    final id = await conflicted();
    await repository.resolveConflict(id: id, status: SyncConflictStatus.rejected, resolution: 'remote_keep_remote');
    expect(await repository.listOpenConflicts(scopeId: _scope), isEmpty);
    expect((await repository.listUnsettledLinkedConflicts(scopeId: _scope)).single.id, id);
    expect(await repository.listUnsettledLinkedConflicts(scopeId: 'other-family'), isEmpty);
    await settle(id);
    expect(await repository.listUnsettledLinkedConflicts(scopeId: _scope), isEmpty);
  });

  test('reopened or additional unresolved conflicts retain snapshot protection', () async {
    final id = await conflicted();
    await settle(id);
    final token = (await repository.getConflictResolutionRefreshToken(_scope))!;
    await repository.resolveConflict(id: id, status: SyncConflictStatus.open);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    expect(await repository.clearConflictResolutionRefresh(scopeId: _scope, token: token), isFalse);
    await expectLater(settle(id), throwsStateError);
  });

  test('another open conflict for the same outbox prevents dependency unblocking', () async {
    final id = await conflicted();
    await settle(id);
    await repository.recordConflict(const SyncConflictDraft(
      scopeId: _scope, changeId: 'later-server-change', outboxChangeId: 'edit',
      entity: 'products', entityId: 'product', reason: 'REMOTE_CHANGE_WITH_PENDING_LOCAL_CHANGE',
    ));
    await repository.enqueue(SyncOutboxDraft(
      changeId: 'dependent', scopeId: _scope, operation: SyncOperation.entityUpsert,
      entity: 'product_batches', entityId: 'batch', idempotencyKey: 'dependent-original-key',
      requestJson: jsonEncode({'payload': {'product_id': 'product'}}),
    ));
    await repository.refreshDependencyBlocks(scopeId: _scope);
    expect((await repository.getByChangeId('dependent'))!.status, SyncOutboxStatus.blocked);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    expect(await repository.claimNext(scopeId: _scope), isNull);
  });

  test('corrupt or mismatched settlement evidence never removes blockers', () async {
    final id = await conflicted();
    await settle(id);
    final marker = (await database.select(database.appSettings).get())
        .singleWhere((row) => row.key.startsWith('sync_outbox_settlement:'));
    await (database.update(database.appSettings)..where((row) => row.key.equals(marker.key)))
        .write(const AppSettingsCompanion(value: Value('invalid-json')));
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    final changed = Map<String, dynamic>.from(jsonDecode(marker.value) as Map)
      ..['idempotency_key'] = 'different-key';
    await (database.update(database.appSettings)..where((row) => row.key.equals(marker.key)))
        .write(AppSettingsCompanion(value: Value(jsonEncode(changed))));
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
  });

  test('unrelated and cross-scope unresolved edits remain protected', () async {
    final id = await conflicted();
    await conflicted(changeId: 'unresolved', status: SyncOutboxStatus.rejected);
    await conflicted(changeId: 'other-family-edit', scopeId: 'family-b');
    await settle(id);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: 'family-b'), isTrue);
    expect(await repository.getConflictResolutionRefreshToken('family-b'), isNull);
  });

  test('coordination identity is shared only by repositories on the same database', () async {
    final sibling = SyncOutboxRepository(database);
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      expect(identical(repository.coordinationKey, sibling.coordinationKey), isTrue);
      expect(identical(repository.coordinationKey,
          SyncOutboxRepository(other).coordinationKey), isFalse);
    } finally {
      await other.close();
    }
  });

  Future<void> enqueuePending(String id, {String scope = _scope}) =>
      repository.enqueue(SyncOutboxDraft(
        changeId: id, scopeId: scope, operation: SyncOperation.entityUpsert,
        entity: 'products', entityId: id,
        idempotencyKey: '$id-stable-idempotency-key',
        requestJson: jsonEncode({'entity': 'products', 'entity_id': id,
          'payload': {'name': id}}),
      )).then((_) {});

  Future<void> flushWatch() async {
    // Drift's in-memory stream query uses asynchronous invalidation/SQLite.
    // Wait event turns (not a network/scheduler sleep) before absence assertions.
    for (var i = 0; i < 8; i++) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  test('pending watch filters reads/status/retry receipts and other scopes', () async {
    final events = <List<SyncOutboxEntry>>[];
    final subscription = repository.watchPendingContentChanges(scopeId: _scope)
        .listen(events.add);
    addTearDown(subscription.cancel);
    await flushWatch();
    expect(events, isEmpty);
    await enqueuePending('first');
    await flushWatch();
    expect(events.length, 1);
    expect(events.single.single.changeId, 'first');

    await repository.listPending(scopeId: _scope);
    await repository.getByChangeId('first');
    await repository.transaction(() async {}); // Remote/no-op read transaction.
    await repository.claimNext(scopeId: _scope);
    await flushWatch();
    await repository.releaseInFlight(changeId: 'first', errorCode: 'network',
      errorMessage: 'retry', nextAttemptAt: DateTime.now().toUtc());
    await flushWatch();
    await enqueuePending('other-scope', scope: 'family-b');
    await flushWatch();
    expect(events.length, 1);

    // Same pending identity, new sync request content -> genuine local commit.
    await (database.update(database.syncOutbox)
          ..where((row) => row.changeId.equals('first')))
        .write(const SyncOutboxCompanion(requestJson: Value('{"name":"edited"}')));
    await flushWatch();
    expect(events.length, 2);
    expect(events.last.single.requestJson, '{"name":"edited"}');
    await repository.markAccepted(changeId: 'first', serverCursor: 10);
    await flushWatch();
    expect(events.length, 2);
  });

  test('pending watch sees one committed transaction, not rollback or retry duplicates', () async {
    final events = <List<SyncOutboxEntry>>[];
    final subscription = repository.watchPendingContentChanges(scopeId: _scope)
        .listen(events.add);
    addTearDown(subscription.cancel);
    await flushWatch();
    await expectLater(repository.transaction(() async {
      await enqueuePending('rollback');
      throw StateError('rollback');
    }), throwsStateError);
    await flushWatch();
    expect(events, isEmpty);
    await repository.transaction(() async {
      await enqueuePending('one');
      await enqueuePending('two');
    });
    await flushWatch();
    expect(events.length, 1);
    expect(events.single.map((entry) => entry.changeId), ['one', 'two']);
    await enqueuePending('one'); // Original idempotency retry, not a new intent.
    await flushWatch();
    expect(events.length, 1);
  });

  test('pending watch first snapshot includes only existing scoped pending work', () async {
    await enqueuePending('existing');
    await enqueuePending('foreign', scope: 'family-b');
    final event = await repository.watchPendingContentChanges(scopeId: _scope).first;
    expect(event.map((entry) => entry.changeId), ['existing']);
  });

  test('non-pending blockers exclude pending without weakening snapshot guard', () async {
    await enqueuePending('ready');
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isFalse);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
    await repository.claimNext(scopeId: _scope);
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
    await repository.releaseInFlight(changeId: 'ready');
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isFalse);
    await repository.markRejected(changeId: 'ready', errorCode: 'NO_STOCK', errorMessage: 'refused');
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: 'family-b'), isFalse);
  });

  test('non-pending blockers retain blocked and unlinked open/deferred conflicts', () async {
    await enqueuePending('blocked');
    await (database.update(database.syncOutbox)
          ..where((row) => row.changeId.equals('blocked')))
        .write(SyncOutboxCompanion(status: Value(SyncOutboxStatus.blocked.wireValue)));
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
    await repository.markAccepted(changeId: 'blocked', serverCursor: 1);
    for (final status in [SyncConflictStatus.open, SyncConflictStatus.deferred]) {
      final id = await repository.recordConflict(SyncConflictDraft(
        scopeId: _scope, changeId: 'remote-${status.wireValue}', entity: 'products',
        reason: 'remote protected', status: status,
      ));
      expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
      await repository.resolveConflict(id: id, status: SyncConflictStatus.resolved,
        resolution: 'reviewed');
    }
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isFalse);
  });

  for (final status in [SyncOutboxStatus.conflict, SyncOutboxStatus.rejected]) {
    test('validly settled ${status.wireValue} audit does not block continuation', () async {
      final id = await conflicted(status: status);
      expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
      await settle(id);
      await enqueuePending('next');
      expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isFalse);
      expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
      final marker = (await database.select(database.appSettings).get())
          .singleWhere((row) => row.key.startsWith('sync_outbox_settlement:'));
      await (database.update(database.appSettings)..where((row) => row.key.equals(marker.key)))
          .write(const AppSettingsCompanion(value: Value('invalid-json')));
      expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
    });
  }

  test('pending watch gives simultaneous and later subscribers independent baselines', () async {
    final stream = repository.watchPendingContentChanges(scopeId: _scope);
    final firstEvents = <List<SyncOutboxEntry>>[];
    final secondEvents = <List<SyncOutboxEntry>>[];
    final first = stream.listen(firstEvents.add);
    final second = stream.listen(secondEvents.add);
    addTearDown(first.cancel);
    addTearDown(second.cancel);
    await flushWatch();
    await enqueuePending('shared');
    await flushWatch();
    expect(firstEvents.single.single.changeId, 'shared');
    expect(secondEvents.single.single.changeId, 'shared');
    // A resubscription must not inherit another observer's already-seen set.
    final later = await stream.first;
    expect(later.single.changeId, 'shared');
    await (database.update(database.syncOutbox)
          ..where((row) => row.changeId.equals('shared')))
        .write(const SyncOutboxCompanion(requestJson: Value('{"name":"new request"}')));
    await flushWatch();
    expect(firstEvents.length, 2);
    expect(secondEvents.length, 2);
  });

  test('remote auxiliary application and conflict bookkeeping do not emit local intent', () async {
    final events = <List<SyncOutboxEntry>>[];
    final subscription = repository.watchPendingContentChanges(scopeId: _scope)
        .listen(events.add);
    addTearDown(subscription.cancel);
    await flushWatch();
    await repository.applyRemoteAuxiliaryEntity(
      scopeId: _scope, entity: 'categories', entityId: 'remote',
      payload: {'name': 'Remote'}, version: 1, updatedAt: DateTime.utc(2026),
    );
    await InventoryRepository(database, outbox: repository, syncScopeId: _scope)
        .applyRemoteProduct(
      productId: 'remote-product', payload: {'name': 'Remote', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    await ShoppingRepository(database, outbox: repository, syncScopeId: _scope)
        .applyRemoteShoppingEntry(
      entryId: 'remote-shopping', payload: {'name': 'Remote', 'desired_quantity': 1},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    await repository.recordConflict(const SyncConflictDraft(
      scopeId: _scope, changeId: 'remote-conflict', entity: 'products',
      reason: 'protected remote change',
    ));
    await flushWatch();
    expect(events, isEmpty);
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
  });

  test('coordination identity follows the database instance, not repository wrappers', () async {
    final sibling = SyncOutboxRepository(database);
    final independent = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(independent.close);
    expect(repository.coordinationKey, same(database));
    expect(sibling.coordinationKey, same(repository.coordinationKey));
    expect(SyncOutboxRepository(independent).coordinationKey,
        isNot(same(repository.coordinationKey)));
  });

  test('settled audit still blocks drain when a linked conflict is reopened', () async {
    final id = await conflicted();
    await settle(id);
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isFalse);
    await repository.recordConflict(const SyncConflictDraft(
      scopeId: _scope, changeId: 'new-conflict', outboxChangeId: 'edit',
      entity: 'products', entityId: 'product', reason: 'requires review',
      status: SyncConflictStatus.deferred,
    ));
    expect(await repository.hasNonPendingSnapshotBlockers(scopeId: _scope), isTrue);
    expect(await repository.hasSnapshotBlockingChanges(scopeId: _scope), isTrue);
  });

}
