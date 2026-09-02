import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  late AppDatabase database;
  late ShoppingRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = ShoppingRepository(database);
  });

  tearDown(() => database.close());

  test('相同商品的未完成采购项会合并数量', () async {
    final productId = await InventoryRepository(database).createProductWithBatch(
      const IntakeDraft(name: '牛奶', category: '食品生鲜', quantity: 1),
    );
    await repository.addOrMerge(
      itemName: '牛奶',
      targetQuantity: 2,
      reason: '来自库存提醒',
      productId: productId,
      category: '食品生鲜',
    );
    await repository.addOrMerge(
      itemName: '牛奶',
      targetQuantity: 3,
      reason: '来自库存快捷操作',
      productId: productId,
      category: '食品生鲜',
    );

    final entries = await database.select(database.shoppingEntries).get();
    expect(entries, hasLength(1));
    expect(entries.single.targetQuantity, 5);
    expect(entries.single.reason, '来自库存提醒');
  });

  test('已完成采购项不会被提醒再次合并', () async {
    final productId = await InventoryRepository(database).createProductWithBatch(
      const IntakeDraft(name: '维生素 C', category: '药品保健', quantity: 1),
    );
    await repository.addOrMerge(
      itemName: '维生素 C',
      targetQuantity: 1,
      reason: '来自库存提醒',
      productId: productId,
    );
    final entry = (await database.select(database.shoppingEntries).get()).single;
    await repository.setCompleted(entry.id, true);

    await repository.addOrMerge(
      itemName: '维生素 C',
      targetQuantity: 2,
      reason: '来自库存提醒',
      productId: productId,
    );

    final entries = await database.select(database.shoppingEntries).get();
    expect(entries, hasLength(2));
    expect(entries.map((item) => item.targetQuantity), containsAll(<int>[1, 2]));
    expect(entries.where((item) => !item.isCompleted).single.targetQuantity, 2);
  });

  test('无商品关联时会按规范化名称合并', () async {
    await repository.addOrMerge(
      itemName: '  纸巾 ',
      targetQuantity: 1,
      reason: '手动添加',
    );
    await repository.addOrMerge(
      itemName: '纸巾',
      targetQuantity: 2,
      reason: '来自库存提醒',
    );

    final entries = await database.select(database.shoppingEntries).get();
    expect(entries, hasLength(1));
    expect(entries.single.itemName, '纸巾');
    expect(entries.single.targetQuantity, 3);
  });
}
