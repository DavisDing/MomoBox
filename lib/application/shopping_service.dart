import '../data/repositories/shopping_repository.dart';
import '../data/repositories/inventory_repository.dart';
import 'inventory_service.dart';
import '../domain/models/inventory_models.dart';

class ShoppingService {
  ShoppingService(this._repository, {InventoryRepository? inventory})
      : _inventory = inventory {
    if (inventory != null && !identical(inventory.database, _repository.database)) {
      throw ArgumentError('采购入库必须使用同一数据库事务。');
    }
  }

  final ShoppingRepository _repository;
  final InventoryRepository? _inventory;

  Future<String> intakePurchasedEntry(
    ShoppingEntry entry,
    IntakeDraft draft, {
    String? mergeProductId,
  }) {
    final inventory = _inventory;
    if (inventory == null) throw StateError('采购入库服务尚未就绪。');
    return _repository.intakeAndDelete(
      expectedEntry: entry,
      intake: () => InventoryService(inventory).intake(draft, mergeProductId: mergeProductId),
    );
  }

  Stream<List<ShoppingEntry>> watchEntries() => _repository.watchEntries();

  Future<List<ShoppingEntry>> readEntries() => _repository.readEntries();

  Future<void> addOrMerge({
    required String itemName,
    required int targetQuantity,
    required String reason,
    String? productId,
    String? category,
  }) =>
      _repository.addOrMerge(
        itemName: itemName,
        targetQuantity: targetQuantity,
        reason: reason,
        productId: productId,
        category: category,
      );

  Future<void> setCompleted(String id, bool completed) =>
      _repository.setCompleted(id, completed);

  Future<void> delete(String id) => _repository.delete(id);
}
