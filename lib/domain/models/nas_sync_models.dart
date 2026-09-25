import 'dart:convert';

import 'sync_models.dart';

/// Wire DTOs for the versioned NAS sync API.
///
/// These types intentionally stay separate from Drift/local-first models. The
/// sync engine is the only layer that translates an outbox row into a wire
/// change and persists the returned cursor.
class NasSyncBootstrap {
  const NasSyncBootstrap({
    required this.schemaVersion,
    required this.syncProtocolVersion,
    required this.serverCursor,
    required this.mergeRequired,
    required this.availableModes,
    this.family,
    this.snapshot,
  });

  final int schemaVersion;
  final int syncProtocolVersion;
  final int serverCursor;
  final bool mergeRequired;
  final List<String> availableModes;
  final Map<String, dynamic>? family;
  final Map<String, dynamic>? snapshot;

  factory NasSyncBootstrap.fromJson(Map<String, dynamic> json) {
    return NasSyncBootstrap(
      schemaVersion: _requiredInt(json, 'schema_version'),
      syncProtocolVersion: _requiredInt(json, 'sync_protocol_version'),
      serverCursor: _requiredInt(json, 'server_cursor'),
      mergeRequired: _requiredBool(json, 'merge_required'),
      availableModes: _stringList(json['available_modes'], 'available_modes'),
      family: _optionalMap(json['family']),
      snapshot: _optionalMap(json['snapshot']),
    );
  }
}

class NasSyncConfirmResult {
  const NasSyncConfirmResult({
    required this.accepted,
    required this.nextAction,
    required this.serverCursor,
  });

  final bool accepted;
  final String nextAction;
  final int serverCursor;

  factory NasSyncConfirmResult.fromJson(Map<String, dynamic> json) {
    return NasSyncConfirmResult(
      accepted: _requiredBool(json, 'accepted'),
      nextAction: _requiredString(json, 'next_action'),
      serverCursor: _requiredInt(json, 'server_cursor'),
    );
  }
}

class NasSyncChange {
  const NasSyncChange({
    required this.changeId,
    required this.operation,
    required this.idempotencyKey,
    this.entity,
    this.entityId,
    this.baseVersion = 0,
    this.payload,
    this.command,
    this.operationId,
    this.allocations = const <NasSyncInventoryAllocation>[],
    this.integrationId,
    this.parameters,
    this.clientUpdatedAt,
  });

  final String changeId;
  final String operation;
  final String idempotencyKey;
  final String? entity;
  final String? entityId;
  final int baseVersion;
  final Map<String, dynamic>? payload;
  final String? command;
  final String? operationId;
  final List<NasSyncInventoryAllocation> allocations;
  final String? integrationId;
  final Map<String, dynamic>? parameters;
  final String? clientUpdatedAt;

  factory NasSyncChange.fromJson(Map<String, dynamic> json) {
    return NasSyncChange(
      changeId: _requiredString(json, 'change_id'),
      operation: _requiredString(json, 'operation'),
      idempotencyKey: _requiredString(json, 'idempotency_key'),
      entity: _optionalString(json['entity']),
      entityId: _optionalString(json['entity_id']),
      baseVersion: _optionalInt(json['base_version']) ?? 0,
      payload: _optionalMap(json['payload']),
      command: _optionalString(json['command']),
      operationId: _optionalString(json['operation_id']),
      allocations: _allocationList(json['allocations']),
      integrationId: _optionalString(json['integration_id']),
      parameters: _optionalMap(json['parameters']),
      clientUpdatedAt: _optionalString(json['client_updated_at']),
    );
  }

  /// Converts a durable outbox entry without changing its operation kind.
  /// In particular, inventory commands remain commands and are never modeled
  /// as a product quantity upsert.
  factory NasSyncChange.fromOutbox(SyncOutboxEntry entry) {
    final decoded = jsonDecode(entry.requestJson);
    if (decoded is! Map) {
      throw const FormatException('outbox request_json must be an object');
    }
    final json = Map<String, dynamic>.from(decoded);
    json['change_id'] ??= entry.changeId;
    json['operation'] ??= entry.operation.wireValue;
    json['idempotency_key'] ??= entry.idempotencyKey;
    json['entity'] ??= entry.entity;
    json['entity_id'] ??= entry.entityId;
    json['base_version'] ??= entry.baseVersion;
    json['operation_id'] ??= entry.operationId;
    json['integration_id'] ??= entry.integrationId;
    json['command'] ??= entry.command;
    final change = NasSyncChange.fromJson(json);
    change.validateForPush();
    return change;
  }

