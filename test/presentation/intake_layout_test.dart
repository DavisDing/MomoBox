import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/domain/models/ai_action.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/intake_sheet.dart';

void main() {
  testWidgets('图片/OCR/AI解析和品牌/规格同行，工具入口不再放在表单末尾', (tester) async {
    await _pumpIntake(tester);
    final tools = ['图片', 'OCR', 'AI解析'].map(find.text).toList();
    final top = tester.getTopLeft(tools.first).dy;
    for (final tool in tools) {
      expect(tester.getTopLeft(tool).dy, closeTo(top, 1));
      expect(tester.getTopLeft(tool).dy, lessThan(tester.getTopLeft(_field('物品名称 *')).dy));
    }
    final brand = tester.getRect(_field('品牌（可选）'));
    final specification = tester.getRect(_field('规格（可选）'));
    expect(brand.top, closeTo(specification.top, 1));
    expect(brand.right, lessThan(specification.left));
    expect(find.byTooltip('关闭入库草稿'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('名称建议更新下拉选中值，用户手选后不被重算覆盖', (tester) async {
    await _pumpIntake(tester);
    await tester.enterText(_field('物品名称 *'), '薯片');
    await tester.pump();
    expect(_category(tester), '零食饮料');
    await tester.tap(find.byType(DropdownButtonFormField<String>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('食品生鲜').last);
    await tester.pumpAndSettle();
    await tester.enterText(_field('物品名称 *'), '巧克力');
    await tester.pump();
    expect(_category(tester), '食品生鲜');
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await _pumpIntake(tester, sheet: const IntakeSheet());
    await tester.enterText(_field('物品名称 *'), '薯片');
    await tester.pump();
    expect(_category(tester), '食品生鲜');
    expect(tester.takeException(), isNull);
  });

  testWidgets('旧自定义分类保留，未知物品不默认成为药品', (tester) async {
    await _pumpIntake(tester, sheet: const IntakeSheet(
      initialName: '薯片', initialCategory: '原有自定义分类',
    ));
    expect(_category(tester), '原有自定义分类');
    await tester.enterText(_field('物品名称 *'), '饼干');
    await tester.pump();
    expect(_category(tester), '原有自定义分类');
    await _pumpIntake(tester);
    expect(_category(tester), '其他物品');
  });

  testWidgets('AI 分类如实预填，不按薯片关键词覆盖，未知品牌规格保持空白', (tester) async {
    final draft = AiInventoryAction.fromJson({
      'kind': 'intake', 'name': '薯片', 'quantity': 1, 'category': '食品生鲜',
    })!.intakeDraft;
    await _pumpIntake(tester, sheet: IntakeSheet(
      initialDraft: draft, initialCategoryFromAi: true,
    ));
    expect(tester.widget<TextField>(_field('物品名称 *')).controller!.text, '薯片');
    expect(tester.widget<TextField>(_field('入库数量 *')).controller!.text, '1');
    expect(_category(tester), '食品生鲜');
    expect(tester.widget<TextField>(_field('品牌（可选）')).controller!.text, isEmpty);
    expect(tester.widget<TextField>(_field('规格（可选）')).controller!.text, isEmpty);
    expect(find.text('已入库'), findsNothing);
  });

  testWidgets('改名称不清空已有合理建议，日期来源不能改变手选分类', (tester) async {
    await _pumpIntake(tester, sheet: const IntakeSheet(
      initialDraft: IntakeDraft(
        name: '牛奶', category: '食品生鲜', quantity: 1, dateSource: 'ai',
      ),
      initialCategoryFromAi: true,
    ));
    await tester.enterText(_field('物品名称 *'), '薯片');
    await tester.pump();
    expect(_category(tester), '食品生鲜');

    await _pumpIntake(tester, sheet: const IntakeSheet(
      initialDraft: IntakeDraft(
        name: '薯片', category: '我的分类', quantity: 1, dateSource: 'ai',
      ),
    ));
    await tester.enterText(_field('物品名称 *'), '巧克力');
    await tester.pump();
    expect(_category(tester), '我的分类');
  });

  testWidgets('模型未确定分类时保持中性默认，编辑名称也不切回本地猜测', (tester) async {
    final draft = AiInventoryAction.fromJson({
      'kind': 'intake', 'name': '薯片', 'quantity': 1,
    })!.intakeDraft;
    await _pumpIntake(tester, sheet: IntakeSheet(
      initialDraft: draft, initialCategoryFromAi: true,
    ));
    expect(_category(tester), '其他物品');
    await tester.enterText(_field('物品名称 *'), '洗衣液');
    await tester.pump();
    expect(_category(tester), '其他物品');
    expect(tester.takeException(), isNull);
  });

  for (final brightness in Brightness.values) {
    for (final size in [const Size(320, 720), const Size(844, 390)]) {
      for (final scale in [1.0, 3.4]) {
        testWidgets(
          '${brightness.name} $size $scale 倍字/键盘下工具和确认按钮可操作，无溢出',
          (tester) async {
            await _pumpIntake(tester, size: size, scale: scale,
              keyboard: 120, brightness: brightness, assets: [
                MediaAsset(
                  id: 'preview', entityType: 'intake_draft', entityId: 'test',
                  type: MediaAssetType.instructionImage,
                  localPath: '/missing-intake-layout-test.png',
                  mimeType: 'image/png', sizeBytes: 1, sha256: 'test-only',
                  createdAt: DateTime(2026, 10, 28),
                ),
              ]);
            final scroll = find.descendant(
              of: find.byType(IntakeSheet), matching: find.byType(Scrollable),
            ).first;
            await tester.scrollUntilVisible(find.text('AI解析'), 180, scrollable: scroll);
            // The label can intersect the viewport while its center is still
            // below the keyboard-reduced sheet, especially at 3.4x text size.
            await Scrollable.ensureVisible(tester.element(find.text('AI解析')), alignment: 0.5);
            await tester.pumpAndSettle();
            expect(find.text('AI解析').hitTestable(), findsOneWidget);
            await tester.tap(find.text('AI解析'));
            await tester.pumpAndSettle();
            expect(find.text('请先对说明书或包装图片执行本地 OCR。'), findsOneWidget);
            // Verify the feedback first, then let its normal lifetime finish;
            // a SnackBar must not be mistaken for an unreachable form control.
            final feedback = tester.widget<SnackBar>(find.byType(SnackBar));
            await tester.pump(feedback.duration);
            await tester.pumpAndSettle();
            await tester.scrollUntilVisible(find.text('确认入库'), 220, scrollable: scroll);
            await Scrollable.ensureVisible(tester.element(find.text('确认入库')), alignment: 0.5);
            await tester.pumpAndSettle();
            expect(find.text('确认入库').hitTestable(), findsOneWidget);
            expect(tester.takeException(), isNull);
          },
        );
      }
    }
  }
}

Finder _field(String label) => find.byWidgetPredicate(
  (widget) => widget is TextField && widget.decoration?.labelText == label,
);

String? _category(WidgetTester tester) => tester.widget<DropdownButton<String>>(
  find.descendant(
    of: find.byType(DropdownButtonFormField<String>),
    matching: find.byType(DropdownButton<String>),
  ),
).value;

Future<void> _pumpIntake(
  WidgetTester tester, {
  IntakeSheet? sheet,
  Size size = const Size(390, 844),
  double scale = 1,
  double keyboard = 0,
  Brightness brightness = Brightness.light,
  List<MediaAsset> assets = const [],
}) async {
  await tester.binding.setSurfaceSize(size);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(ProviderScope(
    key: UniqueKey(),
    overrides: [
      mediaAssetsProvider.overrideWith((ref, target) => Stream.value(assets)),
    ],
    child: MaterialApp(
      theme: buildMomoTheme(MomoPalette.defaultPalette, brightness),
      builder: (context, child) => MediaQuery(
        data: MediaQuery.of(context).copyWith(
          textScaler: TextScaler.linear(scale),
          viewInsets: EdgeInsets.only(bottom: keyboard),
        ),
        child: child!,
      ),
      home: Scaffold(
        // Simulate the real route's resizable viewport without removing the
        // sheet's keyboard inset a second time in this direct-widget harness.
        resizeToAvoidBottomInset: false,
        body: sheet ?? const IntakeSheet(initialName: ''),
      ),
    ),
  ));
  await tester.pumpAndSettle();
}
