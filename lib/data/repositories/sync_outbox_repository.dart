import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/sync_models.dart';

/// Local persistence boundary for sync metadata and pending changes.
///
/// This repository intentionally does not make network calls. It provides the
/// durable state that a later bootstrap/push/pull worker can use safely after
/// process death or a temporary network outage.
class SyncOutboxRepository {
  SyncOutboxRepository(this._database);

  final AppDatabase _database;

  Future<SyncStateModel?> getState(String scopeId) async {
    final row = await (_database.select(_database.syncStates)
          ..where((state) => state.scopeId.equals(scopeId)))
        .getSingleOrNull();
    return row == null ? null : _stateFromRecord(row);
  }

  Stream<SyncStateModel?> watchState(String scopeId) {
    return (_database.select(_database.syncStates)
          ..where((state) => state.scopeId.equals(scopeId)))
        .watchSingleOrNull()
        .map((row) => row == null ? null : _stateFromRecord(row));
  }

  Future<SyncStateModel> ensureState({
    required String scopeId,
    String? familyId,
    String? deviceId,
    String? localWorkspaceId,
  }) async {
    final existing = await getState(scopeId);
    if (existing != null) return existing;

    final now = _now();
    await _database.into(_database.syncStates).insert(
          SyncStatesCompanion.insert(
            scopeId: scopeId,
            familyId: Value(familyId),
            deviceId: Value(deviceId),
            localWorkspaceId: Value(localWorkspaceId),
            updatedAt: now,
          ),
        );
    return (await getState(scopeId))!;
  }

  Future<void> saveState(SyncStateModel state) async {
    await _database.into(_database.syncStates).insertOnConflictUpdate(
          SyncStatesCompanion.insert(
            scopeId: state.scopeId,
            familyId: Value(state.familyId),
            deviceId: Value(state.deviceId),
            localWorkspaceId: Value(state.localWorkspaceId),
            bootstrapStatus: Value(state.bootstrapStatus.wireValue),
            pullCursor: Value(state.pullCursor),
            pushAckCursor: Value(state.pushAckCursor),
            lastPushAt: Value(state.lastPushAt),
            lastPullAt: Value(state.lastPullAt),
            lastSuccessAt: Value(state.lastSuccessAt),
            lastErrorCode: Value(state.lastErrorCode),
            lastErrorMessage: Value(state.lastErrorMessage),
            consecutiveFailures: Value(state.consecutiveFailures),
            nextRetryAt: Value(state.nextRetryAt),
            serverSchemaVersion: Value(state.serverSchemaVersion),
            syncProtocolVersion: Value(state.syncProtocolVersion),
            updatedAt: state.updatedAt,
          ),
        );
  }

  Future<SyncOutboxEntry?> getByChangeId(String changeId) async {
    final row = await (_database.select(_database.syncOutbox)
          ..where((entry) => entry.changeId.equals(changeId)))
        .getSingleOrNull();
    return row == null ? null : _outboxFromRecord(row);
  }

  Future<SyncOutboxEntry?> getByIdempotencyKey({
    required String scopeId,
    required String idempotencyKey,
  }) async {
    final row = await (_database.select(_database.syncOutbox)
          ..where((entry) =>
              entry.scopeId.equals(scopeId) &
              entry.idempotencyKey.equals(idempotencyKey)))
        .getSingleOrNull();
    return row == null ? null : _outboxFromRecord(row);
  }

  /// Inserts a durable outbox item, or returns the existing item for a retry.
  ///
  /// A change id or idempotency key can never be silently reused for a
  /// different request. This protects callers from accidentally creating a
  /// second logical operation after a timeout.
  Future<SyncOutboxEntry> enqueue(SyncOutboxDraft draft) async {
    final existing = await getByChangeId(draft.changeId);
    if (existing != null) {
      _ensureSameRequest(existing, draft);
      return existing;
    }

    final sameIdempotency = await getByIdempotencyKey(
      scopeId: draft.scopeId,
      idempotencyKey: draft.idempotencyKey,
    );
    if (sameIdempotency != null) {
      _ensureSameRequest(sameIdempotency, draft);
      return sameIdempotency;
    }

    final now = draft.createdAt ?? _now();
    await _database.into(_database.syncOutbox).insert(
          SyncOutboxCompanion.insert(
            changeId: draft.changeId,
            scopeId: draft.scopeId,
            operation: draft.operation.wireValue,
            entity: Value(draft.entity),
            entityId: Value(draft.entityId),
            baseVersion: Value(draft.baseVersion),
            operationId: Value(draft.operationId),
            integrationId: Value(draft.integrationId),
            command: Value(draft.command),
            idempotencyKey: draft.idempotencyKey,
            requestJson: draft.requestJson,
            status: Value(draft.status.wireValue),
            nextAttemptAt: Value(draft.nextAttemptAt),
            createdAt: now,
            updatedAt: now,
          ),
        );
    return (await getByChangeId(draft.changeId))!;
  }