  Map<String, dynamic> toJson() {
    final result = <String, dynamic>{
      'change_id': changeId,
      'operation': operation,
      'idempotency_key': idempotencyKey,
    };
    _putIfNotNull(result, 'entity', entity);
    _putIfNotNull(result, 'entity_id', entityId);
    if (baseVersion != 0 || operation == 'entity_upsert' || operation == 'entity_delete') {
      result['base_version'] = baseVersion;
    }
    _putIfNotNull(result, 'payload', payload);
    _putIfNotNull(result, 'command', command);
    _putIfNotNull(result, 'operation_id', operationId);
    if (allocations.isNotEmpty) {
      result['allocations'] = allocations.map((item) => item.toJson()).toList();
    }
    _putIfNotNull(result, 'integration_id', integrationId);
    _putIfNotNull(result, 'parameters', parameters);
    _putIfNotNull(result, 'client_updated_at', clientUpdatedAt);
    return result;
  }

  /// Performs only client-side contract checks. Server validation remains the
  /// source of truth; this prevents accidental cross-operation field mixing.
  void validateForPush() {
    if (changeId.trim().isEmpty || idempotencyKey.trim().isEmpty) {
      throw const FormatException('change_id and idempotency_key are required');
    }
    if (baseVersion < 0) {
      throw const FormatException('base_version must be non-negative');
    }
    switch (operation) {
      case 'entity_upsert':
        if (entity == null || entityId == null || payload == null) {
          throw const FormatException('entity_upsert requires entity, entity_id and payload');
        }
        if (command != null || operationId != null || allocations.isNotEmpty ||
            integrationId != null || parameters != null) {
          throw const FormatException('entity_upsert contains command fields');
        }
        return;
      case 'entity_delete':
        if (entity == null || entityId == null) {
          throw const FormatException('entity_delete requires entity and entity_id');
        }
        if (payload != null || command != null || operationId != null ||
            allocations.isNotEmpty || integrationId != null || parameters != null) {
          throw const FormatException('entity_delete contains incompatible fields');
        }
        return;
      case 'inventory_command':
        if (command == null || operationId == null) {
          throw const FormatException('inventory_command requires command and operation_id');
        }
        if (entity != null || entityId != null || payload != null ||
            integrationId != null || parameters != null) {
          throw const FormatException('inventory_command contains entity fields');
        }
        for (final allocation in allocations) {
          if (allocation.quantity < 1) {
            throw const FormatException('inventory allocation quantity must be positive');
          }
        }
        return;
      case 'home_assistant_command':
        if (integrationId == null || entityId == null || command == null) {
          throw const FormatException(
            'home_assistant_command requires integration_id, entity_id and command',
          );
        }
        if (entity != null || payload != null || operationId != null || allocations.isNotEmpty) {
          throw const FormatException('home_assistant_command contains incompatible fields');
        }
        _validateHaParameters(parameters);
        return;
      default:
        throw FormatException('unsupported sync operation: $operation');
    }
  }
}

class NasSyncInventoryAllocation {
  const NasSyncInventoryAllocation({required this.batchId, required this.quantity});

  final String batchId;
  final int quantity;

  factory NasSyncInventoryAllocation.fromJson(Object? value) {
    if (value is! Map) throw const FormatException('invalid inventory allocation');
    final json = Map<String, dynamic>.from(value);
    return NasSyncInventoryAllocation(
      batchId: _requiredString(json, 'batch_id'),
      quantity: _requiredInt(json, 'quantity'),
    );
  }

  Map<String, dynamic> toJson() => {'batch_id': batchId, 'quantity': quantity};
}

class NasSyncAcceptedChange {
  const NasSyncAcceptedChange({
    required this.changeId,
    required this.serverCursor,
    this.entityId,
    this.serverVersion,
    this.result,
    this.status,
  });

  final String changeId;
  final String? entityId;
  final int? serverVersion;
  final int serverCursor;
  final Map<String, dynamic>? result;
  final String? status;

  factory NasSyncAcceptedChange.fromJson(Map<String, dynamic> json) {
    return NasSyncAcceptedChange(
      changeId: _requiredString(json, 'change_id'),
      entityId: _optionalString(json['entity_id']),
      serverVersion: _optionalInt(json['server_version']),
      serverCursor: _requiredInt(json, 'server_cursor'),
      result: _optionalMap(json['result']),
      status: _optionalString(json['status']),
    );
  }
}

class NasSyncReplayedChange {
  const NasSyncReplayedChange({
    required this.changeId,
    required this.originalStatus,
    this.accepted,
    this.conflict,
    this.rejected,
  });

  final String changeId;
  final String originalStatus;
  final NasSyncAcceptedChange? accepted;
  final NasSyncConflict? conflict;
  final NasSyncRejectedChange? rejected;

