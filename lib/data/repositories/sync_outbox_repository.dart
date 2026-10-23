import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/nas_sync_models.dart';
import '../../domain/models/sync_models.dart';

/// Local persistence boundary for sync metadata and pending changes.
///
/// This repository intentionally does not make network calls. It provides the
/// durable state that a later bootstrap/push/pull worker can use safely after
/// process death or a temporary network outage.
const _syncLeaseDuration = Duration(minutes: 5);

class SyncOutboxRepository {
  SyncOutboxRepository(this._database);

  final AppDatabase _database;

  /// Opaque identity for same-isolate, database/scope coordination.
  Object get coordinationKey => _database;

  /// All business repositories passed to the sync adapter share this database.
  AppDatabase get database => _database;

  Future<T> transaction<T>(Future<T> Function() action) =>
      _database.transaction(action);

  Future<Map<String, dynamic>?> getRemoteAuxiliaryEntity({
    required String scopeId,
    required String entity,
    required String entityId,
  }) async {
    final key = _auxiliaryKey(scopeId: scopeId, entity: entity, entityId: entityId);
    final row = await (_database.select(_database.appSettings)
          ..where((setting) => setting.key.equals(key)))
        .getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.value);
    if (decoded is! Map) throw const FormatException('invalid auxiliary sync record');
    return Map<String, dynamic>.from(decoded);
  }

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

  String _auxiliaryKey({required String scopeId, required String entity, required String entityId}) =>
      'sync_aux:$scopeId:$entity:$entityId';

  Future<SyncRemoteApplyStatus> applyRemoteAuxiliaryEntity({
    required String scopeId,
    required String entity,
    required String entityId,
    required Map<String, dynamic> payload,
    required int version,
    required DateTime updatedAt,
    DateTime? deletedAt,
    bool businessApplied = false,
  }) async {
    final key = _auxiliaryKey(scopeId: scopeId, entity: entity, entityId: entityId);
    final existing = await (_database.select(_database.appSettings)
          ..where((row) => row.key.equals(key)))
        .getSingleOrNull();
    Map<String, dynamic>? previous;
    if (existing != null) {
      final decoded = jsonDecode(existing.value);
      if (decoded is Map) previous = Map<String, dynamic>.from(decoded);
    }
    final previousVersion = previous?['version'];
    final localVersion = previousVersion is num ? previousVersion.toInt() : null;
    if (localVersion != null && version > 0 && localVersion > version) {
      return SyncRemoteApplyStatus.ignoredStale;
    }
    if (localVersion != null && version > 0 && localVersion == version &&
        (!businessApplied || previous?['business_applied'] == true)) {
      return SyncRemoteApplyStatus.alreadyApplied;
    }
    final record = <String, dynamic>{
      'entity': entity,
      'entity_id': entityId,
      'version': version,
      'updated_at': updatedAt.toUtc().toIso8601String(),
      'deleted_at': deletedAt?.toUtc().toIso8601String(),
      'payload': payload,
      'business_applied': businessApplied,
    };
    await _database.into(_database.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: key,
            value: jsonEncode(record),
            updatedAt: updatedAt.toUtc(),
          ),
        );
    return SyncRemoteApplyStatus.applied;
  }

  Future<void> savePendingBootstrap({
    required String scopeId,
    required Map<String, dynamic> snapshot,
    required int serverCursor,
    String? checkpoint,
    String? bootstrapState,
    String? mode,
    bool refreshRequired = false,
  }) async {
    await _saveInternalSetting(
      'sync_bootstrap:$scopeId',
      jsonEncode({
        'server_cursor': serverCursor,
        'snapshot': snapshot,
        if (checkpoint != null && checkpoint.trim().isNotEmpty) 'checkpoint': checkpoint,
        if (bootstrapState != null && bootstrapState.trim().isNotEmpty)
          'bootstrap_state': bootstrapState,
        if (mode != null && mode.trim().isNotEmpty) 'mode': mode,
        if (refreshRequired) 'refresh_required': true,
        'saved_at': _now().toIso8601String(),
      }),
    );
  }

  Future<Map<String, dynamic>?> _getBootstrapRecord(String scopeId) async {
    final row = await (_database.select(_database.appSettings)
          ..where((setting) => setting.key.equals('sync_bootstrap:$scopeId')))
        .getSingleOrNull();
    if (row == null) return null;
    final decoded = jsonDecode(row.value);
    if (decoded is! Map) throw const FormatException('invalid bootstrap record');
    return Map<String, dynamic>.from(decoded);
  }

  Future<Map<String, dynamic>?> getPendingBootstrap(String scopeId) async {
    final record = await _getBootstrapRecord(scopeId);
    // A completed record retains only the confirmed mode, not a pending
    // snapshot. Preserve that choice across restart without a schema change.
    return record != null && record.containsKey('snapshot') ? record : null;
  }

  Future<String?> getConfirmedBootstrapMode(String scopeId) async {
    final record = await _getBootstrapRecord(scopeId);
    final mode = record?['mode'];
    return mode is String && mode.isNotEmpty ? mode : null;
  }

  Future<void> clearPendingBootstrap(String scopeId) async {
    final mode = await getConfirmedBootstrapMode(scopeId);
    if (mode != null) {
      await _saveInternalSetting('sync_bootstrap:$scopeId', jsonEncode({
        'mode': mode,
        'bootstrap_state': 'completed',
      }));
      return;
    }
    await (_database.delete(_database.appSettings)
          ..where((setting) => setting.key.equals('sync_bootstrap:$scopeId')))
        .go();
  }

  /// A snapshot may replace quantities only when the whole scope is quiescent.
  /// Include failed commands: a rejected stock operation is not permission to
  /// discard the user's local edit. Resolution must be explicit.
  Future<bool> hasSnapshotBlockingChanges({required String scopeId}) =>
      _hasSnapshotBlockers(scopeId: scopeId, includePending: true);

  /// Pending work alone may be a bounded maxPush continuation. Unsettled
  /// failures/claims and open/deferred conflicts must still stop that drain.
  /// Validly settled rejected/conflict audit rows are not permanent blockers.
  Future<bool> hasNonPendingSnapshotBlockers({required String scopeId}) =>
      _hasSnapshotBlockers(scopeId: scopeId, includePending: false);

  Future<bool> _hasSnapshotBlockers({
    required String scopeId,
    required bool includePending,
  }) async {
    final outbox = await (_database.select(_database.syncOutbox)
          ..where((row) => row.scopeId.equals(scopeId) & row.status.isIn([
            if (includePending) SyncOutboxStatus.pending.wireValue,
            SyncOutboxStatus.inFlight.wireValue,
            SyncOutboxStatus.blocked.wireValue,
            SyncOutboxStatus.conflict.wireValue,
            SyncOutboxStatus.rejected.wireValue,
          ])))
        .get();
    for (final row in outbox) {
      if (!await _isSettledOutboxEntry(_outboxFromRecord(row))) return true;
    }
    final conflict = await (_database.select(_database.syncConflicts)
          ..where((row) => row.scopeId.equals(scopeId) & row.status.isIn([
            SyncConflictStatus.open.wireValue,
            SyncConflictStatus.deferred.wireValue,
          ]))
          ..limit(1))
        .getSingleOrNull();
    return conflict != null;
  }

  Future<void> _saveInternalSetting(String key, String value) async {
    await _database.into(_database.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(key: key, value: value, updatedAt: _now()),
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
    return _database.transaction(() => enqueueInCurrentTransaction(draft));
  }

  /// Enqueues a change without opening a nested transaction.
  ///
  /// Repository writes that must be durable together with their sync intent
  /// call this from their existing Drift transaction. Do not call this method
  /// outside a transaction; use [enqueue] for standalone outbox writes.
  Future<SyncOutboxEntry> enqueueInCurrentTransaction(SyncOutboxDraft draft) async {
    _validateDraft(draft);

    final existing = await (_database.select(_database.syncOutbox)
          ..where((entry) => entry.changeId.equals(draft.changeId)))
        .getSingleOrNull();
    if (existing != null) {
      final value = _outboxFromRecord(existing);
      _ensureSameRequest(value, draft);
      return value;
    }

    final sameIdempotency = await (_database.select(_database.syncOutbox)
          ..where((entry) =>
              entry.scopeId.equals(draft.scopeId) &
              entry.idempotencyKey.equals(draft.idempotencyKey)))
        .getSingleOrNull();
    if (sameIdempotency != null) {
      final value = _outboxFromRecord(sameIdempotency);
      _ensureSameRequest(value, draft);
      return value;
    }

    final requestedAt = draft.createdAt ?? _now();
    final latest = await (_database.select(_database.syncOutbox)
          ..where((entry) => entry.scopeId.equals(draft.scopeId))
          ..orderBy([(entry) => OrderingTerm.desc(entry.createdAt)])
          ..limit(1))
        .getSingleOrNull();
    // Several business mutations can be committed in one Drift transaction
    // with the same wall-clock timestamp. Keep the durable queue order
    // deterministic so a newly-created batch is pushed before its restock
    // command, even after a process restart.
    final now = latest != null && !requestedAt.isAfter(latest.createdAt)
        ? latest.createdAt.add(const Duration(microseconds: 1))
        : requestedAt;
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
    final inserted = await (_database.select(_database.syncOutbox)
          ..where((entry) => entry.changeId.equals(draft.changeId)))
        .getSingleOrNull();
    if (inserted == null) {
      throw StateError('sync outbox insert did not return the inserted change');
    }
    return _outboxFromRecord(inserted);
  }

  void _validateDraft(SyncOutboxDraft draft) {
    if (draft.changeId.trim().isEmpty || draft.scopeId.trim().isEmpty) {
      throw const FormatException('change_id and scope_id are required');
    }
    if (draft.idempotencyKey.length < 16 || draft.idempotencyKey.length > 255) {
      throw const FormatException('idempotency_key must contain 16 to 255 characters');
    }
    if (draft.requestJson.trim().isEmpty) {
      throw const FormatException('request_json must not be empty');
    }
  }

  Future<List<SyncOutboxEntry>> listForEntity({
    required String scopeId,
    required String entity,
    required String entityId,
    bool includeTerminal = false,
  }) async {
    final query = _database.select(_database.syncOutbox)
      ..where((entry) =>
          entry.scopeId.equals(scopeId) &
          entry.entity.equals(entity) &
          entry.entityId.equals(entityId));
    if (!includeTerminal) {
      query.where((entry) =>
          entry.status.equals(SyncOutboxStatus.pending.wireValue) |
          entry.status.equals(SyncOutboxStatus.inFlight.wireValue));
    }
    final rows = await (query
          ..orderBy([(entry) => OrderingTerm.desc(const CustomExpression<int>('rowid'))]))
        .get();
    return rows.map(_outboxFromRecord).toList(growable: false);
  }

  Future<List<SyncOutboxEntry>> listForOperation({
    required String scopeId,
    required SyncOperation operation,
    bool includeTerminal = false,
  }) async {
    final query = _database.select(_database.syncOutbox)
      ..where((entry) =>
          entry.scopeId.equals(scopeId) &
          entry.operation.equals(operation.wireValue));
    if (!includeTerminal) {
      query.where((entry) =>
          entry.status.equals(SyncOutboxStatus.pending.wireValue) |
          entry.status.equals(SyncOutboxStatus.inFlight.wireValue));
    }
    final rows = await (query
          ..orderBy([(entry) => OrderingTerm.desc(entry.createdAt)]))
        .get();
    return rows.map(_outboxFromRecord).toList(growable: false);
  }

  /// Allocate a version for a newly-created immutable entity request. Pending
  /// predecessors reserve one version each; failed predecessors remain queue
  /// barriers until explicit settlement, so predictions never authorize sends.
  Future<int> nextEntityBaseVersion({
    required String scopeId,
    required String entity,
    required String entityId,
    required int serverVersion,
  }) async {
    var version = serverVersion;
    final entries = await listForEntity(scopeId: scopeId, entity: entity,
      entityId: entityId, includeTerminal: true);
    for (final entry in entries.reversed) {
      if (entry.operation != SyncOperation.entityUpsert &&
          entry.operation != SyncOperation.entityDelete) {
        continue;
      }
      if (entry.status == SyncOutboxStatus.accepted || entry.status == SyncOutboxStatus.replayed) {
        if ((entry.serverVersion ?? 0) > version) version = entry.serverVersion!;
      } else if (!await _isSettledOutboxEntry(entry)) {
        final base = entry.baseVersion;
        if (base >= version) version = base + 1;
      }
    }
    return version;
  }

  /// Emits only new or changed pending request content after a committed write.
  ///
  /// Observe the scoped ledger, not just pending membership: claim/retry/status
  /// transitions must not look like a newly submitted local request. Reads,
  /// receipt metadata, and remote application without an outbox write never
  /// trigger this stream. No lease reclamation or dependency writes occur here.
  /// Each subscriber keeps its own baseline; the first snapshot emits any
  /// existing pending work so restart/scope changes do not lose local intent.
  Stream<List<SyncOutboxEntry>> watchPendingContentChanges({
    required String scopeId,
  }) {
    // A baseline belongs to a subscription, not the stream object. A shared
    // map would let the first listener consume changes intended for another
    // listener (or hide existing work when the same stream is resubscribed).
    return Stream<List<SyncOutboxEntry>>.multi((controller) {
      var previous = <String, String>{};
      final subscription = (_database.select(_database.syncOutbox)
            ..where((entry) => entry.scopeId.equals(scopeId))
            ..orderBy([(entry) => OrderingTerm.asc(entry.changeId)]))
          .watch()
          .map((rows) {
        final next = <String, String>{};
        final changed = <SyncOutboxEntry>[];
        for (final row in rows) {
          // Do not include scheduling/receipt fields (status, attempts,
          // timestamps, errors, server versions) in the content identity.
          final fingerprint = jsonEncode([
            row.operation, row.entity, row.entityId, row.baseVersion,
            row.operationId, row.integrationId, row.command,
            row.idempotencyKey, row.requestJson,
          ]);
          next[row.changeId] = fingerprint;
          if (row.status == SyncOutboxStatus.pending.wireValue &&
              previous[row.changeId] != fingerprint) {
            changed.add(_outboxFromRecord(row));
          }
        }
        previous = next;
        return changed;
      })
          .where((changed) => changed.isNotEmpty)
          .listen(controller.add,
              onError: controller.addError, onDone: controller.close);
      controller.onCancel = subscription.cancel;
      controller.onPause = subscription.pause;
      controller.onResume = subscription.resume;
    }, isBroadcast: true);
  }

  Future<List<SyncOutboxEntry>> listPending({
    required String scopeId,
    int limit = 100,
    DateTime? now,
  }) async {
    if (limit < 1) throw ArgumentError.value(limit, 'limit');
    final readyAt = now ?? _now();
    await reclaimExpiredInFlight(scopeId: scopeId, now: readyAt);
    await refreshDependencyBlocks(scopeId: scopeId, now: readyAt);
    final rows = await (_database.select(_database.syncOutbox)
          ..where((entry) =>
              entry.scopeId.equals(scopeId) &
              entry.status.equals(SyncOutboxStatus.pending.wireValue) &
              (entry.nextAttemptAt.isNull() |
                  entry.nextAttemptAt.isSmallerOrEqualValue(readyAt)))
          ..orderBy([(entry) => OrderingTerm.asc(const CustomExpression<int>('rowid'))])
          ..limit(limit * 4))
        .get();
    final entries = rows.map(_outboxFromRecord).toList(growable: false);
    final order = {for (var i = 0; i < entries.length; i++) entries[i].changeId: i};
    entries.sort((a, b) => _dependencyRank(a).compareTo(_dependencyRank(b)) != 0
        ? _dependencyRank(a).compareTo(_dependencyRank(b))
        : order[a.changeId]!.compareTo(order[b.changeId]!));
    return entries.take(limit).toList(growable: false);
  }

  /// Reclaims a process-crashed claim after the five-minute local lease.
  /// The server's idempotency key still protects a request that actually
  /// reached the NAS before the process died.
  Future<int> reclaimExpiredInFlight({
    required String scopeId,
    DateTime? now,
  }) async {
    final cutoff = (now ?? _now()).subtract(_syncLeaseDuration);
    return (_database.update(_database.syncOutbox)
          ..where((entry) =>
              entry.scopeId.equals(scopeId) &
              entry.status.equals(SyncOutboxStatus.inFlight.wireValue) &
              entry.updatedAt.isSmallerThanValue(cutoff)))
        .write(
      SyncOutboxCompanion(
        status: Value(SyncOutboxStatus.pending.wireValue),
        nextAttemptAt: const Value(null),
        lastErrorCode: const Value('stale_in_flight_reclaimed'),
        lastErrorMessage: const Value('本地同步租约已过期，已回收并准备重试。'),
        updatedAt: Value(now ?? _now()),
      ),
    );
  }

  /// Claims the oldest ready item, respecting product -> batch -> shopping
  /// -> inventory dependency ordering. Claiming also reclaims stale leases.
  Future<SyncOutboxEntry?> claimNext({
    required String scopeId,
    DateTime? now,
  }) async {
    final claimedAt = now ?? _now();
    return _database.transaction(() async {
      final cutoff = claimedAt.subtract(_syncLeaseDuration);
      await (_database.update(_database.syncOutbox)
            ..where((entry) =>
                entry.scopeId.equals(scopeId) &
                entry.status.equals(SyncOutboxStatus.inFlight.wireValue) &
                entry.updatedAt.isSmallerThanValue(cutoff)))
          .write(
        SyncOutboxCompanion(
          status: Value(SyncOutboxStatus.pending.wireValue),
          nextAttemptAt: const Value(null),
          lastErrorCode: const Value('stale_in_flight_reclaimed'),
          lastErrorMessage: const Value('本地同步租约已过期，已回收并准备重试。'),
          updatedAt: Value(claimedAt),
        ),
      );
      await _refreshDependencyBlocksInCurrentTransaction(
        scopeId: scopeId,
        now: claimedAt,
      );
      final rows = await (_database.select(_database.syncOutbox)
          ..where((entry) =>
              entry.scopeId.equals(scopeId) &
              entry.status.equals(SyncOutboxStatus.pending.wireValue) &
              (entry.nextAttemptAt.isNull() |
                  entry.nextAttemptAt.isSmallerOrEqualValue(claimedAt)))
          ..orderBy([(entry) => OrderingTerm.asc(const CustomExpression<int>('rowid'))])
          ..limit(500)).get();
      if (rows.isEmpty) return null;
      final sorted = rows.map(_outboxFromRecord).toList(growable: false);
      final order = {for (var i = 0; i < sorted.length; i++) sorted[i].changeId: i};
      sorted.sort((a, b) => _dependencyRank(a).compareTo(_dependencyRank(b)) != 0
          ? _dependencyRank(a).compareTo(_dependencyRank(b))
          : order[a.changeId]!.compareTo(order[b.changeId]!));
      final selected = sorted.first;
      await (_database.update(_database.syncOutbox)
            ..where((entry) => entry.changeId.equals(selected.changeId)))
          .write(
        SyncOutboxCompanion(
          status: Value(SyncOutboxStatus.inFlight.wireValue),
          attemptCount: Value(selected.attemptCount + 1),
          updatedAt: Value(claimedAt),
        ),
      );
      return selected.copyWith(
        status: SyncOutboxStatus.inFlight,
        attemptCount: selected.attemptCount + 1,
        updatedAt: claimedAt,
      );
    });
  }

  Future<void> refreshDependencyBlocks({required String scopeId, DateTime? now}) async {
    await _database.transaction(() => _refreshDependencyBlocksInCurrentTransaction(
          scopeId: scopeId,
          now: now ?? _now(),
        ));
  }

  Future<void> _refreshDependencyBlocksInCurrentTransaction({
    required String scopeId,
    required DateTime now,
  }) async {
    final rows = await (_database.select(_database.syncOutbox)
          ..where((entry) => entry.scopeId.equals(scopeId))
          ..orderBy([(entry) => OrderingTerm.asc(const CustomExpression<int>('rowid'))]))
        .get();
    final entries = rows.map(_outboxFromRecord).toList(growable: false);
    final queueOrder = {for (var i = 0; i < entries.length; i++) entries[i].changeId: i};
    final byEntity = <String, SyncOutboxEntry>{};
    final settled = <String>{};
    for (final entry in entries) {
      if (await _isSettledOutboxEntry(entry)) {
        settled.add(entry.changeId);
        continue;
      }
      final request = _decodedRequest(entry);
      final entity = _entryEntity(entry, request ?? const <String, dynamic>{});
      final entityId = request == null ? entry.entityId : _entryEntityId(entry, request);
      if (entity == null || entityId == null) continue;
      final key = '$entity:$entityId';
      final previous = byEntity[key];
      if (previous == null || queueOrder[entry.changeId]! > queueOrder[previous.changeId]!) {
        byEntity[key] = entry;
      }
    }
    for (final entry in entries) {
      if (settled.contains(entry.changeId) ||
          (entry.status != SyncOutboxStatus.pending && entry.status != SyncOutboxStatus.blocked)) {
        continue;
      }
      final dependencyKeys = _dependencyKeys(entry);
      final predecessors = entries.where((other) =>
          other.changeId != entry.changeId && other.entity == entry.entity &&
          other.entityId == entry.entityId && entry.entity != null && entry.entityId != null &&
          queueOrder[other.changeId]! < queueOrder[entry.changeId]! && !settled.contains(other.changeId) &&
          other.status != SyncOutboxStatus.accepted && other.status != SyncOutboxStatus.replayed);
      final prior = predecessors.isEmpty ? null : predecessors.first;
      final blockedBy = prior != null ? 'change:${prior.changeId}' : dependencyKeys.firstWhere(
        (key) {
          final dependency = byEntity[key];
          return dependency != null &&
              const {
                SyncOutboxStatus.pending,
                SyncOutboxStatus.inFlight,
                SyncOutboxStatus.blocked,
                SyncOutboxStatus.conflict,
                SyncOutboxStatus.rejected,
              }.contains(dependency.status);
        },
        orElse: () => '',
      );
      final shouldBlock = blockedBy.isNotEmpty;
      if (shouldBlock &&
          (entry.status == SyncOutboxStatus.pending || entry.status == SyncOutboxStatus.blocked)) {
        await (_database.update(_database.syncOutbox)
              ..where((row) => row.changeId.equals(entry.changeId)))
            .write(
          SyncOutboxCompanion(
            status: Value(SyncOutboxStatus.blocked.wireValue),
            lastErrorCode: const Value('dependency_blocked'),
            lastErrorMessage: Value('等待依赖变化完成：$blockedBy'),
            updatedAt: Value(now),
          ),
        );
      } else if (!shouldBlock && entry.status == SyncOutboxStatus.blocked) {
        await (_database.update(_database.syncOutbox)
              ..where((row) => row.changeId.equals(entry.changeId)))
            .write(
          SyncOutboxCompanion(
            status: Value(SyncOutboxStatus.pending.wireValue),
            nextAttemptAt: const Value(null),
            lastErrorCode: const Value(null),
            lastErrorMessage: const Value(null),
            updatedAt: Value(now),
          ),
        );
      }
    }
  }

  List<String> _dependencyKeys(SyncOutboxEntry entry) {
    final keys = <String>{};
    final request = _decodedRequest(entry);
    if (request == null) return const <String>[];
    final payload = _mapValue(request['payload']);
    final entity = _entryEntity(entry, request);
    final entityId = _entryEntityId(entry, request);
    final isInventoryCommand = entry.operation == SyncOperation.inventoryCommand ||
        request['operation'] == SyncOperation.inventoryCommand.wireValue;

    void addDependency(String dependencyEntity, String? dependencyId) {
      final normalized = dependencyId?.trim();
      if (normalized == null || normalized.isEmpty) return;
      // A legacy request can repeat its own id in payload/entity_id. Do not
      // turn that into a self-dependency which would block the outbox forever.
      if (dependencyEntity == entity && normalized == entityId) return;
      keys.add('$dependencyEntity:$normalized');
    }

    final requestAndPayload = <Map<String, dynamic>>[
      request,
      if (payload != null) payload,
    ];

    final productRelatedEntities = const {
      'product_batches',
      'shopping_items',
      'reminder_settings',
      'reminder_acknowledgments',
    };
    if (productRelatedEntities.contains(entity) || isInventoryCommand) {
      for (final productId in _identifiersFromMaps(
        requestAndPayload,
        const ['product_id', 'productId'],
      )) {
        addDependency('products', productId);
      }
    }

    // Products may refer to a family category. Keep both snake_case and
    // camelCase wire variants so old and new clients are ordered identically.
    if (entity != 'categories') {
      for (final categoryId in _identifiersFromMaps(
        requestAndPayload,
        const ['category_id', 'categoryId'],
      )) {
        addDependency('categories', categoryId);
      }
    }

    // Reminder settings are product-scoped. Acknowledgements normally encode
    // the product in reminder_key (for example <product-id>:low-stock), but
    // also accept explicit relation fields used by newer payloads.
    if (entity != 'reminder_settings') {
      for (final reminderSettingId in _identifiersFromMaps(
        requestAndPayload,
        const ['reminder_setting_id', 'reminderSettingId'],
      )) {
        addDependency('reminder_settings', reminderSettingId);
      }
    }
    if (entity == 'reminder_acknowledgments') {
      for (final reminderKey in _identifiersFromMaps(
        requestAndPayload,
        const ['reminder_key', 'reminderKey'],
      )) {
        final separator = reminderKey.indexOf(':');
        if (separator > 0) {
          addDependency('products', reminderKey.substring(0, separator));
        }
      }
    }

    final batchRelated = isInventoryCommand;
    if (batchRelated) {
      // Inventory command fields are part of the top-level request in the
      // current protocol, while older clients nested them under payload.
      for (final batchId in _identifiersFromMaps(
        requestAndPayload,
        const ['batch_id', 'batchId'],
      )) {
        addDependency('product_batches', batchId);
      }
      for (final allocations in <Object?>[
        request['allocations'],
        payload?['allocations'],
      ]) {
        if (allocations is! List) continue;
        for (final rawAllocation in allocations) {
          final allocation = _mapValue(rawAllocation);
          if (allocation == null) continue;
          for (final batchId in _identifiersFromMaps(
            [allocation],
            const ['batch_id', 'batchId'],
          )) {
            addDependency('product_batches', batchId);
          }
        }
      }

      // Some command payloads carry the affected batch only as
      // payload.entity_id. Use it for inventory ordering, but not for a
      // normal product-batch entity delete where it would be self-referential.
      if (isInventoryCommand) {
        addDependency(
          'product_batches',
          _firstIdentifier([payload?['entity_id'], payload?['entityId']]),
        );
      }
    }

    return keys.toList(growable: false);
  }

  Map<String, dynamic>? _decodedRequest(SyncOutboxEntry entry) {
    try {
      final decoded = jsonDecode(entry.requestJson);
      return _mapValue(decoded);
    } catch (_) {
      return null;
    }
  }

  Map<String, dynamic>? _mapValue(Object? value) {
    if (value is Map<String, dynamic>) return value;
    if (value is Map) return Map<String, dynamic>.from(value);
    return null;
  }

  String? _entryEntity(SyncOutboxEntry entry, Map<String, dynamic> request) {
    final direct = entry.entity?.trim();
    if (direct != null && direct.isNotEmpty) return direct;
    final requestEntity = request['entity'];
    return requestEntity is String && requestEntity.trim().isNotEmpty
        ? requestEntity.trim()
        : null;
  }

  String? _entryEntityId(SyncOutboxEntry entry, Map<String, dynamic> request) {
    final payload = _mapValue(request['payload']);
    return _firstIdentifier([
      entry.entityId,
      request['entity_id'],
      request['entityId'],
      payload?['entity_id'],
      payload?['entityId'],
    ]);
  }

  String? _firstIdentifier(Iterable<Object?> values) {
    for (final value in values) {
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  Set<String> _identifiersFromMaps(
    Iterable<Map<String, dynamic>> maps,
    List<String> fieldNames,
  ) {
    final values = <String>{};
    for (final map in maps) {
      for (final fieldName in fieldNames) {
        final value = map[fieldName];
        if (value is String && value.trim().isNotEmpty) {
          values.add(value.trim());
        }
      }
    }
    return values;
  }

  int _dependencyRank(SyncOutboxEntry entry) {
    if (entry.operation == SyncOperation.inventoryCommand) return 6;
    final entity = _entryEntity(entry, _decodedRequest(entry) ?? const <String, dynamic>{});
    return switch (entity) {
      'categories' => 0,
      'products' => 1,
      'reminder_settings' => 2,
      'product_batches' => 3,
      'shopping_items' => 4,
      'reminder_acknowledgments' => 5,
      _ => 2,
    };
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
    bool confirmedByNas = false,
    bool failedBeforeFirstSend = false,
    DateTime? completedAt,
  }) async {
    await _database.transaction(() async {
      final entry = await getByChangeId(changeId);
      await _markTerminal(changeId: changeId, status: SyncOutboxStatus.rejected,
        errorCode: errorCode, errorMessage: errorMessage, completedAt: completedAt);
      if (entry != null && ((confirmedByNas && _isDefinitiveRejection(entry, errorCode)) ||
          (failedBeforeFirstSend && entry.attemptCount == 1))) {
        await _saveInternalSetting(_rejectionEvidenceKey(entry.scopeId, changeId), jsonEncode({
          ..._outboxIdentity(entry),
          'source': confirmedByNas ? 'nas_rejected' : 'never_sent',
          'error_code': errorCode,
          'error_message': errorMessage,
          'recorded_at': _now().toIso8601String(),
        }));
      }
    });
  }

  bool _isDefinitiveRejection(SyncOutboxEntry entry, String code) {
    // Legacy NAS versions may classify transport/audit errors after an HA
    // effect as rejected. Those are not proof that the physical action did
    // not happen. Reused keys likewise cannot establish the original outcome.
    if (code.contains('UNKNOWN') || code == 'IDEMPOTENCY_KEY_REUSE') return false;
    if (entry.operation != SyncOperation.homeAssistantCommand) return true;
    return const {
      'VALIDATION_FAILED', 'UNSUPPORTED_OPERATION', 'INVALID_CURSOR',
      'HOME_ASSISTANT_NOT_CONFIGURED', 'HA_FORBIDDEN', 'HA_INVALID_ROLE',
      'HA_INVALID_ARGUMENT', 'HA_INVALID_COMMAND', 'HA_INVALID_PARAMETERS',
      'HA_UNSUPPORTED_COMMAND', 'HA_NOT_FOUND',
    }.contains(code);
  }

  String _rejectionEvidenceKey(String scopeId, String changeId) =>
      'sync_rejection_evidence:${jsonEncode([scopeId, changeId])}';

  String _rejectedSettlementKey(String scopeId, String changeId) =>
      'sync_rejected_settlement:${jsonEncode([scopeId, changeId])}';

  Map<String, dynamic> _outboxIdentity(SyncOutboxEntry entry) => {
    'scope_id': entry.scopeId, 'outbox_change_id': entry.changeId,
    'outbox_status': SyncOutboxStatus.rejected.wireValue,
    'operation': entry.operation.wireValue, 'idempotency_key': entry.idempotencyKey,
    'request_json': entry.requestJson,
  };

  Future<bool> canAbandonRejected(SyncOutboxEntry entry) async {
    if (entry.status != SyncOutboxStatus.rejected || await _isSettledOutboxEntry(entry)) return false;
    final evidence = await _readSettlement(_rejectionEvidenceKey(entry.scopeId, entry.changeId));
    return evidence != null && _settlementMatchesOutbox(evidence, entry) &&
        (evidence['source'] == 'nas_rejected' || evidence['source'] == 'never_sent') &&
        evidence['error_code'] == entry.lastErrorCode &&
        evidence['error_message'] == entry.lastErrorMessage;
  }

  /// Explicitly withdraw an intent with durable proof that it did not execute.
  /// Unknown requests never enter here. The original request and refusal remain
  /// unchanged; a fresh authoritative snapshot removes optimistic local effects.
  Future<void> abandonRejected({required String scopeId, required String changeId}) async {
    await _database.transaction(() async {
      final entry = await getByChangeId(changeId);
      if (entry != null && entry.scopeId == scopeId && await _isSettledOutboxEntry(entry) &&
          (await _readSettlement(_rejectedSettlementKey(scopeId, changeId)))?['action'] == 'abandon_rejected') {
        return;
      }
      if (entry == null || entry.scopeId != scopeId || !await canAbandonRejected(entry)) {
        throw StateError('Missing definitive rejection evidence; the request remains protected.');
      }
      final linked = await (_database.select(_database.syncConflicts)
        ..where((row) => row.scopeId.equals(scopeId) & row.outboxChangeId.equals(changeId) &
            row.status.isIn([SyncConflictStatus.open.wireValue, SyncConflictStatus.deferred.wireValue])))
        .get();
      for (final row in linked) {
        if (!_isProtectionForIntent(_conflictFromRecord(row), entry)) {
          throw StateError('A linked conflict requires a NAS resolution receipt.');
        }
      }
      final evidence = (await _readSettlement(_rejectionEvidenceKey(scopeId, changeId)))!;
      await _saveInternalSetting(_rejectedSettlementKey(scopeId, changeId), jsonEncode({
        ...evidence, 'action': 'abandon_rejected', 'settled_at': _now().toIso8601String(),
      }));
      for (final row in linked) {
        await resolveConflict(id: row.id, status: SyncConflictStatus.rejected,
          resolution: 'abandon_rejected');
        await _recordProtectionRetirement(_conflictFromRecord(row), entry,
          action: 'abandon_rejected');
      }
      await _saveInternalSetting(_resolutionRefreshKey(scopeId), const Uuid().v4());
      await _refreshDependencyBlocksInCurrentTransaction(scopeId: scopeId, now: _now());
    });
  }

  Future<List<SyncOutboxEntry>> _listRejectedEntries(String scopeId) async {
    final rows = await (_database.select(_database.syncOutbox)
      ..where((row) => row.scopeId.equals(scopeId) & row.status.equals(SyncOutboxStatus.rejected.wireValue))
      ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
      .get();
    return rows.map(_outboxFromRecord).toList(growable: false);
  }

  Future<List<SyncOutboxEntry>> listAbandonedRejected({required String scopeId}) async {
    final entries = await _listRejectedEntries(scopeId);
    final result = <SyncOutboxEntry>[];
    for (final entry in entries) {
      final marker = await _readSettlement(_rejectedSettlementKey(scopeId, entry.changeId));
      final restored = await _readSettlement(_rejectedRestoredKey(scopeId, entry.changeId));
      if (marker?['action'] == 'abandon_rejected' &&
          (restored == null || !_settlementMatchesOutbox(restored, entry)) &&
          await _isSettledOutboxEntry(entry)) {
        result.add(entry);
      }
    }
    return result;
  }

  String _rejectedRestoredKey(String scopeId, String changeId) =>
      'sync_rejected_restored:${jsonEncode([scopeId, changeId])}';

  /// Called only inside the authoritative business snapshot transaction. A
  /// failed snapshot/receipt/cursor commit rolls this checkpoint back as well.
  Future<void> markAbandonedRejectedRestored(SyncOutboxEntry entry, int serverCursor) async {
    if (!await _isSettledOutboxEntry(entry)) throw StateError('Abandonment is no longer settled.');
    await _saveInternalSetting(_rejectedRestoredKey(entry.scopeId, entry.changeId), jsonEncode({
      ..._outboxIdentity(entry), 'server_cursor': serverCursor,
      'restored_at': _now().toIso8601String(),
    }));
  }

  Future<List<SyncOutboxEntry>> listUnsettledRejected({required String scopeId}) async {
    final entries = await _listRejectedEntries(scopeId);
    final result = <SyncOutboxEntry>[];
    for (final entry in entries) {
      if (!await _isSettledOutboxEntry(entry)) result.add(entry);
    }
    return result;
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
        status: Value(SyncOutboxStatus.pending.wireValue),
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
          status: Value(SyncOutboxStatus.conflict.wireValue),
          updatedAt: Value(now),
          completedAt: Value(now),
        ),
      );
      await recordConflict(conflict);
    });
  }

  /// Called only after NAS has accepted keep_local/keep_remote. NAS keep_local
  /// already applies the entity mutation and emits a new change-log entry: the
  /// original idempotency key must NEVER be requeued (including stock commands).
  /// Keep the original conflict/rejected row and request as audit evidence;
  /// explicit settlement, local resolution and fresh-snapshot intent commit
  /// together. No push/pull cursor is advanced by a resolution receipt.
  Future<void> settleOutboxConflict({
    required int conflictId,
    required String scopeId,
    required String changeId,
    required String remoteConflictId,
    required String action,
    required NasSyncConflictResolveResponse response,
  }) async {
    await _database.transaction(() async {
      var primaryId = conflictId;
      final selected = await getConflict(conflictId);
      if (selected == null || selected.scopeId != scopeId) {
        throw StateError('The selected local conflict is missing.');
      }
      final selectedEntry = await getByChangeId(selected.outboxChangeId ?? selected.changeId);
      if (selected.changeId != changeId) {
        if (selectedEntry == null || selectedEntry.changeId != changeId ||
            !_isProtectionForIntent(selected, selectedEntry)) {
          throw StateError('The selected conflict does not protect this immutable request.');
        }
        // Persist an audit of the real NAS conflict/receipt separately from
        // a pull-side guard. Its remote version does not resolve newer pulls.
        final existing = await getConflictByChangeId(scopeId: scopeId, changeId: changeId);
        primaryId = existing?.id ?? await recordConflict(SyncConflictDraft(
          scopeId: scopeId, changeId: changeId, outboxChangeId: selectedEntry.changeId,
          entity: response.conflict.entity, entityId: response.conflict.entityId,
          reason: response.conflict.reason, serverVersion: response.conflict.serverVersion,
          serverPayloadJson: response.conflict.serverPayload == null ? null : jsonEncode(response.conflict.serverPayload),
          clientPayloadJson: response.conflict.clientPayload == null ? null : jsonEncode(response.conflict.clientPayload),
        ));
      }
      await _settleOneOutboxConflict(conflictId: primaryId, scopeId: scopeId,
        changeId: changeId, remoteConflictId: remoteConflictId, action: action, response: response);
      final primary = (await getConflict(primaryId))!;
      final entry = await getByChangeId(primary.outboxChangeId ?? primary.changeId);
      if (entry == null || entry.changeId != changeId) return;
      final rows = await (_database.select(_database.syncConflicts)
        ..where((row) => row.scopeId.equals(scopeId) & row.outboxChangeId.equals(changeId) &
            row.status.isIn([SyncConflictStatus.open.wireValue, SyncConflictStatus.deferred.wireValue])))
        .get();
      for (final row in rows) {
        final guard = _conflictFromRecord(row);
        if (!_isProtectionForIntent(guard, entry)) continue;
        // Only the local protection reason is retired. In particular a newer
        // remote version is NOT described as resolved by this older receipt:
        // the durable refresh token requires a current authoritative snapshot.
        await resolveConflict(id: row.id, status: SyncConflictStatus.resolved,
          resolution: 'protection_retired_after_intent_settlement');
        await _recordProtectionRetirement(guard, entry,
          action: action, nasConflictId: remoteConflictId);
      }
      await _refreshDependencyBlocksInCurrentTransaction(scopeId: scopeId, now: _now());
    });
  }

  /// The protected local entity can differ from the observed remote entity
  /// (a reminder policy may protect its product). Keep the actual snapshot
  /// target and its version instead of comparing unrelated entity versions.
  Future<void> recordProtectionSnapshotTarget({
    required int conflictId,
    required String scopeId,
    required String entity,
    required String entityId,
    required int version,
  }) async {
    if (entity.trim().isEmpty || entityId.trim().isEmpty || version < 0) {
      throw const FormatException('invalid protection snapshot target');
    }
    await _saveInternalSetting(_protectionTargetKey(scopeId, conflictId), jsonEncode({
      'scope_id': scopeId, 'conflict_id': conflictId,
      'snapshot_entity': entity, 'snapshot_entity_id': entityId,
      'snapshot_version': version,
    }));
  }

  String _protectionTargetKey(String scopeId, int conflictId) =>
      'sync_protection_target:${jsonEncode([scopeId, conflictId])}';

  Future<void> _recordProtectionRetirement(SyncConflictEntry guard, SyncOutboxEntry entry, {
    required String action,
    String? nasConflictId,
  }) async {
    final target = await _readSettlement(_protectionTargetKey(guard.scopeId, guard.id));
    await _saveInternalSetting(
      'sync_protection_retirement:${jsonEncode([guard.scopeId, guard.id])}', jsonEncode({
        'scope_id': guard.scopeId, 'conflict_id': guard.id,
        'outbox_change_id': entry.changeId, 'idempotency_key': entry.idempotencyKey,
        'request_json': entry.requestJson, 'nas_conflict_id': nasConflictId,
        'action': action, 'guard_change_id': guard.changeId,
        'guard_server_version': guard.serverVersion,
        // Older persisted guards did not retain a separate source target.
        // Their recorded entity/version remains a conservative lower bound.
        'snapshot_entity': target?['snapshot_entity'] ?? guard.entity,
        'snapshot_entity_id': target?['snapshot_entity_id'] ?? guard.entityId,
        'snapshot_version': target?['snapshot_version'] ?? guard.serverVersion ?? 0,
        'requires_fresh_snapshot': true, 'retired_at': _now().toIso8601String(),
      }),
    );
  }

  /// Run inside the authoritative snapshot transaction, before business writes.
  /// Every still-pending observation must be represented, including tombstones,
  /// at its observed version or later. The completion checkpoint rolls back
  /// with business rows and the refresh-token/cursor commit on any failure.
  Future<void> restoreRetiredProtectionsFromSnapshot({
    required String scopeId,
    required List<NasSyncPullChange> snapshot,
    required int serverCursor,
  }) async {
    final prefix = 'sync_protection_retirement:[${jsonEncode(scopeId)},';
    final rows = await (_database.select(_database.appSettings)
      ..where((row) => row.key.like('sync_protection_retirement:%'))).get();
    for (final row in rows.where((row) => row.key.startsWith(prefix))) {
      final marker = _mapValue(jsonDecode(row.value));
      if (marker == null || marker['scope_id'] != scopeId) {
        throw const FormatException('invalid protection retirement evidence');
      }
      if (marker['requires_fresh_snapshot'] != true) continue;
      final conflictId = marker['conflict_id'];
      final guard = conflictId is int ? await getConflict(conflictId) : null;
      final changeId = marker['outbox_change_id'];
      final entry = changeId is String ? await getByChangeId(changeId) : null;
      if (guard == null || entry == null || !_isProtectionForIntent(guard, entry) ||
          entry.scopeId != scopeId || marker['request_json'] != entry.requestJson ||
          marker['idempotency_key'] != entry.idempotencyKey) {
        throw StateError('Protection retirement no longer matches the immutable intent.');
      }
      final entity = marker['snapshot_entity'] ?? guard.entity;
      final entityId = marker['snapshot_entity_id'] ?? guard.entityId;
      final version = marker['snapshot_version'] ?? marker['guard_server_version'] ?? 0;
      if (entity is! String || entityId is! String || version is! int || version < 0) {
        throw const FormatException('protection retirement has no verifiable snapshot target');
      }
      final matching = snapshot.where((change) => change.entity == entity && change.entityId == entityId);
      if (matching.length != 1 || (matching.single.version ?? -1) < version) {
        throw const FormatException('fresh snapshot is older than an observed protected remote change');
      }
      await _saveInternalSetting(row.key, jsonEncode({
        ...marker, 'requires_fresh_snapshot': false, 'restored_server_cursor': serverCursor,
        'restored_at': _now().toIso8601String(),
      }));
    }
  }

  bool _isProtectionForIntent(SyncConflictEntry guard, SyncOutboxEntry entry) {
    if (guard.scopeId != entry.scopeId || guard.outboxChangeId != entry.changeId ||
        guard.changeId == entry.changeId || guard.clientPayloadJson != entry.requestJson ||
        !const {'REMOTE_CHANGE_WITH_PENDING_LOCAL_CHANGE',
          'REMOTE_INVENTORY_COMMAND_WITH_PENDING_LOCAL_CHANGE'}.contains(guard.reason)) {
      return false;
    }
    if (entry.operation == SyncOperation.entityUpsert || entry.operation == SyncOperation.entityDelete) {
      return guard.entity == entry.entity && guard.entityId == entry.entityId;
    }
    if (entry.operation == SyncOperation.inventoryCommand && guard.entity == 'product_batches') {
      final request = _decodedRequest(entry);
      final allocations = request?['allocations'];
      return allocations is List && allocations.any((raw) => raw is Map && raw['batch_id'] == guard.entityId);
    }
    return false;
  }

  Future<void> _settleOneOutboxConflict({
    required int conflictId,
    required String scopeId,
    required String changeId,
    required String remoteConflictId,
    required String action,
    required NasSyncConflictResolveResponse response,
  }) async {
    final remote = response.conflict;
    if (scopeId.trim().isEmpty || changeId.trim().isEmpty ||
        remoteConflictId.trim().isEmpty ||
        (action != 'keep_local' && action != 'keep_remote') ||
        !response.accepted || remote.status != 'resolved' ||
        remote.conflictId != remoteConflictId || remote.changeId != changeId ||
        remote.resolution?['action'] != action) {
      throw StateError('Invalid NAS conflict resolution receipt.');
    }
    await _database.transaction(() async {
      final local = await getConflict(conflictId);
      if (local == null || local.scopeId != scopeId ||
          (local.changeId != changeId && local.outboxChangeId != changeId) ||
          local.entity != remote.entity || local.entityId != remote.entityId) {
        throw StateError('Resolution does not match the local scope/change.');
      }
      final entry = await getByChangeId(local.outboxChangeId ?? local.changeId);
      if (local.outboxChangeId != null && entry == null) {
        throw StateError('The linked outbox change is missing.');
      }
      if (local.changeId != changeId) {
        throw StateError('A NAS receipt cannot directly resolve a pull protection record.');
      }
      if (entry != null &&
          (entry.scopeId != scopeId ||
              (entry.status != SyncOutboxStatus.conflict &&
                  entry.status != SyncOutboxStatus.rejected) ||
              (entry.entity != null && entry.entity != local.entity) ||
              (entry.entityId != null && entry.entityId != local.entityId) ||
              (remote.operation != null && remote.operation != entry.operation.wireValue))) {
        throw StateError('Resolution does not match a failed outbox change.');
      }
      final requestOperation = entry == null ? null : _decodedRequest(entry)?['operation'];
      final remoteIsEntity = remote.operation == SyncOperation.entityUpsert.wireValue ||
          remote.operation == SyncOperation.entityDelete.wireValue;
      final localIsEntity = entry == null ||
          entry.operation == SyncOperation.entityUpsert || entry.operation == SyncOperation.entityDelete;
      if (action == 'keep_local' &&
          (!remoteIsEntity || !localIsEntity ||
              (entry != null &&
                  (entry.operationId != null || entry.integrationId != null ||
                      entry.command != null ||
                      (requestOperation != null && requestOperation != entry.operation.wireValue))))) {
        throw StateError('keep_local cannot settle an inventory or HA command.');
      }
      final status = action == 'keep_local'
          ? SyncConflictStatus.resolved : SyncConflictStatus.rejected;
      final resolution = 'remote_$action';
      final key = _conflictSettlementKey(scopeId, conflictId);
      final previous = await _readSettlement(key);
      if (previous != null) {
        if (previous['remote_conflict_id'] != remoteConflictId ||
            previous['remote_change_id'] != changeId || previous['action'] != action ||
            !_settlementMatchesConflict(previous, local) ||
            (entry != null && !_settlementMatchesOutbox(previous, entry))) {
          throw StateError('Conflict was settled with different evidence.');
        }
        // Idempotent retry: do not overwrite audit or re-arm a consumed refresh.
        return;
      }
      if (local.status != SyncConflictStatus.open &&
          local.status != SyncConflictStatus.deferred &&
          (local.status != status || local.resolution != resolution)) {
        throw StateError('Local conflict has a different resolution.');
      }
      final marker = <String, dynamic>{
        'scope_id': scopeId,
        'conflict_id': conflictId,
        'local_change_id': local.changeId,
        'outbox_change_id': entry?.changeId,
        'remote_conflict_id': remoteConflictId,
        'remote_change_id': changeId,
        'action': action,
        'remote_operation': remote.operation,
        'remote_server_version': remote.serverVersion,
        'remote_resolution': remote.resolution,
        'result_change_id': response.result?.changeId,
        'result_server_cursor': response.result?.serverCursor,
        'result_server_version': response.result?.serverVersion,
        'entity': local.entity,
        'entity_id': local.entityId,
        'settled_at': _now().toIso8601String(),
        if (entry != null) ...{
          'outbox_status': entry.status.wireValue,
          'operation': entry.operation.wireValue,
          'idempotency_key': entry.idempotencyKey,
          'request_json': entry.requestJson,
        },
      };
      await resolveConflict(id: conflictId, status: status, resolution: resolution);
      await _saveInternalSetting(key, jsonEncode(marker));
      if (entry != null) {
        await _saveInternalSetting(
          _outboxSettlementKey(scopeId, entry.changeId), jsonEncode(marker),
        );
      }
      await _saveInternalSetting(_resolutionRefreshKey(scopeId), const Uuid().v4());
      await _refreshDependencyBlocksInCurrentTransaction(scopeId: scopeId, now: _now());
    });
  }

  /// Engine integration: capture this revision BEFORE fetching a fresh NAS
  /// snapshot, even if bootstrap is completed and pull has no new change_log.
  /// Keep it across offline/error/restart; an old cached snapshot is not enough.
  Future<String?> getConflictResolutionRefreshToken(String scopeId) async {
    final row = await (_database.select(_database.appSettings)
          ..where((setting) => setting.key.equals(_resolutionRefreshKey(scopeId))))
        .getSingleOrNull();
    return row?.value;
  }

  /// Call from the fresh snapshot's onApplied transaction, with its captured
  /// token. A resolution committed during the fetch must not be cleared by an
  /// older snapshot. Never clear on mere runOnce/pull/network success.
  Future<bool> clearConflictResolutionRefresh({
    required String scopeId,
    required String token,
  }) => _database.transaction(() async {
    if (await getConflictResolutionRefreshToken(scopeId) != token ||
        await hasSnapshotBlockingChanges(scopeId: scopeId)) {
      return false;
    }
    final deleted = await (_database.delete(_database.appSettings)
          ..where((setting) => setting.key.equals(_resolutionRefreshKey(scopeId)) &
              setting.value.equals(token)))
        .go();
    return deleted == 1;
  });

  String _resolutionRefreshKey(String scopeId) =>
      'sync_resolution_refresh:${jsonEncode(scopeId)}';

  String _conflictSettlementKey(String scopeId, int conflictId) =>
      'sync_conflict_settlement:${jsonEncode([scopeId, conflictId])}';

  String _outboxSettlementKey(String scopeId, String changeId) =>
      'sync_outbox_settlement:${jsonEncode([scopeId, changeId])}';

  Future<Map<String, dynamic>?> _readSettlement(String key) async {
    final row = await (_database.select(_database.appSettings)
          ..where((setting) => setting.key.equals(key)))
        .getSingleOrNull();
    if (row == null) return null;
    try {
      return _mapValue(jsonDecode(row.value));
    } on FormatException {
      return null; // Corrupt evidence never removes a blocker.
    }
  }

  bool _settlementMatchesConflict(Map<String, dynamic> marker, SyncConflictEntry local) {
    final action = marker['action'];
    return (action == 'keep_local' || action == 'keep_remote') &&
        marker['remote_conflict_id'] is String &&
        (marker['remote_conflict_id'] as String).trim().isNotEmpty &&
        marker['scope_id'] == local.scopeId && marker['conflict_id'] == local.id &&
        marker['local_change_id'] == local.changeId &&
        (marker['remote_change_id'] == local.changeId ||
            marker['remote_change_id'] == local.outboxChangeId) &&
        marker['entity'] == local.entity && marker['entity_id'] == local.entityId &&
        local.status == (action == 'keep_local'
            ? SyncConflictStatus.resolved : SyncConflictStatus.rejected) &&
        local.resolution == 'remote_$action';
  }

  bool _settlementMatchesOutbox(Map<String, dynamic> marker, SyncOutboxEntry entry) =>
      marker['scope_id'] == entry.scopeId && marker['outbox_change_id'] == entry.changeId &&
      marker['outbox_status'] == entry.status.wireValue &&
      marker['operation'] == entry.operation.wireValue &&
      marker['idempotency_key'] == entry.idempotencyKey &&
      marker['request_json'] == entry.requestJson;

  Future<bool> _isSettledOutboxEntry(SyncOutboxEntry entry) async {
    if (entry.status == SyncOutboxStatus.rejected) {
      final rejected = await _readSettlement(_rejectedSettlementKey(entry.scopeId, entry.changeId));
      final evidence = await _readSettlement(_rejectionEvidenceKey(entry.scopeId, entry.changeId));
      if (rejected != null && evidence != null &&
          rejected['action'] == 'abandon_rejected' &&
          (evidence['source'] == 'nas_rejected' || evidence['source'] == 'never_sent') &&
          _settlementMatchesOutbox(rejected, entry) && _settlementMatchesOutbox(evidence, entry) &&
          rejected['source'] == evidence['source'] &&
          rejected['error_code'] == entry.lastErrorCode && evidence['error_code'] == entry.lastErrorCode) {
        return !await _hasUnresolvedLinkedConflicts(entry);
      }
    }
    if (entry.status != SyncOutboxStatus.conflict &&
        entry.status != SyncOutboxStatus.rejected) {
      return false;
    }
    final marker = await _readSettlement(_outboxSettlementKey(entry.scopeId, entry.changeId));
    if (marker == null || !_settlementMatchesOutbox(marker, entry)) return false;
    final id = marker['conflict_id'];
    if (id is! int) return false;
    final local = await getConflict(id);
    if (local == null ||
        (local.outboxChangeId ?? local.changeId) != entry.changeId ||
        !_settlementMatchesConflict(marker, local)) {
      return false;
    }
    return !await _hasUnresolvedLinkedConflicts(entry);
  }

  Future<bool> _hasUnresolvedLinkedConflicts(SyncOutboxEntry entry) async {
    final unresolved = await (_database.select(_database.syncConflicts)
          ..where((row) => row.scopeId.equals(entry.scopeId) &
              (row.changeId.equals(entry.changeId) | row.outboxChangeId.equals(entry.changeId)) &
              row.status.isIn([SyncConflictStatus.open.wireValue, SyncConflictStatus.deferred.wireValue]))
          ..limit(1))
        .getSingleOrNull();
    return unresolved != null;
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
    // Pull retries and process restarts can report the same remote conflict
    // more than once. Keep one open record for the same remote change and
    // local outbox item so the conflict UI remains actionable instead of
    // growing duplicate rows.
    final existing = await (_database.select(_database.syncConflicts)
          ..where((row) =>
              row.scopeId.equals(conflict.scopeId) &
              row.changeId.equals(conflict.changeId) &
              row.entity.equals(conflict.entity) &
              (conflict.entityId == null ? row.entityId.isNull() : row.entityId.equals(conflict.entityId!)) &
              row.reason.equals(conflict.reason) &
              (conflict.serverVersion == null ? row.serverVersion.isNull() : row.serverVersion.equals(conflict.serverVersion!)) &
              (conflict.clientPayloadJson == null ? row.clientPayloadJson.isNull() : row.clientPayloadJson.equals(conflict.clientPayloadJson!)) &
              (conflict.serverPayloadJson == null ? row.serverPayloadJson.isNull() : row.serverPayloadJson.equals(conflict.serverPayloadJson!)) &
              row.status.equals(SyncConflictStatus.open.wireValue) &
              (conflict.outboxChangeId == null
                  ? row.outboxChangeId.isNull()
                  : row.outboxChangeId.equals(conflict.outboxChangeId!))))
        .getSingleOrNull();
    if (existing != null) return existing.id;
    return _database.into(_database.syncConflicts).insert(
          _conflictCompanion(conflict, createdAt: _now()),
        );
  }

  Future<SyncConflictEntry?> getConflict(int id) async {
    final row = await (_database.select(_database.syncConflicts)
          ..where((conflict) => conflict.id.equals(id)))
        .getSingleOrNull();
    return row == null ? null : _conflictFromRecord(row);
  }

  Future<SyncConflictEntry?> getConflictByChangeId({
    required String scopeId,
    required String changeId,
  }) async {
    final row = await (_database.select(_database.syncConflicts)
          ..where((conflict) =>
              conflict.scopeId.equals(scopeId) &
              conflict.changeId.equals(changeId))
          ..orderBy([(conflict) => OrderingTerm.desc(conflict.id)])
          ..limit(1))
        .getSingleOrNull();
    return row == null ? null : _conflictFromRecord(row);
  }

  Future<void> saveConflictCursor({
    required String scopeId,
    required String changeId,
    required int cursor,
  }) async {
    await _saveInternalSetting(
      'sync_conflict_cursor:$scopeId:$changeId',
      '$cursor',
    );
  }

  Future<int?> getConflictCursor({required String scopeId, required String changeId}) async {
    final row = await (_database.select(_database.appSettings)
          ..where((setting) => setting.key.equals('sync_conflict_cursor:$scopeId:$changeId')))
        .getSingleOrNull();
    return row == null ? null : int.tryParse(row.value);
  }

  Future<void> clearConflictCursor({required String scopeId, required String changeId}) async {
    await (_database.delete(_database.appSettings)
          ..where((setting) => setting.key.equals('sync_conflict_cursor:$scopeId:$changeId')))
        .go();
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

  /// Review candidates include legacy half-settlements: older UI closed the
  /// local record but left its failed outbox permanently blocking snapshots.
  /// Never expose already-settled audit rows as new conflicts.
  Future<List<SyncConflictEntry>> listUnsettledLinkedConflicts({
    required String scopeId,
  }) async {
    final rows = await (_database.select(_database.syncConflicts)
          ..where((row) => row.scopeId.equals(scopeId))
          ..orderBy([(row) => OrderingTerm.asc(row.createdAt)]))
        .get();
    final result = <SyncConflictEntry>[];
    for (final row in rows) {
      final local = _conflictFromRecord(row);
      if (local.status == SyncConflictStatus.open || local.status == SyncConflictStatus.deferred) {
        result.add(local);
        continue;
      }
      final legacy = (local.status == SyncConflictStatus.resolved && local.resolution == 'remote_keep_local') ||
          (local.status == SyncConflictStatus.rejected && local.resolution == 'remote_keep_remote');
      if (!legacy) continue;
      final entry = await getByChangeId(local.outboxChangeId ?? local.changeId);
      if (entry != null && entry.scopeId == scopeId &&
          (entry.status == SyncOutboxStatus.conflict || entry.status == SyncOutboxStatus.rejected) &&
          !await _isSettledOutboxEntry(entry)) {
        result.add(local);
      }
    }
    return result;
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
    await commitAppliedChange(
      scopeId: scopeId,
      changeId: changeId,
      cursor: cursor,
      appliedAt: appliedAt,
    );
  }

  /// Commits the idempotency marker and the safe pull cursor together.
  /// The cursor never moves backwards, including when a replayed marker is
  /// encountered after a process restart.
  Future<void> commitAppliedChange({
    required String scopeId,
    required String changeId,
    required int cursor,
    DateTime? appliedAt,
  }) async {
    if (cursor < 0) throw ArgumentError.value(cursor, 'cursor');
    final now = appliedAt ?? _now();
    await _database.transaction(() async {
      await _database.into(_database.syncAppliedChanges).insertOnConflictUpdate(
            SyncAppliedChangesCompanion.insert(
              scopeId: scopeId,
              changeId: changeId,
              cursor: cursor,
              appliedAt: now,
            ),
          );
      final state = await (_database.select(_database.syncStates)
            ..where((row) => row.scopeId.equals(scopeId)))
          .getSingleOrNull();
      if (state == null || state.pullCursor >= cursor) return;
      await (_database.update(_database.syncStates)
            ..where((row) => row.scopeId.equals(scopeId)))
          .write(
        SyncStatesCompanion(
          pullCursor: Value(cursor),
          lastPullAt: Value(now),
          updatedAt: Value(now),
        ),
      );
    });
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
