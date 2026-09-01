import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/fefo.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryBatch batch(String id, int quantity, DateTime? expiry) => InventoryBatch(
      id: id,
      productId: 'product',
      batchNo: id,
      initialQuantity: quantity,
      remainingQuantity: quantity,
      isDiscarded: false,
      expiryDate: expiry,
      productionDate: null,
    );

void main() {
  test('FEFO 优先消耗最早且未过期批次，无效期最后消耗', () {
    final allocations = Fefo.allocate(
      [
        batch('undated', 5, null),
        batch('later', 3, DateTime(2026, 10, 1)),
        batch('first', 2, DateTime(2026, 9, 2)),
      ],
      4,
      today: DateTime(2026, 9, 1),
    );
    expect(allocations.map((entry) => '${entry.batchId}:${entry.quantity}'), ['first:2', 'later:2']);
  });

  test('FEFO 拒绝过期批次和负库存', () {
    expect(
      () => Fefo.allocate([batch('expired', 2, DateTime(2026, 8, 31))], 1, today: DateTime(2026, 9, 1)),
      throwsStateError,
    );
  });
}
