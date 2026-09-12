import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/shopping_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/alerts_screen.dart';
import 'package:momo_box/presentation/screens/product_detail_screen.dart';
import 'package:momo_box/presentation/screens/shopping_screen.dart';
import 'package:momo_box/presentation/widgets/intake_sheet.dart';

void main() {
  late AppDatabase database;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
  });

  tearDown(() => database.close());

  testWidgets('相似商品可以合并、新建或取消并保留表单', (tester) async {
    final inventory = InventoryService(InventoryRepository(database));
    await inventory.intake(const IntakeDraft(
      name: '原商品',
      category: '食品生鲜',
      quantity: 2,
      barcode: '6900000000001',
    ));

    await _pumpSheet(tester, database);
    await _pumpUntilFound(tester, _field('物品名称 *'));
    await _enterField(tester, '物品名称 *', '待确认商品');
    await _enterField(tester, '条码', '6900000000001');
    await _submitSheet(tester);
    expect(find.text('发现相似商品'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _pumpUntilAbsent(tester, find.text('发现相似商品'));
    await _scrollSheetToTop(tester);
    await _pumpUntilFound(tester, _field('物品名称 *'));
    expect(find.text('发现相似商品'), findsNothing);
    expect(_fieldController(tester, '物品名称 *').text, '待确认商品');
    await _scrollSheetUntilFound(tester, _field('条码'));
    expect(_fieldController(tester, '条码').text, '6900000000001');
    expect(await database.select(database.products).get(), hasLength(1));

    await _submitSheet(tester);
    await tester.tap(find.text('合并到已有商品'));
    await _pumpForUi(tester);
    expect(await database.select(database.products).get(), hasLength(1));
    expect(await database.select(database.productBatches).get(), hasLength(2));

    await _pumpUntilAbsent(tester, _field('物品名称 *'));
    await _openIntakeSheet(tester);
    await _enterField(tester, '物品名称 *', '独立商品');
    await _enterField(tester, '条码', '6900000000001');
    await _submitSheet(tester);
    await tester.tap(find.text('新建独立商品'));
    await _pumpForUi(tester);
    expect(await database.select(database.products).get(), hasLength(2));
    expect(await database.select(database.productBatches).get(), hasLength(3));
    await _pumpUntilAbsent(tester, _field('物品名称 *'));
    await _disposeWidgetTree(tester);
  });

  testWidgets('勾选采购项后打开预填的入库表单', (tester) async {
    final shopping = ShoppingService(ShoppingRepository(database));
    await shopping.addOrMerge(
      itemName: '洗衣液',
      targetQuantity: 3,
      reason: '已用完',
      category: '其他物品',
    );

    await _pumpScreen(tester, database, const ShoppingScreen());
    await _pumpUntilFound(tester, find.text('洗衣液'));
    expect(find.text('洗衣液'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await _pumpForUi(tester);

    await _pumpUntilFound(tester, _field('物品名称 *'));
    expect(find.text('入库'), findsOneWidget);
    expect(_fieldController(tester, '物品名称 *').text, '洗衣液');
    expect(_fieldController(tester, '入库数量 *').text, '3');
    expect((await database.select(database.shoppingEntries).get()).single.isCompleted, isTrue);
    await _dismissModalRoute(tester);
    await _disposeWidgetTree(tester);
  });

    testWidgets('主题变更时App Logo图标跟随切换', (tester) async {
    await _pumpApp(tester, database);
    // 默认主题下，库存页 App Logo 为 defaultPalette.appLogoIcon (Icons.all_inbox_rounded)
    expect(find.byIcon(Icons.all_inbox_rounded), findsWidgets);

    // 切换为 momo 主题
    final settingsRepo = SettingsRepository(database);
    await settingsRepo.setValue('theme', 'momo');
    await _pumpForUi(tester);

    // 验证 momo 主题下的 logo (Icons.inventory_rounded) 显示，默认 logo 不再显示
    expect(find.byIcon(Icons.inventory_rounded), findsWidgets);
    expect(find.byIcon(Icons.all_inbox_rounded), findsNothing);

    // 切换为 doraemon 主题
    await settingsRepo.setValue('theme', 'doraemon');
    await _pumpForUi(tester);

    // 验证 doraemon 主题下的 logo (Icons.card_giftcard_rounded) 显示
    expect(find.byIcon(Icons.card_giftcard_rounded), findsWidgets);
    expect(find.byIcon(Icons.inventory_rounded), findsNothing);
    await _disposeWidgetTree(tester);
  });

testWidgets('提醒支持单条和分组已处理，确认状态持久化', (tester) async {
    final inventory = InventoryService(InventoryRepository(database));
    final today = _today();
    await inventory.intake(IntakeDraft(
      name: '过期物品',
      category: '其他物品',
      quantity: 2,
      expiryDate: today.subtract(const Duration(days: 1)),
    ));
    await inventory.intake(IntakeDraft(
      name: '临期物品',
      category: '其他物品',
      quantity: 2,
      expiryDate: today.add(const Duration(days: 2)),
    ));
    await inventory.intake(IntakeDraft(
      name: '低库存物品',
      category: '其他物品',
      quantity: 1,
      lowStockThreshold: 3,
    ));

    await _pumpScreen(tester, database, const AlertsScreen());
    await _pumpUntilFound(tester, find.text('过期物品'));
    expect(find.text('过期物品'), findsOneWidget);
    expect(find.text('临期物品'), findsOneWidget);

    await tester.tap(find.byTooltip('标记已处理').first);
    await _pumpForUi(tester);
    expect(find.text('过期物品'), findsNothing);
    expect((await database.select(database.reminderAcknowledgments).get()), hasLength(1));

    await tester.tap(find.text('全部标记已处理').first);
    await _pumpForUi(tester);
    expect(find.text('临期物品'), findsNothing);
    expect((await database.select(database.reminderAcknowledgments).get()), hasLength(2));
    await _scrollUntilFound(tester, find.text('低库存物品'));
    expect(find.text('低库存物品'), findsOneWidget);
    await _disposeWidgetTree(tester);
  });

  testWidgets('低库存提醒在恢复阈值后确认失效，再次跌破时重新出现', (tester) async {
    final inventory = InventoryService(InventoryRepository(database));
    final productId = await inventory.intake(const IntakeDraft(
      name: '周期性低库存',
      category: '其他物品',
      quantity: 1,
      lowStockThreshold: 2,
    ));
    final batchId = (await database.select(database.productBatches).get()).single.id;

    await _pumpApp(tester, database);
    await _pumpUntilFound(tester, find.text('待处理详情 >'));
    await tester.tap(find.text('待处理详情 >'));
    final alertItem = find.descendant(
      of: find.byType(AlertsScreen),
      matching: find.text('周期性低库存'),
    );
    await _pumpUntilFound(tester, alertItem);
    expect(alertItem, findsOneWidget);

    await tester.tap(find.byTooltip('标记已处理'));
    await _pumpForUi(tester);
    expect(alertItem, findsNothing);

    await inventory.replenishBatch(batchId, 2);
    await _pumpForUi(tester);
    await inventory.consumeBatch(productId, batchId, 2);
    await _pumpUntilFound(tester, alertItem);
    expect(alertItem, findsOneWidget);
    await _disposeWidgetTree(tester);
  });

  testWidgets('商品详情支持补充、指定批次消耗和报废二次确认', (tester) async {
    final inventory = InventoryService(InventoryRepository(database));
    final today = _today();
    final productId = await inventory.intake(IntakeDraft(
      name: '多批次商品',
      category: '食品生鲜',
      quantity: 3,
      batchNo: '近批次',
      expiryDate: today.add(const Duration(days: 5)),
    ));
    await inventory.intake(
      IntakeDraft(
        name: '多批次商品',
        category: '食品生鲜',
        quantity: 4,
        batchNo: '远批次',
        expiryDate: today.add(const Duration(days: 20)),
      ),
      mergeProductId: productId,
    );

    await _pumpScreen(tester, database, ProductDetailScreen(productId: productId));
    await _scrollUntilFound(tester, find.text('近批次'));
    expect(find.text('近批次'), findsOneWidget);
    await _scrollUntilFound(tester, find.text('远批次'));
    expect(find.text('远批次'), findsOneWidget);

    await _tapBatchMenu(tester, '近批次');
    await _pumpForUi(tester);
    await tester.tap(find.text('消耗指定数量'));
    await _pumpForUi(tester);
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.text('确认消耗'));
    await _pumpForUi(tester);

    var batches = await database.select(database.productBatches).get();
    final nearBatch = batches.singleWhere((batch) => batch.batchNo == '近批次');
    expect(nearBatch.remainingQuantity, 1);

    await _tapBatchMenu(tester, '远批次');
    await _pumpForUi(tester);
    await tester.tap(find.text('补充指定数量'));
    await _pumpForUi(tester);
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.text('确认补充'));
    await _pumpForUi(tester);

    batches = await database.select(database.productBatches).get();
    final farBatch = batches.singleWhere((batch) => batch.batchNo == '远批次');
    expect(farBatch.remainingQuantity, 6);

    await _tapBatchMenu(tester, '远批次');
    await _pumpForUi(tester);
    await tester.tap(find.text('报废批次'));
    await _pumpForUi(tester);
    expect(find.text('确认报废批次？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _pumpForUi(tester);
    expect((await database.select(database.productBatches).get()).singleWhere((batch) => batch.batchNo == '远批次').isDiscarded, isFalse);

    await _tapBatchMenu(tester, '远批次');
    await _pumpForUi(tester);
    await tester.tap(find.text('报废批次'));
    await _pumpForUi(tester);
    await tester.tap(find.text('确认报废'));
    await _pumpForUi(tester);
    expect((await database.select(database.productBatches).get()).singleWhere((batch) => batch.batchNo == '远批次').isDiscarded, isTrue);
    await _disposeWidgetTree(tester);
  });

  testWidgets('窄屏、横屏和键盘打开时关键页面仍可操作', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    await _pumpApp(tester, database);
    await _pumpUntilFound(tester, find.byType(NavigationBar));
    expect(find.byType(NavigationBar), findsOneWidget);

    // 访问首页提醒详情
    await _pumpUntilFound(tester, find.text('待处理详情 >'));
    await tester.tap(find.text('待处理详情 >'));
    await _pumpUntilFound(tester, find.text('效期与库存提醒'));
    expect(find.text('效期与库存提醒'), findsOneWidget);
    await _dismissModalRoute(tester);

    // 切换到底栏“库存”Tab
    await tester.tap(find.byIcon(Icons.all_inbox_rounded));
    await _pumpUntilFound(tester, find.text('嬷嬷的小箱子'));
    expect(find.text('嬷嬷的小箱子'), findsOneWidget);
    await _pumpUntilFound(tester, find.text('入库'));

    tester.widget<FloatingActionButton>(find.byType(FloatingActionButton)).onPressed!();
    await tester.pump();
    final nameField = _field('物品名称 *');
    await _pumpUntilFound(tester, nameField);
    await tester.showKeyboard(nameField);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();
    final sheetScrollView = find.descendant(
      of: find.byType(DraggableScrollableSheet).first,
      matching: find.byType(Scrollable),
    ).first;
    final submitButton = find.text('确认入库');
    for (var attempt = 0; attempt < 8 && submitButton.evaluate().isEmpty; attempt++) {
      await tester.drag(sheetScrollView, const Offset(0, -240), warnIfMissed: false);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(submitButton, findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = const FakeViewPadding();
    tester.view.physicalSize = const Size(800, 480);
    await tester.pump();
    expect(find.text('确认入库'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await _dismissModalRoute(tester);
    await _disposeWidgetTree(tester);
  });
}

// Several screens intentionally show indeterminate loading indicators while
// repository streams connect. Avoid pumpAndSettle, which waits forever for
// those animations; bounded frames still allow routes and async UI work to render.
Future<void> _pumpForUi(WidgetTester tester) async {
  // Riverpod streams and modal route transitions can require more than one
  // frame on the GitHub Actions runner. Keep this bounded instead of using
  // pumpAndSettle because some screens intentionally show indeterminate
  // progress indicators.
  await tester.pump();
  for (var index = 0; index < 4; index++) {
    await tester.pump(const Duration(milliseconds: 150));
  }
}

Future<void> _pumpUntilFound(
  WidgetTester tester,
  Finder finder, {
  Duration step = const Duration(milliseconds: 100),
  int maxPumps = 30,
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt++) {
    if (finder.evaluate().isNotEmpty) return;
    await tester.pump(step);
  }

  if (finder.evaluate().isEmpty) {
    throw TestFailure(
      'Timed out after ${step.inMilliseconds * maxPumps} ms waiting for ${finder.describeMatch(Plurality.many)}.',
    );
  }
}

Future<void> _scrollUntilFound(WidgetTester tester, Finder finder) async {
  await tester.scrollUntilVisible(
    finder,
    240,
    scrollable: find.byType(Scrollable).first,
  );
}

Future<void> _pumpUntilAbsent(
  WidgetTester tester,
  Finder finder, {
  Duration step = const Duration(milliseconds: 100),
  int maxPumps = 30,
}) async {
  for (var attempt = 0; attempt < maxPumps; attempt++) {
    if (finder.evaluate().isEmpty) return;
    await tester.pump(step);
  }

  throw TestFailure(
    'Timed out after ${step.inMilliseconds * maxPumps} ms waiting for ${finder.describeMatch(Plurality.many)} to disappear.',
  );
}

Future<void> _pumpSheet(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(database)],
      child: MaterialApp(
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: FilledButton(
                onPressed: () => showModalBottomSheet<void>(
                  context: context,
                  isScrollControlled: true,
                  useSafeArea: true,
                  builder: (_) => const IntakeSheet(),
                ),
                child: const Text('打开测试入库表单'),
              ),
            ),
          ),
        ),
      ),
    ),
  );
  await _openIntakeSheet(tester);
}