  factory NasSyncReplayedChange.fromJson(Map<String, dynamic> json) {
    return NasSyncReplayedChange(
      changeId: _requiredString(json, 'change_id'),
      originalStatus: _requiredString(json, 'original_status'),
      accepted: _optionalObject(json['accepted'], NasSyncAcceptedChange.fromJson),
      conflict: _optionalObject(json['conflict'], NasSyncConflict.fromJson),
      rejected: _optionalObject(json['rejected'], NasSyncRejectedChange.fromJson),
    );
  }
}

class NasSyncConflict {
  const NasSyncConflict({
    required this.changeId,
    required this.entity,
    required this.reason,
    this.entityId,
    this.serverVersion,
    this.serverPayload,
    this.clientPayload,
  });

  final String changeId;
  final String entity;
  final String? entityId;
  final String reason;
  final int? serverVersion;
  final Map<String, dynamic>? serverPayload;
  final Map<String, dynamic>? clientPayload;

  factory NasSyncConflict.fromJson(Map<String, dynamic> json) {
    return NasSyncConflict(
      changeId: _requiredString(json, 'change_id'),
      entity: _requiredString(json, 'entity'),
      entityId: _optionalString(json['entity_id']),
      reason: _requiredString(json, 'reason'),
      serverVersion: _optionalInt(json['server_version']),
      serverPayload: _optionalMap(json['server_payload']),
      clientPayload: _optionalMap(json['client_payload']),
    );
  }
}

class NasSyncRejectedChange {
  const NasSyncRejectedChange({
    required this.changeId,
    required this.code,
    required this.message,
    this.details,
  });

  final String changeId;
  final String code;
  final String message;
  final Map<String, dynamic>? details;

  factory NasSyncRejectedChange.fromJson(Map<String, dynamic> json) {
    return NasSyncRejectedChange(
      changeId: _requiredString(json, 'change_id'),
      code: _requiredString(json, 'code'),
      message: _requiredString(json, 'message'),
      details: _optionalMap(json['details']),
    );
  }
}

class NasSyncPushResult {
  const NasSyncPushResult({
    required this.changeId,
    required this.status,
    this.originalStatus,
    this.accepted,
    this.conflict,
    this.rejected,
  });

  final String changeId;
  final String status;
  final String? originalStatus;
  final NasSyncAcceptedChange? accepted;
  final NasSyncConflict? conflict;
  final NasSyncRejectedChange? rejected;

  factory NasSyncPushResult.fromJson(Map<String, dynamic> json) {
    return NasSyncPushResult(
      changeId: _requiredString(json, 'change_id'),
      status: _requiredString(json, 'status'),
      originalStatus: _optionalString(json['original_status']),
      accepted: _optionalObject(json['accepted'], NasSyncAcceptedChange.fromJson),
      conflict: _optionalObject(json['conflict'], NasSyncConflict.fromJson),
      rejected: _optionalObject(json['rejected'], NasSyncRejectedChange.fromJson),
    );
  }
}

class NasSyncPushResponse {
  const NasSyncPushResponse({
    required this.accepted,
    required this.replayed,
    required this.conflicts,
    required this.rejected,
    required this.results,
    required this.cursor,
  });

  final List<NasSyncAcceptedChange> accepted;
  final List<NasSyncReplayedChange> replayed;
  final List<NasSyncConflict> conflicts;
  final List<NasSyncRejectedChange> rejected;
  final List<NasSyncPushResult> results;
  final int cursor;

  factory NasSyncPushResponse.fromJson(Map<String, dynamic> json) {
    return NasSyncPushResponse(
      accepted: _objectList(json['accepted'], NasSyncAcceptedChange.fromJson, 'accepted'),
      replayed: _objectList(json['replayed'], NasSyncReplayedChange.fromJson, 'replayed'),
      conflicts: _objectList(json['conflicts'], NasSyncConflict.fromJson, 'conflicts'),
      rejected: _objectList(json['rejected'], NasSyncRejectedChange.fromJson, 'rejected'),
      results: _objectList(json['results'], NasSyncPushResult.fromJson, 'results', optional: true),
      cursor: _requiredInt(json, 'cursor'),
    );
  }
}

class NasSyncPullChange {
  const NasSyncPullChange({
    required this.changeId,
    required this.cursor,
    required this.operation,
    required this.entity,
    this.entityId,
    this.version,
    this.payload,
    this.command,
    this.clientUpdatedAt,
  });

  final String changeId;
  final int cursor;
  final String operation;
  final String entity;
  final String? entityId;
  final int? version;
  final Map<String, dynamic>? payload;
  final String? command;
  final String? clientUpdatedAt;

