import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/calendar_refresh_scheduler.dart';
import 'package:momo_box/domain/inventory/calendar_date.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';

void main() {
  testWidgets('family midnight refreshes expiry without any inventory write', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var now = DateTime.utc(2026, 11, 2, 15, 59, 59);
    var refreshes = 0;
    final expiry = CalendarDate.decode('2026-11-02');
    ExpiryStatus status() => ExpiryRules.statusFor(expiry,
      today: CalendarDate.today(timeZone: 'Asia/Shanghai', instant: now));
    var renderedStatus = status();
    final scheduler = CalendarRefreshScheduler(clock: () => now, onRefresh: () {
      refreshes++;
      renderedStatus = status();
    })..updateTimeZone('Asia/Shanghai');
    addTearDown(scheduler.dispose);
    scheduler.start();
    scheduler.start();
    expect(renderedStatus, ExpiryStatus.expiring);
    expect(refreshes, 0);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(renderedStatus, ExpiryStatus.expired);
    expect(refreshes, 1);
    now = now.add(const Duration(minutes: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 1);
    scheduler.dispose();
  });

  testWidgets('background stops timers; only a changed calendar refreshes on resume', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var now = DateTime.utc(2026, 11, 2, 4);
    var refreshes = 0;
    final scheduler = CalendarRefreshScheduler(clock: () => now,
      onRefresh: () => refreshes++)..updateTimeZone('Asia/Shanghai');
    addTearDown(scheduler.dispose);
    scheduler.start();
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(refreshes, 0); // Permission dialogs must not replan notifications.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    now = now.add(const Duration(days: 3));
    await tester.pump(const Duration(days: 3));
    expect(refreshes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(refreshes, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 1);
    scheduler.dispose();
  });

  testWidgets('clock jumps and timezone changes do not create a refresh loop', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var now = DateTime.utc(2026, 11, 2, 16, 30);
    var refreshes = 0;
    final scheduler = CalendarRefreshScheduler(clock: () => now,
      onRefresh: () => refreshes++)..updateTimeZone('Asia/Shanghai');
    addTearDown(scheduler.dispose);
    scheduler.start();
    scheduler.updateTimeZone('America/New_York');
    expect(refreshes, 0); // Inventory already refreshed the timezone.
    now = DateTime.utc(2026, 11, 3, 4, 59, 59);
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 0);
    now = now.add(const Duration(seconds: 1));
    await tester.pump(const Duration(seconds: 1));
    expect(refreshes, 1);
    now = now.subtract(const Duration(days: 1));
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 2);
    scheduler.updateTimeZone('America/New_York');
    await tester.pump(const Duration(minutes: 1));
    expect(refreshes, 2);
    scheduler.dispose();
  });

  testWidgets('stop/remount and disposal release all timers and lifecycle observation', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    var now = DateTime.utc(2026, 11, 2);
    var refreshes = 0;
    final scheduler = CalendarRefreshScheduler(clock: () => now,
      onRefresh: () => refreshes++)..updateTimeZone('Asia/Shanghai');
    addTearDown(scheduler.dispose);
    scheduler.start();
    scheduler.stop();
    now = now.add(const Duration(days: 1));
    await tester.pump(const Duration(days: 1));
    expect(refreshes, 0);
    scheduler.start();
    expect(refreshes, 1);
    scheduler.dispose();
    scheduler.start();
    now = now.add(const Duration(days: 1));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump(const Duration(days: 1));
    expect(refreshes, 1);
  });

  testWidgets('mounting in background waits for resume', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    var now = DateTime.utc(2026, 11, 2);
    var refreshes = 0;
    final scheduler = CalendarRefreshScheduler(clock: () => now,
      onRefresh: () => refreshes++);
    addTearDown(scheduler.dispose);
    scheduler.start();
    now = now.add(const Duration(days: 1));
    await tester.pump(const Duration(days: 1));
    expect(refreshes, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    expect(refreshes, 1);
    scheduler.dispose();
  });
}
