import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:timezone/timezone.dart' as tz;
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/services/local_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 9, 15, 8);

  test('通知预算先保留近期计划，与库存输入顺序无关', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(plugin: plugin,
      localTimeZoneReader: () async => 'UTC', pendingNotificationLimit: 1);
    await service.initialize();
    await service.sync([
      _expiryItem(DateTime(2026, 11, 1), id: 'later',
        policy: const ReminderPolicy(lowStockThreshold: 1)),
      _expiryItem(DateTime(2026, 9, 17), id: 'soon',
        policy: const ReminderPolicy(lowStockThreshold: 1)),
    ], now: DateTime.utc(2026, 9, 15, 8), acknowledgements: [
      for (final id in ['later', 'soon']) ReminderAcknowledgement(
        reminderKey: '$id:low-stock', fingerprint: 'threshold:1', acknowledgedAt: now)
    ]);
    expect(plugin.scheduleCalls, 1);
    expect(plugin.scheduledPayloads.single, 'soon');
    expect(plugin.scheduledTimes.single.day, 15);
  });

  test('DST 切换后的次日仍在目标家庭时区九点，且严格晚于现在', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(plugin: plugin,
      localTimeZoneReader: () async => 'UTC');
    await service.initialize();
    final reference = DateTime.utc(2026, 11, 1, 16); // New York 11:00 after fallback.
    await service.sync([_expiryItem(DateTime(2026, 10, 1),
      familyTimeZone: 'America/New_York')], now: reference);
    for (final scheduled in plugin.scheduledTimes) {
      expect(scheduled.isAfter(reference), isTrue);
      expect(scheduled.day, 2);
      expect(scheduled.hour, 9);
      expect(scheduled.timeZoneOffset, const Duration(hours: -5));
    }
    expect(plugin.scheduleCalls, greaterThan(0));
  });

  test('设备时区失败时不静默用UTC覆盖旧计划，家庭时区仍可调度', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(plugin: plugin,
      localTimeZoneReader: () async => throw StateError('unavailable'));
    await service.initialize();
    await expectLater(service.sync([_lowStockItem(1)], now: now), throwsStateError);
    expect(plugin.cancelCalls, 0);
    await service.sync([_expiryItem(DateTime(2026, 9, 17),
      familyTimeZone: 'Asia/Shanghai')], now: now);
    expect(plugin.scheduleCalls, greaterThan(0));
    expect(plugin.scheduledTimes.every((t) => t.location.name == 'Asia/Shanghai'), isTrue);
  });

  test('设备时区API恢复后下一次同步可重试，无需重启服务', () async {
    final plugin = _RecordingPlugin();
    var fail = true;
    final service = LocalNotificationService(plugin: plugin, localTimeZoneReader: () async {
      if (fail) throw StateError('temporarily unavailable');
      return 'UTC';
    });
    await service.initialize();
    await expectLater(service.sync([_lowStockItem(1)], now: now), throwsStateError);
    fail = false;
    await service.sync([_lowStockItem(1)], now: now);
    expect(plugin.pending, hasLength(1));
  });

  test('旧通知排程暂停时，新确认同步必须等待，最终不能复活提醒', () async {
    final plugin = _RecordingPlugin()..blockFirstSchedule = true;
    final service = LocalNotificationService(plugin: plugin, localTimeZoneReader: () async => 'UTC');
    await service.initialize();
    final items = [_lowStockItem(1)];
    final candidate = ReminderRules.candidates(items, today: now).single;

    final oldSync = service.sync(items, now: now);
    await plugin.scheduleEntered.future;
    final newSync = service.sync(items, now: now, acknowledgements: [
      ReminderAcknowledgement(
        reminderKey: candidate.key,
        fingerprint: candidate.fingerprint,
        acknowledgedAt: now,
      ),
    ]);
    await Future<void>.delayed(Duration.zero);
    expect(plugin.cancelCalls, 1);
    plugin.releaseSchedule.complete();
    await Future.wait([oldSync, newSync]);
    expect(plugin.cancelCalls, 2);
    expect(plugin.pending, isEmpty);
  });

  test('并发库存更新后仅保留最新数量的通知', () async {
    final plugin = _RecordingPlugin()..blockFirstSchedule = true;
    final service = LocalNotificationService(plugin: plugin, localTimeZoneReader: () async => 'UTC');
    await service.initialize();
    final first = service.sync([_lowStockItem(1)], now: now);
    await plugin.scheduleEntered.future;
    final last = service.sync([_lowStockItem(2)], now: now);
    plugin.releaseSchedule.complete();
    await Future.wait([first, last]);
    expect(plugin.pending, hasLength(1));
    expect(plugin.pending.values.single, contains('剩余 2 件'));
  });

  test('通知正文使用商品有效临期窗口而非写死三十天', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(
      plugin: plugin,
      localTimeZoneReader: () async => 'UTC',
      permissionStatusReader: () async => NotificationPermissionStatus.allowed,
    );
    await service.initialize();
    await service.sync([
      _expiryItem(now.add(const Duration(days: 7))),
    ], now: now);

    // 库存等于阈值仍触发低库存，未过期批次还会预排程未来过期通知。
    expect(plugin.pending, hasLength(3));
    expect(plugin.pending.values, contains('酸奶 剩余 1 件，低于阈值 1。'));
    expect(plugin.pending.values, contains('酸奶 有批次已过期，请检查并报废。'));
    final expiringBodies = plugin.pending.values
        .where((body) => body.startsWith('酸奶 将在 '))
        .toList();
    expect(expiringBodies, hasLength(1));
    expect(expiringBodies.single, contains('将在 7 天内到期'));
    expect(expiringBodies.single, isNot(contains('30 天')));
  });

  test('有效提醒策略关闭时取消此前全部排程且不新增通知', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(
      plugin: plugin,
      localTimeZoneReader: () async => 'UTC',
      permissionStatusReader: () async => NotificationPermissionStatus.allowed,
    );
    await service.initialize();
    final expiryDate = now.add(const Duration(days: 7));
    await service.sync([_expiryItem(expiryDate)], now: now);

    // 必须先真实走过服务排程，不能从空 pending 推断取消成功。
    expect(plugin.cancelCalls, 1);
    expect(plugin.scheduleCalls, 3);
    expect(plugin.pending, hasLength(3));

    // 商品、批次、库存、到期日和临期窗口不变，仅关闭有效策略。
    await service.sync([
      _expiryItem(
        expiryDate,
        policy: const ReminderPolicy(enabled: false, expiryWarningDays: 7),
      ),
    ], now: now);

    expect(plugin.cancelCalls, 2);
    expect(plugin.scheduleCalls, 3);
    expect(plugin.pending, isEmpty);
  });

  test('通知权限拒绝时跳过排程，不影响同步调用完成', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(
      plugin: plugin,
      localTimeZoneReader: () async => 'UTC',
      permissionStatusReader: () async => NotificationPermissionStatus.denied,
    );
    await service.initialize();

    await service.sync([_lowStockItem(1)], now: now);

    expect(plugin.cancelCalls, 0);
    expect(plugin.scheduleCalls, 0);
  });

  test('通知平台不可用时跳过排程并保持后续同步可用', () async {
    final plugin = _RecordingPlugin();
    var statusCalls = 0;
    final service = LocalNotificationService(
      plugin: plugin,
      localTimeZoneReader: () async => 'UTC',
      permissionStatusReader: () async {
        statusCalls++;
        return NotificationPermissionStatus.unavailable;
      },
    );
    await service.initialize();

    await service.sync([_lowStockItem(1)], now: now);
    await service.sync([_lowStockItem(2)], now: now);

    expect(statusCalls, 2);
    expect(plugin.cancelCalls, 0);
    expect(plugin.scheduleCalls, 0);
  });

  test('一次排程失败会返回错误，但不会阻塞后续同步', () async {
    final plugin = _RecordingPlugin()..failNextCancel = true;
    final service = LocalNotificationService(plugin: plugin, localTimeZoneReader: () async => 'UTC');
    await service.initialize();
    await expectLater(service.sync([_lowStockItem(1)], now: now), throwsStateError);
    await service.sync([_lowStockItem(2)], now: now);
    expect(plugin.pending.values.single, contains('剩余 2 件'));
  });
}

