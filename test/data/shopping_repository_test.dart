import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/application/shopping_service.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  late AppDatabase database;
  late ShoppingRepository repository;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = ShoppingRepository(database);
  });

  tearDown(() => database.close());

  ShoppingService intakeService({bool sync = false}) => ShoppingService(
    sync ? ShoppingRepository(database, outbox: SyncOutboxRepository(database), syncScopeId: 'family-a') : repository,
    inventory: InventoryRepository(database,
      outbox: sync ? SyncOutboxRepository(database) : null,
      syncScopeId: sync ? 'family-a' : null),
  );

  Future<ShoppingEntry> addPurchase(String name) async {
    await repository.addOrMerge(itemName: name, targetQuantity: 2, reason: '补货');
    return (await repository.readEntries()).singleWhere((entry) => entry.itemName == name);
  }

  IntakeDraft draftFor(ShoppingEntry entry) => IntakeDraft(
    name: entry.itemName, category: entry.category ?? '其他物品', quantity: entry.targetQuantity);

  test('采购入库与清单删除及出站在同一事务，重复点击不再增库存', () async {
    final entry = await addPurchase('纸巾');
    final service = intakeService(sync: true);
    await service.intakePurchasedEntry(entry, draftFor(entry));
    expect(await repository.readEntries(), isEmpty);
    expect((await database.select(database.productBatches).getSingle()).remainingQuantity, 2);
    final requests = (await database.select(database.syncOutbox).get())
      .map((row) => jsonDecode(row.requestJson) as Map<String, dynamic>).toList();
    expect(requests.any((row) => row['command'] == 'restock'), isTrue);
    expect(requests.any((row) => row['operation'] == 'entity_delete' && row['entity'] == 'shopping_items'), isTrue);
    await expectLater(service.intakePurchasedEntry(entry, draftFor(entry)), throwsA(isA<StateError>()));
    expect(await database.select(database.productBatches).get(), hasLength(1));
    expect(await database.select(database.stockMovements).get(), hasLength(1));
  });

  test('采购项删除失败时回滚库存、流水和全部新出站，仍可重试', () async {
    final entry = await addPurchase('肥皂');
    await database.customStatement("""
      CREATE TRIGGER fail_purchase_delete BEFORE UPDATE OF deleted_at ON shopping_entries
      WHEN NEW.deleted_at IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'purchase delete failed'); END
    """);
    final service = intakeService(sync: true);
    await expectLater(service.intakePurchasedEntry(entry, draftFor(entry)), throwsA(anything));
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
    expect(await database.select(database.stockMovements).get(), isEmpty);
    expect(await database.select(database.syncOutbox).get(), isEmpty);
    expect(await repository.readEntries(), hasLength(1));
    await database.customStatement('DROP TRIGGER fail_purchase_delete');
    await service.intakePurchasedEntry(entry, draftFor(entry));
    expect(await repository.readEntries(), isEmpty);
  });

  test('并发采购入库仅一项事务成功', () async {
    final entry = await addPurchase('电池');
    final service = intakeService();
    final errors = <Object>[];
    Future<String?> attempt() async {
      try {
        return await service.intakePurchasedEntry(entry, draftFor(entry));
      } catch (error) {
        errors.add(error);
        return null;
      }
    }
    final results = await Future.wait([attempt(), attempt()]);
    expect(results.whereType<String>(), hasLength(1));
    expect(errors, hasLength(1));
    expect(errors.single, isA<StateError>());
    expect(await database.select(database.productBatches).get(), hasLength(1));
    expect(await database.select(database.stockMovements).get(), hasLength(1));
  });

  test('确认后的采购项变化拒绝旧入库计划', () async {
    final entry = await addPurchase('牛奶');
    await repository.addOrMerge(itemName: '牛奶', targetQuantity: 3, reason: '新增');
    await expectLater(intakeService().intakePurchasedEntry(entry, draftFor(entry)), throwsA(isA<StateError>()));
    expect(await database.select(database.products).get(), isEmpty);
    expect((await repository.readEntries()).single.targetQuantity, 5);
  });

  test('逐项入库保留前项成功，后项失败不留下半项库存', () async {
    final first = await addPurchase('第一项');
    final second = await addPurchase('第二项');
    await database.customStatement("""
      CREATE TRIGGER fail_second_delete BEFORE UPDATE OF deleted_at ON shopping_entries
      WHEN NEW.item_name = '第二项' AND NEW.deleted_at IS NOT NULL
      BEGIN SELECT RAISE(ABORT, 'second purchase delete failed'); END
    """);
    final service = intakeService();
    await service.intakePurchasedEntry(first, draftFor(first));
    await expectLater(service.intakePurchasedEntry(second, draftFor(second)), throwsA(anything));
    expect((await database.select(database.products).get()).single.name, '第一项');
    expect((await repository.readEntries()).single.id, second.id);
    expect(await database.select(database.productBatches).get(), hasLength(1));
  });

  test('采购入库拒绝两个不同数据库，避免伪原子事务', () async {
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    try {
      expect(() => ShoppingService(repository, inventory: InventoryRepository(other)), throwsArgumentError);
    } finally {
      await other.close();
    }
  });

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
