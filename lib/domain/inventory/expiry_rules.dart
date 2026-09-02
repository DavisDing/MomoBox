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
    var result = expiry;
    for (var index = 0; index < amount; index++) {
      final previousMonth = result.month == 1
          ? DateTime(result.year - 1, 12, 1)
          : DateTime(result.year, result.month - 1, 1);
      final lastDay = DateTime(previousMonth.year, previousMonth.month + 1, 0).day;
      result = DateTime(previousMonth.year, previousMonth.month, result.day > lastDay ? lastDay : result.day);
    }
    return result;
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
