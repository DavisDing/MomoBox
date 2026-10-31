import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/inventory_screen.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/widgets/momo_floating_dock.dart';
import 'package:momo_box/presentation/widgets/momo_glass_components.dart';
import 'package:momo_box/presentation/widgets/momo_mobile_layout.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(390, 844), const Size(430, 932), const Size(844, 390)]) {
    for (final scale in [1.0, 1.3, 3.4]) {
      for (final brightness in Brightness.values) {
        testWidgets('$size / $scale / ${brightness.name}: root pages stay usable', (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          tester.view.padding = const FakeViewPadding(top: 24, bottom: 34);
          tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 34);
          tester.platformDispatcher.platformBrightnessTestValue = brightness;
          addTearDown(tester.view.reset);
          addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);
          final database = AppDatabase.forTesting(NativeDatabase.memory());
          final appScale = scale > 1.3 ? 1.3 : scale;
          tester.platformDispatcher.textScaleFactorTestValue = scale / appScale;
          addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
          try {
            await SettingsRepository(database).setValue('font_scale', '$appScale');
            await InventoryService(InventoryRepository(database)).intake(const IntakeDraft(
              name: '厨房储物柜里的长名称测试物品', category: '家居清洁', quantity: 3,
            ));
            await tester.pumpWidget(ProviderScope(
              overrides: [databaseProvider.overrideWithValue(database)],
              child: const MomoBoxApp(enableMediaReconciliation: false),
            ));
            await _frames(tester);
            final container = ProviderScope.containerOf(tester.element(find.byType(MomoBoxApp)));
            final router = container.read(appRouterProvider);
            for (final route in ['/', '/inventory', '/smart-home', '/settings']) {
              router.go(route);
              await _frames(tester);
              expect(find.byType(MomoPageHeader), findsOneWidget);
              expect(MediaQuery.textScalerOf(tester.element(find.byType(MomoPageHeader))).scale(14), closeTo(14 * scale, 0.01));
              expect(tester.takeException(), isNull, reason: route);
              if (route == '/inventory') {
                final search = find.byType(TextField);
                expect(search, findsOneWidget);
                await tester.ensureVisible(search);
                await tester.enterText(search, '没有此商品');
                await _frames(tester);
                final scrollable = find.descendant(of: find.byType(InventoryScreen), matching: find.byType(Scrollable)).first;
                await tester.scrollUntilVisible(find.text('没有符合筛选条件的物品'), 200, scrollable: scrollable);
                expect(find.text('没有符合筛选条件的物品'), findsOneWidget);
                tester.state<ScrollableState>(scrollable).position.jumpTo(0);
                await tester.pump();
                await tester.ensureVisible(find.byTooltip('清除搜索'));
                await tester.tap(find.byTooltip('清除搜索'));
                await _frames(tester);
                await tester.scrollUntilVisible(find.text('厨房储物柜里的长名称测试物品'), 200, scrollable: scrollable);
                expect(find.text('厨房储物柜里的长名称测试物品'), findsOneWidget);
                // Header action replaces the movable overlay.
                expect(find.byTooltip('入库'), findsOneWidget);
                expect(find.byType(FloatingActionButton), findsNothing);
              }
              if (route == '/settings') {
                final scrollable = find.descendant(of: find.byType(SettingsScreen), matching: find.byType(Scrollable)).first;
                await tester.scrollUntilVisible(find.text('关于与存储信息'), 240, scrollable: scrollable);
                final state = tester.state<ScrollableState>(scrollable);
                state.position.jumpTo(state.position.maxScrollExtent);
                await tester.pump();
                expect(find.text('关于与存储信息').hitTestable(), findsOneWidget);
                if (size.width < 840) {
                  expect(tester.getBottomLeft(find.text('关于与存储信息')).dy,
                    lessThan(tester.getTopLeft(find.byType(MomoFloatingCapsuleDock)).dy));
                }
              }
            }
            expect(tester.takeException(), isNull);
          } finally {
            // Detach consumers and drain Drift's deferred stream cleanup before
            // closing SQLite in the real async zone. A fake-clock teardown can
            // otherwise leave timers pending and block the rest of the suite.
            await tester.pumpWidget(const SizedBox.shrink());
            await tester.pump(Duration.zero);
            await tester.runAsync(database.close);
          }
        });
      }
    }
  }

  testWidgets('spring press can reverse before settling and reduced motion keeps feedback static', (tester) async {
    var taps = 0;
    Future<void> mount({bool reduce = false}) => tester.pumpWidget(MaterialApp(
      theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: Scaffold(body: Center(child: MomoCapsuleButton(label: '保存', onPressed: () => taps++))),
      ),
    ));
    await mount();
    final button = find.byType(FilledButton);
    final scale = find.ancestor(of: button, matching: find.byType(ScaleTransition)).first;
    final press = await tester.startGesture(tester.getCenter(button));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 40));
    final downScale = tester.widget<ScaleTransition>(scale).scale.value;
    expect(downScale, lessThan(1));
    await press.up();
    await tester.pump();
    expect(tester.widget<ScaleTransition>(scale).scale.value, closeTo(downScale, 0.001));
    await tester.pumpAndSettle();
    expect(tester.widget<ScaleTransition>(scale).scale.value, closeTo(1, 0.001));
    expect(taps, 1);
    await mount(reduce: true);
    final staticPress = await tester.startGesture(tester.getCenter(button));
    await tester.pump(const Duration(milliseconds: 40));
    expect(tester.widget<ScaleTransition>(scale).scale.value, 1);
    await staticPress.up();
    await tester.pumpAndSettle();
    expect(taps, 2);
    expect(tester.takeException(), isNull);
  });

  testWidgets('secondary toolbar grows to fit its full title and preserves action targets', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
      home: MediaQuery(
        data: const MediaQueryData(size: Size(320, 640), textScaler: TextScaler.linear(3.4)),
        child: Builder(builder: (context) => Scaffold(
          appBar: MomoGlassAppBar.adaptive(context,
            title: const Text('AI 解析与模型配置'),
            actions: [IconButton(tooltip: '完成', onPressed: () {}, icon: const Icon(Icons.check))],
          ),
        )),
      ),
    ));
    await tester.pumpAndSettle();
    final bar = tester.getRect(find.byType(AppBar));
    final title = tester.getRect(find.text('AI 解析与模型配置'));
    expect(bar.height, greaterThan(56));
    expect(title.top, greaterThanOrEqualTo(bar.top));
    expect(title.bottom, lessThanOrEqualTo(bar.bottom));
    expect(title.right, lessThanOrEqualTo(tester.getTopLeft(find.byTooltip('完成')).dx));
    expect(find.byTooltip('完成').hitTestable(), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('tiles reflow with text while respecting horizontal screen cutouts', (tester) async {
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    addTearDown(tester.view.reset);
    for (final scale in [1.0, 3.4]) {
      await tester.pumpWidget(MaterialApp(home: MediaQuery(
        data: MediaQueryData(size: const Size(320, 640), textScaler: TextScaler.linear(scale), padding: const EdgeInsets.only(left: 44)),
        child: Scaffold(body: Builder(builder: (context) => ListView(
          padding: MomoMobileLayout.pageInsets(context),
          children: [MomoAdaptiveTiles(minimumWidth: 110, children: const [Text('第一项'), Text('第二项')])],
        ))),
      )));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('第一项')).dx, greaterThanOrEqualTo(44));
      if (scale == 1) {
        expect(tester.getTopLeft(find.text('第一项')).dy, tester.getTopLeft(find.text('第二项')).dy);
      } else {
        expect(tester.getTopLeft(find.text('第二项')).dy, greaterThan(tester.getTopLeft(find.text('第一项')).dy));
      }
      expect(tester.takeException(), isNull);
    }
  });
}

Future<void> _frames(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}
