import '../models/inventory_models.dart';

enum InventorySortOption {
  expirySoonest('最近到期'),
  nameAscending('名称 A–Z'),
  stockAscending('库存从少到多'),
  stockDescending('库存从多到少');

  const InventorySortOption(this.label);

  final String label;
}

/// Returns a new list so changing the selected sort order never mutates the
/// inventory state cached by the repository/provider.
List<InventoryItem> sortInventoryItems(
  Iterable<InventoryItem> source,
  InventorySortOption option,
) {
  final items = source.toList(growable: false);
  items.sort((left, right) {
    final comparison = switch (option) {
      InventorySortOption.expirySoonest => _compareByExpiry(left, right),
      InventorySortOption.nameAscending => _compareName(left, right),
      InventorySortOption.stockAscending => left.totalStock.compareTo(right.totalStock),
      InventorySortOption.stockDescending => right.totalStock.compareTo(left.totalStock),
    };
    return comparison == 0 ? _compareName(left, right) : comparison;
  });
  return items;
}

int _compareByExpiry(InventoryItem left, InventoryItem right) {
  final leftDate = left.nearestDatedBatch?.expiryDate;
  final rightDate = right.nearestDatedBatch?.expiryDate;
  if (leftDate == null && rightDate == null) return 0;
  if (leftDate == null) return 1;
  if (rightDate == null) return -1;
  return leftDate.compareTo(rightDate);
}

int _compareName(InventoryItem left, InventoryItem right) =>
    left.name.toLowerCase().compareTo(right.name.toLowerCase());
