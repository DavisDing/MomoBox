import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/alerts_screen.dart';
import 'package:momo_box/presentation/screens/home_screen.dart';
import 'package:momo_box/presentation/screens/inventory_screen.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/screens/shopping_screen.dart';
import 'package:momo_box/presentation/screens/smart_home_screen.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('单机首次启动：四个主页面及首页提醒、采买二级入口可访问', (tester) async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(database.close);
    // Put the secondary-route entries first so the test does not depend on
    // the device height or unrelated dashboard cards.
    await SettingsRepository(database).setValue(
      homeSectionOrderKey,
      'alert_summary,shopping_summary,quick_intake',
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [databaseProvider.overrideWithValue(database)],
        child: const MomoBoxApp(enableMediaReconciliation: false),
      ),
    );
    await _waitFor(tester, find.text('待处理详情 >'));
    expect(find.byType(HomeScreen), findsOneWidget);

    await tester.ensureVisible(find.text('待处理详情 >'));
    await tester.tap(find.text('待处理详情 >'));
    await _waitFor(tester, find.byType(AlertsScreen));
    await _waitFor(tester, find.text('当前无待处理提醒。'));
    await tester.pageBack();
    await _waitFor(tester, find.text('查看完整清单 >'));

    await tester.ensureVisible(find.text('查看完整清单 >'));
    await tester.tap(find.text('查看完整清单 >'));
    await _waitFor(tester, find.byType(ShoppingScreen));
    await _waitFor(tester, find.text('暂无待采买物品。'));
    await tester.pageBack();
    await _waitFor(tester, find.byType(HomeScreen));

    await _tapPrimaryNavigation(tester, '库存');
    await _waitFor(tester, find.byType(InventoryScreen));
    await _tapPrimaryNavigation(tester, '家居');
    await _waitFor(tester, find.byType(SmartHomeScreen));
    await _waitFor(tester, find.text('Home Assistant 尚未配置'));
    await _tapPrimaryNavigation(tester, '我的');
    await _waitFor(tester, find.byType(SettingsScreen));
    await _tapPrimaryNavigation(tester, '首页');
    await _waitFor(tester, find.byType(HomeScreen));

    expect(tester.takeException(), isNull);
    // Release listeners and scheduler timers before closing the database.
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}

Future<void> _tapPrimaryNavigation(WidgetTester tester, String label) async {
  final navigation = find.byWidgetPredicate(
    (widget) => widget is NavigationBar || widget is NavigationRail,
  );
  final target = find.descendant(of: navigation, matching: find.text(label));
  expect(target, findsOneWidget);
  await tester.tap(target);
  await tester.pump();
}

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}
