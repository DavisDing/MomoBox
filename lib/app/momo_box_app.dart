import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../domain/models/inventory_models.dart';
import '../presentation/controllers/providers.dart';
import '../presentation/screens/alerts_screen.dart';
import '../presentation/screens/inventory_screen.dart';
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
    ref.listen<AsyncValue<List<InventoryItem>>>(inventoryProvider, (_, next) {
      next.whenData((items) {
        // 通知是增强能力；平台调度失败不能阻塞本地库存页面。
        ref.read(localNotificationServiceProvider).sync(items).catchError((_) {});
      });
    }, fireImmediately: true);
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
