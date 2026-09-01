import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';

void main() {
  group('ExpiryRules', () {
    test('到期当天仍有效且归类为临期', () {
      final today = DateTime(2026, 9, 1);
      expect(ExpiryRules.daysUntil(today, today: today), 0);
      expect(ExpiryRules.statusFor(today, today: today), ExpiryStatus.expiring);
    });

    test('到期日次日归类为过期', () {
      final today = DateTime(2026, 9, 1);
      expect(ExpiryRules.statusFor(DateTime(2026, 8, 31), today: today), ExpiryStatus.expired);
    });

    test('无效期批次不参与效期状态', () {
      expect(ExpiryRules.statusFor(null), ExpiryStatus.noExpiry);
      expect(ExpiryRules.daysUntil(null), isNull);
    });

    test('日历加月正确处理月末和闰年', () {
      expect(ExpiryRules.addCalendarMonths(DateTime(2024, 1, 31), 1), DateTime(2024, 2, 29));
      expect(ExpiryRules.addCalendarMonths(DateTime(2025, 1, 31), 1), DateTime(2025, 2, 28));
    });
  });
}
