enum ExpiryStatus { safe, expiring, expired, noExpiry }

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

  static DateTime addCalendarMonths(DateTime source, int months) {
    if (months < 0) throw ArgumentError.value(months, 'months', '不能为负数');
    final monthIndex = source.month - 1 + months;
    final year = source.year + monthIndex ~/ 12;
    final month = monthIndex % 12 + 1;
    final lastDay = DateTime(year, month + 1, 0).day;
    return DateTime(year, month, source.day > lastDay ? lastDay : source.day);
  }
}
