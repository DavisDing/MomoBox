import 'dart:convert';

import '../data/repositories/inventory_repository.dart';
import '../data/repositories/shopping_repository.dart';
import '../data/repositories/reminder_repository.dart';
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
        _scopeId = scopeId {
    if (!identical(_inventory.database, _outbox.database) ||
        !identical(_shopping.database, _outbox.database)) {
      throw ArgumentError('sync repositories must share one AppDatabase');
    }
  }

  final InventoryRepository _inventory;
  final ShoppingRepository _shopping;
  final SyncOutboxRepository _outbox;
  final String _scopeId;

  static const _snapshotOrder = [
    'categories',
    'products',
    'product_batches',
    'shopping_items',
    'reminder_settings',
  ];

  Future<void> applyRemoteSnapshot(
    Map<String, dynamic> snapshot,
    int serverCursor, {
    Future<void> Function()? onApplied,
  }) async {
    if (serverCursor < 0) throw const FormatException('snapshot cursor must be non-negative');
    await _assertSnapshotScopeQuiescent();
    // Build and validate the complete plan before writing even the first row.
    // Never depend on JSON map order or silently accept a new wire entity.
    final plan = <NasSyncPullChange>[];
    for (final entity in snapshot.keys) {
      if (!_snapshotOrder.contains(entity)) {
        throw FormatException('unsupported snapshot entity: $entity');
      }
      if (snapshot[entity] is! List) {
        throw FormatException('bootstrap snapshot entity $entity must be an array');
      }
    }
    final categoryNames = <String, String>{};
    final deletedCategoryIds = <String>{};
    final productIds = <String>{};
    final reminderTargets = <String?>{};
    for (final entity in _snapshotOrder) {
      final seen = <String>{};
      for (final raw in (snapshot[entity] as List?) ?? const []) {
        if (raw is! Map || raw.keys.any((key) => key is! String)) {
          throw FormatException('bootstrap snapshot entity $entity contains a non-object record');
        }
        final payload = Map<String, dynamic>.from(raw);
        final entityId = _string(payload, 'id');
        if (entityId == null || !seen.add(entityId)) {
          throw FormatException('bootstrap snapshot entity $entity requires unique non-empty ids');
        }
        final version = _integer(payload, const ['version']) ?? serverCursor;
        if (version < 0) throw const FormatException('snapshot version must be non-negative');
        final updatedAt = _updatedAtFromPayload(payload);
        final deletedAt = _date(payload, 'deleted_at');
        _validateSnapshotFields(payload);
        if (entity == 'categories' && deletedAt != null) {
          deletedCategoryIds.add(entityId);
        }
        if (deletedAt == null) {
          switch (entity) {
            case 'categories':
              _validateCategory(payload);
              categoryNames[entityId] = _string(payload, 'name')!;
              break;
            case 'products':
              final existing = await _inventory.getProductRecord(entityId);
              if (existing == null && _string(payload, 'name') == null) {
                throw const FormatException('products snapshot requires name for a new product');
              }
              if (deletedCategoryIds.contains(_string(payload, 'category_id'))) {
                throw const FormatException('products.category_id references a deleted category');
              }
              final mapped = await _productPayload(
                payload, snapshotCategoryNames: categoryNames,
              );
              if (existing == null && _string(mapped, 'category') == null &&
                  _string(mapped, 'category_name') == null) {
                throw const FormatException('products snapshot requires a category for a new product');
              }
              productIds.add(entityId);
              break;
            case 'product_batches':
              final existing = await _inventory.getBatchRecord(entityId);
              final productId = _string(payload, 'product_id') ?? existing?.productId;
              if (productId == null ||
                  (!productIds.contains(productId) && await _inventory.getProductRecord(productId) == null)) {
                throw const FormatException('product_batches snapshot references an unknown product');
              }
              final quantity = _integer(payload, const ['quantity', 'current_quantity', 'remaining_quantity']);
              if (quantity == null) {
                throw const FormatException('product_batches snapshot requires authoritative quantity');
              }
              break;
            case 'shopping_items':
              // A snapshot is a full server record, not an arbitrary partial patch.
              if (_string(payload, 'name') == null) {
                throw const FormatException('shopping_items snapshot requires name');
              }
              final productId = _string(payload, 'product_id');
              if (productId != null && !productIds.contains(productId) &&
                  await _inventory.getProductRecord(productId) == null) {
                throw const FormatException('shopping_items snapshot references an unknown product');
              }
              break;
            case 'reminder_settings':
              ReminderRepository.validateRemoteSettings(payload);
              final productId = _string(payload, 'product_id');
              if (!reminderTargets.add(productId)) {
                throw const FormatException('reminder_settings snapshot contains duplicate active policies');
              }
              if (productId != null && !productIds.contains(productId) &&
                  await _inventory.getProductRecord(productId) == null) {
                throw const FormatException('reminder_settings snapshot references an unknown product');
              }
              break;
          }
        }
        plan.add(NasSyncPullChange(
          changeId: 'bootstrap:$entity:$entityId:$version',
          cursor: serverCursor,
          operation: deletedAt == null ? 'entity_upsert' : 'entity_delete',
          entity: entity,
          entityId: entityId,
          version: version,
          payload: payload,
          clientUpdatedAt: updatedAt.toIso8601String(),
        ));
      }
    }
    // A replacement policy may sort before its predecessor's tombstone in
    // the wire snapshot. Remove old policies first, without changing the
    // dependency order of other entities or weakening duplicate validation.
    final orderedPlan = <NasSyncPullChange>[
      for (final change in plan)
        if (change.entity != 'reminder_settings' || change.operation == 'entity_delete')
          change,
      for (final change in plan)
        if (change.entity == 'reminder_settings' && change.operation == 'entity_upsert')
          change,
    ];
    await _assertSnapshotScopeQuiescent();
    await _outbox.transaction(() async {
      // A local mutation can commit between preflight and acquiring the write
      // transaction. Recheck before the first row and before completion.
      await _assertSnapshotScopeQuiescent();
      // Only this quiescent, atomic snapshot path may replace equal-version
      // optimistic data/tombstones. Incremental handlers retain their defaults.
      for (final change in orderedPlan) {
        if (change.entity == 'product_batches' && change.operation == 'entity_upsert') {
          await _inventory.applyRemoteProductBatch(
            batchId: change.entityId!,
            payload: change.payload!,
            version: change.version!,
            updatedAt: _updatedAt(change, change.payload!),
            updatedByDevice: _string(change.payload!, 'updated_by_device'),
            applyQuantity: true,
            authoritativeSnapshot: true,
          );
        } else if (change.operation == 'entity_delete') {
          await _applyEntityDelete(
            change, change.payload!, _updatedAt(change, change.payload!),
            authoritativeSnapshot: true,
          );
        } else {
          await _applyEntityUpsert(
            change, change.payload!, _updatedAt(change, change.payload!),
            authoritativeSnapshot: true,
          );
        }
      }
      await _assertSnapshotScopeQuiescent();
      if (onApplied != null) await onApplied();
      await _assertSnapshotScopeQuiescent();
    });
  }

  Future<void> _assertSnapshotScopeQuiescent() async {
    if (await _outbox.hasSnapshotBlockingChanges(scopeId: _scopeId)) {
      throw const SyncRemoteChangeDeferred(
        'snapshot waits for pending, in-flight, blocked or unresolved local operations',
      );
    }
  }

  void _validateSnapshotFields(Map<String, dynamic> payload) {
    for (final key in [
      'created_at', 'updated_at', 'deleted_at', 'produced_date',
      'production_date', 'expiry_date', 'opened_date', 'checked_at',
    ]) {
      if (payload.containsKey(key)) _date(payload, key);
    }
    for (final key in [
      'quantity', 'current_quantity', 'remaining_quantity', 'initial_quantity',
      'expiry_warning_days', 'opened_warning_days', 'sort_order',
    ]) {
      if (payload[key] == null) continue;
      final value = _integer(payload, [key])!;
      if (value < 0) throw FormatException('$key must be non-negative');
    }
    for (final key in ['low_stock_threshold', 'desired_quantity']) {
      if (payload[key] == null) continue;
      if (_integer(payload, [key])! < 1) throw FormatException('$key must be positive');
    }
    for (final key in ['enabled', 'checked', 'is_opened', 'is_discarded']) {
      if (payload.containsKey(key) && payload[key] is! bool) {
        throw FormatException('$key must be a boolean');
      }
    }
  }

  void _validateCategory(Map<String, dynamic> payload) {
    if (_string(payload, 'name') == null) {
      throw const FormatException('categories.name must be a non-empty string');
    }
    if (payload['color'] != null || (payload['sort_order'] ?? 0) != 0) {
      throw const FormatException('unsupported categories color/sort_order: local categories are strings only');
    }
  }

  Future<Map<String, dynamic>> _productPayload(
    Map<String, dynamic> payload, {
    Map<String, String> snapshotCategoryNames = const {},
  }) async {
    if (!payload.containsKey('category_id')) return payload;
    final rawId = payload['category_id'];
    if (rawId == null) {
      return {...payload, 'category': _string(payload, 'category') ?? '其他'};
    }
    if (rawId is! String || rawId.trim().isEmpty) {
      throw const FormatException('products.category_id must be a non-empty string or null');
    }
    final categoryId = rawId.trim();
    String? name = snapshotCategoryNames[categoryId];
    if (name == null) {
      final record = await _outbox.getRemoteAuxiliaryEntity(
        scopeId: _scopeId,
        entity: 'categories',
        entityId: categoryId,
      );
      if (record != null && record['deleted_at'] != null) {
        throw const FormatException('products.category_id references a deleted category');
      }
      if (record != null) {
        name = _string(Map<String, dynamic>.from(record['payload'] as Map), 'name');
      }
    }
    if (name == null) {
      throw const FormatException('products.category_id references an unknown category');
    }
    return {...payload, 'category': name};
  }

  Future<void> _applyAuxiliary(
    NasSyncPullChange change,
    Map<String, dynamic> payload,
    DateTime updatedAt, {
    required bool deleted,
  }) async {
    final entity = change.entity;
    final entityId = _requiredEntityId(change);
    if (entity == 'reminder_settings' && !deleted) {
      // Preserve the conflict record when a pending product edit blocks a
      // policy; writing it in the transaction that throws would roll it back.
      final previous = await _outbox.getRemoteAuxiliaryEntity(
        scopeId: _scopeId,
        entity: entity,
        entityId: entityId,
      );
      await _protectReminderProduct(change, {
        if (previous?['payload'] is Map)
          ...Map<String, dynamic>.from(previous!['payload'] as Map),
        ...payload,
      });
    }
    await _outbox.transaction(() async {
      final previous = await _outbox.getRemoteAuxiliaryEntity(
        scopeId: _scopeId,
        entity: entity,
        entityId: entityId,
      );
      final previousVersion = previous?['version'];
      final version = change.version ?? 0;
      if (previousVersion is num && version > 0 &&
          (previousVersion > version ||
              (previousVersion == version && previous?['business_applied'] == true))) {
        return;
      }
      final merged = <String, dynamic>{
        if (previous?['payload'] is Map)
          ...Map<String, dynamic>.from(previous!['payload'] as Map),
        ...payload,
      };
      final deletedAt = deleted ? (_date(payload, 'deleted_at') ?? updatedAt) : null;
      if (entity == 'categories') {
        if (!deleted) {
          _validateCategory(merged);
          await _inventory.applyRemoteCategoryName(
            scopeId: _scopeId,
            categoryId: entityId,
            name: _string(merged, 'name')!,
          );
        }
      } else {
        if (!deleted) {
          ReminderRepository.validateRemoteSettings(merged);
          final productId = _string(merged, 'product_id');
          if (productId != null && await _inventory.getProductRecord(productId) == null) {
            throw const FormatException('reminder_settings references an unknown product');
          }
        }
        await ReminderRepository(_outbox.database).applyRemoteSettings(
          scopeId: _scopeId,
          entityId: entityId,
          payload: merged,
          updatedAt: updatedAt,
          deleted: deleted,
        );
      }
      await _outbox.applyRemoteAuxiliaryEntity(
        scopeId: _scopeId,
        entity: entity,
        entityId: entityId,
        payload: merged,
        version: version,
        updatedAt: updatedAt,
        deletedAt: deletedAt,
        businessApplied: true,
      );
    });
  }

  Future<void> _protectReminderProduct(
    NasSyncPullChange change,
    Map<String, dynamic> payload,
  ) async {
    if (_inventory.syncScopeId != _scopeId) {
      throw const FormatException('unsupported reminder_settings: inventory repository must consume the same sync scope');
    }
    final productId = _string(payload, 'product_id');
    if (productId == null) return;
    await _protectPendingLocalChange(
      change: NasSyncPullChange(
        changeId: change.changeId,
        cursor: change.cursor,
        operation: change.operation,
        entity: 'products',
        entityId: productId,
        version: change.version,
        payload: payload,
      ),
      entityId: productId,
      serverPayload: payload,
    );
  }

  Future<void> applyRemoteChange(NasSyncPullChange change) async {
    if (change.changeId.trim().isEmpty) {
      throw const FormatException('pull change_id is required');
    }
    if (change.version != null && change.version! < 0) {
      throw const FormatException('pull version must be non-negative');
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
    DateTime updatedAt, {
    bool authoritativeSnapshot = false,
  }) async {
    final entityId = _requiredEntityId(change);
    await _protectPendingLocalChange(
      change: change,
      entityId: entityId,
      serverPayload: payload,
    );

    switch (change.entity) {
      case 'categories':
      case 'reminder_settings':
        await _applyAuxiliary(change, payload, updatedAt, deleted: false);
        return;
      case 'products':
        await _outbox.transaction(() async {
          final existing = await _inventory.getProductRecord(entityId);
          final version = change.version ?? 0;
          if (existing != null && version > 0 &&
              (existing.serverVersion > version ||
                  (!authoritativeSnapshot && existing.serverVersion == version))) {
            return;
          }
          final mapped = await _productPayload(payload);
          final status = await _inventory.applyRemoteProduct(
            productId: entityId,
            payload: mapped,
            version: version,
            updatedAt: updatedAt,
            updatedByDevice: _string(payload, 'updated_by_device'),
            deletedAt: _date(payload, 'deleted_at'),
            authoritativeSnapshot: authoritativeSnapshot,
          );
          if (status == SyncRemoteApplyStatus.applied &&
              (payload.containsKey('category_id') ||
                  payload.containsKey('category') ||
                  payload.containsKey('category_name'))) {
            await _inventory.bindRemoteProductCategory(
              scopeId: _scopeId,
              productId: entityId,
              categoryId: _string(payload, 'category_id'),
              updatedAt: updatedAt,
            );
          }
        });
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
          authoritativeSnapshot: authoritativeSnapshot,
        );
        return;
      default:
        throw FormatException('unsupported pull entity: ${change.entity}');
    }
  }

  Future<void> _applyEntityDelete(
    NasSyncPullChange change,
    Map<String, dynamic> payload,
    DateTime updatedAt, {
    bool authoritativeSnapshot = false,
  }) async {
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
      case 'categories':
      case 'reminder_settings':
        await _applyAuxiliary(change, payload, updatedAt, deleted: true);
        return;
      case 'products':
        await _inventory.applyRemoteProductDelete(
          productId: entityId,
          version: version,
          deletedAt: deletedAt,
          updatedByDevice: updatedByDevice,
          authoritativeSnapshot: authoritativeSnapshot,
        );
        return;
      case 'product_batches':
        await _inventory.applyRemoteProductBatchDelete(
          batchId: entityId,
          version: version,
          deletedAt: deletedAt,
          updatedByDevice: updatedByDevice,
          authoritativeSnapshot: authoritativeSnapshot,
        );
        return;
      case 'shopping_items':
        await _shopping.applyRemoteShoppingEntryDelete(
          entryId: entityId,
          version: version,
          deletedAt: deletedAt,
          updatedByDevice: updatedByDevice,
          authoritativeSnapshot: authoritativeSnapshot,
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
    if (!const {'restock', 'consume_fefo', 'consume_allocated', 'discard'}.contains(command)) {
      throw FormatException('unsupported inventory command result: $command');
    }
    if (change.cursor < 0) {
      throw const FormatException('inventory_command cursor must be non-negative');
    }
    if (await _outbox.hasAppliedChange(scopeId: _scopeId, changeId: change.changeId)) {
      return;
    }
    final allocations = _allocations(resultPayload['allocations']);
    if (allocations.isEmpty) {
      throw const FormatException('inventory_command result requires allocations');
    }

    // Validate every allocation before any write, and persist a deferred
    // conflict outside the write transaction so rollback cannot erase it.
    await _validateInventoryAllocations(allocations);
    Future<void> protectPendingChanges() async {
      for (final allocation in allocations) {
        await _protectPendingLocalChange(
          change: change,
          entityId: allocation.batchId,
          serverPayload: resultPayload,
          inventoryCommand: true,
        );
      }
    }
    await protectPendingChanges();

    try {
      await _outbox.transaction(() async {
        // Another invocation/local edit may have committed after preflight.
        if (await _outbox.hasAppliedChange(scopeId: _scopeId, changeId: change.changeId)) {
          return;
        }
        final productIds = await _validateInventoryAllocations(allocations);
        await protectPendingChanges();
        for (final allocation in allocations) {
          await _inventory.applyRemoteProductBatch(
            batchId: allocation.batchId,
            payload: {
              'product_id': productIds[allocation.batchId]!,
              'quantity': allocation.afterQuantity!,
              'command': command,
              'operation_id': _string(resultPayload, 'operation_id'),
              'allocations': [allocation.toJson()],
            },
            // The envelope version belongs to the primary batch only.
            version: allocation.afterVersion!,
            updatedAt: updatedAt,
            updatedByDevice: _string(resultPayload, 'updated_by_device'),
            applyQuantity: true,
          );
        }
        // Includes the safe cursor. Inventory, restock initial quantities and
        // the receipt commit together, including direct adapter invocations.
        // The engine observes this receipt instead of writing it a second time.
        await _outbox.recordAppliedChange(
          scopeId: _scopeId,
          changeId: change.changeId,
          cursor: change.cursor,
        );
      });
    } on SyncRemoteChangeDeferred {
      // The transaction recheck can discover a newly pending local command.
      // Recreate its conflict only after the business transaction rolled back.
      await protectPendingChanges();
      rethrow;
    }
  }

  Future<Map<String, String>> _validateInventoryAllocations(
    List<NasSyncInventoryAllocation> allocations,
  ) async {
    final productIds = <String, String>{};
    for (final allocation in allocations) {
      if (allocation.batchId.trim().isEmpty || productIds.containsKey(allocation.batchId)) {
        throw const FormatException('inventory_command result contains empty or duplicate batch_id');
      }
      if (allocation.quantity <= 0) {
        throw const FormatException('inventory_command allocation quantity must be positive');
      }
      final quantity = allocation.afterQuantity;
      final version = allocation.afterVersion;
      if (quantity == null || quantity < 0 || version == null || version < 1) {
        throw const FormatException(
          'inventory_command allocation requires non-negative afterQuantity and positive afterVersion',
        );
      }
      final existing = await _inventory.getBatchRecord(allocation.batchId);
      if (existing == null) {
        throw FormatException(
          'inventory_command result references an unknown local batch: ${allocation.batchId}',
        );
      }
      productIds[allocation.batchId] = existing.productId;
    }
    return productIds;
  }

  Future<void> _protectPendingLocalChange({
    required NasSyncPullChange change,
    required String entityId,
    required Map<String, dynamic> serverPayload,
    bool inventoryCommand = false,
  }) async {
    final candidates = inventoryCommand
        ? await _outbox.listForOperation(
            scopeId: _scopeId,
            operation: SyncOperation.inventoryCommand,
            includeTerminal: true,
          )
        : await _outbox.listForEntity(
            scopeId: _scopeId,
            entity: change.entity,
            entityId: entityId,
            includeTerminal: true,
          );
    // Dependency-blocked rows are still unsent local edits. Repository default
    // queries omit them, but that must not let a remote result overwrite them.
    final pending = candidates
        .where((entry) =>
            entry.status == SyncOutboxStatus.pending ||
            entry.status == SyncOutboxStatus.inFlight ||
            entry.status == SyncOutboxStatus.blocked)
        .toList(growable: false);
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
    for (final key in ['updated_at', 'created_at']) {
      if (!payload.containsKey(key)) continue;
      final parsed = _date(payload, key);
      if (parsed == null) throw FormatException('$key must be a timestamp');
      return parsed;
    }
    return DateTime.now().toUtc();
  }

  DateTime _updatedAt(NasSyncPullChange change, Map<String, dynamic> payload) {
    if (change.clientUpdatedAt != null) {
      return _date({'client_updated_at': change.clientUpdatedAt}, 'client_updated_at')!;
    }
    return _updatedAtFromPayload(payload);
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
    if (value is! String) throw FormatException('$key must be an ISO date/timestamp');
    final parts = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2})(?:T\d{2}:\d{2}:\d{2}(?:\.\d+)?(?:Z|[+-]\d{2}:?\d{2})?)?$',
    ).firstMatch(value);
    final parsed = DateTime.tryParse(value);
    if (parts == null || parsed == null) {
      throw FormatException('$key must be an ISO date/timestamp');
    }
    final year = int.parse(parts[1]!);
    final month = int.parse(parts[2]!);
    final day = int.parse(parts[3]!);
    final calendarDate = DateTime.utc(year, month, day);
    if (calendarDate.year != year || calendarDate.month != month || calendarDate.day != day) {
      throw FormatException('$key has an invalid calendar date');
    }
    // DateTime.tryParse normalizes overflowing clock values; reject those too.
    if (value.length > 10) {
      final hour = int.parse(value.substring(11, 13));
      final minute = int.parse(value.substring(14, 16));
      final second = int.parse(value.substring(17, 19));
      if (hour > 23 || minute > 59 || second > 59) {
        throw FormatException('$key has an invalid clock time');
      }
    }
    return parsed.toUtc();
  }

  int? _integer(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value is int) return value;
      if (value is num && value.isFinite && value == value.toInt()) return value.toInt();
      throw FormatException('$key must be an integer');
    }
    return null;
  }

  List<NasSyncInventoryAllocation> _allocations(Object? raw) {
    if (raw is! List) {
      throw const FormatException('inventory_command allocations must be an array');
    }
    return raw.map((item) {
      if (item is! Map || item.keys.any((key) => key is! String)) {
        throw const FormatException('inventory_command allocation must be an object');
      }
      final payload = Map<String, dynamic>.from(item);
      final batchId = _string(payload, 'batch_id');
      final quantity = _integer(payload, const ['quantity']);
      if (batchId == null || quantity == null) {
        throw const FormatException('inventory_command allocation requires batch_id and quantity');
      }
      // The backend emits final_quantity/after_version. Retain supported wire
      // aliases, but never fall back past an explicitly malformed numeric field.
      return NasSyncInventoryAllocation(
        batchId: batchId,
        quantity: quantity,
        afterQuantity: _integer(
          payload, const ['after_quantity', 'final_quantity', 'remaining_quantity'],
        ),
        afterVersion: _integer(payload, const ['after_version', 'version']),
      );
    }).toList(growable: false);
  }
}
