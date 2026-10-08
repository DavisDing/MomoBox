import 'dart:convert';

import '../data/nas/nas_api_error.dart';
import '../data/nas/nas_sync_api.dart';
import '../data/repositories/inventory_repository.dart';
import '../data/repositories/shopping_repository.dart';
import '../data/repositories/sync_outbox_repository.dart';
import '../domain/models/nas_sync_models.dart';
import '../domain/models/sync_models.dart';
import 'sync_business_adapter.dart';
import 'sync_change_control.dart';
import 'sync_execution_coordinator.dart';

typedef ApplyNasSyncChange = Future<void> Function(NasSyncPullChange change);
typedef ApplyNasSyncSnapshot = Future<void> Function(Map<String, dynamic> snapshot, int serverCursor);

typedef ApplyNasSyncSnapshotWithCompletion = Future<void> Function(
  Map<String, dynamic> snapshot, int serverCursor, Future<void> Function() onApplied,
);

const _unset = Object();

class SyncRunReport {
  const SyncRunReport({
    required this.pushed,
    required this.pulled,
    required this.skipped,
    this.reason,
    this.deferred = 0,
    this.hasMorePending = false,
    this.hasMoreRemote = false,
  });

  final int pushed;
  final int pulled;
  final bool skipped;
  final String? reason;
  final int deferred;

  /// More immediately sendable operations remain after a bounded push. This
  /// must never be inferred from deferred/conflict counts alone.
  final bool hasMorePending;

  /// The bounded pull page budget ended with more remote pages remaining.
  /// This is separate from blocked local intents and never bypasses deferral.
  final bool hasMoreRemote;
}

/// Orchestrates the durable local sync substrate and the NAS sync protocol.
///
/// Business repositories remain behind [applyRemoteChange]; this prevents the
/// sync layer from guessing how products or shopping items should be merged.
/// In particular, inventory commands are never converted into quantity
/// upserts here.
class SyncEngine {
  SyncEngine({
    required NasSyncApi api,
    required SyncOutboxRepository repository,
    required String scopeId,
    required String deviceId,
    required ApplyNasSyncChange applyRemoteChange,
    ApplyNasSyncSnapshot? applyRemoteSnapshot,
    ApplyNasSyncSnapshotWithCompletion? applyRemoteSnapshotWithCompletion,
    this.familyId,
    this.localWorkspaceId,
  })  : _api = api,
        _repository = repository,
        _scopeId = scopeId,
        _deviceId = deviceId,
        _applyRemoteChange = applyRemoteChange,
        _applyRemoteSnapshot = applyRemoteSnapshot,
        _applyRemoteSnapshotWithCompletion = applyRemoteSnapshotWithCompletion;

  /// Builds the engine with the app's concrete inventory and shopping merge
  /// adapter. Scheduling remains outside this class so callers can choose an
  /// app-lifecycle, connectivity, or user-triggered policy.
  SyncEngine.withBusinessAdapter({
    required NasSyncApi api,
    required SyncOutboxRepository repository,
    required InventoryRepository inventoryRepository,
    required ShoppingRepository shoppingRepository,
    required String scopeId,
    required String deviceId,
    String? familyId,
    String? localWorkspaceId,
  }) : this._withBusinessAdapter(
          api: api,
          repository: repository,
          inventoryRepository: inventoryRepository,
          shoppingRepository: shoppingRepository,
          scopeId: scopeId,
          deviceId: deviceId,
          familyId: familyId,
          localWorkspaceId: localWorkspaceId,
        );

  SyncEngine._withBusinessAdapter({
    required NasSyncApi api,
    required SyncOutboxRepository repository,
    required InventoryRepository inventoryRepository,
    required ShoppingRepository shoppingRepository,
    required String scopeId,
    required String deviceId,
    String? familyId,
    String? localWorkspaceId,
  }) : this._fromAdapter(
          api: api,
          repository: repository,
          adapter: SyncBusinessAdapter(
            inventoryRepository: inventoryRepository,
            shoppingRepository: shoppingRepository,
            outboxRepository: repository,
            scopeId: scopeId,
          ),
          scopeId: scopeId,
          deviceId: deviceId,
          familyId: familyId,
          localWorkspaceId: localWorkspaceId,
        );

  SyncEngine._fromAdapter({
    required NasSyncApi api,
    required SyncOutboxRepository repository,
    required SyncBusinessAdapter adapter,
    required String scopeId,
    required String deviceId,
    String? familyId,
    String? localWorkspaceId,
  }) : this(
          api: api,
          repository: repository,
          scopeId: scopeId,
          deviceId: deviceId,
          familyId: familyId,
          localWorkspaceId: localWorkspaceId,
          applyRemoteChange: adapter.applyRemoteChange,
          applyRemoteSnapshotWithCompletion: (snapshot, cursor, onApplied) =>
              adapter.applyRemoteSnapshot(snapshot, cursor, onApplied: onApplied),
        );

