import 'dart:ui' show SemanticsAction;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/presentation/widgets/momo_glass_components.dart';

void main() {
  testWidgets('大字体下操作和搜索可增长，按钮保留键盘操作能力', (tester) async {
    await tester.binding.setSurfaceSize(const Size(320, 720));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMomoTheme(MomoPalette.forestPalette, Brightness.light),
        builder:
            (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: const TextScaler.linear(3)),
              child: child!,
            ),
        home: Scaffold(
          body: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              MomoCapsuleButton(label: '确认保存当前配置', onPressed: () => presses++),
              const SizedBox(height: 16),
              const MomoGlassSearchBar(hintText: '搜索'),
            ],
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(tester.getSize(find.byType(FilledButton)).height, greaterThan(48));
    expect(tester.getSize(find.byType(TextField)).height, greaterThan(40));
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pump();
    expect(presses, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('加载操作有明确读屏标签且不能重复提交', (tester) async {
    final semantics = tester.ensureSemantics();
    var presses = 0;
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.dark),
        home: Scaffold(
          body: MomoCapsuleButton(
            label: '保存',
            isLoading: true,
            onPressed: () => presses++,
          ),
        ),
      ),
    );
    expect(find.text('处理中…'), findsOneWidget);
    expect(find.bySemanticsLabel('处理中…'), findsWidgets);
    await tester.tap(find.text('处理中…'));
    await tester.pump();
    expect(presses, 0);
    semantics.dispose();
    expect(tester.takeException(), isNull);
  });

  testWidgets('所有皮肤在深色模式下卡片保持暗色，保留可点击语义', (tester) async {
    final semantics = tester.ensureSemantics();
    for (final palette in MomoPalette.allPalettes) {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildMomoTheme(palette, Brightness.dark),
          home: Scaffold(
            body: MomoGlassCard(
              palette: palette,
              onTap: () {},
              child: const Text('打开详情'),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final material = tester.widget<Material>(
        find.descendant(
          of: find.byType(MomoGlassCard),
          matching: find.byType(Material),
        ),
      );
      expect(material.color!.computeLuminance(), lessThan(0.1));
      expect(
        tester
            .getSemantics(find.text('打开详情'))
            .getSemanticsData()
            .hasAction(SemanticsAction.tap),
        isTrue,
      );
      expect(tester.takeException(), isNull);
    }
    semantics.dispose();
  });

  group('MomoGlassComponents Tests', () {
    testWidgets(
      'MomoCapsuleButton renders primary and secondary styles with callbacks',
      (tester) async {
        bool pressed = false;
        await tester.pumpWidget(
          MaterialApp(
            home: Scaffold(
              body: Column(
                children: [
                  MomoCapsuleButton(
                    label: '主操作',
                    isPrimary: true,
                    onPressed: () => pressed = true,
                  ),
                  MomoCapsuleButton(
                    label: '次操作',
                    isPrimary: false,
                    onPressed: () {},
                  ),
                  const MomoCapsuleButton(label: '禁用态', onPressed: null),
                ],
              ),
            ),
          ),
        );

        expect(find.text('主操作'), findsOneWidget);
        expect(find.text('次操作'), findsOneWidget);
        expect(find.text('禁用态'), findsOneWidget);

        await tester.tap(find.text('主操作'));
        expect(pressed, isTrue);
      },
    );

    testWidgets('MomoGlassCard renders and responds to tap', (tester) async {
      bool cardTapped = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MomoGlassCard(
              onTap: () => cardTapped = true,
              child: const Text('卡片内容'),
            ),
          ),
        ),
      );

      expect(find.text('卡片内容'), findsOneWidget);
      await tester.tap(find.text('卡片内容'));
      expect(cardTapped, isTrue);
    });

    testWidgets('MomoGlassSearchBar inputs text', (tester) async {
      String submitted = '';
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: MomoGlassSearchBar(
              hintText: '搜索商品...',
              onSubmitted: (val) => submitted = val,
            ),
          ),
        ),
      );

      expect(find.text('搜索商品...'), findsOneWidget);
      await tester.enterText(find.byType(TextField), '牛奶');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      expect(submitted, '牛奶');
    });
  });
}