InventoryItem _lowStockItem(int quantity) => InventoryItem(
      id: 'item', name: '纸巾', category: '其他物品', brand: null,
      specification: null, barcode: null, location: null, unit: '件',
      lowStockThreshold: 3,
      batches: [
        InventoryBatch(
          id: 'batch', productId: 'item', batchNo: null,
          productionDate: null, expiryDate: null, initialQuantity: 3,
          remainingQuantity: quantity, isDiscarded: false,
        ),
      ],
    );

InventoryItem _expiryItem(
  DateTime expiryDate, {
  ReminderPolicy policy = const ReminderPolicy(expiryWarningDays: 7),
  String id = 'expiry-item',
  String? familyTimeZone,
}) =>
    InventoryItem(
      id: id, name: '酸奶', category: '食品', brand: null,
      specification: null, barcode: null, location: null, unit: '件',
      lowStockThreshold: 1,
      reminderPolicy: policy,
      familyTimeZone: familyTimeZone,
      batches: [
        InventoryBatch(
          id: '$id-batch', productId: id, batchNo: null,
          productionDate: null, expiryDate: expiryDate,
          initialQuantity: 1, remainingQuantity: 1, isDiscarded: false,
          reminderPolicy: policy,
        ),
      ],
    );

// Only the platform boundary is faked; sync ordering and reminder rules are real.
class _RecordingPlugin implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  final scheduledTimes = <tz.TZDateTime>[];
  final scheduledPayloads = <String>[];
  final scheduleEntered = Completer<void>();
  final releaseSchedule = Completer<void>();
  bool blockFirstSchedule = false;
  bool failNextCancel = false;
  int cancelCalls = 0;
  int scheduleCalls = 0;

  @override
  Future<void> cancelAll() async {
    cancelCalls++;
    if (failNextCancel) {
      failNextCancel = false;
      throw StateError('test scheduling failure');
    }
    pending.clear();
  }

  Future<void> _recordSchedule(Invocation invocation) async {
    scheduleCalls++;
    scheduledTimes.add(invocation.positionalArguments[3] as tz.TZDateTime);
    scheduledPayloads.add(invocation.namedArguments[#payload] as String);
    if (scheduleCalls == 1) {
      scheduleEntered.complete();
      if (blockFirstSchedule) await releaseSchedule.future;
    }
    pending[invocation.positionalArguments[0] as int] =
        invocation.positionalArguments[2] as String;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #initialize) return Future<bool?>.value(true);
    if (invocation.memberName == #zonedSchedule) return _recordSchedule(invocation);
    return super.noSuchMethod(invocation);
  }
}
