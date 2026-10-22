import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/calendar_date.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';

void main() {
  test('calendar encoding preserves components instead of converting an instant', () {
    expect(CalendarDate.encode(DateTime.utc(2026, 10, 22, 23, 59)), '2026-10-22');
    expect(CalendarDate.encode(CalendarDate.decode('2028-02-29')), '2028-02-29');
    for (final value in ['2026-02-29', '2026-13-01', '2026-10-22T00:00:00Z']) {
      expect(() => CalendarDate.decode(value), throwsFormatException);
    }
  });

  test('family today is scoped per call across date lines and DST, without changing global timezone', () {
    final instant = DateTime.utc(2026, 10, 22, 16, 1);
    expect(CalendarDate.encode(CalendarDate.today(timeZone: 'Asia/Shanghai', instant: instant)), '2026-10-23');
    expect(CalendarDate.encode(CalendarDate.today(timeZone: 'America/New_York', instant: instant)), '2026-10-22');
    expect(CalendarDate.encode(CalendarDate.today(timeZone: 'Pacific/Kiritimati', instant: instant)), '2026-10-23');
    final before = CalendarDate.today(timeZone: 'America/New_York', instant: DateTime.utc(2026, 3, 8, 6, 59));
    final after = CalendarDate.today(timeZone: 'America/New_York', instant: DateTime.utc(2026, 3, 8, 7, 1));
    expect(CalendarDate.encode(before), '2026-03-08');
    expect(CalendarDate.encode(after), '2026-03-08');
    final expiry = CalendarDate.decode('2026-10-22');
    expect(ExpiryRules.statusFor(expiry, today: CalendarDate.today(timeZone: 'Asia/Shanghai', instant: instant)), ExpiryStatus.expired);
    expect(ExpiryRules.statusFor(expiry, today: CalendarDate.today(timeZone: 'America/New_York', instant: instant)), ExpiryStatus.expiring);
  });
}
