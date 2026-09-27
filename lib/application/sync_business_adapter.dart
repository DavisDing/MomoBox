import 'dart:convert';

import '../data/repositories/inventory_repository.dart';
import '../data/repositories/shopping_repository.dart';
import '../data/repositories/sync_outbox_repository.dart';
import '../domain/models/nas_sync_models.dart';
import '../domain/models/sync_models.dart';
import 'sync_change_control.dart';

/// Applies NAS pull changes to the local business repositories.
///
/// The adapter deliberately keeps the wire protocol out of the repositories:
/// entity changes are routed by the server entity name and inventory commands
/// are applied as commands/results, never as ordinary batch quantity upserts.
/// A local pending outbox change blocks an incoming change for the same entity
/// and is recorded as an open conflict so a later resolution flow can decide
/// which version to keep.
class SyncBusinessAdapter {
  SyncBusinessAdapter({
    required InventoryRepository inventoryRepository,
    required ShoppingRepository shoppingRepository,
    required SyncOutboxRepository outboxRepository,
    required String scopeId,
  })  : _inventory = inventoryRepository,
        _shopping = shoppingRepository,
        _outbox = outboxRepository,
        _scopeId = scopeId;

  final InventoryRepository _inventory;
  final ShoppingRepository _shopping;
  final SyncOutboxRepository _outbox;
  final String _scopeId;

  Future<void> applyRemoteSnapshot(Map<String, dynamic> snapshot, int serverCursor) async {
    for (final entry in snapshot.entries) {
      final entity = entry.key.trim();
      final records = entry.value;
      if (records is! List) {
        throw FormatException('bootstrap snapshot entity $entity must be an array');
      }
      for (final raw in records) {
        if (raw is! Map) {
          throw FormatException('bootstrap snapshot entity $entity contains a non-object record');
        }
        final payload = Map<String, dynamic>.from(raw);
        final entityId = _string(payload, 'id');
        if (entityId == null) {
          throw FormatException('bootstrap snapshot entity $entity requires id');
        }
        final version = _integer(payload, const ['version']) ?? serverCursor;
        final updatedAt = _updatedAtFromPayload(payload);
        final deletedAt = _date(payload, 'deleted_at');
        if (entity == 'categories' || entity == 'reminder_settings' || entity == 'reminder_acknowledgments') {
          await _outbox.applyRemoteAuxiliaryEntity(
            scopeId: _scopeId,
            entity: entity,
            entityId: entityId,
            payload: payload,
            version: version,
            updatedAt: updatedAt,
            deletedAt: deletedAt,
          );
          continue;
        }
        await applyRemoteChange(
          NasSyncPullChange(
            changeId: 'bootstrap:$entity:$entityId:$version',
            cursor: serverCursor,
            operation: deletedAt == null ? 'entity_upsert' : 'entity_delete',
            entity: entity,
            entityId: entityId,
            version: version,
            payload: payload,
            clientUpdatedAt: updatedAt.toIso8601String(),
          ),
        );
      }
    }
  }

  Future<void> applyRemoteChange(NasSyncPullChange change) async {
    if (change.changeId.trim().isEmpty) {
      throw const FormatException('pull change_id is required');
    }
    final payload = change.payload ?? const <String, dynamic>{};
    final updatedAt = _updatedAt(change, payload);

    switch (change.operation) {
      case 'entity_upsert':
        await _applyEntityUpsert(change, payload, updatedAt);
        return;
      case 'entity_delete':
        await _applyEntityDelete(change, payload, updatedAt);
        return;
      case 'inventory_command':
        await _applyInventoryCommand(change, payload, updatedAt);
        return;
      default:
        throw FormatException('unsupported pull operation: ${change.operation}');
    }
  }

