import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/models/inventory_models.dart';

class ReminderRepository {
  ReminderRepository(this._database);

  final AppDatabase _database;

  Stream<List<ReminderAcknowledgement>> watchAcknowledgements() {
    return (_database.select(_database.reminderAcknowledgments)
          ..orderBy([(entry) => OrderingTerm.desc(entry.acknowledgedAt)]))
        .watch()
        .map(
          (entries) => entries
              .map(
                (entry) => ReminderAcknowledgement(
                  reminderKey: entry.reminderKey,
                  fingerprint: entry.fingerprint,
                  acknowledgedAt: entry.acknowledgedAt,
                ),
              )
              .toList(growable: false),
        );
  }

  Future<void> acknowledge({required String reminderKey, required String fingerprint}) async {
    final normalizedKey = reminderKey.trim();
    final normalizedFingerprint = fingerprint.trim();
    if (normalizedKey.isEmpty) throw ArgumentError('提醒标识不能为空。');
    if (normalizedFingerprint.isEmpty) throw ArgumentError('提醒状态不能为空。');

    // The database primary key is reminderKey. Replacing the row makes a
    // second acknowledgement advance the current reminder cycle instead of
    // accumulating stale fingerprints forever.
    await _database.into(_database.reminderAcknowledgments).insertOnConflictUpdate(
          ReminderAcknowledgmentsCompanion.insert(
            reminderKey: normalizedKey,
            fingerprint: normalizedFingerprint,
            acknowledgedAt: DateTime.now(),
          ),
        );
  }

  /// 删除已经恢复正常的低库存确认记录。
  ///
  /// 低库存确认记录代表当前提醒周期。商品回到阈值以上后，确认状态失效；
  /// 下次重新跌破阈值时会自然生成新的提醒周期。
  Future<void> clearRecoveredLowStockAcknowledgements(
    Iterable<InventoryItem> items,
  ) async {
    final keys = items
        .where((item) => !item.isLowStock)
        .map((item) => '${item.id}:low-stock')
        .toSet()
        .toList(growable: false);
    if (keys.isEmpty) return;
    await (_database.delete(_database.reminderAcknowledgments)
          ..where((row) => row.reminderKey.isIn(keys)))
        .go();
  }

  Future<void> acknowledgeAll(
    Iterable<({String reminderKey, String fingerprint})> reminders,
  ) async {
    final entries = reminders.toList(growable: false);
    if (entries.isEmpty) return;
    await _database.transaction(() async {
      for (final reminder in entries) {
        await acknowledge(
          reminderKey: reminder.reminderKey,
          fingerprint: reminder.fingerprint,
        );
      }
    });
  }
}