Future<void> _openIntakeSheet(WidgetTester tester) async {
  await tester.tap(find.text('打开测试入库表单'));
  await _pumpUntilFound(tester, _field('物品名称 *'));
}

Future<void> _scrollSheetToTop(WidgetTester tester) async {
  final sheetScrollView = find.descendant(
    of: find.byType(DraggableScrollableSheet),
    matching: find.byType(Scrollable),
  ).first;
  final scrollable = tester.state<ScrollableState>(sheetScrollView);
  scrollable.position.jumpTo(scrollable.position.minScrollExtent);
  await tester.pump();
}

Future<void> _scrollSheetUntilFound(WidgetTester tester, Finder finder) async {
  final sheetScrollView = find.descendant(
    of: find.byType(DraggableScrollableSheet),
    matching: find.byType(Scrollable),
  ).first;
  await tester.scrollUntilVisible(
    finder,
    120,
    scrollable: sheetScrollView,
  );
}

Future<void> _dismissModalRoute(WidgetTester tester) async {
  tester.binding.handlePopRoute();
  await _pumpUntilAbsent(tester, _field('物品名称 *'));
}

Future<void> _disposeWidgetTree(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drift defers closing stream queries with a zero-duration timer.
  await tester.pump(const Duration(milliseconds: 1));
}