  final NasSyncApi _api;
  final SyncOutboxRepository _repository;
  final String _scopeId;
  final String _deviceId;
  final ApplyNasSyncChange _applyRemoteChange;
  final ApplyNasSyncSnapshot? _applyRemoteSnapshot;
  final ApplyNasSyncSnapshotWithCompletion? _applyRemoteSnapshotWithCompletion;
  final String? familyId;
  final String? localWorkspaceId;

  Future<SyncRunReport>? _runInFlight;

  Future<T> _coordinated<T>(Future<T> Function() operation) =>
      SyncExecutionCoordinator.run(_repository.coordinationKey, _scopeId, operation);

  Future<NasSyncBootstrap> bootstrap() => _coordinated(_bootstrap);

  Future<NasSyncBootstrap> _bootstrap() async {
    final previousPending = await _repository.getPendingBootstrap(_scopeId);
    final previousMode = await _repository.getConfirmedBootstrapMode(_scopeId);
    late final NasSyncBootstrap response;
    try {
      await _verifyRemoteCompatibility(checkRecordedVersions: false);
      response = await _api.bootstrap(deviceId: _deviceId);
      _requireSupportedVersions(response.schemaVersion, response.syncProtocolVersion);
    } catch (error) {
      await _recordFailureSafely(error);
      rethrow;
    }
    await _repository.transaction(() async {
      if (jsonEncode(await _repository.getPendingBootstrap(_scopeId)) != jsonEncode(previousPending) ||
          await _repository.getConfirmedBootstrapMode(_scopeId) != previousMode) {
        throw const SyncRemoteChangeDeferred('bootstrap choice changed while fetching snapshot');
      }
      final mode = previousMode;
      if (previousPending?['refresh_required'] == true && response.snapshot == null) {
        throw const FormatException('fresh bootstrap snapshot is required after local push');
      }
      if (response.snapshot != null) {
        await _repository.savePendingBootstrap(
          scopeId: _scopeId, snapshot: response.snapshot!,
          serverCursor: response.serverCursor, checkpoint: response.checkpoint,
          bootstrapState: response.bootstrapState, mode: mode,
          refreshRequired: previousPending?['refresh_required'] == true,
        );
      } else {
        await _repository.clearPendingBootstrap(_scopeId);
      }
      final current = await _ensureState();
      await _repository.saveState(_replaceState(
        current,
        // A new snapshot cursor rotates the checkpoint; an unchanged cursor
        // can reuse it. Either way a fetched snapshot must be reconfirmed.
        // Ready on an empty initial family is not a mode choice.
        bootstrapStatus: mode == 'keep_local_only'
            ? SyncBootstrapStatus.keepLocalOnly
            : mode != null || response.mergeRequired
                ? SyncBootstrapStatus.awaitingConfirmation
                : SyncBootstrapStatus.ready,
        pushAckCursor: response.serverCursor > current.pushAckCursor
            ? response.serverCursor : current.pushAckCursor,
        serverSchemaVersion: response.schemaVersion,
        syncProtocolVersion: response.syncProtocolVersion,
        lastErrorCode: null, lastErrorMessage: null,
        consecutiveFailures: 0, nextRetryAt: null,
      ));
    });
    return response;
  }

  Future<NasSyncConfirmResult> confirmBootstrap({required String mode}) async {
    // A user choosing keep_local_only must be able to interrupt an in-flight
    // snapshot request. Keep confirmation outside the run/bootstrap queue;
    // exact durable mode/checkpoint/revision checks guard late responses.
    try {
      await _verifyRemoteCompatibility();
      return await _confirmBootstrap(mode: mode);
    } catch (error) {
      await _recordFailureSafely(error);
      rethrow;
    }
  }

