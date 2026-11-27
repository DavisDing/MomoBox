import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/widgets/assistant_action_review.dart';
import 'package:momo_box/presentation/widgets/receipt_intake_review.dart';

void main() {
  testWidgets('采购审阅只确认保留勾选的项目', (tester) async {
    Set<int>? selected;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder:
                (context) => TextButton(
                  child: const Text('审阅'),
                  onPressed: () async {
                    selected = await showDialog<Set<int>>(
                      context: context,
                      builder:
                          (_) => const AssistantPurchaseReviewDialog(
                            items: ['番茄 × 2 件', '鸡蛋 × 3 件'],
                          ),
                    );
                  },
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('审阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('鸡蛋 × 3 件'));
    await tester.tap(find.text('确认加入'));
    await tester.pumpAndSettle();
    expect(selected, {0});
  });

  testWidgets('小票未识别数量时须填写，或取消勾选该项', (tester) async {
    List<IntakeDraft>? drafts;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder:
                (context) => TextButton(
                  child: const Text('审阅'),
                  onPressed: () async {
                    drafts = await showDialog<List<IntakeDraft>>(
                      context: context,
                      builder:
                          (_) => const ReceiptIntakeReview([
                            (name: '番茄', quantity: null, category: '食品生鲜'),
                            (name: '鸡蛋', quantity: 3, category: '食品生鲜'),
                          ]),
                    );
                  },
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('审阅'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(find.text('请输入 1–9999 的整数'), findsOneWidget);
    expect(drafts, isNull);
    await tester.tap(find.widgetWithText(CheckboxListTile, '番茄'));
    await tester.tap(find.text('下一步'));
    await tester.pumpAndSettle();
    expect(drafts?.single.name, '鸡蛋');
    expect(drafts?.single.quantity, 3);
  });
}
