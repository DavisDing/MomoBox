import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/application/network_status_source.dart';
import 'package:momo_box/application/reminder_service.dart';
import 'package:momo_box/application/sync_scheduler.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/services/local_notification_service.dart';

class _Network implements NetworkStatusSource {
  @override
  Stream<NetworkAvailability> get changes => const Stream.empty();

  @override
  Future<NetworkAvailability> get current async => NetworkAvailability.offline;

  @override
  void dispose() {}
}

class _Reminders implements ReminderService {
  @override
  Future<void> reconcile(List<InventoryItem> items) async {}

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Notifications extends LocalNotificationService {
  bool allowed = false;
  int permissionChecks = 0;
  final plans = <List<ReminderCandidate>>[];

  @override
  Future<void> sync(List<InventoryItem> items, {
    DateTime? now,
    Iterable<ReminderAcknowledgement> acknowledgements = const [],
  }) async {
    permissionChecks++;
    if (allowed) {
      plans.add(ReminderRules.unacknowledgedCandidates(items, acknowledgements));
    }
  }
}

InventoryItem _item(String id) => InventoryItem(
  id: id, name: id, category: '其他物品', brand: null, specification: null,
  barcode: null, location: null, unit: '件', lowStockThreshold: 3,
  familyTimeZone: 'Asia/Shanghai',
  batches: [InventoryBatch(
    id: '$id-batch', productId: id, batchNo: null, initialQuantity: 2,
    remainingQuantity: 2, isDiscarded: false, expiryDate: null,
    productionDate: null, familyTimeZone: 'Asia/Shanghai',
  )],
);

void main() {
  testWidgets('cross-day resume reloads inventory and notifications with real acknowledgement filtering', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final handled = _item('handled');
    var items = [handled];
    final candidate = ReminderRules.candidates([handled]).single;
    final acknowledgements = [ReminderAcknowledgement(
      reminderKey: candidate.key, fingerprint: candidate.fingerprint,
      acknowledgedAt: DateTime.now(),
    )];
    var reads = 0;
    var now = DateTime.utc(2026, 11, 2, 15, 59, 59);
    final notifications = _Notifications();
    final scheduler = SyncScheduler(engineReader: () => null,
      foregroundPullInterval: Duration.zero, networkStatusSource: _Network());
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => Consumer(builder: (_, ref, __) {
        return Text('待处理 ${ref.watch(reminderSummaryProvider).lowStock.length}');
      })),
    ]);
    final container = ProviderContainer(overrides: [
      appRouterProvider.overrideWithValue(router),
      calendarClockProvider.overrideWithValue(() => now),
      syncSchedulerProvider.overrideWithValue(scheduler),
      inventoryProvider.overrideWith((ref) {
        reads++;
        return Stream.value(items);
      }),
      reminderAcknowledgementsProvider.overrideWith((ref) => Stream.value(acknowledgements)),
      reminderServiceProvider.overrideWithValue(_Reminders()),
      localNotificationServiceProvider.overrideWithValue(notifications),
      themeNameProvider.overrideWith((ref) => Stream.value('default')),
      fontScaleProvider.overrideWith((ref) => Stream.value(1.0)),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: const MomoBoxApp(enableMediaReconciliation: false)));
      await tester.pumpAndSettle();
      expect(reads, 1);
      expect(find.text('待处理 0'), findsOneWidget);
      expect(notifications.plans, isEmpty);

      // No DB event: system settings granted permission while backgrounded.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      notifications.allowed = true;
      items = [handled, _item('latest')];
      now = now.add(const Duration(seconds: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 2);
      expect(find.text('待处理 1'), findsOneWidget);
      expect(notifications.plans, hasLength(1));
      expect(notifications.plans.single.map((plan) => plan.item.id), ['latest']);

      // Mounted App follows a replaced provider, leaving one timer owner.
      container.invalidate(calendarRefreshSchedulerProvider);
      await tester.pumpAndSettle();
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      now = now.add(const Duration(days: 1));
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
      expect(reads, 3);
      expect(notifications.plans, hasLength(2));

      final checks = notifications.permissionChecks;
      await tester.pumpWidget(const SizedBox.shrink());
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pump(const Duration(days: 1));
      expect(reads, 3);
      expect(notifications.permissionChecks, checks);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      scheduler.dispose();
      router.dispose();
      await tester.pump(Duration.zero);
    }
  });

  testWidgets('loading or failed acknowledgement reads preserve existing plans until fresh data arrives', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final items = StreamController<List<InventoryItem>>();
    final acknowledgements = StreamController<List<ReminderAcknowledgement>>();
    final notifications = _Notifications()..allowed = true;
    final scheduler = SyncScheduler(engineReader: () => null,
      foregroundPullInterval: Duration.zero, networkStatusSource: _Network());
    final router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
    ]);
    final container = ProviderContainer(overrides: [
      appRouterProvider.overrideWithValue(router),
      calendarClockProvider.overrideWithValue(() => DateTime.utc(2026, 11, 2, 4)),
      syncSchedulerProvider.overrideWithValue(scheduler),
      inventoryProvider.overrideWith((ref) => items.stream),
      reminderAcknowledgementsProvider.overrideWith((ref) => acknowledgements.stream),
      reminderServiceProvider.overrideWithValue(_Reminders()),
      localNotificationServiceProvider.overrideWithValue(notifications),
      themeNameProvider.overrideWith((ref) => Stream.value('default')),
      fontScaleProvider.overrideWith((ref) => Stream.value(1.0)),
    ]);
    try {
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
        child: const MomoBoxApp(enableMediaReconciliation: false)));
      items.add([_item('first')]);
      await tester.pumpAndSettle();
      expect(notifications.permissionChecks, 0);
      acknowledgements.addError(StateError('acknowledgements unavailable'));
      items.add([_item('second')]);
      await tester.pumpAndSettle();
      expect(notifications.permissionChecks, 0);
      acknowledgements.add([]);
      await tester.pumpAndSettle();
      expect(notifications.plans, hasLength(1));
      expect(notifications.plans.single.single.item.id, 'second');

      // AsyncError may retain previous data; it must still block scheduling.
      acknowledgements.addError(StateError('acknowledgements failed again'));
      items.add([_item('third')]);
      await tester.pumpAndSettle();
      expect(notifications.plans, hasLength(1));
      acknowledgements.add([]);
      await tester.pumpAndSettle();
      expect(notifications.plans, hasLength(2));
      expect(notifications.plans.last.single.item.id, 'third');

      items.addError(StateError('inventory failed'));
      acknowledgements.add([]);
      await tester.pumpAndSettle();
      expect(notifications.plans, hasLength(2));
      items.add([_item('recovered')]);
      await tester.pumpAndSettle();
      expect(notifications.plans.last.single.item.id, 'recovered');
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      container.dispose();
      scheduler.dispose();
      router.dispose();
      await items.close();
      await acknowledgements.close();
      await tester.pump(Duration.zero);
    }
  });
}