  Future<NasSyncConfirmResult> _confirmBootstrap({
    required String mode,
    bool refreshedSnapshot = false,
  }) async {
    final pending = await _repository.getPendingBootstrap(_scopeId);
    final pendingCursor = pending?['server_cursor'];
    final snapshotCursor = pendingCursor is num &&
            pendingCursor >= 0 &&
            pendingCursor == pendingCursor.toInt()
        ? pendingCursor.toInt()
        : null;
    final pendingCheckpoint = pending?['checkpoint'];
    final checkpoint = pendingCheckpoint is String && pendingCheckpoint.trim().isNotEmpty
        ? pendingCheckpoint.trim()
        : null;
    if (!const ['join_and_merge', 'create_new_family', 'keep_local_only'].contains(mode)) {
      throw const FormatException('unsupported bootstrap mode');
    }
    if (mode != 'keep_local_only' && (checkpoint == null || snapshotCursor == null)) {
      throw const FormatException('bootstrap confirmation requires a fresh checkpoint and cursor');
    }
    late final NasSyncConfirmResult response;
    try {
      response = await _api.confirmBootstrap(
        mode: mode,
        deviceId: _deviceId,
        localWorkspaceId: localWorkspaceId,
        snapshotCursor: snapshotCursor,
        checkpoint: checkpoint,
      );
    } catch (error) {
      await _recordFailureSafely(error);
      rethrow;
    }
    final status = switch (response.nextAction) {
      'pull_snapshot' || 'push_local_changes' => SyncBootstrapStatus.ready,
      'keep_local_only' => SyncBootstrapStatus.keepLocalOnly,
      _ => SyncBootstrapStatus.blocked,
    };
    final expectedAction = switch (mode) {
      'join_and_merge' => 'pull_snapshot',
      'create_new_family' => 'push_local_changes',
      _ => 'keep_local_only',
    };
    final validConfirmation = response.accepted &&
        response.nextAction == expectedAction &&
        (mode == 'keep_local_only' ||
            (response.checkpoint == checkpoint && response.serverCursor >= snapshotCursor!));
    final invalidReceipt = response.accepted && !validConfirmation;
    await _repository.transaction(() async {
      final latestPending = await _repository.getPendingBootstrap(_scopeId);
      if (jsonEncode(latestPending) != jsonEncode(pending)) {
        throw const FormatException('bootstrap checkpoint changed during confirmation');
      }
      if (validConfirmation) {
        await _repository.savePendingBootstrap(
          scopeId: _scopeId,
          snapshot: pending == null ? <String, dynamic>{}
              : Map<String, dynamic>.from(pending['snapshot'] as Map),
          serverCursor: snapshotCursor ?? response.serverCursor,
          checkpoint: checkpoint,
          bootstrapState: response.bootstrapState,
          mode: mode,
          refreshRequired: !refreshedSnapshot && pending?['refresh_required'] == true,
        );
        if (pending == null || mode == 'keep_local_only') {
          await _repository.clearPendingBootstrap(_scopeId);
        }
      }
      final current = await _ensureState();
      await _repository.saveState(_replaceState(
        current,
        bootstrapStatus: validConfirmation ? status : SyncBootstrapStatus.blocked,
        pushAckCursor: validConfirmation && response.serverCursor > current.pushAckCursor
            ? response.serverCursor : current.pushAckCursor,
        lastErrorCode: validConfirmation ? null
            : invalidReceipt ? 'invalid_bootstrap_receipt' : 'bootstrap_rejected',
        lastErrorMessage: validConfirmation ? null
            : 'NAS bootstrap confirmation did not match the selected mode/checkpoint',
        consecutiveFailures: validConfirmation ? 0 : current.consecutiveFailures + 1,
        nextRetryAt: null,
      ));
    });
    if (invalidReceipt) {
      throw const FormatException('bootstrap confirmation receipt does not match checkpoint or mode');
    }
    return response;
  }

  Future<SyncRunReport> runOnce({int maxPush = 100, int pullLimit = 100}) {
    if (maxPush < 1 || maxPush > 100 || pullLimit < 1 || pullLimit > 500) {
      return Future.error(ArgumentError('maxPush must be 1..100 and pullLimit 1..500'));
    }
    final active = _runInFlight;
    if (active != null) return active;
    final operation = _coordinated(() => _runOnce(maxPush: maxPush, pullLimit: pullLimit));
    _runInFlight = operation;
    return operation.whenComplete(() {
      if (identical(_runInFlight, operation)) _runInFlight = null;
    });
  }