  factory NasSyncPullChange.fromJson(Map<String, dynamic> json) {
    return NasSyncPullChange(
      changeId: _requiredString(json, 'change_id'),
      cursor: _requiredInt(json, 'cursor'),
      operation: _requiredString(json, 'operation'),
      entity: _requiredString(json, 'entity'),
      entityId: _optionalString(json['entity_id']),
      version: _optionalInt(json['version']),
      payload: _optionalMap(json['payload']),
      command: _optionalString(json['command']),
      clientUpdatedAt: _optionalString(json['client_updated_at']),
    );
  }
}

class NasSyncPullResponse {
  const NasSyncPullResponse({
    required this.changes,
    required this.nextCursor,
    required this.hasMore,
  });

  final List<NasSyncPullChange> changes;
  final int nextCursor;
  final bool hasMore;

  factory NasSyncPullResponse.fromJson(Map<String, dynamic> json) {
    final changes = _objectList(json['changes'], NasSyncPullChange.fromJson, 'changes');
    final nextCursor = _requiredInt(json, 'next_cursor');
    if (nextCursor < 0) throw const FormatException('next_cursor must be non-negative');
    for (final change in changes) {
      if (change.cursor < 0) throw const FormatException('change cursor must be non-negative');
    }
    return NasSyncPullResponse(
      changes: changes,
      nextCursor: nextCursor,
      hasMore: _requiredBool(json, 'has_more'),
    );
  }
}

void _validateHaParameters(Map<String, dynamic>? parameters) {
  if (parameters == null) return;
  const allowed = {'brightness', 'temperature', 'hvac_mode'};
  for (final key in parameters.keys) {
    if (!allowed.contains(key)) {
      throw FormatException('unsupported Home Assistant parameter: $key');
    }
  }
  final brightness = parameters['brightness'];
  if (brightness != null && (brightness is! num || brightness < 0 || brightness > 100)) {
    throw const FormatException('brightness must be between 0 and 100');
  }
  final temperature = parameters['temperature'];
  if (temperature != null && (temperature is! num || temperature < -100 || temperature > 200)) {
    throw const FormatException('temperature must be between -100 and 200');
  }
  final hvacMode = parameters['hvac_mode'];
  if (hvacMode != null && (hvacMode is! String || hvacMode.trim().isEmpty || hvacMode.length > 64)) {
    throw const FormatException('hvac_mode must be a non-empty string of at most 64 characters');
  }
}

void _putIfNotNull(Map<String, dynamic> map, String key, Object? value) {
  if (value != null) map[key] = value;
}

String _requiredString(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is String && value.trim().isNotEmpty) return value;
  throw FormatException('$key must be a non-empty string');
}

String? _optionalString(Object? value) => value is String ? value : null;

int _requiredInt(Map<String, dynamic> json, String key) {
  final value = _optionalInt(json[key]);
  if (value != null) return value;
  throw FormatException('$key must be an integer');
}

int? _optionalInt(Object? value) {
  if (value is int) return value;
  if (value is num && value == value.toInt()) return value.toInt();
  return null;
}

bool _requiredBool(Map<String, dynamic> json, String key) {
  final value = json[key];
  if (value is bool) return value;
  throw FormatException('$key must be a boolean');
}

Map<String, dynamic>? _optionalMap(Object? value) {
  if (value == null) return null;
  if (value is! Map) throw const FormatException('expected an object');
  return Map<String, dynamic>.from(value);
}

List<String> _stringList(Object? value, String key) {
  if (value is! List) throw FormatException('$key must be an array');
  return value.map((item) {
    if (item is String && item.trim().isNotEmpty) return item;
    throw FormatException('$key must contain strings');
  }).toList(growable: false);
}

List<NasSyncInventoryAllocation> _allocationList(Object? value) {
  if (value == null) return const <NasSyncInventoryAllocation>[];
  if (value is! List) throw const FormatException('allocations must be an array');
  return value.map(NasSyncInventoryAllocation.fromJson).toList(growable: false);
}

T? _optionalObject<T>(Object? value, T Function(Map<String, dynamic>) parser) {
  if (value == null) return null;
  if (value is! Map) throw const FormatException('expected an object');
  return parser(Map<String, dynamic>.from(value));
}

List<T> _objectList<T>(
  Object? value,
  T Function(Map<String, dynamic>) parser,
  String key, {
  bool optional = false,
}) {
  if (value == null && optional) return const <T>[];
  if (value is! List) throw FormatException('$key must be an array');
  return value.map((item) {
    if (item is! Map) throw FormatException('$key must contain objects');
    return parser(Map<String, dynamic>.from(item));
  }).toList(growable: false);
}
