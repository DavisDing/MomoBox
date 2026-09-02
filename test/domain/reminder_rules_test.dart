import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryItem item(String id, {int stock = 3, DateTime? expiry, int threshold = 1}) => InventoryItem(
      id: id,
      name: id,
      category: '其他物品',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: threshold,
      batches: [
        InventoryBatch(
          id: '$id-batch',
          productId: id,
          batchNo: null,
          initialQuantity: stock,
          remainingQuantity: stock,
          isDiscarded: false,
          expiryDate: expiry,
          productionDate: null,
        ),
      ],
    );

void main() {
  final today = DateTime(2026, 9, 1);

  test('未来效期会生成临期和过期两个计划', () {
    final candidates = ReminderRules.candidates(
      [item('牛奶', expiry: DateTime(2026, 10, 15))],
      today: today,
    );
    expect(candidates.map((candidate) => candidate.type), containsAll([ReminderType.expiring, ReminderType.expired]));
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expiring).date, DateTime(2026, 9, 15));
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expired).date, DateTime(2026, 10, 16));
  });

  test('当前临期仍会提前注册后续过期提醒', () {
    final candidates = ReminderRules.candidates(
      [item('临期', expiry: DateTime(2026, 9, 10))],
      today: today,
    );
    expect(candidates.map((candidate) => candidate.type), containsAll([ReminderType.expiring, ReminderType.expired]));
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expiring).date, today);
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expired).date, DateTime(2026, 9, 11));
  });

  test('无效期商品不生成效期提醒', () {
    final candidates = ReminderRules.candidates([item('无效期')], today: today);
    expect(candidates.where((candidate) => candidate.type != ReminderType.lowStock), isEmpty);
  });

  test('当前临期、过期和低库存各生成一条提醒', () {
    final candidates = ReminderRules.candidates(
      [
        item('临期', expiry: DateTime(2026, 9, 10)),
        item('过期', expiry: DateTime(2026, 8, 31)),
        item('缺货', stock: 1, threshold: 1),
      ],
      today: today,
    );
    expect(candidates.map((candidate) => candidate.type), containsAll([
      ReminderType.expiring,
      ReminderType.expired,
      ReminderType.lowStock,
    ]));
  });
}