  Future<SyncRunReport> _runOnce({required int maxPush, required int pullLimit}) async {
    final state = await _ensureState();
    final now = DateTime.now().toUtc();
    final retryPending = await _repository.getPendingBootstrap(_scopeId);
    final savedMode = await _repository.getConfirmedBootstrapMode(_scopeId);
    final resumingRefresh = state.bootstrapStatus == SyncBootstrapStatus.awaitingConfirmation &&
        retryPending?['refresh_required'] == true &&
        (savedMode == 'join_and_merge' || savedMode == 'create_new_family');
    if (state.bootstrapStatus != SyncBootstrapStatus.ready && !resumingRefresh) {
      return SyncRunReport(
        pushed: 0,
        pulled: 0,
        skipped: true,
        reason: 'bootstrap is not ready',
      );
    }
    if (state.nextRetryAt != null && state.nextRetryAt!.isAfter(now)) {
      return SyncRunReport(
        pushed: 0,
        pulled: 0,
        skipped: true,
        reason: 'retry backoff is active',
      );
    }

    var pushed = 0;
    try {
      await _verifyRemoteCompatibility();
      await _assertRemoteSyncChoiceActive();
      final pending = await _repository.getPendingBootstrap(_scopeId);
      final resolutionToken = await _repository.getConflictResolutionRefreshToken(_scopeId);
      if (pending != null) {
        final mode = await _repository.getConfirmedBootstrapMode(_scopeId);
        final blocked = await _repository.hasSnapshotBlockingChanges(scopeId: _scopeId);
        if (blocked && mode == null) {
          // Do not push/auto-confirm an initial empty-family ready state.
          await _repository.saveState(_replaceState(
            await _ensureState(),
            bootstrapStatus: SyncBootstrapStatus.awaitingConfirmation,
            lastErrorCode: 'bootstrap_confirmation_required',
            lastErrorMessage: '存在本地操作，请先明确选择首次连接模式。',
          ));
          return const SyncRunReport(pushed: 0, pulled: 0, skipped: true,
            deferred: 1, reason: 'bootstrap mode requires explicit confirmation');
        }
        final needsRefresh = blocked || pending['refresh_required'] == true ||
            resolutionToken != null || mode == 'create_new_family';
        if (needsRefresh) {
          if (mode != 'join_and_merge' && mode != 'create_new_family') {
            throw const SyncRemoteChangeDeferred('snapshot refresh requires a confirmed remote-sync mode');
          }
          // Persist BEFORE network push. If the process dies after an accepted
          // push, the old snapshot remains unusable on the next invocation.
          await _repository.transaction(() async {
            if (jsonEncode(await _repository.getPendingBootstrap(_scopeId)) != jsonEncode(pending) ||
                await _repository.getConfirmedBootstrapMode(_scopeId) != mode ||
                (await _ensureState()).bootstrapStatus == SyncBootstrapStatus.keepLocalOnly) {
              throw const SyncRemoteChangeDeferred('bootstrap choice changed before pushing local operations');
            }
            await _repository.savePendingBootstrap(
              scopeId: _scopeId, snapshot: Map<String, dynamic>.from(pending['snapshot'] as Map),
              serverCursor: pending['server_cursor'] as int,
              checkpoint: pending['checkpoint'] as String?,
              bootstrapState: pending['bootstrap_state'] as String?,
              mode: mode, refreshRequired: true,
            );
          });
          pushed = await _pushPending(maxPush);
          await _assertSnapshotScopeQuiescent();
          await _refreshSnapshotAfterPush(mode, resolutionToken: resolutionToken);
        }
        await _applyPendingBootstrapSnapshot(resolutionToken: resolutionToken);
      } else {
        // Legacy completed states retain ordinary push/pull compatibility,
        // but a conflict refresh requires an explicitly saved remote mode.
        if (resolutionToken != null &&
            savedMode != 'join_and_merge' && savedMode != 'create_new_family') {
          throw const SyncRemoteChangeDeferred('conflict resolution refresh requires an explicit remote-sync mode');
        }
        pushed = await _pushPending(maxPush);
        await _assertSnapshotScopeQuiescent();
        if (resolutionToken != null) {
          await _refreshSnapshotAfterPush(savedMode!, resolutionToken: resolutionToken);
          await _applyPendingBootstrapSnapshot(resolutionToken: resolutionToken);
        }
      }
      if (await _repository.getConflictResolutionRefreshToken(_scopeId) != null) {
        throw const SyncRemoteChangeDeferred('a new conflict resolution requires a fresh snapshot before pull');
      }
      final pullResult = await _pullChanges(pullLimit);
      final latest = await _ensureState();
      final hasDeferred = pullResult.deferred > 0;
      await _repository.saveState(
        _replaceState(
          latest,
          lastSuccessAt: hasDeferred || pullResult.hasMore
              ? latest.lastSuccessAt : DateTime.now().toUtc(),
          lastErrorCode: hasDeferred ? 'sync_conflict_deferred' : null,
          lastErrorMessage: hasDeferred ? '存在待处理同步冲突，已暂停推进远端游标。' : null,
          consecutiveFailures: hasDeferred ? latest.consecutiveFailures : 0,
          nextRetryAt: null,
        ),
      );
      return SyncRunReport(
        pushed: pushed,
        pulled: pullResult.applied,
        deferred: pullResult.deferred,
        hasMoreRemote: pullResult.hasMore,
        skipped: false,
      );
    } on SyncRemoteChangeDeferred catch (error) {
      await _repository.saveState(_replaceState(
        await _ensureState(),
        lastErrorCode: 'sync_conflict_deferred', lastErrorMessage: error.reason,
      ));
      final canContinue = pushed > 0 && await _canContinuePendingPush();
      return SyncRunReport(pushed: pushed, pulled: 0, skipped: false,
        deferred: 1, hasMorePending: canContinue, reason: error.reason);
    } catch (error) {
      await _recordFailureSafely(error);
      rethrow;
    }
  }

  void _requireSupportedVersions(int schemaVersion, int syncProtocolVersion) {
    if (schemaVersion == 1 && syncProtocolVersion == 1) return;
    throw NasApiError(
      kind: NasApiErrorKind.validation,
      code: 'SYNC_VERSION_INCOMPATIBLE',
      message: 'NAS 同步版本不兼容（数据契约 $schemaVersion，协议 $syncProtocolVersion；'
          '本 App 支持 1/1）。请使用兼容的 App/NAS 版本后重试，本机数据与待同步操作已保留。',
    );
  }

  Future<void> _verifyRemoteCompatibility({bool checkRecordedVersions = true}) async {
    // /capabilities has no checkpoint side effects, unlike bootstrap. Probe
    // before any queued command, even for a legacy already-ready local state.
    final versions = await _api.capabilities();
    _requireSupportedVersions(versions.schemaVersion, versions.syncProtocolVersion);
    final state = await _ensureState();
    // An existing snapshot was decoded using the recorded contract. A newer
    // endpoint cannot make an incompatible staged snapshot safe to consume.
    if (checkRecordedVersions) {
      _requireSupportedVersions(state.serverSchemaVersion ?? 1, state.syncProtocolVersion ?? 1);
    }
  }

