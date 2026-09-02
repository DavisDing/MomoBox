import '../models/inventory_models.dart';
import 'expiry_rules.dart';

class BatchConsumption {
  static void validate(
    InventoryBatch batch,
    int quantity, {
    DateTime? today,
  }) {
    if (quantity < 1) {
      throw ArgumentError.value(quantity, 'quantity', '消耗数量必须大于 0');
    }
    if (batch.isDiscarded) {
      throw StateError('已报废批次不能消耗。');
    }
    if (batch.remainingQuantity < 1) {
      throw StateError('当前批次没有可消耗库存。');
    }
    if (ExpiryRules.statusFor(batch.expiryDate, today: today) ==
        ExpiryStatus.expired) {
      throw StateError('已过期批次不能消耗。');
    }
    if (batch.remainingQuantity < quantity) {
      throw StateError('当前批次库存不足，不能产生负库存。');
    }
  }
}
