import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

InventoryItem item(String id, {int stock = 3, DateTime? expiry, int threshold = 1}) => InventoryItem(
      id: id,
      name: id,
      category: '其他物品',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: threshold,
      batches: [
        InventoryBatch(
          id: '$id-batch',
          productId: id,
          batchNo: null,
          initialQuantity: stock,
          remainingQuantity: stock,
          isDiscarded: false,
          expiryDate: expiry,
          productionDate: null,
        ),
      ],
    );

void main() {
  final today = DateTime(2026, 9, 1);

  test('未来效期会生成临期和过期两个计划', () {
    final candidates = ReminderRules.candidates(
      [item('牛奶', expiry: DateTime(2026, 10, 15))],
      today: today,
    );
    expect(candidates.map((candidate) => candidate.type), containsAll([ReminderType.expiring, ReminderType.expired]));
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expiring).date, DateTime(2026, 9, 15));
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expired).date, DateTime(2026, 10, 16));
  });

  test('当前临期仍会提前注册后续过期提醒', () {
    final candidates = ReminderRules.candidates(
      [item('临期', expiry: DateTime(2026, 9, 10))],
      today: today,
    );
    expect(candidates.map((candidate) => candidate.type), containsAll([ReminderType.expiring, ReminderType.expired]));
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expiring).date, today);
    expect(candidates.firstWhere((candidate) => candidate.type == ReminderType.expired).date, DateTime(2026, 9, 11));
  });

  test('无效期商品不生成效期提醒', () {
    final candidates = ReminderRules.candidates([item('无效期')], today: today);
    expect(candidates.where((candidate) => candidate.type != ReminderType.lowStock), isEmpty);
  });

  test('当前临期、过期和低库存各生成一条提醒', () {
    final candidates = ReminderRules.candidates(
      [
        item('临期', expiry: DateTime(2026, 9, 10)),
        item('过期', expiry: DateTime(2026, 8, 31)),
        item('缺货', stock: 1, threshold: 1),
      ],
      today: today,
    );
    expect(candidates.map((candidate) => candidate.type), containsAll([
      ReminderType.expiring,
      ReminderType.expired,
      ReminderType.lowStock,
    ]));
  });
  test('展示提醒不包含为未来过期日预注册的通知计划', () {
    final visible = ReminderRules.visibleCandidates(
      [item('当前临期', expiry: DateTime(2026, 9, 10))],
      const [],
      today: today,
    );
    expect(visible.map((candidate) => candidate.type), [ReminderType.expiring]);
  });

  test('通知计划保留未来的临期和过期候选，展示列表不会提前显示', () {
    final target = item('未来效期', expiry: DateTime(2026, 10, 15));

    final scheduled = ReminderRules.unacknowledgedCandidates(
      [target],
      const [],
      today: today,
    );
    final visible = ReminderRules.visibleCandidates(
      [target],
      const [],
      today: today,
    );

    expect(scheduled.map((candidate) => candidate.type), [
      ReminderType.expiring,
      ReminderType.expired,
    ]);
    expect(visible, isEmpty);
  });

  test('已处理记录按提醒 key 和 fingerprint 过滤', () {
    final target = item('低库存', stock: 1, threshold: 1);
    final visible = ReminderRules.visibleCandidates(
      [target],
      [
        ReminderAcknowledgement(
          reminderKey: '低库存:low-stock',
          fingerprint: 'threshold:1',
          acknowledgedAt: today,
        ),
      ],
      today: today,
    );
    expect(visible, isEmpty);
  });

  test('提醒状态变化后新的 fingerprint 不会被旧记录隐藏', () {
    final target = item('低库存', stock: 1, threshold: 1);
    final visible = ReminderRules.visibleCandidates(
      [target],
      [
        ReminderAcknowledgement(
          reminderKey: '低库存:low-stock',
          fingerprint: 'threshold:2',
          acknowledgedAt: today,
        ),
      ],
      today: today,
    );
    expect(visible.map((candidate) => candidate.key), contains('低库存:low-stock'));
  });

  test('批次切换后效期 fingerprint 变化会重新显示提醒', () {
    final target = item('效期物品', expiry: DateTime(2026, 10, 15));
    final candidate = ReminderRules.candidates([target], today: today)
        .firstWhere((entry) => entry.type == ReminderType.expiring);
    final visible = ReminderRules.visibleCandidates(
      [target],
      [
        ReminderAcknowledgement(
          reminderKey: candidate.key,
          fingerprint: 'other-batch:2026-10-15T00:00:00.000',
          acknowledgedAt: today,
        ),
      ],
      today: today,
    );
    expect(visible, isNotEmpty);
  });
  test('摘要统计仅计算未来三天内到期的临期商品', () {
    final summary = ReminderSummary(
      expired: [item('已过期', expiry: DateTime(2026, 8, 31))],
      expiring: [
        item('今天到期', expiry: DateTime(2026, 9, 1)),
        item('两天后到期', expiry: DateTime(2026, 9, 3)),
        item('四天后到期', expiry: DateTime(2026, 9, 5)),
      ],
      lowStock: const [],
    );
    expect(summary.expiryAlertCount, 4);
    expect(summary.expiringWithinDays(3, today: today), 2);
  });

  test('提醒按处理紧急程度排序', () {
    final sorted = ReminderRules.sortByUrgency([
      ReminderCandidate(
        key: 'low:low-stock',
        fingerprint: 'threshold:2',
        type: ReminderType.lowStock,
        item: item('低库存', stock: 0, threshold: 2),
        date: today,
      ),
      ReminderCandidate(
        key: 'expiring:expiring',
        fingerprint: 'expiring',
        type: ReminderType.expiring,
        item: item('临期', expiry: DateTime(2026, 9, 2)),
        date: today,
      ),
      ReminderCandidate(
        key: 'expired:expired',
        fingerprint: 'expired',
        type: ReminderType.expired,
        item: item('过期', expiry: DateTime(2026, 8, 30)),
        date: today,
      ),
    ], today: today);
    expect(sorted.map((candidate) => candidate.type), [
      ReminderType.expired,
      ReminderType.expiring,
      ReminderType.lowStock,
    ]);
  });

}
