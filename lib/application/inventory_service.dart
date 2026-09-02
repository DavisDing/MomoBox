import '../data/repositories/inventory_repository.dart';
import '../domain/inventory/expiry_rules.dart';
import '../domain/models/inventory_models.dart';

class InventoryService {
  InventoryService(this._repository);

  final InventoryRepository _repository;

  Future<String> intake(IntakeDraft draft) {
    _validateDraft(draft);
    final expiryDate = draft.expiryDate ??
        (draft.productionDate != null && draft.shelfLifeAmount != null
            ? ExpiryRules.calculateExpiry(
                startDate: draft.productionDate!,
                amount: draft.shelfLifeAmount!,
                unit: draft.shelfLifeUnit,
              )
            : null);
    return _repository.createProductWithBatch(
      IntakeDraft(
        name: draft.name,
        category: draft.category,
        quantity: draft.quantity,
        brand: draft.brand,
        specification: draft.specification,
        barcode: draft.barcode,
        location: draft.location,
        unit: draft.unit,
        lowStockThreshold: draft.lowStockThreshold,
        batchNo: draft.batchNo,
        productionDate: draft.productionDate,
        expiryDate: expiryDate,
        shelfLifeAmount: draft.shelfLifeAmount,
        shelfLifeUnit: draft.shelfLifeUnit,
      ),
    );
  }

  Future<void> consume(String productId, int quantity) {
    if (quantity < 1) throw ArgumentError('消耗数量必须为大于 0 的整数。');
    return _repository.consumeByFefo(productId, quantity);
  }

  Future<void> replenishBatch(String batchId, int quantity) {
    if (quantity < 1) throw ArgumentError('补充数量必须为大于 0 的整数。');
    return _repository.replenishBatch(batchId, quantity);
  }

  Future<void> discardBatch(String batchId) => _repository.discardBatch(batchId);

  void _validateDraft(IntakeDraft draft) {
    if (draft.name.trim().isEmpty) throw ArgumentError('请填写物品名称。');
    if (draft.quantity < 1) throw ArgumentError('数量必须为大于 0 的整数。');
    if (draft.lowStockThreshold < 1) {
      throw ArgumentError('低库存阈值必须为大于 0 的整数。');
    }
    if (draft.shelfLifeAmount != null && draft.shelfLifeAmount! < 1) {
      throw ArgumentError('保质期必须为大于 0 的整数。');
    }
    if (draft.productionDate != null && draft.expiryDate != null &&
        draft.expiryDate!.isBefore(draft.productionDate!)) {
      throw ArgumentError('到期日期不能早于生产日期。');
    }
  }
}
