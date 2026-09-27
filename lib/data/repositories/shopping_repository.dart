import 'dart:convert';

import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/sync_models.dart';
import 'sync_outbox_repository.dart';

class ShoppingRepository {
  ShoppingRepository(
    this._database, {
    Uuid? uuid,
    SyncOutboxRepository? outbox,
    String? syncScopeId,
  })  : _uuid = uuid ?? const Uuid(),
        _outbox = outbox,
        _syncScopeId = syncScopeId;

  final AppDatabase _database;
  final Uuid _uuid;
  final SyncOutboxRepository? _outbox;
  final String? _syncScopeId;

  Stream<List<ShoppingEntry>> watchEntries() {
    return (_database.select(_database.shoppingEntries)
          ..where((entry) => entry.deletedAt.isNull())
          ..orderBy([
            (entry) => OrderingTerm.asc(entry.isCompleted),
            (entry) => OrderingTerm.desc(entry.updatedAt),
          ]))
        .watch()
        .map(
          (entries) => entries
              .map(
                (entry) => ShoppingEntry(
                  id: entry.id,
                  productId: entry.productId,
                  itemName: entry.itemName,
                  category: entry.category,
                  targetQuantity: entry.targetQuantity,
                  reason: entry.reason,
                  isCompleted: entry.isCompleted,
                ),
              )
              .toList(growable: false),
        );
  }

  /// Returns the persisted entry, including a soft-deleted row.
  Future<ShoppingEntryRecord?> getEntryRecord(String entryId) {
    return (_database.select(_database.shoppingEntries)
          ..where((entry) => entry.id.equals(entryId)))
        .getSingleOrNull();
  }

  Future<void> addOrMerge({
    required String itemName,
    required int targetQuantity,
    required String reason,
    String? productId,
    String? category,
  }) async {
    if (itemName.trim().isEmpty) throw ArgumentError('请填写采购物品名称。');
    if (targetQuantity < 1) throw ArgumentError('采购数量必须大于 0。');

    final now = DateTime.now();
    await _database.transaction(() async {
      final existing = await (_database.select(_database.shoppingEntries)
            ..where((entry) =>
                entry.isCompleted.equals(false) & entry.deletedAt.isNull()))
          .get();
      final normalizedName = itemName.trim().toLowerCase();
      final candidate = existing.cast<ShoppingEntryRecord?>().firstWhere(
            (entry) =>
                entry != null &&
                ((productId != null && entry.productId == productId) ||
                    (productId == null &&
                        entry.productId == null &&
                        entry.itemName.trim().toLowerCase() == normalizedName)),
            orElse: () => null,
          );
      if (candidate != null) {
        final nextQuantity = candidate.targetQuantity + targetQuantity;
        await (_database.update(_database.shoppingEntries)
              ..where((entry) => entry.id.equals(candidate.id)))
            .write(
          ShoppingEntriesCompanion(
            targetQuantity: Value(nextQuantity),
            updatedAt: Value(now),
          ),
        );
        await _enqueueEntityUpsert(
          entryId: candidate.id,
          baseVersion: candidate.serverVersion,
          payload: _entryPayload(
            productId: candidate.productId ?? productId,
            itemName: candidate.itemName,
            targetQuantity: nextQuantity,
            completed: candidate.isCompleted,
            reason: candidate.reason,
          ),
          now: now,
        );
        return;
      }

      final entryId = _uuid.v4();
      await _database.into(_database.shoppingEntries).insert(
            ShoppingEntriesCompanion.insert(
              id: entryId,
              productId: Value(productId),
              itemName: itemName.trim(),
              category: Value(category),
              targetQuantity: Value(targetQuantity),
              reason: Value(reason),
              createdAt: now,
              updatedAt: now,
            ),
          );
      await _enqueueEntityUpsert(
        entryId: entryId,
        baseVersion: 0,
        payload: _entryPayload(
          productId: productId,
          itemName: itemName.trim(),
          targetQuantity: targetQuantity,
          completed: false,
          reason: reason,
        ),
        now: now,
      );
    });
  }

