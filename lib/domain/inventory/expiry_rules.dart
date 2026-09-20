enum ExpiryStatus { safe, expiring, expired, noExpiry }

enum ShelfLifeUnit { days, months }

class ExpiryRules {
  static const int expiringDays = 30;

  /// Normalizes a timestamp to the user's local calendar date.
  ///
  /// Inventory expiry values are date-only values. Rebuilding the value from
  /// its calendar components prevents a time-of-day from changing the result
  /// of comparisons at the expiry boundary.
  static DateTime dateOnly(DateTime value) =>
      DateTime(value.year, value.month, value.day);

  static int? daysUntil(DateTime? expiryDate, {DateTime? today}) {
    if (expiryDate == null) return null;
    final start = _dateOnlyUtc(today ?? DateTime.now());
    final expiry = _dateOnlyUtc(expiryDate);
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
    _validateAmount(amount);
    return unit == ShelfLifeUnit.days
        ? dateOnly(startDate).add(Duration(days: amount))
        : addCalendarMonths(dateOnly(startDate), amount);
  }

  static DateTime calculateProduction({
    required DateTime expiryDate,
    required int amount,
    required ShelfLifeUnit unit,
  }) {
    _validateAmount(amount);
    final expiry = dateOnly(expiryDate);
    if (unit == ShelfLifeUnit.days) {
      return expiry.subtract(Duration(days: amount));
    }

    // 一次性定位目标月份，避免逐月截断日期导致误差：
    // 例如 2026-03-31 反推 2 个月应得到 2026-01-31，
    // 不能先截成 2026-02-28 后再得到 2026-01-28。
    return _shiftCalendarMonths(expiry, -amount);
  }

  static DateTime addCalendarMonths(DateTime source, int months) {
    if (months < 0) {
      throw ArgumentError.value(months, 'months', '不能为负数');
    }
    return _shiftCalendarMonths(dateOnly(source), months);
  }

  static DateTime _shiftCalendarMonths(DateTime source, int months) {
    final monthIndex = source.month - 1 + months;
    // Dart integer division truncates toward zero. Use an explicit floor
    // quotient so subtracting months across a year boundary remains valid.
    final yearOffset = monthIndex >= 0
        ? monthIndex ~/ 12
        : -(((-monthIndex) + 11) ~/ 12);
    final year = source.year + yearOffset;
    final month = monthIndex - yearOffset * 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, source.day > lastDay ? lastDay : source.day);
  }

  static DateTime _dateOnlyUtc(DateTime value) =>
      DateTime.utc(value.year, value.month, value.day);

  static void _validateAmount(int amount) {
    if (amount < 1) {
      throw ArgumentError.value(amount, 'amount', '保质期必须大于 0');
    }
  }
}
