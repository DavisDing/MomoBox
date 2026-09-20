import 'dart:async';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/services/local_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final now = DateTime(2026, 9, 15, 8);

  test('旧通知排程暂停时，新确认同步必须等待，最终不能复活提醒', () async {
    final plugin = _RecordingPlugin()..blockFirstSchedule = true;
    final service = LocalNotificationService(plugin: plugin);
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
    final service = LocalNotificationService(plugin: plugin);
    await service.initialize();
    final first = service.sync([_lowStockItem(1)], now: now);
    await plugin.scheduleEntered.future;
    final last = service.sync([_lowStockItem(2)], now: now);
    plugin.releaseSchedule.complete();
    await Future.wait([first, last]);
    expect(plugin.pending, hasLength(1));
    expect(plugin.pending.values.single, contains('剩余 2 件'));
  });

  test('通知权限拒绝时跳过排程，不影响同步调用完成', () async {
    final plugin = _RecordingPlugin();
    final service = LocalNotificationService(
      plugin: plugin,
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
    final service = LocalNotificationService(plugin: plugin);
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

// Only the platform boundary is faked; sync ordering and reminder rules are real.
class _RecordingPlugin implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
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