  Future<void> setCompleted(String id, bool completed) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final existing = await (_database.select(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) throw StateError('找不到采购项。');
      await (_database.update(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(id)))
          .write(
        ShoppingEntriesCompanion(
          isCompleted: Value(completed),
          updatedAt: Value(now),
        ),
      );
      await _enqueueEntityUpsert(
        entryId: id,
        baseVersion: existing.serverVersion,
        payload: _entryPayload(
          productId: existing.productId,
          itemName: existing.itemName,
          targetQuantity: existing.targetQuantity,
          completed: completed,
          reason: existing.reason,
        ),
        now: now,
      );
    });
  }

  Future<SyncRemoteApplyStatus> applyRemoteShoppingEntry({
    required String entryId,
    required Map<String, dynamic> payload,
    required int version,
    required DateTime updatedAt,
    String? updatedByDevice,
    DateTime? deletedAt,
  }) async {
    final now = updatedAt.toUtc();
    return _database.transaction(() async {
      final existing = await (_database.select(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(entryId)))
          .getSingleOrNull();
      if (_isStale(existing?.serverVersion, version)) {
        return SyncRemoteApplyStatus.ignoredStale;
      }
      if (_isSameVersion(existing?.serverVersion, version)) {
        return SyncRemoteApplyStatus.alreadyApplied;
      }

      final name = _firstString(payload, const ['name', 'item_name', 'itemName']);
      final productId = _nullableString(payload, const ['product_id', 'productId']);
      final category = _nullableString(payload, const ['category']);
      final quantity = _intValue(payload, const ['desired_quantity', 'target_quantity', 'targetQuantity']);
      final checked = _boolValue(payload, const ['checked', 'is_completed', 'isCompleted']);
      final reason = _firstString(payload, const ['reason', 'notes']) ?? existing?.reason ?? '手动添加';

      if (existing == null && name == null) {
        throw const FormatException('shopping_items upsert requires name for a new local entry');
      }
      final targetQuantity = quantity ?? existing?.targetQuantity ?? 1;
      if (targetQuantity < 1) {
        throw const FormatException('shopping_items.desired_quantity must be positive');
      }

      if (existing == null) {
        await _database.into(_database.shoppingEntries).insert(
              ShoppingEntriesCompanion.insert(
                id: entryId,
                productId: Value(productId),
                itemName: name!,
                category: Value(category),
                targetQuantity: Value(targetQuantity),
                reason: Value(reason),
                isCompleted: Value(checked ?? false),
                createdAt: now,
                updatedAt: now,
                serverVersion: Value(version),
                deletedAt: Value(deletedAt),
                updatedByDevice: Value(updatedByDevice),
              ),
            );
      } else {
        await (_database.update(_database.shoppingEntries)
              ..where((entry) => entry.id.equals(entryId)))
            .write(
          ShoppingEntriesCompanion(
            productId: productId == null ? const Value.absent() : Value(productId),
            itemName: name == null ? const Value.absent() : Value(name),
            category: _nullableCompanion(payload, 'category'),
            targetQuantity: quantity == null ? const Value.absent() : Value(quantity),
            reason: _stringCompanion(payload, 'reason', fallbackKey: 'notes'),
            isCompleted: checked == null ? const Value.absent() : Value(checked),
            updatedAt: Value(now),
            serverVersion: Value(version),
            deletedAt: Value(deletedAt),
            updatedByDevice: Value(updatedByDevice),
          ),
        );
      }
      return SyncRemoteApplyStatus.applied;
    });
  }

  Future<SyncRemoteApplyStatus> applyRemoteShoppingEntryDelete({
    required String entryId,
    required int version,
    required DateTime deletedAt,
    String? updatedByDevice,
  }) async {
    return _database.transaction(() async {
      final existing = await (_database.select(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(entryId)))
          .getSingleOrNull();
      if (existing == null) return SyncRemoteApplyStatus.alreadyApplied;
      if (_isStale(existing.serverVersion, version)) {
        return SyncRemoteApplyStatus.ignoredStale;
      }
      if (_isSameVersion(existing.serverVersion, version)) {
        return SyncRemoteApplyStatus.alreadyApplied;
      }
      await (_database.update(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(entryId)))
          .write(
        ShoppingEntriesCompanion(
          deletedAt: Value(deletedAt.toUtc()),
          serverVersion: Value(version),
          updatedAt: Value(deletedAt.toUtc()),
          updatedByDevice: Value(updatedByDevice),
        ),
      );
      return SyncRemoteApplyStatus.applied;
    });
  }

  bool _isStale(int? localVersion, int remoteVersion) =>
      remoteVersion > 0 && localVersion != null && localVersion > remoteVersion;

  bool _isSameVersion(int? localVersion, int remoteVersion) =>
      remoteVersion > 0 && localVersion != null && localVersion == remoteVersion;

  String? _firstString(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      final value = payload[key];
      if (value is String && value.trim().isNotEmpty) return value.trim();
    }
    return null;
  }

  String? _nullableString(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value == null) return null;
      if (value is String) return value.trim().isEmpty ? null : value.trim();
      throw FormatException('$key must be a string or null');
    }
    return null;
  }

  Value<String?> _nullableCompanion(Map<String, dynamic> payload, String key) {
    if (!payload.containsKey(key)) return const Value.absent();
    return Value(_nullableString(payload, [key]));
  }

  Value<String> _stringCompanion(Map<String, dynamic> payload, String key, {String? fallbackKey}) {
    final selected = payload.containsKey(key)
        ? key
        : fallbackKey != null && payload.containsKey(fallbackKey)
            ? fallbackKey
            : null;
    if (selected == null) return const Value.absent();
    final value = _firstString(payload, [selected]);
    return value == null ? const Value.absent() : Value(value);
  }

  int? _intValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value is int) return value;
      if (value is num && value == value.toInt()) return value.toInt();
      throw FormatException('$key must be an integer');
    }
    return null;
  }

  bool? _boolValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value is bool) return value;
      throw FormatException('$key must be a boolean');
    }
    return null;
  }

  DateTime? _dateValue(Map<String, dynamic> payload, List<String> keys) {
    for (final key in keys) {
      if (!payload.containsKey(key)) continue;
      final value = payload[key];
      if (value == null) return null;
      if (value is String) return DateTime.parse(value).toUtc();
      throw FormatException('$key must be an RFC3339 date or null');
    }
    return null;
  }

  Future<void> delete(String id) async {
    final now = DateTime.now();
    await _database.transaction(() async {
      final existing = await (_database.select(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(id)))
          .getSingleOrNull();
      if (existing == null) return;
      await (_database.update(_database.shoppingEntries)
            ..where((entry) => entry.id.equals(id)))
          .write(
        ShoppingEntriesCompanion(
          deletedAt: Value(now),
          updatedAt: Value(now),
        ),
      );
      await _enqueueEntityDelete(
        entryId: id,
        baseVersion: existing.serverVersion,
        now: now,
      );
    });
  }

  Future<void> _enqueueEntityUpsert({
    required String entryId,
    required int baseVersion,
    required Map<String, dynamic> payload,
    required DateTime now,
  }) async {
    final scopeId = _syncScopeId;
    final outbox = _outbox;
    if (scopeId == null || scopeId.trim().isEmpty || outbox == null) return;
    final changeId = _uuid.v4();
    final idempotencyKey = '$scopeId:$changeId';
    await outbox.enqueueInCurrentTransaction(
      SyncOutboxDraft(
        changeId: changeId,
        scopeId: scopeId,
        operation: SyncOperation.entityUpsert,
        entity: 'shopping_items',
        entityId: entryId,
        baseVersion: baseVersion,
        idempotencyKey: idempotencyKey,
        requestJson: jsonEncode({
          'change_id': changeId,
          'operation': SyncOperation.entityUpsert.wireValue,
          'entity': 'shopping_items',
          'entity_id': entryId,
          'base_version': baseVersion,
          'payload': payload,
          'idempotency_key': idempotencyKey,
          'client_updated_at': now.toUtc().toIso8601String(),
        }),
        createdAt: now.toUtc(),
      ),
    );
  }

  Future<void> _enqueueEntityDelete({
    required String entryId,
    required int baseVersion,
    required DateTime now,
  }) async {
    final scopeId = _syncScopeId;
    final outbox = _outbox;
    if (scopeId == null || scopeId.trim().isEmpty || outbox == null) return;
    final changeId = _uuid.v4();
    final idempotencyKey = '$scopeId:$changeId';
    await outbox.enqueueInCurrentTransaction(
      SyncOutboxDraft(
        changeId: changeId,
        scopeId: scopeId,
        operation: SyncOperation.entityDelete,
        entity: 'shopping_items',
        entityId: entryId,
        baseVersion: baseVersion,
        idempotencyKey: idempotencyKey,
        requestJson: jsonEncode({
          'change_id': changeId,
          'operation': SyncOperation.entityDelete.wireValue,
          'entity': 'shopping_items',
          'entity_id': entryId,
          'base_version': baseVersion,
          'idempotency_key': idempotencyKey,
          'client_updated_at': now.toUtc().toIso8601String(),
        }),
        createdAt: now.toUtc(),
      ),
    );
  }

  Map<String, dynamic> _entryPayload({
    required String? productId,
    required String itemName,
    required int targetQuantity,
    required bool completed,
    required String reason,
  }) {
    return <String, dynamic>{
      if (productId != null) 'product_id': productId,
      'name': itemName,
      'desired_quantity': targetQuantity,
      'checked': completed,
      'notes': reason,
    };
  }
}
