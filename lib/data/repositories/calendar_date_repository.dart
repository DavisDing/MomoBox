import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/inventory/calendar_date.dart';

/// Preserve calendar fields independently of SQLite's timestamp encoding.
/// Legacy null columns are deliberately not backfilled by guessing a zone.
class CalendarDateRepository {
  CalendarDateRepository(this.database);
  final AppDatabase database;

  Future<Map<String, String?>> read(String batchId) async {
    final row = await database.customSelect('''
      SELECT production_date_calendar,expiry_date_calendar FROM product_batches WHERE id=?
    ''', variables: [Variable<String>(batchId)]).getSingleOrNull();
    return {'produced_date': row?.readNullable<String>('production_date_calendar'),
      'expiry_date': row?.readNullable<String>('expiry_date_calendar')};
  }

  Future<void> write(String batchId, {required DateTime? producedDate,
    required DateTime? expiryDate}) => database.customStatement('''
      UPDATE product_batches SET production_date_calendar=?,expiry_date_calendar=? WHERE id=?
    ''', [producedDate == null ? null : CalendarDate.encode(producedDate),
      expiryDate == null ? null : CalendarDate.encode(expiryDate), batchId]);

  Future<void> applyPayload(String batchId, Map<String, dynamic> payload) async {
    for (final entry in const {'produced_date': 'production_date_calendar',
      'production_date': 'production_date_calendar', 'productionDate': 'production_date_calendar',
      'expiry_date': 'expiry_date_calendar', 'expiryDate': 'expiry_date_calendar'}.entries) {
      if (!payload.containsKey(entry.key)) continue;
      final raw = payload[entry.key];
      final value = raw == null ? null : CalendarDate.encode(CalendarDate.decode(raw as String));
      await database.customStatement('UPDATE product_batches SET ${entry.value}=? WHERE id=?',
        [value, batchId]);
    }
  }

  Future<String?> familyTimeZone(String? scopeId) async {
    if (scopeId == null) return null;
    final row = await (database.select(database.appSettings)
      ..where((setting) => setting.key.equals('sync_family_time_zone:$scopeId'))).getSingleOrNull();
    final zone = row?.value ?? 'Asia/Shanghai';
    CalendarDate.validateTimeZone(zone);
    return zone;
  }
}
