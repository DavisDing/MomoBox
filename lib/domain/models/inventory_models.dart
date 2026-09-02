import '../inventory/expiry_rules.dart';

class IntakeDraft {
  const IntakeDraft({
    required this.name,
    required this.category,
    required this.quantity,
    this.brand,
    this.specification,
    this.barcode,
    this.location,
    this.unit = '件',
    this.lowStockThreshold = 1,
    this.batchNo,
    this.productionDate,
    this.expiryDate,
    this.shelfLifeAmount,
    this.shelfLifeUnit = ShelfLifeUnit.days,
    this.dateSource = 'manual',
    this.datePrecision = 'day',
  });

  final String name;
  final String category;
  final int quantity;
  final String? brand;
  final String? specification;
  final String? barcode;
  final String? location;
  final String unit;
  final int lowStockThreshold;
  final String? batchNo;
  final DateTime? productionDate;
  final DateTime? expiryDate;
  final int? shelfLifeAmount;
  final ShelfLifeUnit shelfLifeUnit;

  /// 日期信息的真实来源，当前 MVP 支持 manual / calculated。
  /// 预留 ai 供后续 OCR/AI 接入时使用。
  final String dateSource;
  final String datePrecision;
}

class ProductMatchCandidate {
  const ProductMatchCandidate({
    required this.id,
    required this.name,
    required this.category,
    required this.brand,
    required this.specification,
    required this.barcode,
  });

  final String id;
  final String name;
  final String category;
  final String? brand;
  final String? specification;
  final String? barcode;
}

class InventoryBatch {
  const InventoryBatch({
    required this.id,
    required this.productId,
    required this.batchNo,
    required this.initialQuantity,
    required this.remainingQuantity,
    required this.isDiscarded,
    required this.expiryDate,
    required this.productionDate,
  });

  final String id;
  final String productId;
  final String? batchNo;
  final int initialQuantity;
  final int remainingQuantity;
  final bool isDiscarded;
  final DateTime? expiryDate;
  final DateTime? productionDate;

  ExpiryStatus get expiryStatus => ExpiryRules.statusFor(expiryDate);
  int? get daysUntilExpiry => ExpiryRules.daysUntil(expiryDate);
  bool get isAvailable => remainingQuantity > 0 && !isDiscarded;
}

class InventoryItem {
  const InventoryItem({
    required this.id,
    required this.name,
    required this.category,
    required this.brand,
    required this.specification,
    required this.barcode,
    required this.location,
    required this.unit,
    required this.lowStockThreshold,
    required this.batches,
  });

  final String id;
  final String name;
  final String category;
  final String? brand;
  final String? specification;
  final String? barcode;
  final String? location;
  final String unit;
  final int lowStockThreshold;
  final List<InventoryBatch> batches;

  int get totalStock => batches
      .where((batch) => !batch.isDiscarded)
      .fold(0, (sum, batch) => sum + batch.remainingQuantity);

  bool get isLowStock => totalStock <= lowStockThreshold;

  List<InventoryBatch> get activeBatches => batches
      .where((batch) => batch.isAvailable)
      .toList(growable: false);

  InventoryBatch? get nearestDatedBatch {
    final dated = activeBatches.where((batch) => batch.expiryDate != null).toList()
      ..sort((a, b) => a.expiryDate!.compareTo(b.expiryDate!));
    return dated.isEmpty ? null : dated.first;
  }

  ExpiryStatus get overallExpiryStatus =>
      nearestDatedBatch?.expiryStatus ?? ExpiryStatus.noExpiry;
}

class StockMovement {
  const StockMovement({
    required this.id,
    required this.type,
    required this.quantity,
    required this.note,
    required this.createdAt,
  });

  final String id;
  final String type;
  final int quantity;
  final String? note;
  final DateTime createdAt;
}

class ShoppingEntry {
  const ShoppingEntry({
    required this.id,
    required this.itemName,
    required this.targetQuantity,
    required this.reason,
    required this.isCompleted,
    this.productId,
    this.category,
  });

  final String id;
  final String? productId;
  final String itemName;
  final String? category;
  final int targetQuantity;
  final String reason;
  final bool isCompleted;
}

class ReminderAcknowledgement {
  const ReminderAcknowledgement({
    required this.reminderKey,
    required this.fingerprint,
    required this.acknowledgedAt,
  });

  final String reminderKey;
  final String fingerprint;
  final DateTime acknowledgedAt;
}

class ReminderSummary {
  const ReminderSummary({
    required this.expired,
    required this.expiring,
    required this.lowStock,
  });

  final List<InventoryItem> expired;
  final List<InventoryItem> expiring;
  final List<InventoryItem> lowStock;

  int get expiryAlertCount => expired.length + expiring.length;

  /// Includes products whose nearest usable batch expires today through the
  /// requested number of days from today. Expired products are counted
  /// separately and are intentionally excluded.
  int expiringWithinDays(int days, {DateTime? today}) {
    if (days < 0) return 0;
    return expiring.where((item) {
      final remainingDays = ExpiryRules.daysUntil(
        item.nearestDatedBatch?.expiryDate,
        today: today,
      );
      return remainingDays != null && remainingDays >= 0 && remainingDays <= days;
    }).length;
  }
}
