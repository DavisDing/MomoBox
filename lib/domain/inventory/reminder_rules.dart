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
    this.batch,
  });

  final String key;
  final ReminderType type;
  final InventoryItem item;
  final DateTime date;
  final String fingerprint;
  final InventoryBatch? batch;
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
    int? expiringDays,
  }) {
    final reference = ExpiryRules.dateOnly(today ??
      (items.isEmpty ? DateTime.now() : items.first.calendarToday));
    final acknowledged = {
      for (final entry in acknowledgements)
        '${entry.reminderKey}|${entry.fingerprint}',
    };
    final all = candidates(items, today: reference, expiringDays: expiringDays);
    final result = all
        .where(
          (candidate) => !acknowledged.contains('${candidate.key}|${candidate.fingerprint}'),
        )
        .toList();
    // An acknowledged old expired batch must not consume the single expired
    // notification slot needed by the next still-valid batch.
    for (final candidate in all.where((c) => c.type == ReminderType.expired)) {
      if (!acknowledged.contains('${candidate.key}|${candidate.fingerprint}') ||
          candidate.batch == null ||
          ExpiryRules.daysUntil(candidate.batch!.expiryDate, today: reference)! >= 0) {
        continue;
      }
      final upcoming = _nearestBatch(candidate.item, reference, expired: false);
      if (upcoming == null) continue;
      final warningDays = expiringDays ?? candidate.item.reminderPolicy.expiryWarningDays;
      final fingerprint = _expiryFingerprint(upcoming, warningDays);
      if (acknowledged.contains('${candidate.key}|$fingerprint')) continue;
      result.add(ReminderCandidate(key: candidate.key, type: ReminderType.expired,
        item: candidate.item, batch: upcoming, fingerprint: fingerprint,
        date: ExpiryRules.addCalendarDays(upcoming.expiryDate!, 1)));
    }
    return result;
  }

  /// Returns the reminders that should be displayed as pending today.
  static List<ReminderCandidate> visibleCandidates(
    List<InventoryItem> items,
    Iterable<ReminderAcknowledgement> acknowledgements, {
    DateTime? today,
    int? expiringDays,
  }) {
    final reference = ExpiryRules.dateOnly(today ??
      (items.isEmpty ? DateTime.now() : items.first.calendarToday));
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
        ReminderType.expired => _daysUntil(left, today: today)
            .compareTo(_daysUntil(right, today: today)),
        ReminderType.expiring => _daysUntil(left, today: today)
            .compareTo(_daysUntil(right, today: today)),
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

  static int _daysUntil(ReminderCandidate candidate, {DateTime? today}) {
    final reference = today ?? candidate.item.calendarToday;
    final batch = candidate.batch ?? _nearestBatch(candidate.item, reference,
        expired: candidate.type == ReminderType.expired);
    return ExpiryRules.daysUntil(batch?.expiryDate, today: reference) ??
        ExpiryRules.expiringDays + 1;
  }

  static InventoryBatch? _nearestBatch(
    InventoryItem item, DateTime today, {required bool expired}
  ) {
    final previousAnchor = item.nearestDatedBatch;
    if (previousAnchor != null &&
        (ExpiryRules.daysUntil(previousAnchor.expiryDate, today: today)! < 0) == expired) {
      return previousAnchor;
    }
    final batches = item.activeBatches.where((batch) => batch.expiryDate != null &&
        (ExpiryRules.daysUntil(batch.expiryDate, today: today)! < 0) == expired)
        .toList();
    batches.sort((a, b) {
      final comparison = ExpiryRules.daysUntil(a.expiryDate, today: today)!
          .compareTo(ExpiryRules.daysUntil(b.expiryDate, today: today)!);
      return comparison != 0 ? comparison : a.expiryDate!.compareTo(b.expiryDate!);
    });
    return batches.firstOrNull;
  }

  static double _stockRatio(InventoryItem item) =>
      item.totalStock / item.lowStockThreshold;

  static List<ReminderCandidate> candidates(
    List<InventoryItem> items, {
    DateTime? today,
    int? expiringDays,
  }) {
    if (expiringDays != null && expiringDays < 0) {
      throw ArgumentError.value(expiringDays, 'expiringDays', '不能为负数');
    }
    final reference = ExpiryRules.dateOnly(today ??
      (items.isEmpty ? DateTime.now() : items.first.calendarToday));
    final result = <ReminderCandidate>[];
    for (final item in items) {
      if (!item.reminderPolicy.enabled) continue;
      // An explicit caller override remains supported for deterministic tests.
      final warningDays = expiringDays ?? item.reminderPolicy.expiryWarningDays;
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

      // Keep the confirmed product + type identity, but select each type's
      // batch independently. Old expired stock must not hide newer expiry.
      final expiredBatch = _nearestBatch(item, reference, expired: true);
      final upcomingBatch = _nearestBatch(item, reference, expired: false);
      if (expiredBatch != null) {
        result.add(
          ReminderCandidate(
            key: '${item.id}:expired',
            fingerprint: _expiryFingerprint(expiredBatch, warningDays),
            batch: expiredBatch,
            type: ReminderType.expired,
            item: item,
            date: reference,
          ),
        );
      }

      if (upcomingBatch == null) continue;
      final expiryDay = ExpiryRules.dateOnly(upcomingBatch.expiryDate!);
      final expiringDay = ExpiryRules.addCalendarDays(expiryDay, -warningDays);
      result.add(
        ReminderCandidate(
          key: '${item.id}:expiring',
          fingerprint: _expiryFingerprint(upcomingBatch, warningDays),
          batch: upcomingBatch,
          type: ReminderType.expiring,
          item: item,
          date: expiringDay.isBefore(reference) ? reference : expiringDay,
        ),
      );
      // 过期提醒必须在临期期间就注册，否则用户不开 App 就会错过状态转换。
      if (expiredBatch == null) {
        result.add(
          ReminderCandidate(
            key: '${item.id}:expired',
            fingerprint: _expiryFingerprint(upcomingBatch, warningDays),
            batch: upcomingBatch,
            type: ReminderType.expired,
            item: item,
            date: ExpiryRules.addCalendarDays(expiryDay, 1),
          ),
        );
      }
    }
    return result;
  }

  static String _expiryFingerprint(InventoryBatch batch, int warningDays) {
    final base = '${batch.id}:${batch.expiryDate?.toIso8601String()}';
    // Preserve existing acknowledgements at the default window, but reschedule
    // when a different effective window replaces the acknowledged policy.
    return warningDays == ExpiryRules.expiringDays
        ? base
        : '$base:warning-days:$warningDays';
  }
}
