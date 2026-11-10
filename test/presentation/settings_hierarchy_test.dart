import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';

import '../support/memory_settings_repository.dart';

void main() {
  testWidgets('我的逐级进入诊断，系统返回逐级恢复列表位置', (tester) async {
    final settings = MemorySettingsRepository();
    try {
      await _mount(tester, settings);
      expect(find.text('一切，按你喜欢。'), findsOneWidget);
      expect(find.text('本地诊断导出'), findsNothing);
      await tester.scrollUntilVisible(find.text('数据与隐私'), 200);
      await tester.pumpAndSettle();
      expect(find.text('数据与隐私').hitTestable(), findsOneWidget);
      final overview = tester.state<ScrollableState>(find.byType(Scrollable).first);
      final overviewOffset = overview.position.pixels;
      await tester.tap(find.text('数据与隐私'));
      await tester.pumpAndSettle();
      expect(find.text('库存统计'), findsOneWidget);
      expect(find.text('数据备份与迁移'), findsOneWidget);
      expect(find.text('隐私与密钥安全'), findsOneWidget);
      final diagnostic = find.text('本地诊断导出');
      await tester.scrollUntilVisible(diagnostic, 200);
      await tester.pumpAndSettle();
      final category = tester.state<ScrollableState>(find.byType(Scrollable).first);
      final categoryOffset = category.position.pixels;
      await tester.tap(diagnostic);
      await tester.pumpAndSettle();
      expect(find.byType(DiagnosticExportScreen), findsOneWidget);
      expect(find.textContaining('不包含错误原文'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsCategoryScreen), findsOneWidget);
      expect(category.position.pixels, closeTo(categoryOffset, 0.01));
      await tester.binding.handlePopRoute();
      await tester.pumpAndSettle();
      expect(find.byType(SettingsScreen), findsOneWidget);
      expect(overview.position.pixels, closeTo(overviewOffset, 0.01));
      expect(settings.values, isEmpty);
      expect(tester.takeException(), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await settings.close();
    }
  });

  for (final reduceMotion in [false, true]) {
    testWidgets('外观设置保留原主题选择，减少动态效果=$reduceMotion', (tester) async {
      final settings = MemorySettingsRepository();
      try {
        await _mount(tester, settings, reduceMotion: reduceMotion);
        await tester.scrollUntilVisible(find.text('外观与显示'), 160);
        await tester.tap(find.text('外观与显示'));
        await tester.pumpAndSettle();
        final category = find.byType(SettingsCategoryScreen);
        final route = ModalRoute.of(tester.element(category))!;
        if (reduceMotion) {
          expect(route, isA<PageRouteBuilder<void>>());
          expect(route.transitionDuration, const Duration(milliseconds: 120));
        } else {
          expect(route, isA<MaterialPageRoute<void>>());
        }
        expect(find.text('界面字体大小'), findsOneWidget);
        await tester.tap(find.text('主题中心与个性化'));
        await tester.pumpAndSettle();
        expect(find.byType(ThemeSettingsScreen), findsOneWidget);
        await tester.ensureVisible(find.text(MomoPalette.momoPalette.label));
        await tester.tap(find.text(MomoPalette.momoPalette.label));
        await tester.pumpAndSettle();
        expect(settings.values['theme'], MomoPalette.momoPalette.storedValue);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.text(MomoPalette.momoPalette.label), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        expect(find.byType(SettingsScreen), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await settings.close();
      }
    });
  }
}

Future<void> _mount(
  WidgetTester tester,
  MemorySettingsRepository settings, {
  bool reduceMotion = false,
}) async {
  await tester.pumpWidget(ProviderScope(
    overrides: [settingsRepositoryProvider.overrideWithValue(settings)],
    child: MaterialApp(
      theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(disableAnimations: reduceMotion),
        child: child!,
      ),
      home: const SettingsScreen(),
    ),
  ));
  await tester.pumpAndSettle();
}
