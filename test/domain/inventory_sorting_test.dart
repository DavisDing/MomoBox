import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/inventory_sorting.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryItem item(String name, {int stock = 1, DateTime? expiry}) => InventoryItem(
      id: name,
      name: name,
      category: '其他物品',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: 1,
      batches: [
        InventoryBatch(
          id: '$name-batch',
          productId: name,
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
  final items = [
    item('无效期', stock: 2),
    item('较晚到期', stock: 4, expiry: DateTime(2026, 10, 10)),
    item('较早到期', stock: 1, expiry: DateTime(2026, 9, 10)),
  ];

  test('按最近到期排序且无效期排在末尾', () {
    final sorted = sortInventoryItems(items, InventorySortOption.expirySoonest);
    expect(sorted.map((entry) => entry.name), ['较早到期', '较晚到期', '无效期']);
  });

  test('可按库存从多到少排序且不修改输入列表', () {
    final sorted = sortInventoryItems(items, InventorySortOption.stockDescending);
    expect(sorted.map((entry) => entry.name), ['较晚到期', '无效期', '较早到期']);
    expect(items.first.name, '无效期');
  });
}
