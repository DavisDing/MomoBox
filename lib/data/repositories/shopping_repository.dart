import 'package:drift/drift.dart';
import 'package:uuid/uuid.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/inventory_models.dart';

class ShoppingRepository {
  ShoppingRepository(this._database, {Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final AppDatabase _database;
  final Uuid _uuid;

  Stream<List<ShoppingEntry>> watchEntries() {
    return (_database.select(_database.shoppingEntries)
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
            ..where((entry) => entry.isCompleted.equals(false)))
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
        await (_database.update(_database.shoppingEntries)
              ..where((entry) => entry.id.equals(candidate.id)))
            .write(
          ShoppingEntriesCompanion(
            targetQuantity: Value(candidate.targetQuantity + targetQuantity),
            updatedAt: Value(now),
          ),
        );
        return;
      }

      await _database.into(_database.shoppingEntries).insert(
            ShoppingEntriesCompanion.insert(
              id: _uuid.v4(),
              productId: Value(productId),
              itemName: itemName.trim(),
              category: Value(category),
              targetQuantity: Value(targetQuantity),
              reason: Value(reason),
              createdAt: now,
              updatedAt: now,
            ),
          );
    });
  }

  Future<void> setCompleted(String id, bool completed) async {
    await (_database.update(_database.shoppingEntries)
          ..where((entry) => entry.id.equals(id)))
        .write(
      ShoppingEntriesCompanion(
        isCompleted: Value(completed),
        updatedAt: Value(DateTime.now()),
      ),
    );
  }

  Future<void> delete(String id) async {
    await (_database.delete(_database.shoppingEntries)
          ..where((entry) => entry.id.equals(id)))
        .go();
  }
}
