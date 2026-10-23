import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  late AppDatabase database;
  late InventoryRepository repository;
  late InventoryService service;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    repository = InventoryRepository(database);
    service = InventoryService(repository);
  });

  tearDown(() => database.close());

  test('报废已耗尽批次不会写入零数量流水', () async {
    final productId = await repository.createProductWithBatch(
      const IntakeDraft(
        name: '测试物品',
        category: '其他',
        quantity: 1,
      ),
    );
    final batch = (await database.select(database.productBatches).get()).single;

    await repository.consumeBatch(productId, batch.id, 1);
    await repository.discardBatch(batch.id);

    final batches = await database.select(database.productBatches).get();
    final movements = await database.select(database.stockMovements).get();
    expect(batches.single.remainingQuantity, 0);
    expect(batches.single.isDiscarded, isTrue);
    expect(movements.map((movement) => movement.quantity), everyElement(isNot(0)));
    expect(movements.where((movement) => movement.type == 'discard'), isEmpty);
  });

  test('软删除商品不返回合并候选，旧确认也不能新增隐藏批次', () async {
    const draft = IntakeDraft(name: '已删商品', category: '其他物品',
      quantity: 2, barcode: 'deleted-barcode');
    final productId = await repository.createProductWithBatch(draft);
    expect(await repository.findMatchingProducts(draft), hasLength(1));
    await repository.applyRemoteProductDelete(productId: productId,
      version: 1, deletedAt: DateTime.now());
    expect(await repository.findMatchingProducts(draft), isEmpty);
    await expectLater(service.intake(draft, mergeProductId: productId),
      throwsA(isA<StateError>()));
    expect(await database.select(database.productBatches).get(), hasLength(1));
    expect(await database.select(database.stockMovements).get(), hasLength(1));
  });

  test('零余量报废仍发送 discard 状态命令，保留零流水限制', () async {
    final synced = InventoryRepository(database, outbox: SyncOutboxRepository(database),
      syncScopeId: 'family-a');
    final productId = await synced.createProductWithBatch(const IntakeDraft(
      name: '已耗尽', category: '其他物品', quantity: 1));
    final batch = await database.select(database.productBatches).getSingle();
    await synced.consumeBatch(productId, batch.id, 1);
    await synced.discardBatch(batch.id);
    final requests = (await database.select(database.syncOutbox).get())
        .map((row) => jsonDecode(row.requestJson) as Map<String, dynamic>)
        .where((request) => request['command'] == 'discard').toList();
    expect(requests, hasLength(1));
    expect(requests.single['allocations'], [{'batch_id': batch.id, 'quantity': 0}]);
    expect((await database.select(database.stockMovements).get())
      .where((row) => row.quantity == 0), isEmpty);
    await expectLater(synced.discardBatch(batch.id), throwsA(isA<StateError>()));
    expect((await database.select(database.syncOutbox).get())
      .where((row) => (jsonDecode(row.requestJson) as Map)['command'] == 'discard'), hasLength(1));
  });

  test('accepted 实体版本只升不降且保留后续乐观库存', () async {
    final id = await repository.createProductWithBatch(const IntakeDraft(
      name: '本地新编辑', category: '其他物品', quantity: 3));
    final batch = await database.select(database.productBatches).getSingle();
    await repository.acknowledgeEntityVersion(entity: 'products', entityId: id, version: 4);
    await repository.acknowledgeEntityVersion(entity: 'products', entityId: id, version: 2);
    await repository.acknowledgeEntityVersion(entity: 'product_batches', entityId: batch.id, version: 5);
    expect((await repository.getProductRecord(id))!.serverVersion, 4);
    final updated = (await repository.getBatchRecord(batch.id))!;
    expect(updated.serverVersion, 5);
    expect(updated.remainingQuantity, 3);
    expect(updated.initialQuantity, 3);
  });

  test('放弃未创建商品不会隐藏仍有库存的子批次或已同步商品', () async {
    final id = await repository.createProductWithBatch(const IntakeDraft(
      name: '受保护的库存', category: '其他物品', quantity: 3));
    final batch = await database.select(database.productBatches).getSingle();
    await expectLater(repository.abandonUncreatedEntity(entity: 'products', entityId: id),
      throwsA(isA<StateError>()));
    expect((await repository.getProductRecord(id))!.deletedAt, isNull);
    await repository.acknowledgeEntityVersion(entity: 'product_batches', entityId: batch.id, version: 2);
    await repository.abandonUncreatedEntity(entity: 'product_batches', entityId: batch.id);
    expect((await repository.getBatchRecord(batch.id))!.deletedAt, isNull);
    await repository.acknowledgeEntityVersion(entity: 'products', entityId: id, version: 2);
    await repository.abandonUncreatedEntity(entity: 'products', entityId: id);
    expect((await repository.getProductRecord(id))!.deletedAt, isNull);
  });

  test('相似商品只返回候选，默认新建且显式选择后才合并', () async {
    final barcodeProductId = await repository.createProductWithBatch(
      const IntakeDraft(
        name: '条码物品',
        category: '其他物品',
        quantity: 1,
        barcode: '6901234567890',
      ),
    );
    final barcodeMatches = await repository.findMatchingProducts(
      const IntakeDraft(
        name: '不同名称也以条码匹配',
        category: '食品生鲜',
        quantity: 2,
        barcode: '6901234567890',
      ),
    );
    expect(barcodeMatches.map((candidate) => candidate.id), contains(barcodeProductId));

    final sameBarcodeProductId = await repository.createProductWithBatch(
      const IntakeDraft(
        name: '不同名称也以条码归并',
        category: '食品生鲜',
        quantity: 2,
        barcode: '6901234567890',
      ),
    );
    expect(sameBarcodeProductId, isNot(barcodeProductId));
    final multipleBarcodeMatches = await repository.findMatchingProducts(
      const IntakeDraft(
        name: '再次录入条码商品',
        category: '其他物品',
        quantity: 1,
        barcode: '6901234567890',
      ),
    );
    expect(multipleBarcodeMatches, hasLength(2));

    final noBarcodeProductId = await repository.createProductWithBatch(
      const IntakeDraft(
        name: '无条码物品',
        category: '药品保健',
        brand: '品牌 A',
        specification: '10 片',
        quantity: 1,
      ),
    );
    final noBarcodeMatches = await repository.findMatchingProducts(
      const IntakeDraft(
        name: ' 无条码物品 ',
        category: '药品保健',
        brand: '品牌 A ',
        specification: ' 10 片',
        quantity: 2,
      ),
    );
    expect(noBarcodeMatches.map((candidate) => candidate.id), contains(noBarcodeProductId));

    final mergedProductId = await repository.createProductWithBatch(
      const IntakeDraft(
        name: ' 无条码物品 ',
        category: '药品保健',
        brand: '品牌 A ',
        specification: ' 10 片',
        quantity: 2,
      ),
      existingProductId: noBarcodeProductId,
    );
    expect(mergedProductId, noBarcodeProductId);
    expect(await database.select(database.products).get(), hasLength(3));
    expect(await database.select(database.productBatches).get(), hasLength(4));
  });

  test('合并目标不存在时失败且不写入批次', () async {
    expect(
      () => repository.createProductWithBatch(
        const IntakeDraft(
          name: '待合并物品',
          category: '其他物品',
          quantity: 1,
        ),
        existingProductId: 'missing-product',
      ),
      throwsA(isA<StateError>()),
    );
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
    expect(await database.select(database.stockMovements).get(), isEmpty);
  });

  test('选择新建时不会因为相似候选而归并', () async {
    await repository.createProductWithBatch(
      const IntakeDraft(
        name: '已有物品',
        category: '其他物品',
        quantity: 1,
        barcode: '123',
      ),
    );

    final draft = const IntakeDraft(
      name: '新物品',
      category: '其他物品',
      quantity: 2,
      barcode: '123',
    );
    final matches = await service.findMatchingProducts(draft);
    expect(matches, hasLength(1));
    final newProductId = await service.intake(draft);

    expect(newProductId, isNot(matches.single.id));
    expect(await database.select(database.products).get(), hasLength(2));
  });

  test('FEFO 消耗、补充和报废都会更新批次及库存流水', () async {
    final productId = await repository.createProductWithBatch(
      IntakeDraft(
        name: 'FEFO 测试物品',
        category: '其他物品',
        quantity: 2,
        batchNo: 'early',
        expiryDate: DateTime(2099, 1, 1),
      ),
    );
    await repository.addBatch(
      productId: productId,
      quantity: 3,
      batchNo: 'late',
      expiryDate: DateTime(2099, 2, 1),
    );

    await repository.consumeByFefo(productId, 3);
    final afterConsume = await database.select(database.productBatches).get();
    final early = afterConsume.firstWhere((batch) => batch.batchNo == 'early');
    final late = afterConsume.firstWhere((batch) => batch.batchNo == 'late');
    expect(early.remainingQuantity, 0);
    expect(late.remainingQuantity, 2);

    await repository.replenishBatch(late.id, 2);
    await repository.discardBatch(late.id);
    final discarded = (await database.select(database.productBatches).get())
        .firstWhere((batch) => batch.id == late.id);
    expect(discarded.initialQuantity, 5);
    expect(discarded.remainingQuantity, 0);
    expect(discarded.isDiscarded, isTrue);

    final movements = await database.select(database.stockMovements).get();
    expect(movements.map((movement) => movement.quantity), containsAll([2, 3, -2, -1, 2, -4]));
    expect(movements.map((movement) => movement.quantity), everyElement(isNot(0)));
  });

  test('补充批次数量必须为正整数', () async {
    final productId = await repository.createProductWithBatch(
      const IntakeDraft(
        name: '测试物品',
        category: '其他物品',
        quantity: 1,
      ),
    );

    expect(
      () => repository.addBatch(productId: productId, quantity: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(await database.select(database.productBatches).get(), hasLength(1));
    expect(await database.select(database.stockMovements).get(), hasLength(1));
  });

  test('手动到期日期保存为 manual，生产日期加保质期保存为 calculated', () async {
    await service.intake(
      IntakeDraft(
        name: '手动日期物品',
        category: '其他物品',
        quantity: 1,
        expiryDate: DateTime(2026, 9, 30),
      ),
    );
    await service.intake(
      IntakeDraft(
        name: '计算日期物品',
        category: '其他物品',
        quantity: 1,
        productionDate: DateTime(2026, 9, 2),
        shelfLifeAmount: 30,
        shelfLifeUnit: ShelfLifeUnit.days,
      ),
    );

    final batches = await database.select(database.productBatches).get();
    final products = await database.select(database.products).get();
    final productNames = {for (final product in products) product.id: product.name};

    final manual = batches.firstWhere((batch) => productNames[batch.productId] == '手动日期物品');
    final calculated = batches.firstWhere((batch) => productNames[batch.productId] == '计算日期物品');
    expect(manual.dateSource, 'manual');
    expect(manual.datePrecision, 'day');
    expect(calculated.dateSource, 'calculated');
    expect(calculated.datePrecision, 'day');
  });
}
