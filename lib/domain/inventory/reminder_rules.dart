import 'expiry_rules.dart';
import '../models/inventory_models.dart';

enum ReminderType { expiring, expired, lowStock }

class ReminderCandidate {
  const ReminderCandidate({
    required this.key,
    required this.type,
    required this.item,
    required this.date,
  });

  final String key;
  final ReminderType type;
  final InventoryItem item;
  final DateTime date;
}

class ReminderRules {
  static List<ReminderCandidate> candidates(
    List<InventoryItem> items, {
    DateTime? today,
    int expiringDays = ExpiryRules.expiringDays,
  }) {
    final reference = ExpiryRules.dateOnly(today ?? DateTime.now());
    final result = <ReminderCandidate>[];
    for (final item in items) {
      if (item.isLowStock) {
        result.add(
          ReminderCandidate(
            key: '${item.id}:low-stock',
            type: ReminderType.lowStock,
            item: item,
            date: reference,
          ),
        );
      }

      final expiry = item.nearestDatedBatch?.expiryDate;
      if (expiry == null) continue;
      final expiryDay = ExpiryRules.dateOnly(expiry);
      final status = ExpiryRules.statusFor(expiryDay, today: reference);
      if (status == ExpiryStatus.expired) {
        result.add(
          ReminderCandidate(
            key: '${item.id}:expired',
            type: ReminderType.expired,
            item: item,
            date: reference,
          ),
        );
        continue;
      }

      final expiringDay = expiryDay.subtract(Duration(days: expiringDays));
      result.add(
        ReminderCandidate(
          key: '${item.id}:expiring',
          type: ReminderType.expiring,
          item: item,
          date: expiringDay.isBefore(reference) ? reference : expiringDay,
        ),
      );
      // 过期提醒必须在临期期间就注册，否则用户不开 App 就会错过状态转换。
      result.add(
        ReminderCandidate(
          key: '${item.id}:expired',
          type: ReminderType.expired,
          item: item,
          date: expiryDay.add(const Duration(days: 1)),
        ),
      );
    }
    return result;
  }
}
