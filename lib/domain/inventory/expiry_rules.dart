enum ExpiryStatus { safe, expiring, expired, noExpiry }

enum ShelfLifeUnit { days, months }

class ExpiryRules {
  static const int expiringDays = 30;

  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static int? daysUntil(DateTime? expiryDate, {DateTime? today}) {
    if (expiryDate == null) return null;
    final start = dateOnly(today ?? DateTime.now());
    final expiry = dateOnly(expiryDate);
    return expiry.difference(start).inDays;
  }

  static ExpiryStatus statusFor(DateTime? expiryDate, {DateTime? today}) {
    final remaining = daysUntil(expiryDate, today: today);
    if (remaining == null) return ExpiryStatus.noExpiry;
    // 到期日当天仍有效，次日才归类为过期。
    if (remaining < 0) return ExpiryStatus.expired;
    if (remaining <= expiringDays) return ExpiryStatus.expiring;
    return ExpiryStatus.safe;
  }

  static DateTime calculateExpiry({
    required DateTime startDate,
    required int amount,
    required ShelfLifeUnit unit,
  }) {
    if (amount < 1) throw ArgumentError.value(amount, 'amount', '保质期必须大于 0');
    return unit == ShelfLifeUnit.days
        ? dateOnly(startDate).add(Duration(days: amount))
        : addCalendarMonths(dateOnly(startDate), amount);
  }

  static DateTime calculateProduction({
    required DateTime expiryDate,
    required int amount,
    required ShelfLifeUnit unit,
  }) {
    if (amount < 1) throw ArgumentError.value(amount, 'amount', '保质期必须大于 0');
    final expiry = dateOnly(expiryDate);
    if (unit == ShelfLifeUnit.days) return expiry.subtract(Duration(days: amount));
    // 一次性定位目标月份，避免逐月截断日期导致误差：
    // 例如 2026-03-31 反推 2 个月应得到 2026-01-31，
    // 不能先截成 2026-02-28 后再得到 2026-01-28。
    final targetMonth = DateTime(expiry.year, expiry.month - amount, 1);
    final lastDay = DateTime(targetMonth.year, targetMonth.month + 1, 0).day;
    return DateTime(
      targetMonth.year,
      targetMonth.month,
      expiry.day > lastDay ? lastDay : expiry.day,
    );
  }

  static DateTime addCalendarMonths(DateTime source, int months) {
    if (months < 0) throw ArgumentError.value(months, 'months', '不能为负数');
    final monthIndex = source.month - 1 + months;
    final year = source.year + monthIndex ~/ 12;
    final month = monthIndex % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, source.day > lastDay ? lastDay : source.day);
  }
}
