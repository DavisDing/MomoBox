import '../models/inventory_models.dart';
import 'expiry_rules.dart';

class BatchAllocation {
  const BatchAllocation(this.batchId, this.quantity);

  final String batchId;
  final int quantity;
}

class Fefo {
  static List<BatchAllocation> allocate(
    List<InventoryBatch> batches,
    int requestedQuantity, {
    DateTime? today,
  }) {
    if (requestedQuantity < 1) {
      throw ArgumentError.value(requestedQuantity, 'requestedQuantity', '数量必须大于 0');
    }

    final eligible = batches
        .where(
          (batch) =>
              batch.isAvailable &&
              ExpiryRules.statusFor(batch.expiryDate, today: today) !=
                  ExpiryStatus.expired,
        )
        .toList()
      ..sort((left, right) {
        final leftDate = left.expiryDate;
        final rightDate = right.expiryDate;
        if (leftDate == null && rightDate == null) return left.id.compareTo(right.id);
        if (leftDate == null) return 1;
        if (rightDate == null) return -1;
        return leftDate.compareTo(rightDate);
      });

    final available = eligible.fold<int>(0, (sum, batch) => sum + batch.remainingQuantity);
    if (available < requestedQuantity) {
      throw StateError('可消耗库存不足，不能产生负库存。');
    }

    var remaining = requestedQuantity;
    final allocations = <BatchAllocation>[];
    for (final batch in eligible) {
      if (remaining == 0) break;
      final quantity = remaining < batch.remainingQuantity
          ? remaining
          : batch.remainingQuantity;
      allocations.add(BatchAllocation(batch.id, quantity));
      remaining -= quantity;
    }
    return allocations;
  }
}