  Future<void> _applyEntityUpsert(
    NasSyncPullChange change,
    Map<String, dynamic> payload,
    DateTime updatedAt,
  ) async {
    final entityId = _requiredEntityId(change);
    await _protectPendingLocalChange(
      change: change,
      entityId: entityId,
      serverPayload: payload,
    );

    switch (change.entity) {
      case 'products':
        await _inventory.applyRemoteProduct(
          productId: entityId,
          payload: payload,
          version: change.version ?? 0,
          updatedAt: updatedAt,
          updatedByDevice: _string(payload, 'updated_by_device'),
          deletedAt: _date(payload, 'deleted_at'),
        );
        return;
      case 'product_batches':
        await _inventory.applyRemoteProductBatch(
          batchId: entityId,
          payload: payload,
          version: change.version ?? 0,
          updatedAt: updatedAt,
          updatedByDevice: _string(payload, 'updated_by_device'),
          applyQuantity: false,
        );
        return;
      case 'shopping_items':
        await _shopping.applyRemoteShoppingEntry(
          entryId: entityId,
          payload: payload,
          version: change.version ?? 0,
          updatedAt: updatedAt,
          updatedByDevice: _string(payload, 'updated_by_device'),
          deletedAt: _date(payload, 'deleted_at'),
        );
        return;
      default:
        throw FormatException('unsupported pull entity: ${change.entity}');
    }
  }

  Future<void> _applyEntityDelete(
    NasSyncPullChange change,
    Map<String, dynamic> payload,
    DateTime updatedAt,
  ) async {
    final entityId = _requiredEntityId(change);
    await _protectPendingLocalChange(
      change: change,
      entityId: entityId,
      serverPayload: payload,
    );
    final deletedAt = _date(payload, 'deleted_at') ?? updatedAt;
    final version = change.version ?? 0;
    final updatedByDevice = _string(payload, 'updated_by_device');

    switch (change.entity) {
      case 'products':
        await _inventory.applyRemoteProductDelete(
          productId: entityId,
          version: version,
          deletedAt: deletedAt,
          updatedByDevice: updatedByDevice,
        );
        return;
      case 'product_batches':
        await _inventory.applyRemoteProductBatchDelete(
          batchId: entityId,
          version: version,
          deletedAt: deletedAt,
          updatedByDevice: updatedByDevice,
        );
        return;
      case 'shopping_items':
        await _shopping.applyRemoteShoppingEntryDelete(
          entryId: entityId,
          version: version,
          deletedAt: deletedAt,
          updatedByDevice: updatedByDevice,
        );
        return;
      default:
        throw FormatException('unsupported pull entity: ${change.entity}');
    }
  }

  Future<void> _applyInventoryCommand(
    NasSyncPullChange change,
    Map<String, dynamic> resultPayload,
    DateTime updatedAt,
  ) async {
    final command = change.command ?? _string(resultPayload, 'command');
    if (command == null || command.isEmpty) {
      throw const FormatException('inventory_command result requires command');
    }
    final allocations = _allocations(resultPayload['allocations']);
    if (allocations.isEmpty) {
      throw const FormatException('inventory_command result requires allocations');
    }

    final seen = <String>{};
    for (final allocation in allocations) {
      if (!seen.add(allocation.batchId)) {
        throw const FormatException('inventory_command result contains duplicate batch_id');
      }
      final existing = await _inventory.getBatchRecord(allocation.batchId);
      if (existing == null) {
        throw FormatException(
          'inventory_command result references an unknown local batch: ${allocation.batchId}',
        );
      }

      await _protectPendingLocalChange(
        change: change,
        entityId: allocation.batchId,
        serverPayload: resultPayload,
        inventoryCommand: true,
      );

      final quantity = _resultingQuantity(
        command: command,
        allocationQuantity: allocation.quantity,
        existingQuantity: existing.remainingQuantity,
        serverPayload: allocation.batchId == change.entityId ? resultPayload : null,
      );
      final payload = <String, dynamic>{
        'product_id': existing.productId,
        'quantity': quantity,
        'command': command,
        'operation_id': _string(resultPayload, 'operation_id'),
        'allocations': [allocation.toJson()],
      };
      await _inventory.applyRemoteProductBatch(
        batchId: allocation.batchId,
        payload: payload,
        version: change.version ?? 0,
        updatedAt: updatedAt,
        updatedByDevice: _string(resultPayload, 'updated_by_device'),
        applyQuantity: true,
      );
    }
  }

