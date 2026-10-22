import 'package:timezone/data/latest_all.dart' as tzdata;
import 'package:timezone/timezone.dart' as tz;

/// Calendar fields and event instants have deliberately different encodings.
class CalendarDate {
  static bool _zonesInitialized = false;

  static String encode(DateTime value) =>
      '${value.year.toString().padLeft(4, '0')}-'
      '${value.month.toString().padLeft(2, '0')}-'
      '${value.day.toString().padLeft(2, '0')}';

  static DateTime decode(String value) {
    if (!RegExp(r'^\d{4}-\d{2}-\d{2}$').hasMatch(value)) {
      throw const FormatException('日期必须为 YYYY-MM-DD。');
    }
    final year = int.parse(value.substring(0, 4));
    final month = int.parse(value.substring(5, 7));
    final day = int.parse(value.substring(8, 10));
    final result = DateTime.utc(year, month, day);
    if (result.year != year || result.month != month || result.day != day) {
      throw const FormatException('无效日历日期。');
    }
    return result;
  }

  static DateTime today({String? timeZone, DateTime? instant}) {
    final now = instant ?? DateTime.now();
    if (timeZone == null) return DateTime(now.year, now.month, now.day);
    if (!_zonesInitialized) {
      try {
        tz.getLocation('Asia/Shanghai');
      } catch (_) {
        tzdata.initializeTimeZones();
      }
      _zonesInitialized = true;
    }
    final familyNow = tz.TZDateTime.from(now, tz.getLocation(timeZone));
    return DateTime(familyNow.year, familyNow.month, familyNow.day);
  }

  static void validateTimeZone(String name) {
    today(timeZone: name, instant: DateTime.utc(2026));
  }
}
