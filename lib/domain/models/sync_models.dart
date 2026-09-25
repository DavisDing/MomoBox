/// Domain models for the local-first NAS synchronization substrate.
///
/// These models deliberately contain no HTTP code. Network DTOs can map to
/// them later without coupling the local SQLite/outbox layer to a client.
enum SyncOperation {
  entityUpsert('entity_upsert'),
  entityDelete('entity_delete'),
  inventoryCommand('inventory_command'),
  homeAssistantCommand('home_assistant_command');

  const SyncOperation(this.wireValue);

  final String wireValue;

  static SyncOperation fromWire(String value) {
    for (final operation in values) {
      if (operation.wireValue == value) return operation;
    }
    throw FormatException('Unsupported sync operation: $value');
  }
}

enum SyncBootstrapStatus {
  unconfigured('unconfigured'),
  awaitingConfirmation('awaiting_confirmation'),
  ready('ready'),
  keepLocalOnly('keep_local_only'),
  blocked('blocked');

  const SyncBootstrapStatus(this.wireValue);

  final String wireValue;

  static SyncBootstrapStatus fromWire(String value) {
    for (final status in values) {
      if (status.wireValue == value) return status;
    }
    throw FormatException('Unsupported bootstrap status: $value');
  }
}

enum SyncOutboxStatus {
  pending('pending'),
  inFlight('in_flight'),
  accepted('accepted'),
  replayed('replayed'),
  conflict('conflict'),
  rejected('rejected'),
  blocked('blocked');

  const SyncOutboxStatus(this.wireValue);

  final String wireValue;

  static SyncOutboxStatus fromWire(String value) {
    for (final status in values) {
      if (status.wireValue == value) return status;
    }
    throw FormatException('Unsupported outbox status: $value');
  }
}

enum SyncConflictStatus {
  open('open'),
  resolved('resolved'),
  rejected('rejected');

  const SyncConflictStatus(this.wireValue);

  final String wireValue;

  static SyncConflictStatus fromWire(String value) {
    for (final status in values) {
      if (status.wireValue == value) return status;
    }
    throw FormatException('Unsupported conflict status: $value');
  }
}

class SyncStateModel {
  const SyncStateModel({
    required this.scopeId,
    required this.bootstrapStatus,
    required this.pullCursor,
    required this.pushAckCursor,
    required this.consecutiveFailures,
    required this.updatedAt,
    this.familyId,
    this.deviceId,
    this.localWorkspaceId,
    this.lastPushAt,
    this.lastPullAt,
    this.lastSuccessAt,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.nextRetryAt,
    this.serverSchemaVersion,
    this.syncProtocolVersion,
  });

  final String scopeId;
  final String? familyId;
  final String? deviceId;
  final String? localWorkspaceId;
  final SyncBootstrapStatus bootstrapStatus;
  final int pullCursor;
  final int pushAckCursor;
  final DateTime? lastPushAt;
  final DateTime? lastPullAt;
  final DateTime? lastSuccessAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final int consecutiveFailures;
  final DateTime? nextRetryAt;
  final int? serverSchemaVersion;
  final int? syncProtocolVersion;
  final DateTime updatedAt;

  SyncStateModel copyWith({
    Object? familyId = _syncUnset,
    Object? deviceId = _syncUnset,
    Object? localWorkspaceId = _syncUnset,
    SyncBootstrapStatus? bootstrapStatus,
    int? pullCursor,
    int? pushAckCursor,
    Object? lastPushAt = _syncUnset,
    Object? lastPullAt = _syncUnset,
    Object? lastSuccessAt = _syncUnset,
    Object? lastErrorCode = _syncUnset,
    Object? lastErrorMessage = _syncUnset,
    int? consecutiveFailures,
    Object? nextRetryAt = _syncUnset,
    int? serverSchemaVersion,
    int? syncProtocolVersion,
    DateTime? updatedAt,
  }) {
    return SyncStateModel(
      scopeId: scopeId,
      familyId: _syncNullableString(familyId, this.familyId),
      deviceId: _syncNullableString(deviceId, this.deviceId),
      localWorkspaceId: _syncNullableString(localWorkspaceId, this.localWorkspaceId),
      bootstrapStatus: bootstrapStatus ?? this.bootstrapStatus,
      pullCursor: pullCursor ?? this.pullCursor,
      pushAckCursor: pushAckCursor ?? this.pushAckCursor,
      lastPushAt: _syncNullableDateTime(lastPushAt, this.lastPushAt),
      lastPullAt: _syncNullableDateTime(lastPullAt, this.lastPullAt),
      lastSuccessAt: _syncNullableDateTime(lastSuccessAt, this.lastSuccessAt),
      lastErrorCode: _syncNullableString(lastErrorCode, this.lastErrorCode),
      lastErrorMessage: _syncNullableString(lastErrorMessage, this.lastErrorMessage),
      consecutiveFailures: consecutiveFailures ?? this.consecutiveFailures,
      nextRetryAt: _syncNullableDateTime(nextRetryAt, this.nextRetryAt),
      serverSchemaVersion: serverSchemaVersion ?? this.serverSchemaVersion,
      syncProtocolVersion: syncProtocolVersion ?? this.syncProtocolVersion,
      updatedAt: updatedAt ?? this.updatedAt,
    );
  }
}