  Future<void> _protectPendingLocalChange({
    required NasSyncPullChange change,
    required String entityId,
    required Map<String, dynamic> serverPayload,
    bool inventoryCommand = false,
  }) async {
    final pending = inventoryCommand
        ? await _outbox.listForOperation(
            scopeId: _scopeId,
            operation: SyncOperation.inventoryCommand,
          )
        : await _outbox.listForEntity(
            scopeId: _scopeId,
            entity: change.entity,
            entityId: entityId,
          );
    if (pending.isEmpty) return;

    final local = pending.first;
    await _outbox.recordConflict(
      SyncConflictDraft(
        scopeId: _scopeId,
        changeId: change.changeId,
        outboxChangeId: local.changeId,
        entity: change.entity,
        entityId: entityId,
        reason: inventoryCommand
            ? 'REMOTE_INVENTORY_COMMAND_WITH_PENDING_LOCAL_CHANGE'
            : 'REMOTE_CHANGE_WITH_PENDING_LOCAL_CHANGE',
        serverVersion: change.version,
        serverPayloadJson: jsonEncode(serverPayload),
        clientPayloadJson: local.requestJson,
      ),
    );
    throw SyncRemoteChangeDeferred(
      'remote change ${change.changeId} conflicts with pending local change $entityId',
    );
  }

  DateTime _updatedAtFromPayload(Map<String, dynamic> payload) {
    final raw = _string(payload, 'updated_at') ?? _string(payload, 'created_at');
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) throw FormatException('invalid remote timestamp: $raw');
      return parsed.toUtc();
    }
    return DateTime.now().toUtc();
  }

  DateTime _updatedAt(NasSyncPullChange change, Map<String, dynamic> payload) {
    final raw = change.clientUpdatedAt ?? _string(payload, 'updated_at');
    if (raw != null) {
      final parsed = DateTime.tryParse(raw);
      if (parsed == null) throw FormatException('invalid remote timestamp: $raw');
      return parsed.toUtc();
    }
    return DateTime.now().toUtc();
  }

  String _requiredEntityId(NasSyncPullChange change) {
    final value = change.entityId;
    if (value == null || value.trim().isEmpty) {
      throw FormatException('${change.operation} requires entity_id');
    }
    return value;
  }

  String? _string(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    return value is String && value.trim().isNotEmpty ? value.trim() : null;
  }

  DateTime? _date(Map<String, dynamic> payload, String key) {
    final value = payload[key];
    if (value == null) return null;
    if (value is! String) throw FormatException('$key must be an RFC3339 date');
    final parsed = DateTime.tryParse(value);
    if (parsed == null) throw FormatException('$key must be an RFC3339 date');
    return parsed.toUtc();
  }

  int _resultingQuantity({
    required String command,
    required int allocationQuantity,
    required int existingQuantity,
    required Map<String, dynamic>? serverPayload,
  }) {
    final serverQuantity = serverPayload == null
        ? null
        : _integer(serverPayload, const ['quantity', 'current_quantity', 'remaining_quantity']);
    if (serverQuantity != null) {
      if (serverQuantity < 0) throw const FormatException('remote quantity must be non-negative');
      return serverQuantity;
    }
    final quantity = switch (command) {
      'restock' => existingQuantity + allocationQuantity,
      'consume_fefo' || 'consume_allocated' || 'discard' => existingQuantity - allocationQuantity,
      _ => throw FormatException('unsupported inventory command result: $command'),
    };
    if (quantity < 0) {
      throw const FormatException('remote inventory result would make quantity negative');
    }
    return quantity;
  }

  int? _integer(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value is int) return value;
      if (value is num && value == value.toInt()) return value.toInt();
      throw FormatException('$key must be an integer');
    }
    return null;
  }

  List<NasSyncInventoryAllocation> _allocations(Object? raw) {
    if (raw is! List) return const <NasSyncInventoryAllocation>[];
    return raw.map(NasSyncInventoryAllocation.fromJson).toList(growable: false);
  }
}
