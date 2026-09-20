import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:momo_box/presentation/widgets/app_back_guard.dart';

void main() {
  late GoRouter router;
  late int exits;
  late GlobalKey<NavigatorState> shellKey;

  setUp(() {
    exits = 0;
    shellKey = GlobalKey<NavigatorState>();
    router = GoRouter(
      routes: [
        ShellRoute(
          navigatorKey: shellKey,
          builder: (context, state, child) => AppBackGuard(child: child),
          routes: [
            GoRoute(
              path: '/',
              builder: (_, _) => const Scaffold(body: Text('首页')),
            ),
            GoRoute(
              path: '/settings',
              builder: (_, _) => const Scaffold(body: Text('我的')),
            ),
          ],
        ),
        GoRoute(
          path: '/detail',
          builder: (_, _) => const Scaffold(body: Text('详情')),
        ),
      ],
    );
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
          if (call.method == 'SystemNavigator.pop') exits++;
          return null;
        });
  });

  tearDown(() {
    router.dispose();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
  });

  Future<void> pumpApp(WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp.router(
        theme: ThemeData(platform: TargetPlatform.android),
        routerConfig: router,
      ),
    );
    await tester.pumpAndSettle();
  }

  Future<void> back(WidgetTester tester) async {
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
  }

  testWidgets('首页首次返回提示，2 秒内再次返回才退出', (tester) async {
    await pumpApp(tester);
    await back(tester);
    expect(exits, 0);
    expect(find.text('再按一次退出软件'), findsOneWidget);
    await back(tester);
    expect(exits, 1);
  });

  testWidgets('提示超时和前后台切换均重新计次', (tester) async {
    await pumpApp(tester);
    await back(tester);
    await tester.pump(const Duration(seconds: 3));
    await back(tester);
    expect(exits, 0);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await back(tester);
    expect(exits, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('其他一级页面先回首页，再按两次退出', (tester) async {
    await pumpApp(tester);
    router.go('/settings');
    await tester.pumpAndSettle();
    await back(tester);
    expect(router.routeInformationProvider.value.uri.path, '/');
    expect(exits, 0);
    expect(find.text('再按一次退出软件'), findsNothing);
    await back(tester);
    expect(exits, 0);
    await back(tester);
    expect(exits, 1);
  });

  testWidgets('路由详情、原生设置子页、弹窗和底部面板优先返回', (tester) async {
    await pumpApp(tester);
    router.go('/settings');
    await tester.pumpAndSettle();
    router.push('/detail');
    await tester.pumpAndSettle();
    await back(tester);
    expect(router.routeInformationProvider.value.uri.path, '/settings');

    shellKey.currentState!.push(
      MaterialPageRoute<void>(
        builder: (_) => const Scaffold(body: Text('设置子页')),
      ),
    );
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('设置子页'), findsNothing);
    expect(find.text('我的'), findsOneWidget);

    showDialog<void>(
      context: shellKey.currentContext!,
      builder: (_) => const AlertDialog(title: Text('确认')),
    );
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('确认'), findsNothing);
    showModalBottomSheet<void>(
      context: shellKey.currentContext!,
      builder: (_) => const Text('面板'),
    );
    await tester.pumpAndSettle();
    await back(tester);
    expect(find.text('面板'), findsNothing);
    expect(router.routeInformationProvider.value.uri.path, '/settings');
    expect(exits, 0);
  });

  testWidgets('离开首页再返回不会沿用上一次退出计次', (tester) async {
    await pumpApp(tester);
    await back(tester);
    router.go('/settings');
    await tester.pumpAndSettle();
    await back(tester);
    await back(tester);
    expect(exits, 0);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
