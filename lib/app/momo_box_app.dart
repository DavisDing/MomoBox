import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

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

class MomoBoxApp extends ConsumerWidget {
  const MomoBoxApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
