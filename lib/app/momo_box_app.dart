import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../application/sync_scheduler.dart';
import '../application/calendar_refresh_scheduler.dart';
import '../domain/models/inventory_models.dart';
import '../presentation/controllers/providers.dart';
import '../presentation/screens/alerts_screen.dart';
import '../presentation/screens/assistant_screen.dart';
import '../presentation/screens/home_screen.dart';
import '../presentation/screens/inventory_screen.dart';
import '../presentation/screens/product_detail_screen.dart';
import '../presentation/screens/settings_screen.dart';
import '../presentation/screens/shopping_screen.dart';
import '../presentation/screens/smart_home_screen.dart';
import '../presentation/screens/statistics_screen.dart';
import '../presentation/widgets/app_scaffold.dart';
import '../presentation/widgets/app_back_guard.dart';
import 'momo_theme.dart';
import 'momo_typography.dart';
import '../presentation/widgets/nas_required_gate.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppBackGuard(child: AppScaffold(child: child)),
        routes: [
          // Match the five navigation destinations; 今日 remains the default.
          GoRoute(path: '/assistant', builder: (context, state) => const AssistantScreen()),
          GoRoute(path: '/inventory', builder: (context, state) => const InventoryScreen()),
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          GoRoute(path: '/smart-home', builder: (context, state) => const SmartHomeScreen()),
          GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
        ],
      ),
      // 二级独立路由
      GoRoute(
        path: '/alerts',
        builder: (context, state) {
          final filter = state.uri.queryParameters['filter'];
          return AlertsScreen(initialFilter: filter);
        },
      ),
      GoRoute(path: '/shopping', builder: (context, state) => const ShoppingScreen()),
      GoRoute(path: '/statistics', builder: (context, state) => const StatisticsScreen()),
      GoRoute(
        path: '/inventory/:productId',
        builder: (context, state) => ProductDetailScreen(
          productId: state.pathParameters['productId']!,
        ),
      ),
    ],
  );
});

class MomoBoxApp extends ConsumerStatefulWidget {
  const MomoBoxApp({
    super.key,
    this.enableMediaReconciliation = true,
  });

  /// 允许测试跳过依赖平台目录的媒体清理；生产环境默认仍在启动时执行。
  final bool enableMediaReconciliation;

  @override
  ConsumerState<MomoBoxApp> createState() => _MomoBoxAppState();
}

class _MomoBoxAppState extends ConsumerState<MomoBoxApp> {
  late SyncScheduler _syncScheduler;
  late CalendarRefreshScheduler _calendarRefreshScheduler;

  @override
  void initState() {
    super.initState();
    ref.read(legacyClientCleanupProvider.future).catchError((_) {});
    ref.listenManual<CalendarRefreshScheduler>(
      calendarRefreshSchedulerProvider,
      (previous, next) {
        previous?.stop();
        _calendarRefreshScheduler = next;
        final items = ref.read(inventoryProvider).valueOrNull;
        if (items != null && items.isNotEmpty) {
          next.updateTimeZone(items.first.familyTimeZone);
        }
        next.start();
      },
      fireImmediately: true,
    );
    ref.listenManual<AsyncValue<List<InventoryItem>>>(
      inventoryProvider,
      (_, next) {
        if (!next.isLoading && !next.hasError) {
          next.whenData(_reconcileInventoryAndSync);
        }
      },
      fireImmediately: true,
    );
    ref.listenManual<AsyncValue<List<ReminderAcknowledgement>>>(
      reminderAcknowledgementsProvider,
      (_, next) => next.whenData((_) => _syncNotifications()),
      fireImmediately: true,
    );
    if (widget.enableMediaReconciliation) {
      Future<void>.microtask(_reconcileMedia);
    }
    // App mount owns observation, while the provider owns the scheduler. Keep
    // the mounted App attached if the provider is explicitly invalidated, so
    // manual and automatic requests never diverge onto different instances.
    ref.listenManual<SyncScheduler>(
      syncSchedulerProvider,
      (previous, next) {
        previous?.stop();
        _syncScheduler = next;
        next.start();
      },
      fireImmediately: true,
    );
  }

  @override
  void dispose() {
    _calendarRefreshScheduler.stop();
    _syncScheduler.stop();
    super.dispose();
  }

  Future<void> _reconcileMedia() async {
    try {
      await ref.read(mediaServiceProvider).reconcile();
    } catch (_) {
      // 媒体清理失败不应阻塞本地库存核心启动；设置页仍可重试。
    }
  }

  Future<void> _reconcileInventoryAndSync(List<InventoryItem> items) async {
    _calendarRefreshScheduler.updateTimeZone(
      items.isEmpty ? null : items.first.familyTimeZone,
    );
    // 低库存确认只在一个提醒周期内有效；库存恢复正常时清除旧确认。
    try {
      await ref.read(reminderServiceProvider).reconcile(items);
    } catch (_) {
      // 提醒状态清理失败不应阻塞库存页面或通知同步。
    }
    // Reconciliation can finish out of order. Always submit the latest view.
    if (mounted) _syncNotifications();
  }

  void _syncNotifications() {
    if (!mounted) return;
    final inventory = ref.read(inventoryProvider);
    final handled = ref.read(reminderAcknowledgementsProvider);
    if (inventory.isLoading || inventory.hasError || handled.isLoading || handled.hasError) return;
    final currentItems = inventory.asData?.value;
    final acknowledgements = handled.asData?.value;
    // Loading/error states must not erase existing plans or revive reminders
    // by substituting an empty acknowledgement list.
    if (currentItems == null || acknowledgements == null) return;
    // 通知是增强能力；平台调度失败不能阻塞本地库存页面。
    ref.read(localNotificationServiceProvider).sync(
      currentItems,
      acknowledgements: acknowledgements,
    ).catchError((_) {});
  }

  @override
  Widget build(BuildContext context) {
    final storedTheme = ref.watch(themeNameProvider).valueOrNull;
    final fontScale = ref.watch(fontScaleProvider).valueOrNull ?? 1.0;
    final palette = MomoPalette.fromStoredValue(storedTheme);
    return MaterialApp.router(
      title: '嬷嬷的小箱子',
      debugShowCheckedModeBanner: false,
      locale: const Locale('zh', 'CN'),
      supportedLocales: const [
        Locale('zh', 'CN'),
        Locale('en', 'US'),
      ],
      localizationsDelegates: const [
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      theme: buildMomoTheme(palette, Brightness.light),
      darkTheme: buildMomoTheme(palette, Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(appRouterProvider),
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return MediaQuery(
          data: media.copyWith(
            textScaler: MomoTextScaler(media.textScaler, fontScale),
          ),
          child: NasRequiredGate(child:child ?? const SizedBox.shrink()),
        );
      },
    );
  }
}