  Future<bool> _canContinuePendingPush() async {
    // A user may opt out while a bounded push is in flight. Never advertise
    // automatic draining after that durable choice, even if pending rows remain.
    final state = await _ensureState();
    final mode = await _repository.getConfirmedBootstrapMode(_scopeId);
    if (mode == 'keep_local_only' ||
        (state.bootstrapStatus != SyncBootstrapStatus.ready &&
         state.bootstrapStatus != SyncBootstrapStatus.awaitingConfirmation)) {
      return false;
    }
    // Settled audit rows remain intact but no longer block continuation.
    if (await _repository.hasNonPendingSnapshotBlockers(scopeId: _scopeId)) return false;
    return (await _repository.listPending(scopeId: _scopeId, limit: 1)).isNotEmpty;
  }

  Future<void> _assertRemoteSyncChoiceActive() async {
    final state = await _ensureState();
    if (state.bootstrapStatus == SyncBootstrapStatus.keepLocalOnly ||
        await _repository.getConfirmedBootstrapMode(_scopeId) == 'keep_local_only') {
      throw const SyncRemoteChangeDeferred('local-only choice interrupted remote synchronization');
    }
  }

  Future<void> _assertSnapshotScopeQuiescent() async {
    await _assertRemoteSyncChoiceActive();
    if (await _repository.hasSnapshotBlockingChanges(scopeId: _scopeId)) {
      throw const SyncRemoteChangeDeferred('local operations must settle before snapshot/pull');
    }
  }

  Future<void> _refreshSnapshotAfterPush(String mode, {String? resolutionToken}) async {
    final before = await _ensureState();
    final expectedPending = await _repository.getPendingBootstrap(_scopeId);
    if ((expectedPending == null && resolutionToken == null) ||
        (expectedPending != null && expectedPending['mode'] != mode) ||
        await _repository.getConfirmedBootstrapMode(_scopeId) != mode ||
        await _repository.getConflictResolutionRefreshToken(_scopeId) != resolutionToken ||
        before.bootstrapStatus == SyncBootstrapStatus.keepLocalOnly) {
      throw const SyncRemoteChangeDeferred('bootstrap choice changed before refreshing snapshot');
    }
    final response = await _api.bootstrap(deviceId: _deviceId);
    _requireSupportedVersions(response.schemaVersion, response.syncProtocolVersion);
    if (response.snapshot == null || response.checkpoint == null ||
        response.checkpoint!.trim().isEmpty || !response.availableModes.contains(mode) ||
        response.serverCursor < before.pushAckCursor || response.serverCursor < before.pullCursor) {
      throw const FormatException('fresh bootstrap snapshot/checkpoint is missing or predates acknowledged writes');
    }
    await _repository.transaction(() async {
      if (jsonEncode(await _repository.getPendingBootstrap(_scopeId)) != jsonEncode(expectedPending) ||
          await _repository.getConfirmedBootstrapMode(_scopeId) != mode ||
          await _repository.getConflictResolutionRefreshToken(_scopeId) != resolutionToken ||
          (await _ensureState()).bootstrapStatus == SyncBootstrapStatus.keepLocalOnly) {
        throw const SyncRemoteChangeDeferred('bootstrap choice or conflict resolution changed while refreshing snapshot');
      }
      await _repository.savePendingBootstrap(
        scopeId: _scopeId, snapshot: response.snapshot!,
        serverCursor: response.serverCursor, checkpoint: response.checkpoint,
        bootstrapState: response.bootstrapState, mode: mode, refreshRequired: true,
      );
      await _repository.saveState(_replaceState(
        await _ensureState(), bootstrapStatus: SyncBootstrapStatus.awaitingConfirmation,
        serverSchemaVersion: response.schemaVersion,
        syncProtocolVersion: response.syncProtocolVersion,
      ));
    });
    final confirmed = await _confirmBootstrap(mode: mode, refreshedSnapshot: true);
    if (!confirmed.accepted) {
      throw const SyncRemoteChangeDeferred('fresh bootstrap checkpoint was rejected; snapshot is retained');
    }
    await _assertSnapshotScopeQuiescent();
  }

  Future<void> _applyPendingBootstrapSnapshot({String? resolutionToken}) async {
    final applySnapshot = _applyRemoteSnapshot;
    final pending = await _repository.getPendingBootstrap(_scopeId);
    if (pending == null) return;
    if (applySnapshot == null && _applyRemoteSnapshotWithCompletion == null) {
      throw const FormatException('unsupported bootstrap snapshot: no business adapter configured');
    }
    final rawSnapshot = pending['snapshot'];
    if (rawSnapshot is! Map) {
      throw const FormatException('pending bootstrap snapshot must be an object');
    }
    final cursor = pending['server_cursor'];
    if (cursor is! num || cursor < 0 || cursor != cursor.toInt()) {
      throw const FormatException('pending bootstrap server_cursor must be a non-negative integer');
    }
    final snapshot = Map<String, dynamic>.from(rawSnapshot);
    Future<void> complete() => _completeBootstrapSnapshot(
      _repository, _scopeId, snapshot, cursor.toInt(), pending, resolutionToken,
    );
    final businessSnapshot = _applyRemoteSnapshotWithCompletion;
    if (businessSnapshot != null) {
      // Concrete adapter validates outside the transaction, but runs complete
      // inside it using the exact checkpoint read above (not a newer record).
      await businessSnapshot(snapshot, cursor.toInt(), complete);
    } else {
      await _repository.transaction(() async {
        await _assertSnapshotScopeQuiescent();
        await applySnapshot!(snapshot, cursor.toInt());
        await complete();
        await _assertSnapshotScopeQuiescent();
      });
    }
  }

