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
    await _enterField(tester, '物品名称 *', '待确认商品');
    await _enterField(tester, '条码', '6900000000001');
    await _submitSheet(tester);
    expect(find.text('发现相似商品'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(find.text('发现相似商品'), findsNothing);
    expect(_fieldController(tester, '物品名称 *').text, '待确认商品');
    expect(_fieldController(tester, '条码').text, '6900000000001');
    expect(await database.select(database.products).get(), hasLength(1));

    await _submitSheet(tester);
    await tester.tap(find.text('合并到已有商品'));
    await tester.pumpAndSettle();
    expect(await database.select(database.products).get(), hasLength(1));
    expect(await database.select(database.productBatches).get(), hasLength(2));

    await _pumpSheet(tester, database);
    await _enterField(tester, '物品名称 *', '独立商品');
    await _enterField(tester, '条码', '6900000000001');
    await _submitSheet(tester);
    await tester.tap(find.text('新建独立商品'));
    await tester.pumpAndSettle();
    expect(await database.select(database.products).get(), hasLength(2));
    expect(await database.select(database.productBatches).get(), hasLength(3));
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
    expect(find.text('洗衣液'), findsOneWidget);
    await tester.tap(find.byType(Checkbox));
    await tester.pumpAndSettle();

    expect(find.text('手动入库'), findsOneWidget);
    expect(_fieldController(tester, '物品名称 *').text, '洗衣液');
    expect(_fieldController(tester, '入库数量 *').text, '3');
    expect((await database.select(database.shoppingEntries).get()).single.isCompleted, isTrue);
    await tester.pageBack();
    await tester.pumpAndSettle();
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
    expect(find.text('过期物品'), findsOneWidget);
    expect(find.text('临期物品'), findsOneWidget);
    expect(find.text('低库存物品'), findsOneWidget);

    await tester.tap(find.byTooltip('标记已处理').first);
    await tester.pumpAndSettle();
    expect(find.text('过期物品'), findsNothing);
    expect((await database.select(database.reminderAcknowledgments).get()), hasLength(1));

    await tester.tap(find.text('全部标记已处理').first);
    await tester.pumpAndSettle();
    expect(find.text('临期物品'), findsNothing);
    expect((await database.select(database.reminderAcknowledgments).get()), hasLength(2));
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
    await tester.tap(find.text('提醒'));
    await tester.pumpAndSettle();
    expect(find.text('周期性低库存'), findsOneWidget);

    await tester.tap(find.byTooltip('标记已处理'));
    await tester.pumpAndSettle();
    expect(find.text('周期性低库存'), findsNothing);

    await inventory.replenishBatch(batchId, 2);
    await tester.pumpAndSettle();
    await inventory.consumeBatch(productId, batchId, 2);
    await tester.pumpAndSettle();
    expect(find.text('周期性低库存'), findsOneWidget);
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
    expect(find.text('近批次'), findsOneWidget);
    expect(find.text('远批次'), findsOneWidget);

    await _tapBatchMenu(tester, 0);
    await tester.pumpAndSettle();
    await tester.tap(find.text('消耗指定数量'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.text('确认消耗'));
    await tester.pumpAndSettle();

    var batches = await database.select(database.productBatches).get();
    final nearBatch = batches.singleWhere((batch) => batch.batchNo == '近批次');
    expect(nearBatch.remainingQuantity, 1);

    await _tapBatchMenu(tester, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('补充指定数量'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '2');
    await tester.tap(find.text('确认补充'));
    await tester.pumpAndSettle();

    batches = await database.select(database.productBatches).get();
    final farBatch = batches.singleWhere((batch) => batch.batchNo == '远批次');
    expect(farBatch.remainingQuantity, 6);

    await _tapBatchMenu(tester, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('报废批次'));
    await tester.pumpAndSettle();
    expect(find.text('确认报废批次？'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect((await database.select(database.productBatches).get()).singleWhere((batch) => batch.batchNo == '远批次').isDiscarded, isFalse);

    await _tapBatchMenu(tester, 1);
    await tester.pumpAndSettle();
    await tester.tap(find.text('报废批次'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认报废'));
    await tester.pumpAndSettle();
    expect((await database.select(database.productBatches).get()).singleWhere((batch) => batch.batchNo == '远批次').isDiscarded, isTrue);
  });

  testWidgets('窄屏、横屏和键盘打开时关键页面仍可操作', (tester) async {
    addTearDown(tester.view.reset);
    tester.view.devicePixelRatio = 1;
    tester.view.physicalSize = const Size(320, 640);
    await _pumpApp(tester, database);
    expect(find.byType(NavigationBar), findsOneWidget);
    expect(find.text('手动入库'), findsOneWidget);

    await tester.tap(find.text('提醒'));
    await tester.pumpAndSettle();
    expect(find.text('效期与库存提醒'), findsOneWidget);
    await tester.tap(find.text('采买'));
    await tester.pumpAndSettle();
    expect(find.text('待采买清单'), findsOneWidget);
    await tester.tap(find.text('库存'));
    await tester.pumpAndSettle();
    expect(find.text('嬷嬷的小箱子'), findsOneWidget);

    await tester.tap(find.text('手动入库'));
    await tester.pumpAndSettle();
    final nameField = _field('物品名称 *');
    await tester.showKeyboard(nameField);
    tester.view.viewInsets = const FakeViewPadding(bottom: 280);
    await tester.pump();
    await tester.ensureVisible(find.text('确认入库'));
    expect(find.text('确认入库'), findsOneWidget);
    expect(tester.takeException(), isNull);

    tester.view.viewInsets = const FakeViewPadding();
    tester.view.physicalSize = const Size(800, 480);
    await tester.pump();
    expect(find.text('确认入库'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pageBack();
    await tester.pumpAndSettle();
  });
}

Future<void> _pumpSheet(WidgetTester tester, AppDatabase database) async {
  await _pumpScreen(tester, database, const IntakeSheet());
}

Future<void> _pumpScreen(WidgetTester tester, AppDatabase database, Widget child) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(database)],
      child: MaterialApp(home: Scaffold(body: child)),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _pumpApp(WidgetTester tester, AppDatabase database) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [databaseProvider.overrideWithValue(database)],
      child: const MomoBoxApp(),
    ),
  );
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 100));
}

Future<void> _tapBatchMenu(WidgetTester tester, int index) async {
  final menu = find.byTooltip('批次操作').at(index);
  await tester.ensureVisible(menu);
  await tester.tap(menu);
  await tester.pumpAndSettle();
}

Future<void> _enterField(WidgetTester tester, String label, String value) async {
  final field = _field(label);
  await tester.ensureVisible(field);
  await tester.enterText(field, value);
}

Future<void> _submitSheet(WidgetTester tester) async {
  await tester.ensureVisible(find.text('确认入库'));
  await tester.tap(find.text('确认入库'));
  await tester.pumpAndSettle();
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
