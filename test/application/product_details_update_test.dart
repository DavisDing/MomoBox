import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/product_details_patch.dart';
import 'package:momo_box/domain/models/sync_models.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late InventoryRepository repository;
  late InventoryService inventory;
  late AiInventoryActionService actions;
  late String productId;

  Future<InventoryItem> item() async =>
      (await inventory.watchInventory().first).single;
  AiInventoryAction proposal(Map<String, Object?> fields) =>
      AiInventoryAction.fromJson({
        'kind': 'product_update',
        'productId': productId,
        ...fields,
      })!;
  Future<void> connect({
    SyncOutboxRepository? outbox,
    void Function()? guard,
    Future<String?> Function()? scopeResolver,
    bool capability = true,
  }) async {
    if (capability) await settings.setValue('sync_import_format:family-a', '1');
    repository = InventoryRepository(
      db,
      outbox: outbox ?? SyncOutboxRepository(db),
      syncScopeId: 'family-a',
      syncScopeResolver: scopeResolver,
      assertWritable: guard,
    );
    inventory = InventoryService(repository);
    actions = AiInventoryActionService(settings, inventory);
  }

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsRepository(db);
    repository = InventoryRepository(db);
    inventory = InventoryService(repository);
    actions = AiInventoryActionService(settings, inventory);
    productId = await inventory.intake(
      IntakeDraft(
        name: '急支糖浆',
        category: '零食饮料',
        quantity: 3,
        brand: '旧品牌',
        specification: '100ml',
        location: '餐边柜',
        barcode: '123456',
        lowStockThreshold: 2,
        productionDate: DateTime(2026, 10, 1),
        expiryDate: DateTime(2027, 10, 1),
      ),
    );
    await repository.acknowledgeEntityVersion(
      entity: 'products',
      entityId: productId,
      version: 7,
    );
  });
  tearDown(() => db.close());

  test('预览不写入，分类和资料与出站同事务保存，保留批次和库存', () async {
    await connect();
    final before = await item();
    final batches =
        (await db.select(db.productBatches).get())
            .map((b) => b.toJson())
            .toList();
    final movements =
        (await db.select(db.stockMovements).get())
            .map((m) => m.toJson())
            .toList();
    final action = proposal({
      'category': '药品保健',
      'brand': '新品牌',
      'specification': '120ml',
      'location': '药箱',
    });
    final description = await actions.describe(action);
    expect(description, contains('分类：零食饮料 → 药品保健'));
    expect(description, contains('品牌：旧品牌 → 新品牌'));
    expect((await item()).category, '零食饮料');
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    final result = await actions.executeWithResult(
      action,
      confirmedDescription: description,
    );
    final after = await item();
    expect(after.category, '药品保健');
    expect(after.brand, '新品牌');
    expect(after.specification, '120ml');
    expect(after.location, '药箱');
    expect(after.barcode, before.barcode);
    expect(after.totalStock, before.totalStock);
    expect(after.unit, before.unit);
    expect(after.lowStockThreshold, 2);
    expect(
      (await db.select(db.productBatches).get())
          .map((b) => b.toJson())
          .toList(),
      batches,
    );
    expect(
      (await db.select(db.stockMovements).get())
          .map((m) => m.toJson())
          .toList(),
      movements,
    );
    expect(result, contains('已更新「急支糖浆」的资料'));
    expect(result, contains('等待家庭同步'));
    final requests =
        (await db.select(db.syncOutbox).get())
            .map((row) => jsonDecode(row.requestJson) as Map)
            .toList();
    final category = requests.singleWhere((r) => r['entity'] == 'categories');
    final product = requests.singleWhere((r) => r['entity'] == 'products');
    expect(category['payload'], {'name': '药品保健'});
    expect(product['entity_id'], productId);
    expect(product['base_version'], 7);
    expect(product['payload'], {
      'name': '急支糖浆',
      'brand': '新品牌',
      'specification': '120ml',
      'barcode': '123456',
      'category_id': category['entity_id'],
      'location': '药箱',
      'unit': '件',
      'low_stock_threshold': 2,
    });
    expect(
      await settings.getValue('sync_category_binding:family-a:$productId'),
      category['entity_id'],
    );
    await expectLater(
      actions.executeWithResult(action, confirmedDescription: description),
      throwsStateError,
    );
    expect(await db.select(db.syncOutbox).get(), hasLength(2));
  });

  test('清空以明确null出站，省略字段保留，后续编辑延续待同步版本', () async {
    await connect();
    for (final fields in [
      {'brand': null, 'location': null, 'barcode': null},
      {'name': '急支糖浆（家庭用）', 'specification': null},
    ]) {
      final action = proposal(fields);
      await actions.executeWithResult(
        action,
        confirmedDescription: await actions.describe(action),
      );
    }
    final after = await item();
    expect(after.name, '急支糖浆（家庭用）');
    expect(after.category, '零食饮料');
    expect([
      after.brand,
      after.specification,
      after.location,
      after.barcode,
    ], everyElement(isNull));
    final requests =
        (await db.select(db.syncOutbox).get())
            .where((r) => r.entity == 'products')
            .map((r) => jsonDecode(r.requestJson) as Map)
            .toList();
    expect(requests.map((r) => r['base_version']), [7, 8]);
    expect(requests.first['payload'], containsPair('brand', null));
    expect(requests.first['payload'], containsPair('location', null));
    expect(requests.first['payload'], containsPair('barcode', null));
    expect(requests.first['payload'], containsPair('specification', '100ml'));
    expect(requests.last['payload'], containsPair('specification', null));
  });

  test('确认快照涵盖全部资料，事务内防止覆盖并发修改，库存变化可保留', () async {
    await connect();
    final action = proposal({'category': '药品保健'});
    final description = await actions.describe(action);
    final expected = ProductDetailsPatch.snapshot(await item());
    await db.customStatement('UPDATE products SET brand = ? WHERE id = ?', [
      '其他成员修改',
      productId,
    ]);
    await expectLater(
      actions.executeWithResult(action, confirmedDescription: description),
      throwsStateError,
    );
    await expectLater(
      repository.updateProductDetails(
        productId,
        ProductDetailsPatch.fromJson(action.arguments),
        expectedDetails: expected,
      ),
      throwsStateError,
    );
    expect((await item()).brand, '其他成员修改');
    expect((await item()).category, '零食饮料');
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    final refreshed = await actions.describe(action);
    await inventory.consume(productId, 1);
    await actions.executeWithResult(action, confirmedDescription: refreshed);
    expect((await item()).totalStock, 2);
    expect((await item()).category, '药品保健');
  });

  test('未预览、撤销授权、已删除或不存在物品不写入', () async {
    await connect();
    final action = proposal({'location': '药箱'});
    await expectLater(
      actions.executeWithResult(action, confirmedDescription: '自行伪造确认'),
      throwsStateError,
    );
    final description = await actions.describe(action);
    await settings.setValue(AiInventoryActionService.permissionKey, 'false');
    await expectLater(
      actions.executeWithResult(action, confirmedDescription: description),
      throwsStateError,
    );
    await settings.setValue(AiInventoryActionService.permissionKey, 'true');
    await expectLater(
      actions.describe(proposal({'brand': '旧品牌'})),
      throwsStateError,
    );
    await repository.applyRemoteProductDelete(
      productId: productId,
      version: 8,
      deletedAt: DateTime.now(),
    );
    await expectLater(
      actions.executeWithResult(action, confirmedDescription: description),
      throwsStateError,
    );
    await expectLater(
      actions.describe(
        AiInventoryAction(
          kind: 'product_update',
          productId: 'missing',
          arguments: const {'brand': '新品牌'},
        ),
      ),
      throwsStateError,
    );
    expect(await db.select(db.syncOutbox).get(), isEmpty);
  });

  test('扩展资料同步未就绪时拒绝写入，不把资料只保存在手机', () async {
    await connect(capability: false);
    final action = proposal({'category': '药品保健'});
    await expectLater(
      actions.executeWithResult(
        action,
        confirmedDescription: await actions.describe(action),
      ),
      throwsStateError,
    );
    expect((await item()).category, '零食饮料');
    expect(await db.select(db.syncOutbox).get(), isEmpty);
  });

  test('离线、家庭归属变化及事务中失去写权限都回滚', () async {
    var online = true;
    await connect(
      guard: () {
        if (!online) throw StateError('只读');
      },
    );
    final action = proposal({'category': '药品保健'});
    final description = await actions.describe(action);
    online = false;
    await expectLater(
      actions.executeWithResult(action, confirmedDescription: description),
      throwsStateError,
    );
    expect((await item()).category, '零食饮料');
    online = true;
    var scope = 'family-a';
    await connect(scopeResolver: () async => scope);
    scope = 'family-b';
    await expectLater(
      repository.updateProductDetails(
        productId,
        ProductDetailsPatch.fromJson({'category': '药品保健'}),
        expectedDetails: ProductDetailsPatch.snapshot(await item()),
      ),
      throwsStateError,
    );
    await connect(
      outbox: _AfterEnqueueOutbox(db, () => online = false),
      guard: () {
        if (!online) throw StateError('只读');
      },
    );
    await expectLater(
      actions.executeWithResult(
        action,
        confirmedDescription: await actions.describe(action),
      ),
      throwsStateError,
    );
    expect((await item()).category, '零食饮料');
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    expect(
      await settings.getValue('sync_category_binding:family-a:$productId'),
      isNull,
    );
  });

  test('出站失败同时回滚物品、分类与绑定', () async {
    await connect(outbox: _FailingOutbox(db));
    final before = (await repository.getProductRecord(productId))!.toJson();
    final action = proposal({'category': '药品保健', 'brand': null});
    await expectLater(
      actions.executeWithResult(
        action,
        confirmedDescription: await actions.describe(action),
      ),
      throwsStateError,
    );
    expect((await repository.getProductRecord(productId))!.toJson(), before);
    expect(await db.select(db.syncOutbox).get(), isEmpty);
    expect(
      await settings.getValue('sync_category_binding:family-a:$productId'),
      isNull,
    );
    expect(
      await settings.getValue(
        'sync_category_identity:family-a:${Uri.encodeComponent('药品保健')}',
      ),
      isNull,
    );
  });
}

class _FailingOutbox extends SyncOutboxRepository {
  _FailingOutbox(super.database);
  @override
  Future<SyncOutboxEntry> enqueueInCurrentTransaction(
    SyncOutboxDraft draft,
  ) async {
    if (draft.entity == 'products') throw StateError('模拟出站失败');
    return super.enqueueInCurrentTransaction(draft);
  }
}

class _AfterEnqueueOutbox extends SyncOutboxRepository {
  _AfterEnqueueOutbox(super.database, this.after);
  final void Function() after;
  @override
  Future<SyncOutboxEntry> enqueueInCurrentTransaction(
    SyncOutboxDraft draft,
  ) async {
    final result = await super.enqueueInCurrentTransaction(draft);
    if (draft.entity == 'products') after();
    return result;
  }
}
