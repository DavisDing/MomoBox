import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models/inventory_models.dart';
import '../presentation/controllers/providers.dart';
import '../presentation/screens/alerts_screen.dart';
import '../presentation/screens/inventory_screen.dart';
import '../presentation/screens/product_detail_screen.dart';
import '../presentation/screens/settings_screen.dart';
import '../presentation/screens/shopping_screen.dart';
import '../presentation/widgets/app_scaffold.dart';
import 'momo_theme.dart';

final appRouterProvider = Provider<GoRouter>((ref) {
  return GoRouter(
    initialLocation: '/',
    routes: [
      ShellRoute(
        builder: (context, state, child) => AppScaffold(child: child),
        routes: [
          GoRoute(path: '/', builder: (context, state) => const InventoryScreen()),
          GoRoute(path: '/alerts', builder: (context, state) => const AlertsScreen()),
          GoRoute(path: '/shopping', builder: (context, state) => const ShoppingScreen()),
          GoRoute(path: '/settings', builder: (context, state) => const SettingsScreen()),
        ],
      ),
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
  const MomoBoxApp({super.key});

  @override
  ConsumerState<MomoBoxApp> createState() => _MomoBoxAppState();
}

class _MomoBoxAppState extends ConsumerState<MomoBoxApp> {
  @override
  Widget build(BuildContext context) {
    void syncNotifications() {
      final items = ref.read(inventoryProvider).valueOrNull;
      final acknowledgements = ref.read(reminderAcknowledgementsProvider).valueOrNull ??
          const <ReminderAcknowledgement>[];
      if (items == null) return;
      // 通知是增强能力；平台调度失败不能阻塞本地库存页面。
      ref.read(localNotificationServiceProvider).sync(
        items,
        acknowledgements: acknowledgements,
      ).catchError((_) {});
    }

    ref.listen<AsyncValue<List<InventoryItem>>>(inventoryProvider, (_, next) {
      next.whenData((items) async {
        // 低库存确认只在一个提醒周期内有效；库存恢复正常时清除旧确认。
        try {
          await ref.read(reminderServiceProvider).reconcile(items);
        } catch (_) {
          // 提醒状态清理失败不应阻塞库存页面或通知同步。
        }
        syncNotifications();
      });
    }, fireImmediately: true);
    ref.listen<AsyncValue<List<ReminderAcknowledgement>>>(
      reminderAcknowledgementsProvider,
      (_, next) => next.whenData((_) => syncNotifications()),
      fireImmediately: true,
    );
    final storedTheme = ref.watch(themeNameProvider).valueOrNull;
    final palette = MomoPalette.fromStoredValue(storedTheme);
    return MaterialApp.router(
      title: '嬷嬷的小箱子',
      debugShowCheckedModeBanner: false,
      theme: buildMomoTheme(palette, Brightness.light),
      darkTheme: buildMomoTheme(palette, Brightness.dark),
      themeMode: ThemeMode.system,
      routerConfig: ref.watch(appRouterProvider),
    );
  }
}
