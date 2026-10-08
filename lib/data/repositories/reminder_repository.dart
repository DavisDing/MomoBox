import 'dart:convert';

import 'package:drift/drift.dart';

import '../../core/database/app_database.dart';
import '../../domain/inventory/expiry_rules.dart';
import '../../domain/models/inventory_models.dart';

class ReminderRepository {
  ReminderRepository(this._database);

  final AppDatabase _database;

  /// Validate all supported policy fields before any overlay is changed.
  /// Opened-expiry reminders need a separate domain rule and remain explicit
  /// errors even when the incoming policy disables other reminders.
  static void validateRemoteSettings(Map<String, dynamic> payload) {
    final productId = payload['product_id'];
    if (productId != null && (productId is! String || productId.trim().isEmpty)) {
      throw const FormatException('reminder_settings.product_id must be a non-empty string or null');
    }
    final enabled = payload.containsKey('enabled') ? payload['enabled'] : true;
    if (enabled is! bool) {
      throw const FormatException('reminder_settings.enabled must be a boolean');
    }
    final expiryDays = payload.containsKey('expiry_warning_days')
        ? payload['expiry_warning_days']
        : ExpiryRules.expiringDays;
    if (expiryDays is! int || expiryDays < 0) {
      throw const FormatException('reminder_settings.expiry_warning_days must be a non-negative integer');
    }
    final threshold = payload['low_stock_threshold'];
    if (threshold != null && (threshold is! int || threshold < 1)) {
      throw const FormatException('reminder_settings.low_stock_threshold must be a positive integer or null');
    }
    final openedDays = payload['opened_warning_days'];
    if (openedDays != null) {
      throw const FormatException('unsupported reminder_settings.opened_warning_days: no local opened-expiry reminder rule');
    }
  }

  String _remotePolicyKey(String scopeId, String entityId) =>
      'reminder_sync_policy:$scopeId:$entityId';

  /// Called in the adapter's transaction together with the version/tombstone.
  /// Removing an override restores the family policy or local defaults without
  /// guessing a pre-sync value or altering inventory commands.
  Future<void> applyRemoteSettings({
    required String scopeId,
    required String entityId,
    required Map<String, dynamic> payload,
    required DateTime updatedAt,
    bool deleted = false,
  }) async {
    final key = _remotePolicyKey(scopeId, entityId);
    if (deleted) {
      await (_database.delete(_database.appSettings)
            ..where((row) => row.key.equals(key)))
          .go();
      return;
    }
    validateRemoteSettings(payload);
    final policies = await _remotePolicies(scopeId);
    final productId = (payload['product_id'] as String?)?.trim();
    if (policies.entries.any((entry) =>
        entry.key != key && entry.value['product_id'] == productId)) {
      throw const FormatException('reminder_settings contains duplicate active product/default policies');
    }
    await _database.into(_database.appSettings).insertOnConflictUpdate(
          AppSettingsCompanion.insert(
            key: key,
            value: jsonEncode({
              'product_id': productId,
              'enabled': payload['enabled'] ?? true,
              'expiry_warning_days': payload['expiry_warning_days'] ??
                  ExpiryRules.expiringDays,
              'low_stock_threshold': payload['low_stock_threshold'],
              'opened_warning_days': null,
            }),
            updatedAt: updatedAt.toUtc(),
          ),
        );
  }

  Future<Map<String, Map<String, dynamic>>> _remotePolicies(String scopeId) async {
    final prefix = 'reminder_sync_policy:$scopeId:';
    // Filter exact prefixes in Dart instead of SQL LIKE so wildcard characters
    // in a scope ID cannot select another family's policy.
    final rows = await _database.select(_database.appSettings).get();
    return {
      for (final row in rows.where((row) => row.key.startsWith(prefix)))
        row.key: Map<String, dynamic>.from(jsonDecode(row.value) as Map),
    };
  }

  /// The empty key denotes the family policy; product policies take priority.
  /// Legacy threshold-only overlays retain their former enabled/30-day behavior.
  Future<Map<String, ReminderPolicy>> remotePolicies(String scopeId) async {
    final policies = await _remotePolicies(scopeId);
    final result = <String, ReminderPolicy>{};
    for (final payload in policies.values) {
      validateRemoteSettings(payload);
      final productId = (payload['product_id'] as String?)?.trim() ?? '';
      if (result.containsKey(productId)) {
        throw const FormatException(
          'reminder_settings contains duplicate active product/default policies',
        );
      }
      result[productId] = ReminderPolicy(
        enabled: payload['enabled'] as bool? ?? true,
        expiryWarningDays: payload['expiry_warning_days'] as int? ??
            ExpiryRules.expiringDays,
        lowStockThreshold: payload['low_stock_threshold'] as int?,
      );
    }
    return result;
  }

  /// Kept for existing callers; inventory consumes the complete policy instead.
  Future<Map<String, int>> remoteLowStockThresholds(String scopeId) async {
    final policies = await remotePolicies(scopeId);
    return {
      for (final entry in policies.entries)
        if (entry.value.lowStockThreshold != null)
          entry.key: entry.value.lowStockThreshold!,
    };
  }

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