  Future<int> _pushPending(int maxPush) async {
    if (maxPush < 1 || maxPush > 100) {
      throw ArgumentError.value(maxPush, 'maxPush', 'must be between 1 and 100');
    }
    await _assertRemoteSyncChoiceActive();
    final claimed = <SyncOutboxEntry>[];
    for (var index = 0; index < maxPush; index++) {
      final entry = await _repository.claimNext(scopeId: _scopeId);
      if (entry == null) break;
      claimed.add(entry);
    }
    if (claimed.isEmpty) return 0;

    final inFlight = <String>{...claimed.map((entry) => entry.changeId)};
    final handled = <String>{};
    final retryAt = DateTime.now().toUtc().add(_backoff(1));

    try {
      final changes = <NasSyncChange>[];
      for (final entry in claimed) {
        try {
          changes.add(NasSyncChange.fromOutbox(entry));
        } on FormatException catch (error) {
          await _repository.markRejected(
            changeId: entry.changeId,
            errorCode: 'INVALID_LOCAL_CHANGE',
            errorMessage: error.message,
          );
          inFlight.remove(entry.changeId);
          handled.add(entry.changeId);
        }
      }

      if (changes.isNotEmpty) {
        await _assertRemoteSyncChoiceActive();
        final state = await _ensureState();
        final response = await _api.push(
          deviceId: _deviceId,
          baseCursor: state.pushAckCursor,
          changes: changes,
        );

        Future<void> markConflict(NasSyncConflict conflict) async {
          await _repository.markConflict(
            changeId: conflict.changeId,
            conflict: SyncConflictDraft(
              scopeId: _scopeId,
              changeId: conflict.changeId,
              outboxChangeId: conflict.changeId,
              entity: conflict.entity,
              entityId: conflict.entityId,
              reason: conflict.reason,
              serverVersion: conflict.serverVersion,
              serverPayloadJson: _jsonOrNull(conflict.serverPayload),
              clientPayloadJson: _jsonOrNull(conflict.clientPayload),
            ),
          );
          inFlight.remove(conflict.changeId);
          handled.add(conflict.changeId);
        }

        Future<void> markRejected(NasSyncRejectedChange rejected) async {
          await _repository.markRejected(
            changeId: rejected.changeId,
            errorCode: rejected.code,
            errorMessage: rejected.message,
          );
          inFlight.remove(rejected.changeId);
          handled.add(rejected.changeId);
        }

        Future<void> markAccepted(NasSyncAcceptedChange accepted, {bool replayed = false}) async {
          if (replayed) {
            await _repository.markReplayed(
              changeId: accepted.changeId,
              serverCursor: accepted.serverCursor,
              serverVersion: accepted.serverVersion,
            );
          } else {
            await _repository.markAccepted(
              changeId: accepted.changeId,
              serverCursor: accepted.serverCursor,
              serverVersion: accepted.serverVersion,
            );
          }
          inFlight.remove(accepted.changeId);
          handled.add(accepted.changeId);
        }

        Future<void> handleReplayed(NasSyncReplayedChange replayed) async {
          if (replayed.accepted != null) {
            await markAccepted(replayed.accepted!, replayed: true);
          } else if (replayed.conflict != null) {
            await markConflict(replayed.conflict!);
          } else if (replayed.rejected != null) {
            await markRejected(replayed.rejected!);
          }
        }

        // Prefer the per-change result list when present; the legacy arrays
        // below are retained for servers that omit results.
        for (final result in response.results) {
          if (!inFlight.contains(result.changeId)) continue;
          switch (result.status) {
            case 'accepted':
              if (result.accepted != null) await markAccepted(result.accepted!);
              break;
            case 'replayed':
              if (result.accepted != null) {
                await markAccepted(result.accepted!, replayed: true);
              } else if (result.conflict != null) {
                await markConflict(result.conflict!);
              } else if (result.rejected != null) {
                await markRejected(result.rejected!);
              }
              break;
            case 'conflict':
              if (result.conflict != null) await markConflict(result.conflict!);
              break;
            case 'rejected':
              if (result.rejected != null) await markRejected(result.rejected!);
              break;
          }
        }
        for (final accepted in response.accepted) {
          if (inFlight.contains(accepted.changeId)) await markAccepted(accepted);
        }
        for (final replayed in response.replayed) {
          if (inFlight.contains(replayed.changeId)) await handleReplayed(replayed);
        }
        for (final conflict in response.conflicts) {
          if (inFlight.contains(conflict.changeId)) await markConflict(conflict);
        }
        for (final rejected in response.rejected) {
          if (inFlight.contains(rejected.changeId)) await markRejected(rejected);
        }

        for (final changeId in inFlight.toList()) {
          await _repository.releaseInFlight(
            changeId: changeId,
            nextAttemptAt: retryAt,
            errorCode: 'missing_push_result',
            errorMessage: 'NAS did not return a result for the change',
          );
          inFlight.remove(changeId);
        }

        final latest = await _ensureState();
        await _repository.saveState(
          _replaceState(
            latest,
            pushAckCursor: response.cursor,
            lastPushAt: DateTime.now().toUtc(),
          ),
        );
      }
      return handled.length;
    } catch (_) {
      for (final changeId in inFlight.toList()) {
        await _repository.releaseInFlight(
          changeId: changeId,
          nextAttemptAt: retryAt,
          errorCode: 'push_failed',
          errorMessage: 'Push failed; scheduled for retry',
        );
      }
      rethrow;
    }
  }

