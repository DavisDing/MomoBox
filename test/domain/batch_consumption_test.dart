import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/batch_consumption.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryBatch batch({
  int quantity = 3,
  bool isDiscarded = false,
  DateTime? expiryDate,
}) =>
    InventoryBatch(
      id: 'batch',
      productId: 'product',
      batchNo: 'B-001',
      initialQuantity: quantity,
      remainingQuantity: quantity,
      isDiscarded: isDiscarded,
      expiryDate: expiryDate,
      productionDate: null,
    );

void main() {
  final today = DateTime(2026, 9, 2);

  test('可消耗未过期或无效期的指定批次', () {
    expect(
      () => BatchConsumption.validate(
        batch(expiryDate: DateTime(2026, 9, 2)),
        3,
        today: today,
      ),
      returnsNormally,
    );
    expect(
      () => BatchConsumption.validate(batch(), 1, today: today),
      returnsNormally,
    );
  });

  test('拒绝非法数量、库存不足、报废和过期批次', () {
    expect(
      () => BatchConsumption.validate(batch(), 0, today: today),
      throwsArgumentError,
    );
    expect(
      () => BatchConsumption.validate(batch(), 4, today: today), throwsStateError);
    expect(
      () => BatchConsumption.validate(batch(isDiscarded: true), 1, today: today),
      throwsStateError,
    );
    expect(
      () => BatchConsumption.validate(
        batch(expiryDate: DateTime(2026, 9, 1)),
        1,
        today: today,
      ),
      throwsStateError,
    );
  });
}
