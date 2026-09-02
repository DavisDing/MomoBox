import 'expiry_rules.dart';
import '../models/inventory_models.dart';

enum ReminderType { expiring, expired, lowStock }

class ReminderCandidate {
  const ReminderCandidate({
    required this.key,
    required this.type,
    required this.item,
    required this.date,
    required this.fingerprint,
  });

  final String key;
  final ReminderType type;
  final InventoryItem item;
  final DateTime date;
  final String fingerprint;
}

class ReminderRules {
  /// Returns every reminder that still needs notification scheduling.
  ///
  /// This intentionally includes future expiring/expired candidates. Local
  /// notification sync cancels and recreates its plans, so filtering to only
  /// currently visible reminders would silently remove future schedules after
  /// each inventory change.
  static List<ReminderCandidate> unacknowledgedCandidates(
    List<InventoryItem> items,
    Iterable<ReminderAcknowledgement> acknowledgements, {
    DateTime? today,
    int expiringDays = ExpiryRules.expiringDays,
  }) {
    final reference = ExpiryRules.dateOnly(today ?? DateTime.now());
    final acknowledged = {
      for (final entry in acknowledgements)
        '${entry.reminderKey}|${entry.fingerprint}',
    };
    return candidates(items, today: reference, expiringDays: expiringDays)
        .where(
          (candidate) => !acknowledged.contains('${candidate.key}|${candidate.fingerprint}'),
        )
        .toList(growable: false);
  }

  /// Returns the reminders that should be displayed as pending today.
  static List<ReminderCandidate> visibleCandidates(
    List<InventoryItem> items,
    Iterable<ReminderAcknowledgement> acknowledgements, {
    DateTime? today,
    int expiringDays = ExpiryRules.expiringDays,
  }) {
    final reference = ExpiryRules.dateOnly(today ?? DateTime.now());
    return unacknowledgedCandidates(
      items,
      acknowledgements,
      today: reference,
      expiringDays: expiringDays,
    ).where((candidate) => !candidate.date.isAfter(reference)).toList(growable: false);
  }

  /// Orders reminders within each type by the action that should happen first.
  /// This is used by the dashboard after acknowledged reminders are filtered.
  static List<ReminderCandidate> sortByUrgency(
    Iterable<ReminderCandidate> source, {
    DateTime? today,
  }) {
    final candidates = source.toList(growable: false);
    candidates.sort((left, right) {
      final typeComparison = _typePriority(left.type).compareTo(_typePriority(right.type));
      if (typeComparison != 0) return typeComparison;

      final urgencyComparison = switch (left.type) {
        ReminderType.expired => _overdueDays(right.item, today: today)
            .compareTo(_overdueDays(left.item, today: today)),
        ReminderType.expiring => _daysUntil(left.item, today: today)
            .compareTo(_daysUntil(right.item, today: today)),
        ReminderType.lowStock => _stockRatio(left.item).compareTo(_stockRatio(right.item)),
      };
      return urgencyComparison != 0
          ? urgencyComparison
          : left.item.name.toLowerCase().compareTo(right.item.name.toLowerCase());
    });
    return candidates;
  }

  static int _typePriority(ReminderType type) => switch (type) {
        ReminderType.expired => 0,
        ReminderType.expiring => 1,
        ReminderType.lowStock => 2,
      };

  static int _overdueDays(InventoryItem item, {DateTime? today}) =>
      -(_daysUntil(item, today: today));

  static int _daysUntil(InventoryItem item, {DateTime? today}) =>
      ExpiryRules.daysUntil(item.nearestDatedBatch?.expiryDate, today: today) ??
      ExpiryRules.expiringDays +
          1;

  static double _stockRatio(InventoryItem item) =>
      item.totalStock / item.lowStockThreshold;

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
            fingerprint: 'threshold:${item.lowStockThreshold}',
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
            fingerprint: _expiryFingerprint(item),
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
          fingerprint: _expiryFingerprint(item),
          type: ReminderType.expiring,
          item: item,
          date: expiringDay.isBefore(reference) ? reference : expiringDay,
        ),
      );
      // 过期提醒必须在临期期间就注册，否则用户不开 App 就会错过状态转换。
      result.add(
        ReminderCandidate(
          key: '${item.id}:expired',
          fingerprint: _expiryFingerprint(item),
          type: ReminderType.expired,
          item: item,
          date: expiryDay.add(const Duration(days: 1)),
        ),
      );
    }
    return result;
  }

  static String _expiryFingerprint(InventoryItem item) {
    final batch = item.nearestDatedBatch;
    return '${batch?.id}:${batch?.expiryDate?.toIso8601String()}';
  }
}