  Future<_PullResult> _pullChanges(int limit) async {
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 500');
    }
    var appliedCount = 0;
    var deferredCount = 0;
    var pageCount = 0;
    var hasMore = false;
    while (true) {
      var pageDeferred = false;
      final state = await _ensureState();
      final response = await _api.pull(
        deviceId: _deviceId,
        cursor: state.pullCursor,
        limit: limit,
      );
      await _assertRemoteSyncChoiceActive();
      _validatePullPage(response, state.pullCursor);
      if (await _repository.getConflictResolutionRefreshToken(_scopeId) != null) {
        throw const SyncRemoteChangeDeferred('conflict resolution arrived during pull; refresh before applying');
      }
      for (final change in response.changes) {
        await _assertRemoteSyncChoiceActive();
        if (await _repository.hasAppliedChange(
          scopeId: _scopeId,
          changeId: change.changeId,
        )) {
          continue;
        }
        var deferred = false;
        try {
          await _applyRemoteChange(change);
          appliedCount++;
        } on SyncRemoteChangeDeferred {
          // A deferred change is a hard ordering barrier. Do not mark it as
          // applied or advance the cursor past it: later changes can depend
          // on the unresolved conflict and must be replayed after resolution.
          deferredCount++;
          deferred = true;
          pageDeferred = true;
        }
        if (deferred) {
          break;
        }
        // Inventory commands commit their receipt and safe cursor with the
        // business writes. Do not issue a second receipt write that could fail
        // after that atomic commit; custom/entity callbacks still need one.
        if (!await _repository.hasAppliedChange(
          scopeId: _scopeId,
          changeId: change.changeId,
        )) {
          await _repository.recordAppliedChange(
            scopeId: _scopeId,
            changeId: change.changeId,
            cursor: change.cursor,
          );
        }
      }
      if (pageDeferred) {
        // Keep the last successfully committed change cursor, not the page's
        // nextCursor. The deferred change and later changes remain replayable.
        hasMore = false;
        break;
      }
      await _assertRemoteSyncChoiceActive();
      final latest = await _ensureState();
      await _repository.saveState(
        _replaceState(
          latest,
          // A receipt may already have advanced the cursor. Replayed pages
          // or overlapping invocations must not move it backwards.
          pullCursor: response.nextCursor > latest.pullCursor
              ? response.nextCursor
              : latest.pullCursor,
          lastPullAt: DateTime.now().toUtc(),
        ),
      );
      pageCount++;
      hasMore = response.hasMore;
      if (!hasMore || pageCount >= 100) break;
    }
    return _PullResult(applied: appliedCount, deferred: deferredCount, hasMore: hasMore);
  }

  void _validatePullPage(NasSyncPullResponse response, int requestedCursor) {
    // Validate the whole page before business callbacks/receipts. A malformed
    // next cursor must not hide changes, or create 100 identical requests.
    if (response.nextCursor < 0 ||
        (response.hasMore && (response.changes.isEmpty ||
          response.nextCursor <= requestedCursor))) {
      throw NasApiError.invalidResponse(const FormatException('pull page cannot make cursor progress'));
    }
    int? previous;
    final changeIds = <String>{};
    for (final change in response.changes) {
      if (change.cursor < 0 || change.cursor > response.nextCursor ||
          (previous != null && change.cursor <= previous) ||
          !changeIds.add(change.changeId)) {
        throw NasApiError.invalidResponse(const FormatException('pull page has inconsistent cursors or duplicate changes'));
      }
      previous = change.cursor;
    }
    // A terminal replay may contain an older cursor. Existing durable receipts
    // handle its changes and the saved cursor is still clamped monotonically.
  }

  Future<SyncStateModel> _ensureState() {
    return _repository.ensureState(
      scopeId: _scopeId,
      familyId: familyId,
      deviceId: _deviceId,
      localWorkspaceId: localWorkspaceId,
    );
  }

  Future<void> _recordFailureSafely(Object error) async {
    try {
      await _recordFailure(error);
    } catch (_) {
      // Preserve the original sync error if failure-state persistence itself
      // is unavailable. The next invocation can retry persistence.
    }
  }

  Future<void> _recordFailure(Object error) async {
    final current = await _ensureState();
    final failures = current.consecutiveFailures + 1;
    final incompatible = error is NasApiError && error.code == 'SYNC_VERSION_INCOMPATIBLE';
    final retryAt = incompatible ? null : DateTime.now().toUtc().add(_backoff(failures));
    final unsupported =
        error is FormatException && error.message.startsWith('unsupported ');
    final code = error is NasApiError
        ? error.code ?? error.kind.name
        : unsupported
            ? 'sync_mapping_unsupported'
            : 'sync_failed';
    final message = error is NasApiError
        ? error.message
        : unsupported
            ? '远端实体或字段无法安全映射到本地业务，未推进同步游标。'
            : 'Sync failed';
    await _repository.saveState(
      _replaceState(
        current,
        consecutiveFailures: failures,
        nextRetryAt: retryAt,
        lastErrorCode: code,
        lastErrorMessage: message,
      ),
    );
  }

  Duration _backoff(int failures) {
    final exponent = failures.clamp(0, 6).toInt();
    return Duration(seconds: 1 << exponent);
  }

  SyncStateModel _replaceState(
    SyncStateModel state, {
    SyncBootstrapStatus? bootstrapStatus,
    int? pullCursor,
    int? pushAckCursor,
    Object? lastPushAt = _unset,
    Object? lastPullAt = _unset,
    Object? lastSuccessAt = _unset,
    Object? lastErrorCode = _unset,
    Object? lastErrorMessage = _unset,
    int? consecutiveFailures,
    Object? nextRetryAt = _unset,
    int? serverSchemaVersion,
    int? syncProtocolVersion,
  }) {
    return SyncStateModel(
      scopeId: state.scopeId,
      familyId: state.familyId ?? familyId,
      deviceId: state.deviceId ?? _deviceId,
      localWorkspaceId: state.localWorkspaceId ?? localWorkspaceId,
      bootstrapStatus: bootstrapStatus ?? state.bootstrapStatus,
      pullCursor: pullCursor ?? state.pullCursor,
      pushAckCursor: pushAckCursor ?? state.pushAckCursor,
      lastPushAt: _nullableDateTime(lastPushAt, state.lastPushAt),
      lastPullAt: _nullableDateTime(lastPullAt, state.lastPullAt),
      lastSuccessAt: _nullableDateTime(lastSuccessAt, state.lastSuccessAt),
      lastErrorCode: _nullableString(lastErrorCode, state.lastErrorCode),
      lastErrorMessage: _nullableString(lastErrorMessage, state.lastErrorMessage),
      consecutiveFailures: consecutiveFailures ?? state.consecutiveFailures,
      nextRetryAt: _nullableDateTime(nextRetryAt, state.nextRetryAt),
      serverSchemaVersion: serverSchemaVersion ?? state.serverSchemaVersion,
      syncProtocolVersion: syncProtocolVersion ?? state.syncProtocolVersion,
      updatedAt: DateTime.now().toUtc(),
    );
  }
}

