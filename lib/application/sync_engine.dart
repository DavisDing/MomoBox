import 'dart:convert';

import '../data/nas/nas_api_error.dart';
import '../data/nas/nas_sync_api.dart';
import '../data/repositories/sync_outbox_repository.dart';
import '../domain/models/nas_sync_models.dart';
import '../domain/models/sync_models.dart';

typedef ApplyNasSyncChange = Future<void> Function(NasSyncPullChange change);

const _unset = Object();

class SyncRunReport {
  const SyncRunReport({
    required this.pushed,
    required this.pulled,
    required this.skipped,
    this.reason,
  });

  final int pushed;
  final int pulled;
  final bool skipped;
  final String? reason;
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
    this.familyId,
    this.localWorkspaceId,
  })  : _api = api,
        _repository = repository,
        _scopeId = scopeId,
        _deviceId = deviceId,
        _applyRemoteChange = applyRemoteChange;

  final NasSyncApi _api;
  final SyncOutboxRepository _repository;
  final String _scopeId;
  final String _deviceId;
  final ApplyNasSyncChange _applyRemoteChange;
  final String? familyId;
  final String? localWorkspaceId;

  Future<NasSyncBootstrap> bootstrap() async {
    final response = await _api.bootstrap(deviceId: _deviceId);
    final current = await _ensureState();
    await _repository.saveState(
      _replaceState(
        current,
        bootstrapStatus: response.mergeRequired
            ? SyncBootstrapStatus.awaitingConfirmation
            : SyncBootstrapStatus.ready,
        // The snapshot has not been applied by this orchestration layer.
        // Only pull advances the durable pull cursor after the callback succeeds.
        pullCursor: current.pullCursor,
        pushAckCursor: response.serverCursor,
        serverSchemaVersion: response.schemaVersion,
        syncProtocolVersion: response.syncProtocolVersion,
        lastErrorCode: null,
        lastErrorMessage: null,
        consecutiveFailures: 0,
        nextRetryAt: null,
      ),
    );
    return response;
  }

  Future<NasSyncConfirmResult> confirmBootstrap({
    required String mode,
  }) async {
    final response = await _api.confirmBootstrap(
      mode: mode,
      deviceId: _deviceId,
      localWorkspaceId: localWorkspaceId,
    );
    final current = await _ensureState();
    final status = switch (response.nextAction) {
      'keep_local_only' => SyncBootstrapStatus.keepLocalOnly,
      _ => SyncBootstrapStatus.ready,
    };
    await _repository.saveState(
      _replaceState(
        current,
        bootstrapStatus: response.accepted ? status : SyncBootstrapStatus.blocked,
        // Confirming a mode does not itself apply the snapshot/change log.
        pullCursor: current.pullCursor,
        pushAckCursor: response.serverCursor,
        lastErrorCode: response.accepted ? null : 'bootstrap_rejected',
        lastErrorMessage: response.accepted ? null : 'NAS rejected bootstrap confirmation',
        consecutiveFailures: response.accepted ? 0 : current.consecutiveFailures + 1,
        nextRetryAt: null,
      ),
    );
    return response;
  }

  Future<SyncRunReport> runOnce({
    int maxPush = 100,
    int pullLimit = 100,
  }) async {
    final state = await _ensureState();
    final now = DateTime.now().toUtc();
    if (state.bootstrapStatus != SyncBootstrapStatus.ready) {
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

    try {
      final pushed = await _pushPending(maxPush);
      final pulled = await _pullChanges(pullLimit);
      final latest = await _ensureState();
      await _repository.saveState(
        _replaceState(
          latest,
          lastSuccessAt: DateTime.now().toUtc(),
          lastErrorCode: null,
          lastErrorMessage: null,
          consecutiveFailures: 0,
          nextRetryAt: null,
        ),
      );
      return SyncRunReport(pushed: pushed, pulled: pulled, skipped: false);
    } catch (error) {
      await _recordFailure(error);
      rethrow;
    }
  }

  Future<int> _pushPending(int maxPush) async {
    if (maxPush < 1 || maxPush > 100) {
      throw ArgumentError.value(maxPush, 'maxPush', 'must be between 1 and 100');
    }
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

  Future<int> _pullChanges(int limit) async {
    if (limit < 1 || limit > 500) {
      throw ArgumentError.value(limit, 'limit', 'must be between 1 and 500');
    }
    var appliedCount = 0;
    var pageCount = 0;
    while (true) {
      final state = await _ensureState();
      final response = await _api.pull(
        deviceId: _deviceId,
        cursor: state.pullCursor,
        limit: limit,
      );
      for (final change in response.changes) {
        if (await _repository.hasAppliedChange(
          scopeId: _scopeId,
          changeId: change.changeId,
        )) {
          continue;
        }
        await _applyRemoteChange(change);
        await _repository.recordAppliedChange(
          scopeId: _scopeId,
          changeId: change.changeId,
          cursor: change.cursor,
        );
        appliedCount++;
      }
      final latest = await _ensureState();
      await _repository.saveState(
        _replaceState(
          latest,
          pullCursor: response.nextCursor,
          lastPullAt: DateTime.now().toUtc(),
        ),
      );
      pageCount++;
      if (!response.hasMore || pageCount >= 100) break;
    }
    return appliedCount;
  }

  Future<SyncStateModel> _ensureState() {
    return _repository.ensureState(
      scopeId: _scopeId,
      familyId: familyId,
      deviceId: _deviceId,
      localWorkspaceId: localWorkspaceId,
    );
  }

  Future<void> _recordFailure(Object error) async {
    final current = await _ensureState();
    final failures = current.consecutiveFailures + 1;
    final retryAt = DateTime.now().toUtc().add(_backoff(failures));
    final code = error is NasApiError ? error.code ?? error.kind.name : 'sync_failed';
    final message = error is NasApiError ? error.message : 'Sync failed';
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

String? _jsonOrNull(Map<String, dynamic>? value) => value == null ? null : jsonEncode(value);

DateTime? _nullableDateTime(Object? value, DateTime? fallback) {
  return identical(value, _unset) ? fallback : value as DateTime?;
}

String? _nullableString(Object? value, String? fallback) {
  return identical(value, _unset) ? fallback : value as String?;
}