  Future<List<SyncOutboxEntry>> listPending({
    required String scopeId,
    int limit = 100,
    DateTime? now,
  }) async {
    final readyAt = now ?? _now();
    final rows = await (_database.select(_database.syncOutbox)
          ..where((entry) =>
              entry.scopeId.equals(scopeId) &
              entry.status.equals(SyncOutboxStatus.pending.wireValue) &
              (entry.nextAttemptAt.isNull() |
                  entry.nextAttemptAt.isSmallerOrEqualValue(readyAt)))
          ..orderBy([
            (entry) => OrderingTerm.asc(entry.createdAt),
          ])
          ..limit(limit))
        .get();
    return rows.map(_outboxFromRecord).toList(growable: false);
  }

  /// Claims one pending item in a local transaction for a future sync worker.
  Future<SyncOutboxEntry?> claimNext({
    required String scopeId,
    DateTime? now,
  }) async {
    final claimedAt = now ?? _now();
    return _database.transaction(() async {
      final rows = await (_database.select(_database.syncOutbox)
            ..where((entry) =>
                entry.scopeId.equals(scopeId) &
                entry.status.equals(SyncOutboxStatus.pending.wireValue) &
                (entry.nextAttemptAt.isNull() |
                    entry.nextAttemptAt.isSmallerOrEqualValue(claimedAt)))
            ..orderBy([(entry) => OrderingTerm.asc(entry.createdAt)])
            ..limit(1))
          .get();
      if (rows.isEmpty) return null;
      final row = rows.single;

      await (_database.update(_database.syncOutbox)
            ..where((entry) => entry.changeId.equals(row.changeId)))
          .write(
        SyncOutboxCompanion(
          status: Value(SyncOutboxStatus.inFlight.wireValue),
          attemptCount: Value(row.attemptCount + 1),
          updatedAt: Value(claimedAt),
        ),
      );
      return _outboxFromRecord(
        row.copyWith(
          status: SyncOutboxStatus.inFlight.wireValue,
          attemptCount: row.attemptCount + 1,
          updatedAt: claimedAt,
        ),
      );
    });
  }

  Future<void> markAccepted({
    required String changeId,
    required int serverCursor,
    int? serverVersion,
    DateTime? completedAt,
  }) async {
    await _markTerminal(
      changeId: changeId,
      status: SyncOutboxStatus.accepted,
      serverCursor: serverCursor,
      serverVersion: serverVersion,
      completedAt: completedAt,
    );
  }

  Future<void> markReplayed({
    required String changeId,
    int? serverCursor,
    int? serverVersion,
    DateTime? completedAt,
  }) async {
    await _markTerminal(
      changeId: changeId,
      status: SyncOutboxStatus.replayed,
      serverCursor: serverCursor,
      serverVersion: serverVersion,
      completedAt: completedAt,
    );
  }

  Future<void> markRejected({
    required String changeId,
    required String errorCode,
    required String errorMessage,
    DateTime? completedAt,
  }) async {
    await _markTerminal(
      changeId: changeId,
      status: SyncOutboxStatus.rejected,
      errorCode: errorCode,
      errorMessage: errorMessage,
      completedAt: completedAt,
    );
  }

  Future<void> releaseInFlight({
    required String changeId,
    DateTime? nextAttemptAt,
    String? errorCode,
    String? errorMessage,
  }) async {
    final now = _now();
    await (_database.update(_database.syncOutbox)
          ..where((entry) => entry.changeId.equals(changeId)))
        .write(
      SyncOutboxCompanion(
        status: const Value(SyncOutboxStatus.pending.wireValue),
        nextAttemptAt: Value(nextAttemptAt),
        lastErrorCode: Value(errorCode),
        lastErrorMessage: Value(errorMessage),
        updatedAt: Value(now),
      ),
    );
  }