/// Runs inside the business transaction: a rotated/replaced pending checkpoint,
/// a late local edit or completion write failure rolls back all snapshot rows.
Future<void> _completeBootstrapSnapshot(
  SyncOutboxRepository repository,
  String scopeId,
  Map<String, dynamic> snapshot,
  int cursor,
  Map<String, dynamic>? expected,
  String? resolutionToken,
) async {
  if (await repository.hasSnapshotBlockingChanges(scopeId: scopeId)) {
    throw const SyncRemoteChangeDeferred('local edit arrived during snapshot application');
  }
  if (await repository.getConflictResolutionRefreshToken(scopeId) != resolutionToken) {
    throw const SyncRemoteChangeDeferred('conflict resolution changed during snapshot application');
  }
  final pending = await repository.getPendingBootstrap(scopeId);
  if (pending == null || expected == null ||
      pending['server_cursor'] != cursor || pending['checkpoint'] != expected['checkpoint'] ||
      pending['mode'] != expected['mode'] || pending['refresh_required'] == true ||
      jsonEncode(pending['snapshot']) != jsonEncode(snapshot)) {
    throw const FormatException('pending bootstrap checkpoint changed during snapshot application');
  }
  final state = await repository.getState(scopeId);
  if (state == null || state.bootstrapStatus != SyncBootstrapStatus.ready || state.pullCursor > cursor) {
    throw const FormatException('bootstrap snapshot is stale or not confirmed');
  }
  await repository.saveState(state.copyWith(
    pullCursor: cursor, lastPullAt: DateTime.now().toUtc(),
  ));
  await repository.clearPendingBootstrap(scopeId);
  if (resolutionToken != null && !await repository.clearConflictResolutionRefresh(
    scopeId: scopeId, token: resolutionToken,
  )) {
    throw const SyncRemoteChangeDeferred('conflict resolution refresh changed before completion');
  }
}

String? _jsonOrNull(Map<String, dynamic>? value) => value == null ? null : jsonEncode(value);

DateTime? _nullableDateTime(Object? value, DateTime? fallback) {
  return identical(value, _unset) ? fallback : value as DateTime?;
}

String? _nullableString(Object? value, String? fallback) {
  return identical(value, _unset) ? fallback : value as String?;
}

class _PullResult {
  const _PullResult({required this.applied, required this.deferred, required this.hasMore});

  final int applied;
  final int deferred;
  final bool hasMore;
}