class SyncOutboxDraft {
  const SyncOutboxDraft({
    required this.changeId,
    required this.scopeId,
    required this.operation,
    required this.idempotencyKey,
    required this.requestJson,
    this.entity,
    this.entityId,
    this.baseVersion = 0,
    this.operationId,
    this.integrationId,
    this.command,
    this.status = SyncOutboxStatus.pending,
    this.nextAttemptAt,
    this.createdAt,
  });

  final String changeId;
  final String scopeId;
  final SyncOperation operation;
  final String? entity;
  final String? entityId;
  final int baseVersion;
  final String? operationId;
  final String? integrationId;
  final String? command;
  final String idempotencyKey;
  final String requestJson;
  final SyncOutboxStatus status;
  final DateTime? nextAttemptAt;
  final DateTime? createdAt;
}

class SyncOutboxEntry {
  const SyncOutboxEntry({
    required this.changeId,
    required this.scopeId,
    required this.operation,
    required this.idempotencyKey,
    required this.requestJson,
    required this.status,
    required this.baseVersion,
    required this.attemptCount,
    required this.createdAt,
    required this.updatedAt,
    this.entity,
    this.entityId,
    this.operationId,
    this.integrationId,
    this.command,
    this.nextAttemptAt,
    this.lastErrorCode,
    this.lastErrorMessage,
    this.serverCursor,
    this.serverVersion,
    this.completedAt,
  });

  final String changeId;
  final String scopeId;
  final SyncOperation operation;
  final String? entity;
  final String? entityId;
  final int baseVersion;
  final String? operationId;
  final String? integrationId;
  final String? command;
  final String idempotencyKey;
  final String requestJson;
  final SyncOutboxStatus status;
  final int attemptCount;
  final DateTime? nextAttemptAt;
  final String? lastErrorCode;
  final String? lastErrorMessage;
  final int? serverCursor;
  final int? serverVersion;
  final DateTime createdAt;
  final DateTime updatedAt;
  final DateTime? completedAt;
}

class SyncConflictDraft {
  const SyncConflictDraft({
    required this.scopeId,
    required this.changeId,
    required this.entity,
    required this.reason,
    this.outboxChangeId,
    this.entityId,
    this.serverVersion,
    this.serverPayloadJson,
    this.clientPayloadJson,
    this.status = SyncConflictStatus.open,
  });

  final String scopeId;
  final String changeId;
  final String? outboxChangeId;
  final String entity;
  final String? entityId;
  final String reason;
  final int? serverVersion;
  final String? serverPayloadJson;
  final String? clientPayloadJson;
  final SyncConflictStatus status;
}

class SyncConflictEntry {
  const SyncConflictEntry({
    required this.id,
    required this.scopeId,
    required this.changeId,
    required this.entity,
    required this.reason,
    required this.status,
    required this.createdAt,
    this.outboxChangeId,
    this.entityId,
    this.serverVersion,
    this.serverPayloadJson,
    this.clientPayloadJson,
    this.resolution,
    this.resolvedAt,
  });

  final int id;
  final String scopeId;
  final String changeId;
  final String? outboxChangeId;
  final String entity;
  final String? entityId;
  final String reason;
  final int? serverVersion;
  final String? serverPayloadJson;
  final String? clientPayloadJson;
  final SyncConflictStatus status;
  final String? resolution;
  final DateTime createdAt;
  final DateTime? resolvedAt;
}

class SyncAppliedChange {
  const SyncAppliedChange({
    required this.scopeId,
    required this.changeId,
    required this.cursor,
    required this.appliedAt,
  });

  final String scopeId;
  final String changeId;
  final int cursor;
  final DateTime appliedAt;
}

const _syncUnset = Object();

String? _syncNullableString(Object? value, String? fallback) =>
    identical(value, _syncUnset) ? fallback : value as String?;

DateTime? _syncNullableDateTime(Object? value, DateTime? fallback) =>
    identical(value, _syncUnset) ? fallback : value as DateTime?;
