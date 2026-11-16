import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/presentation/widgets/assistant_action_review.dart';
import 'package:momo_box/presentation/widgets/momo_components.dart';

void main() {
  for (final size in [const Size(320, 640), const Size(844, 390)]) {
    for (final scale in [1.0, 3.4]) {
      for (final brightness in Brightness.values) {
        testWidgets('review remains readable and dismissible: $size / $scale / $brightness', (
          tester,
        ) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = size;
          addTearDown(tester.view.reset);
          final description = List.filled(12,
            '修改「厨房储物柜里的长名称物品」的资料：\n存放位置：餐边柜 → 厨房储物柜。').join('\n');
          bool? result;
          await tester.pumpWidget(MaterialApp(
            theme: buildMomoTheme(MomoPalette.defaultPalette, brightness),
            builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context).copyWith(
                textScaler: TextScaler.linear(scale),
                disableAnimations: true,
              ),
              child: child!,
            ),
            home: Scaffold(body: Builder(builder: (context) => Center(
              child: TextButton(
                onPressed: () async {
                  result = await showDialog<bool>(
                    context: context,
                    animationStyle: AnimationStyle.noAnimation,
                    builder: (_) => AssistantActionReviewDialog(
                      kind: 'product_update', description: description,
                    ),
                  );
                },
                child: const Text('打开操作'),
              ),
            ))),
          ));
          Future<void> open() async {
            await tester.tap(find.text('打开操作'));
            await tester.pumpAndSettle();
            expect(result, isNull);
            expect(find.text('确认修改物品资料'), findsOneWidget);
            expect(find.text(description), findsOneWidget);
            final viewport = tester.getRect(find.descendant(
              of: find.byType(AssistantActionReviewDialog),
              matching: find.byType(SingleChildScrollView),
            ));
            expect(viewport.left, greaterThanOrEqualTo(20));
            expect(viewport.right, lessThanOrEqualTo(size.width - 20));
            expect(viewport.top, greaterThanOrEqualTo(24));
            expect(viewport.bottom, lessThanOrEqualTo(size.height - 24));
            final text = tester.element(find.text(description));
            expect(MediaQuery.textScalerOf(text).scale(14), 14 * scale);
            expect(tester.takeException(), isNull);
          }

          await open();
          await tester.ensureVisible(find.text('取消'));
          await tester.pumpAndSettle();
          expect(find.text('取消').hitTestable(), findsOneWidget);
          await tester.tap(find.text('取消'));
          await tester.pumpAndSettle();
          expect(result, isFalse);
          result = null;
          await open();
          await tester.ensureVisible(find.text('确认执行'));
          await tester.pumpAndSettle();
          expect(find.text('确认执行').hitTestable(), findsOneWidget);
          await tester.tap(find.text('确认执行'));
          await tester.pumpAndSettle();
          expect(result, isTrue);
          expect(tester.takeException(), isNull);
        });
      }
    }
  }

  testWidgets('completed action is readable status and cannot be submitted again', (
    tester,
  ) async {
    var calls = 0;
    await tester.pumpWidget(MaterialApp(home: Scaffold(
      body: AssistantActionEntry(receipt: '已执行', onPressed: () => calls++),
    )));
    expect(find.text('已执行'), findsOneWidget);
    expect(find.byType(MomoCapsuleButton), findsNothing);
    await tester.tap(find.text('已执行'));
    await tester.pump();
    expect(calls, 0);
    expect(tester.takeException(), isNull);
  });
}