Future<void> _pumpScreen(WidgetTester tester, AppDatabase database, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(database)],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await _pumpForUi(tester);
}

Future<void> _pumpApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(database)],
      child: const MomoBoxApp(enableMediaReconciliation: false),
    ),
  );
  await _pumpForUi(tester);
}

Future<void> _tapBatchMenu(WidgetTester tester, String batchNo) async {
  final batchLabel = find.text(batchNo);
  await _scrollUntilFound(tester, batchLabel);
  final batchCard = find.ancestor(
    of: batchLabel,
    matching: find.byType(Card),
  ).first;
  final menu = find.descendant(
    of: batchCard,
    matching: find.byTooltip('批次操作'),
  );
  await tester.ensureVisible(menu);
  await tester.pump();
  await tester.tap(menu);
  await _pumpForUi(tester);
}

Future<void> _enterField(WidgetTester tester, String label, String value) async {
  final field = _field(label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
}

Future<void> _submitSheet(WidgetTester tester) async {
  final submitButton = find.widgetWithText(FilledButton, '确认入库');
  final sheetScrollView = find.descendant(
    of: find.byType(DraggableScrollableSheet),
    matching: find.byType(Scrollable),
  ).first;
  for (var attempt = 0; attempt < 8 && submitButton.evaluate().isEmpty; attempt++) {
    await tester.drag(sheetScrollView, const Offset(0, -240), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
  }
  // DraggableScrollableSheet can retain text-field focus outside the test
  // viewport. This helper exercises the form callback once the actual button
  // is mounted; the responsive flow below covers pointer-driven scrolling.
  tester.widget<FilledButton>(submitButton).onPressed!();
  await _pumpForUi(tester);
}

Finder _field(String label) => find.byWidgetPredicate(
      (widget) => widget is TextField && widget.decoration?.labelText == label,
      description: 'TextField($label)',
    );

TextEditingController _fieldController(WidgetTester tester, String label) =>
    tester.widget<TextField>(_field(label)).controller!;

DateTime _today() {
  final now = DateTime.now();
  return DateTime(now.year, now.month, now.day);
}