  Future<void> markConflict({
    required String changeId,
    required SyncConflictDraft conflict,
  }) async {
    final now = _now();
    await _database.transaction(() async {
      await (_database.update(_database.syncOutbox)
            ..where((entry) => entry.changeId.equals(changeId)))
          .write(
        SyncOutboxCompanion(
          status: const Value(SyncOutboxStatus.conflict.wireValue),
          updatedAt: Value(now),
          completedAt: Value(now),
        ),
      );
      await _database.into(_database.syncConflicts).insert(
            _conflictCompanion(conflict, createdAt: now),
          );
    });
  }

  Future<List<SyncOutboxEntry>> listOutbox({
    required String scopeId,
    SyncOutboxStatus? status,
    int limit = 100,
  }) async {
    final query = _database.select(_database.syncOutbox)
      ..where((entry) => entry.scopeId.equals(scopeId))
      ..orderBy([(entry) => OrderingTerm.asc(entry.createdAt)])
      ..limit(limit);
    if (status != null) {
      query.where((entry) => entry.status.equals(status.wireValue));
    }
    final rows = await query.get();
    return rows.map(_outboxFromRecord).toList(growable: false);
  }

  Future<int> recordConflict(SyncConflictDraft conflict) async {
    return _database.into(_database.syncConflicts).insert(
          _conflictCompanion(conflict, createdAt: _now()),
        );
  }

  Future<List<SyncConflictEntry>> listOpenConflicts({
    required String scopeId,
    int limit = 100,
  }) async {
    final rows = await (_database.select(_database.syncConflicts)
          ..where((conflict) =>
              conflict.scopeId.equals(scopeId) &
              conflict.status.equals(SyncConflictStatus.open.wireValue))
          ..orderBy([(conflict) => OrderingTerm.asc(conflict.createdAt)])
          ..limit(limit))
        .get();
    return rows.map(_conflictFromRecord).toList(growable: false);
  }

  Future<void> resolveConflict({
    required int id,
    required SyncConflictStatus status,
    String? resolution,
  }) async {
    final resolvedAt = status == SyncConflictStatus.open ? null : _now();
    await (_database.update(_database.syncConflicts)
          ..where((conflict) => conflict.id.equals(id)))
        .write(
      SyncConflictsCompanion(
        status: Value(status.wireValue),
        resolution: Value(status == SyncConflictStatus.open ? null : resolution),
        resolvedAt: Value(resolvedAt),
      ),
    );
  }

  Future<bool> hasAppliedChange({
    required String scopeId,
    required String changeId,
  }) async {
    final row = await (_database.select(_database.syncAppliedChanges)
          ..where((change) =>
              change.scopeId.equals(scopeId) &
              change.changeId.equals(changeId)))
        .getSingleOrNull();
    return row != null;
  }

  Future<void> recordAppliedChange({
    required String scopeId,
    required String changeId,
    required int cursor,
    DateTime? appliedAt,
  }) async {
    await _database.into(_database.syncAppliedChanges).insertOnConflictUpdate(
          SyncAppliedChangesCompanion.insert(
            scopeId: scopeId,
            changeId: changeId,
            cursor: cursor,
            appliedAt: appliedAt ?? _now(),
          ),
        );
  }

  Future<List<SyncAppliedChange>> listAppliedChanges({
    required String scopeId,
    int limit = 500,
  }) async {
    final rows = await (_database.select(_database.syncAppliedChanges)
          ..where((change) => change.scopeId.equals(scopeId))
          ..orderBy([(change) => OrderingTerm.asc(change.cursor)])
          ..limit(limit))
        .get();
    return rows
        .map(
          (row) => SyncAppliedChange(
            scopeId: row.scopeId,
            changeId: row.changeId,
            cursor: row.cursor,
            appliedAt: row.appliedAt,
          ),
        )
        .toList(growable: false);
  }

