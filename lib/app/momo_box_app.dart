import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models/inventory_models.dart';
import '../presentation/controllers/providers.dart';
import '../presentation/screens/alerts_screen.dart';
import '../presentation/screens/home_screen.dart';
import '../presentation/screens/inventory_screen.dart';
import '../presentation/screens/product_detail_screen.dart';
import '../presentation/screens/settings_screen.dart';
import '../presentation/screens/shopping_screen.dart';
import '../presentation/screens/smart_home_screen.dart';
import '../presentation/widgets/app_scaffold.dart';
import 'momo_theme.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppScaffold(child: child),
        routes: [
          // 1. 首页 (Home / Dashboard)
          GoRoute(path: '/', builder: (context, state) => const HomeScreen()),
          // 2. 库存 (Inventory)
          GoRoute(path: '/inventory', builder: (context, state) => const InventoryScreen()),
          // 3. 家居 (Home Assistant 设备与场景)
          GoRoute(path: '/smart-home', builder: (context, state) => const SmartHomeScreen()),
          // 4. 我的 (Settings / Profile)
          GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
          GoRoute(path: '/profile', builder: (context, state) => const SettingsScreen()),
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
  @override
  void initState() {
    super.initState();
    ref.listenManual<AsyncValue<List<InventoryItem>>>(
      inventoryProvider,
      (_, next) => next.whenData(_reconcileInventoryAndSync),
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
  }

  Future<void> _reconcileMedia() async {
    try {
      await ref.read(mediaServiceProvider).reconcile();
    } catch (_) {
      // 媒体清理失败不应阻塞本地库存核心启动；设置页仍可重试。
    }
  }

  Future<void> _reconcileInventoryAndSync(List<InventoryItem> items) async {
    // 低库存确认只在一个提醒周期内有效；库存恢复正常时清除旧确认。
    try {
      await ref.read(reminderServiceProvider).reconcile(items);
    } catch (_) {
      // 提醒状态清理失败不应阻塞库存页面或通知同步。
    }
    _syncNotifications(items: items);
  }

  void _syncNotifications({List<InventoryItem>? items}) {
    final currentItems = items ?? ref.read(inventoryProvider).valueOrNull;
    final acknowledgements = ref.read(reminderAcknowledgementsProvider).valueOrNull ??
        const <ReminderAcknowledgement>[];
    if (currentItems == null) return;
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
            textScaler: TextScaler.linear(fontScale),
          ),
          child: child ?? const SizedBox.shrink(),
        );
      },
    );
  }
}
