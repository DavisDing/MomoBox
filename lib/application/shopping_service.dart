import '../data/repositories/shopping_repository.dart';
import '../domain/models/inventory_models.dart';

class ShoppingService {
  ShoppingService(this._repository);

  final ShoppingRepository _repository;

  Stream<List<ShoppingEntry>> watchEntries() => _repository.watchEntries();

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
