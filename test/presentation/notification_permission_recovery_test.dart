import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/services/local_notification_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late _RecordingPlugin plugin;
  late _PermissionService service;
  late StreamController<List<InventoryItem>> inventory;
  late StreamController<List<ReminderAcknowledgement>> acknowledgements;
  late ProviderContainer container;

  tearDown(() async {
    container.dispose();
    await inventory.close();
    await acknowledgements.close();
  });

  Future<void> mount(WidgetTester tester, {bool seed = true}) async {
    // Create async sources and the scheduling queue in the Widget fake zone.
    // Real-zone futures otherwise cannot progress while only pumping frames.
    plugin = _RecordingPlugin();
    service = _PermissionService(plugin);
    await tester.runAsync(service.initialize);
    service.permissionRequests = 0;
    inventory = StreamController<List<InventoryItem>>.broadcast();
    acknowledgements = StreamController<List<ReminderAcknowledgement>>.broadcast();
    container = ProviderContainer(overrides: [
      localNotificationServiceProvider.overrideWithValue(service),
      inventoryProvider.overrideWith((ref) => inventory.stream),
      reminderAcknowledgementsProvider.overrideWith((ref) => acknowledgements.stream),
    ]);
    // Keep streams subscribed even while the initial permission is denied.
    container.listen(inventoryProvider, (_, __) {});
    container.listen(reminderAcknowledgementsProvider, (_, __) {});
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: const MaterialApp(home: NotificationSettingsScreen()),
    ));
    if (seed) {
      inventory.add([_item('old', 1)]);
      acknowledgements.add([]);
    }
    await tester.pumpAndSettle();
    expect(find.text('未允许'), findsOneWidget);
  }

  testWidgets('授权成功无库存事件也立即重排正式通知，并过滤已确认提醒', (tester) async {
    await mount(tester);
    final handled = _item('handled', 1);
    inventory.add([_item('current', 2), handled]);
    acknowledgements.add([_acknowledge(handled)]);
    await tester.pumpAndSettle();
    service.permissionResult = true;

    await tester.tap(find.text('请求授权'));
    await tester.pumpAndSettle();

    expect(find.text('已允许'), findsOneWidget);
    expect(service.permissionRequests, 1);
    expect(plugin.cancelCalls, 1);
    expect(plugin.pending.values.single, contains('剩余 2 件'));
    expect(service.lastItems!.map((item) => item.id), ['current', 'handled']);
    expect(service.lastAcknowledgements, hasLength(1));
    expect(service.testCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('授权等待期间库存与确认变化，使用完成时的最新值', (tester) async {
    await mount(tester);
    service.permissionGate = Completer<bool>();
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    inventory.add([_item('latest', 2), _item('handled', 1)]);
    acknowledgements.add([_acknowledge(_item('handled', 1))]);
    await tester.pump();
    service.permissionGate!.complete(true);
    await tester.pumpAndSettle();

    expect(service.lastItems!.first.id, 'latest');
    expect(plugin.pending, hasLength(1));
    expect(plugin.pending.values.single, contains('剩余 2 件'));
  });

  testWidgets('确认流仍加载时不以空确认排程，等待期间再次读取最新库存', (tester) async {
    await mount(tester, seed: false);
    inventory.add([_item('old', 1)]);
    await tester.pump();
    service.permissionResult = true;
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    expect(plugin.cancelCalls, 0);
    inventory.add([_item('latest', 2), _item('handled', 1)]);
    await tester.pump();
    acknowledgements.add([_acknowledge(_item('handled', 1))]);
    await tester.pumpAndSettle();

    expect(service.lastItems!.first.id, 'latest');
    expect(plugin.pending, hasLength(1));
    expect(plugin.pending.values.single, contains('剩余 2 件'));
  });

  testWidgets('拒绝或权限读取失败不排程，失败后入口恢复', (tester) async {
    await mount(tester);
    await tester.tap(find.text('请求授权'));
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    service.failStatus = true;
    await tester.tap(find.text('请求授权'));
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '请求授权')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('系统设置返回仅检查权限，不再次弹授权框，恢复正式通知', (tester) async {
    await mount(tester);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    service.status = NotificationPermissionStatus.allowed;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();

    expect(find.text('已允许'), findsOneWidget);
    expect(service.permissionRequests, 0);
    expect(plugin.pending, hasLength(1));
    // Removing the page also removes its lifecycle observer.
    await tester.pumpWidget(const SizedBox.shrink());
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('授权对话框返回与授权 Future 重叠时不重入，最终重排', (tester) async {
    await mount(tester);
    service.permissionGate = Completer<bool>();
    final staleCallback = tester.widget<TextButton>(find.widgetWithText(TextButton, '请求授权')).onPressed!;
    staleCallback();
    staleCallback();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(service.permissionRequests, 1);
    expect(plugin.cancelCalls, 0);
    service.permissionGate!.complete(true);
    await tester.pumpAndSettle();
    expect(plugin.pending, hasLength(1));
    expect(find.text('已允许'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('排程失败保持权限真实且可重试，不阻塞设置页', (tester) async {
    await mount(tester);
    service.permissionResult = true;
    plugin.failNextCancel = true;
    await tester.tap(find.text('请求授权'));
    await tester.pumpAndSettle();
    expect(find.text('已允许'), findsOneWidget);
    expect(plugin.pending, isEmpty);
    expect(find.textContaining('无法刷新通知状态或重排提醒'), findsOneWidget);
    await tester.tap(find.text('重新检查'));
    await tester.pumpAndSettle();
    expect(plugin.pending, hasLength(1));
    expect(tester.takeException(), isNull);
  });

  testWidgets('库存读取失败不清空旧通知或安排空确认，重试后可恢复', (tester) async {
    await mount(tester);
    inventory.addError(StateError('inventory unavailable'));
    await tester.pump();
    service.permissionResult = true;
    await tester.tap(find.text('请求授权'));
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    inventory.add([_item('recovered', 2)]);
    await tester.pumpAndSettle();
    await tester.tap(find.text('重新检查'));
    await tester.pumpAndSettle();
    expect(plugin.pending.values.single, contains('剩余 2 件'));
    expect(tester.takeException(), isNull);
  });

  testWidgets('等待确认流时库存变为错误，不使用上一份缓存库存排程', (tester) async {
    await mount(tester, seed: false);
    inventory.add([_item('old', 1)]);
    await tester.pump();
    service.permissionResult = true;
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    inventory.addError(StateError('inventory unavailable'));
    await tester.pump();
    acknowledgements.add([]);
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    expect(find.textContaining('无法刷新通知状态或重排提醒'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '重新检查')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('页面销毁后授权回执不访问 ref 或安排通知', (tester) async {
    await mount(tester);
    service.permissionGate = Completer<bool>();
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    service.permissionGate!.complete(true);
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('一条 provider 失败时无需等待另一条首次数据，恢复入口', (tester) async {
    await mount(tester, seed: false);
    service.permissionResult = true;
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    inventory.addError(StateError('inventory unavailable'));
    // The acknowledgement stream deliberately never emits a first value.
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    expect(find.textContaining('无法刷新通知状态或重排提醒'), findsOneWidget);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, '重新检查')).onPressed, isNotNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider future 等待中卸载，迟到数据不访问 ref 或排程', (tester) async {
    await mount(tester, seed: false);
    service.permissionResult = true;
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    expect(plugin.cancelCalls, 0);
    await tester.pumpWidget(const SizedBox.shrink());
    inventory.add([_item('late', 1)]);
    acknowledgements.add([]);
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    expect(service.lastItems, isNull);
    expect(tester.takeException(), isNull);
  });

  testWidgets('provider 等待中卸载后的迟到错误被捕获，不更新已销毁页面', (tester) async {
    await mount(tester, seed: false);
    service.permissionResult = true;
    await tester.tap(find.text('请求授权'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    inventory.addError(StateError('late inventory error'));
    acknowledgements.add([]);
    await tester.pumpAndSettle();
    expect(plugin.cancelCalls, 0);
    expect(tester.takeException(), isNull);
  });

  testWidgets('测试通知等待期间 resumed 的补检查也不调用 cancelAll', (tester) async {
    await mount(tester);
    service.status = NotificationPermissionStatus.allowed;
    service.testGate = Completer<void>();
    await tester.tap(find.text('发送测试提醒'));
    await tester.pump();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    service.testGate!.complete();
    await tester.pumpAndSettle();
    expect(service.testCalls, 1);
    expect(plugin.cancelCalls, 0);
    expect(find.text('已允许'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('发送测试提醒不被随后的业务重排取消', (tester) async {
    await mount(tester);
    service.status = NotificationPermissionStatus.allowed;
    await tester.tap(find.text('发送测试提醒'));
    await tester.pumpAndSettle();
    expect(service.testCalls, 1);
    expect(plugin.cancelCalls, 0);
    expect(tester.takeException(), isNull);
  });
}

InventoryItem _item(String id, int quantity) => InventoryItem(
      id: id,
      name: id,
      category: '其他物品',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: 3,
      batches: [
        InventoryBatch(
          id: '$id-batch',
          productId: id,
          batchNo: null,
          productionDate: null,
          expiryDate: null,
          initialQuantity: 3,
          remainingQuantity: quantity,
          isDiscarded: false,
        ),
      ],
    );

ReminderAcknowledgement _acknowledge(InventoryItem item) {
  final candidate = ReminderRules.candidates([item]).single;
  return ReminderAcknowledgement(
    reminderKey: candidate.key,
    fingerprint: candidate.fingerprint,
    acknowledgedAt: DateTime.now(),
  );
}

// Fake only permission/platform boundaries; scheduling and filtering stay real.
class _PermissionService extends LocalNotificationService {
  _PermissionService(_RecordingPlugin plugin)
      : super(plugin: plugin, permissionStatusReader: () async => NotificationPermissionStatus.allowed);

  NotificationPermissionStatus status = NotificationPermissionStatus.denied;
  bool permissionResult = false;
  bool failStatus = false;
  Completer<bool>? permissionGate;
  int permissionRequests = 0;
  int testCalls = 0;
  Completer<void>? testGate;
  List<InventoryItem>? lastItems;
  List<ReminderAcknowledgement>? lastAcknowledgements;

  @override
  Future<NotificationPermissionStatus> permissionStatus() async {
    if (failStatus) throw StateError('permission unavailable');
    return status;
  }

  @override
  Future<bool> requestPermission() async {
    permissionRequests++;
    final granted = permissionGate == null ? permissionResult : await permissionGate!.future;
    if (granted) status = NotificationPermissionStatus.allowed;
    return granted;
  }

  @override
  Future<void> sync(
    List<InventoryItem> items, {
    Iterable<ReminderAcknowledgement> acknowledgements = const [],
    DateTime? now,
  }) {
    lastItems = items;
    lastAcknowledgements = acknowledgements.toList();
    return super.sync(items, acknowledgements: acknowledgements, now: now);
  }

  @override
  Future<void> showTestNotification() async {
    testCalls++;
    if (testGate != null) await testGate!.future;
  }
}

class _RecordingPlugin implements FlutterLocalNotificationsPlugin {
  final pending = <int, String>{};
  int cancelCalls = 0;
  bool failNextCancel = false;

  @override
  Future<void> cancelAll() async {
    cancelCalls++;
    if (failNextCancel) {
      failNextCancel = false;
      throw StateError('scheduling unavailable');
    }
    pending.clear();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #initialize) return Future<bool?>.value(true);
    if (invocation.memberName == #zonedSchedule) {
      pending[invocation.positionalArguments[0] as int] = invocation.positionalArguments[2] as String;
      return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}
