import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';
import 'package:momo_box/domain/inventory/fefo.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryItem _item({
  required DateTime expiry,
  ReminderPolicy policy = const ReminderPolicy(),
  int stock = 3,
}) =>
    InventoryItem(
      id: 'product',
      name: '物品',
      category: '其他',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: 1,
      reminderPolicy: policy,
      batches: [
        InventoryBatch(
          id: 'batch',
          productId: 'product',
          batchNo: null,
          initialQuantity: stock,
          remainingQuantity: stock,
          isDiscarded: false,
          expiryDate: expiry,
          productionDate: null,
          reminderPolicy: policy,
        ),
      ],
    );

void main() {
  final today = DateTime(2026, 10, 6);

  test('默认构造保持三十天策略和原有 fingerprint', () {
    final target = _item(expiry: DateTime(2026, 11, 15));
    expect(target.reminderPolicy.enabled, isTrue);
    expect(target.reminderPolicy.expiryWarningDays, 30);
    final candidates = ReminderRules.unacknowledgedCandidates(
      [target], const [], today: today,
    );
    final expiring = candidates.firstWhere(
      (entry) => entry.type == ReminderType.expiring,
    );
    expect(expiring.date, DateTime(2026, 10, 16));
    expect(expiring.fingerprint, 'batch:2026-11-15T00:00:00.000');
    expect(candidates.last.date, DateTime(2026, 11, 16));
  });

  test('七天策略推迟临期通知且展示不提前出现', () {
    final target = _item(
      expiry: DateTime(2026, 10, 16),
      policy: const ReminderPolicy(expiryWarningDays: 7),
    );
    final scheduled = ReminderRules.unacknowledgedCandidates(
      [target], const [], today: today,
    );
    expect(scheduled.first.date, DateTime(2026, 10, 9));
    expect(scheduled.last.date, DateTime(2026, 10, 17));
    expect(
      ReminderRules.visibleCandidates([target], const [], today: today),
      isEmpty,
    );
    expect(
      ReminderRules.visibleCandidates(
        [target], const [], today: DateTime(2026, 10, 9),
      ).single.type,
      ReminderType.expiring,
    );
  });

  test('显式 expiringDays 参数仍优先于商品策略', () {
    final target = _item(
      expiry: DateTime(2026, 10, 16),
      policy: const ReminderPolicy(expiryWarningDays: 7),
    );
    final candidates = ReminderRules.unacknowledgedCandidates(
      [target], const [], today: today, expiringDays: 2,
    );
    expect(candidates.first.date, DateTime(2026, 10, 14));
    expect(candidates.first.fingerprint, endsWith(':warning-days:2'));
    expect(
      ReminderRules.visibleCandidates(
        [target], const [], today: today, expiringDays: 30,
      ).single.type,
      ReminderType.expiring,
    );
  });

  test('零天窗口只在到期当天临期且次日才过期', () {
    final target = _item(
      expiry: DateTime(2026, 10, 7),
      policy: const ReminderPolicy(expiryWarningDays: 0),
    );
    expect(
      ReminderRules.visibleCandidates([target], const [], today: today),
      isEmpty,
    );
    expect(
      ReminderRules.visibleCandidates(
        [target], const [], today: DateTime(2026, 10, 7),
      ).single.type,
      ReminderType.expiring,
    );
    expect(
      ReminderRules.visibleCandidates(
        [target], const [], today: DateTime(2026, 10, 8),
      ).single.type,
      ReminderType.expired,
    );
  });

  test('批次标签、整体状态与提醒共用有效窗口', () {
    final expiry = ExpiryRules.dateOnly(DateTime.now())
        .add(const Duration(days: 10));
    final target = _item(
      expiry: expiry,
      policy: const ReminderPolicy(expiryWarningDays: 7),
    );
    expect(target.batches.single.expiryStatus, ExpiryStatus.safe);
    expect(target.overallExpiryStatus, ExpiryStatus.safe);
    expect(
      ReminderRules.visibleCandidates([target], const []),
      isEmpty,
    );
    expect(target.availableQuantity, 3);
    final wider = _item(expiry: expiry);
    expect(wider.batches.single.expiryStatus, ExpiryStatus.expiring);
    expect(wider.overallExpiryStatus, ExpiryStatus.expiring);
    expect(ReminderRules.visibleCandidates([wider], const []), hasLength(1));
  });

  test('禁用同时停止当前和未来通知候选而不隐藏过期和库存事实', () {
    final target = _item(
      expiry: ExpiryRules.dateOnly(DateTime.now())
          .subtract(const Duration(days: 1)),
      stock: 1,
      policy: const ReminderPolicy(enabled: false, expiryWarningDays: 7),
    );
    expect(target.totalStock, 1);
    expect(target.isLowStock, isTrue);
    expect(target.activeBatches, hasLength(1));
    expect(target.batches.single.expiryStatus, ExpiryStatus.expired);
    expect(target.overallExpiryStatus, ExpiryStatus.expired);
    expect(target.availableQuantity, 0);
    expect(ReminderRules.candidates([target]), isEmpty);
    expect(
      ReminderRules.unacknowledgedCandidates([target], const []),
      isEmpty,
    );
    expect(ReminderRules.visibleCandidates([target], const []), isEmpty);
    final future = _item(
      expiry: DateTime(2026, 11, 15),
      policy: const ReminderPolicy(enabled: false),
    );
    expect(
      ReminderRules.unacknowledgedCandidates(
        [future], const [], today: today, expiringDays: 30,
      ),
      isEmpty,
    );
  });

  test('窗口变更使通知 fingerprint 变化且旧确认不隐藏新计划', () {
    final previous = _item(expiry: DateTime(2026, 10, 12));
    final previousCandidate = ReminderRules.candidates(
      [previous], today: today,
    ).first;
    final acknowledgement = ReminderAcknowledgement(
      reminderKey: previousCandidate.key,
      fingerprint: previousCandidate.fingerprint,
      acknowledgedAt: today,
    );
    expect(
      ReminderRules.unacknowledgedCandidates(
        [previous], [acknowledgement], today: today,
      ).where((entry) => entry.type == ReminderType.expiring),
      isEmpty,
    );
    final changed = _item(
      expiry: DateTime(2026, 10, 12),
      policy: const ReminderPolicy(expiryWarningDays: 7),
    );
    final candidates = ReminderRules.unacknowledgedCandidates(
      [changed], [acknowledgement], today: today,
    );
    expect(candidates.first.key, previousCandidate.key);
    expect(candidates.first.fingerprint, isNot(previousCandidate.fingerprint));
    expect(candidates.first.fingerprint, endsWith(':warning-days:7'));
    expect(candidates.first.date, today);
    final repeatedAck = ReminderAcknowledgement(
      reminderKey: candidates.first.key,
      fingerprint: candidates.first.fingerprint,
      acknowledgedAt: today,
    );
    expect(
      ReminderRules.visibleCandidates(
        [changed], [repeatedAck], today: today,
      ),
      isEmpty,
    );
  });

  test('有效阈值改变会更新低库存通知 fingerprint', () {
    final previous = _item(expiry: DateTime(2026, 11, 15), stock: 1);
    final changed = _item(
      expiry: DateTime(2026, 11, 15),
      stock: 1,
      policy: const ReminderPolicy(lowStockThreshold: 2),
    );
    final oldCandidate = ReminderRules.candidates([previous], today: today)
        .firstWhere((entry) => entry.type == ReminderType.lowStock);
    expect(changed.lowStockThreshold, 2);
    final candidates = ReminderRules.visibleCandidates(
      [changed],
      [ReminderAcknowledgement(
        reminderKey: oldCandidate.key,
        fingerprint: oldCandidate.fingerprint,
        acknowledgedAt: today,
      )],
      today: today,
    );
    expect(candidates.single.fingerprint, 'threshold:2');
  });

  test('FEFO仅排除过期批次不受七天窗口和禁用提醒影响', () {
    final enabled = _item(
      expiry: today.add(const Duration(days: 10)),
      policy: const ReminderPolicy(expiryWarningDays: 7),
    );
    final disabled = _item(
      expiry: today.add(const Duration(days: 10)),
      policy: const ReminderPolicy(enabled: false, expiryWarningDays: 0),
    );
    expect(Fefo.allocate(enabled.batches, 2, today: today).single.quantity, 2);
    expect(Fefo.allocate(disabled.batches, 2, today: today).single.quantity, 2);
    final expired = _item(
      expiry: today.subtract(const Duration(days: 1)),
      policy: const ReminderPolicy(enabled: false, expiryWarningDays: 7),
    );
    expect(() => Fefo.allocate(expired.batches, 1, today: today), throwsStateError);
  });

  test('负数显式窗口不会生成错误通知计划', () {
    expect(
      () => ReminderRules.candidates(const [], today: today, expiringDays: -1),
      throwsArgumentError,
    );
    expect(
      () => ExpiryRules.statusFor(null, today: today, expiringDays: -1),
      throwsArgumentError,
    );
  });
}
