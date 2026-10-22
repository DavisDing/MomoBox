import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/domain/models/initial_import_models.dart';
import 'package:momo_box/presentation/widgets/initial_import_review_dialog.dart';

InitialImportPreview _preview({List<String> blockers = const []}) => InitialImportPreview(
  importId: 'import-1',
  target: const SyncWorkspaceIdentity(
    endpoint: 'https://nas.example/api/v1/', userId: 'owner', familyId: 'family-a',
  ),
  localWorkspaceId: 'workspace',
  counts: const {'products': 2, 'product_batches': 3, 'history': 8},
  blockers: blockers,
  exclusions: const ['媒体和 OCR', '提醒确认仅保留本机'],
  categories: const [
    InitialImportCategory(
      sourceName: '食品', categoryId: 'category-a', action: InitialImportCategoryAction.reuse,
    ),
  ],
  fingerprint: 'fingerprint',
  familyTimeZone: 'Asia/Shanghai',
  manifest: const {
    'product_batches': [
      {'id': 'batch-a', 'batch_no': '原批次',
        'produced_date': '2026-10-22', 'expiry_date': '2027-10-22'},
    ],
  },
);

void main() {
  Future<void> open(
    WidgetTester tester, {
    bool confirmImport = false,
    List<String> blockers = const [],
    ValueChanged<bool?>? onResult,
  }) async {
    await tester.binding.setSurfaceSize(const Size(700, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: Builder(
      builder: (context) => TextButton(
        onPressed: () async {
          final result = await showDialog<bool>(
            context: context,
            builder: (_) => InitialImportReviewDialog(
              preview: _preview(blockers: blockers), confirmImport: confirmImport,
            ),
          );
          onResult?.call(result);
        },
        child: const Text('打开审阅'),
      ),
    ))));
    await tester.tap(find.text('打开审阅'));
    await tester.pumpAndSettle();
  }

  testWidgets('review identifies target, archive semantics, category and exclusions', (tester) async {
    await open(tester);
    expect(find.text('家庭：family-a'), findsOneWidget);
    expect(find.text('家庭时区：Asia/Shanghai'), findsOneWidget);
    expect(find.text('本次共 13 条'), findsOneWidget);
    expect(find.textContaining('旧历史单独归档，不再次扣减库存'), findsOneWidget);
    expect(find.textContaining('复用已有分类，保留颜色和排序'), findsOneWidget);
    expect(find.textContaining('媒体和 OCR'), findsOneWidget);
    expect(find.text('批次日期核对'), findsOneWidget);
    expect(find.textContaining('生产日：2026-10-22 · 到期日：2027-10-22'), findsOneWidget);
    final confirm = tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交预检并准备'));
    expect(confirm.onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交预检并准备')).onPressed,
      isNotNull);
  });

  testWidgets('server import is a distinct explicit confirmation', (tester) async {
    bool? accepted;
    await open(tester, confirmImport: true, onResult: (result) => accepted = result);
    expect(find.text('确认导入既有数据'), findsOneWidget);
    expect(find.textContaining('暂停不能撤销 NAS 已接收的数据'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '确认导入')).onPressed, isNull);
    await tester.tap(find.byType(Checkbox));
    await tester.pump();
    await tester.tap(find.widgetWithText(FilledButton, '确认导入'));
    await tester.pumpAndSettle();
    expect(accepted, isTrue);
    expect(find.byType(InitialImportReviewDialog), findsNothing);
  });

  testWidgets('a blocker cannot be acknowledged away', (tester) async {
    await open(tester, blockers: const ['已有 UUID 重叠，请核对原数据']);
    expect(find.textContaining('已有 UUID 重叠'), findsOneWidget);
    expect(find.byType(Checkbox), findsNothing);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, '提交预检并准备')).onPressed, isNull);
  });

  testWidgets('cancel returns no authorization', (tester) async {
    bool? accepted;
    await open(tester, onResult: (result) => accepted = result);
    await tester.tap(find.widgetWithText(TextButton, '取消'));
    await tester.pumpAndSettle();
    expect(accepted, isFalse);
  });
}