  Future<void> _markTerminal({
    required String changeId,
    required SyncOutboxStatus status,
    int? serverCursor,
    int? serverVersion,
    String? errorCode,
    String? errorMessage,
    DateTime? completedAt,
  }) async {
    final now = completedAt ?? _now();
    await (_database.update(_database.syncOutbox)
          ..where((entry) => entry.changeId.equals(changeId)))
        .write(
      SyncOutboxCompanion(
        status: Value(status.wireValue),
        serverCursor: Value(serverCursor),
        serverVersion: Value(serverVersion),
        lastErrorCode: Value(errorCode),
        lastErrorMessage: Value(errorMessage),
        nextAttemptAt: const Value(null),
        completedAt: Value(now),
        updatedAt: Value(now),
      ),
    );
  }

  void _ensureSameRequest(SyncOutboxEntry existing, SyncOutboxDraft draft) {
    if (existing.scopeId != draft.scopeId ||
        existing.idempotencyKey != draft.idempotencyKey ||
        existing.operation != draft.operation ||
        existing.requestJson != draft.requestJson) {
      throw StateError(
        'A sync change or idempotency key was reused for a different request.',
      );
    }
  }

  SyncStateModel _stateFromRecord(SyncStateRecord row) {
    return SyncStateModel(
      scopeId: row.scopeId,
      familyId: row.familyId,
      deviceId: row.deviceId,
      localWorkspaceId: row.localWorkspaceId,
      bootstrapStatus: SyncBootstrapStatus.fromWire(row.bootstrapStatus),
      pullCursor: row.pullCursor,
      pushAckCursor: row.pushAckCursor,
      lastPushAt: row.lastPushAt,
      lastPullAt: row.lastPullAt,
      lastSuccessAt: row.lastSuccessAt,
      lastErrorCode: row.lastErrorCode,
      lastErrorMessage: row.lastErrorMessage,
      consecutiveFailures: row.consecutiveFailures,
      nextRetryAt: row.nextRetryAt,
      serverSchemaVersion: row.serverSchemaVersion,
      syncProtocolVersion: row.syncProtocolVersion,
      updatedAt: row.updatedAt,
    );
  }

  SyncOutboxEntry _outboxFromRecord(SyncOutboxRecord row) {
    return SyncOutboxEntry(
      changeId: row.changeId,
      scopeId: row.scopeId,
      operation: SyncOperation.fromWire(row.operation),
      entity: row.entity,
      entityId: row.entityId,
      baseVersion: row.baseVersion,
      operationId: row.operationId,
      integrationId: row.integrationId,
      command: row.command,
      idempotencyKey: row.idempotencyKey,
      requestJson: row.requestJson,
      status: SyncOutboxStatus.fromWire(row.status),
      attemptCount: row.attemptCount,
      nextAttemptAt: row.nextAttemptAt,
      lastErrorCode: row.lastErrorCode,
      lastErrorMessage: row.lastErrorMessage,
      serverCursor: row.serverCursor,
      serverVersion: row.serverVersion,
      createdAt: row.createdAt,
      updatedAt: row.updatedAt,
      completedAt: row.completedAt,
    );
  }

  SyncConflictEntry _conflictFromRecord(SyncConflictRecord row) {
    return SyncConflictEntry(
      id: row.id,
      scopeId: row.scopeId,
      changeId: row.changeId,
      outboxChangeId: row.outboxChangeId,
      entity: row.entity,
      entityId: row.entityId,
      reason: row.reason,
      serverVersion: row.serverVersion,
      serverPayloadJson: row.serverPayloadJson,
      clientPayloadJson: row.clientPayloadJson,
      status: SyncConflictStatus.fromWire(row.status),
      resolution: row.resolution,
      createdAt: row.createdAt,
      resolvedAt: row.resolvedAt,
    );
  }

  SyncConflictsCompanion _conflictCompanion(
    SyncConflictDraft draft, {
    required DateTime createdAt,
  }) {
    return SyncConflictsCompanion.insert(
      scopeId: draft.scopeId,
      changeId: draft.changeId,
      outboxChangeId: Value(draft.outboxChangeId),
      entity: draft.entity,
      entityId: Value(draft.entityId),
      reason: draft.reason,
      serverVersion: Value(draft.serverVersion),
      serverPayloadJson: Value(draft.serverPayloadJson),
      clientPayloadJson: Value(draft.clientPayloadJson),
      status: Value(draft.status.wireValue),
      createdAt: createdAt,
    );
  }

  DateTime _now() => DateTime.now().toUtc();
}
