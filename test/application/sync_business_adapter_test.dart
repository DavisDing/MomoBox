import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/sync_business_adapter.dart';
import 'package:momo_box/application/sync_change_control.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/inventory/reminder_rules.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';

const scope = 'family-a';

// Injects an actual pending row after preflight and before the write transaction,
// rather than mocking a deferred exception or a successful business write.
class RacingOutboxRepository extends SyncOutboxRepository {
  RacingOutboxRepository(super.database);

  bool injectPendingCommand = false;

  @override
  Future<T> transaction<T>(Future<T> Function() action) async {
    if (injectPendingCommand) {
      injectPendingCommand = false;
      await enqueue(const SyncOutboxDraft(
        changeId: 'racing-local-command', scopeId: scope,
        operation: SyncOperation.inventoryCommand,
        idempotencyKey: 'racing-local-idempotency-key', requestJson: '{}',
      ));
    }
    return super.transaction(action);
  }
}

class LateSnapshotEditRepository extends SyncOutboxRepository {
  LateSnapshotEditRepository(super.database);
  int checks = 0;

  @override
  Future<bool> hasSnapshotBlockingChanges({required String scopeId}) async {
    checks++;
    if (checks == 4) {
      // Insert a real row during the transaction, after all snapshot rows.
      await enqueueInCurrentTransaction(SyncOutboxDraft(
        changeId: 'late-local-edit', scopeId: scopeId,
        operation: SyncOperation.inventoryCommand,
        idempotencyKey: 'late-local-edit-idempotency', requestJson: '{}',
      ));
    }
    return super.hasSnapshotBlockingChanges(scopeId: scopeId);
  }
}

Map<String, dynamic> snapshot({int version = 1, int quantity = 2}) => {
      // Intentionally opposite to the business dependency order.
      'reminder_settings': [
        {
          'id': 'policy', 'product_id': 'product', 'enabled': true,
          'expiry_warning_days': 30, 'low_stock_threshold': 3,
          'opened_warning_days': null, 'version': version,
        },
      ],
      'shopping_items': [
        {'id': 'shopping', 'name': '牛奶', 'product_id': 'product', 'version': version},
      ],
      'product_batches': [
        {'id': 'batch', 'product_id': 'product', 'quantity': quantity, 'version': version},
      ],
      'products': [
        {'id': 'product', 'name': '牛奶', 'category_id': 'category', 'version': version},
      ],
      'categories': [
        {'id': 'category', 'name': '食品', 'color': null, 'sort_order': 0, 'version': version},
      ],
    };

NasSyncPullChange change(String entity, String id, Map<String, dynamic> payload, {
  int version = 2, bool deleted = false,
}) => NasSyncPullChange(
      changeId: '$entity:$id:$version', cursor: version,
      operation: deleted ? 'entity_delete' : 'entity_upsert',
      entity: entity, entityId: id, version: version, payload: payload,
    );

void main() {
  late AppDatabase database;
  late InventoryRepository inventory;
  late SyncOutboxRepository outbox;
  late SyncBusinessAdapter adapter;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    inventory = InventoryRepository(database, syncScopeId: scope);
    outbox = SyncOutboxRepository(database);
    adapter = SyncBusinessAdapter(
      inventoryRepository: inventory, shoppingRepository: ShoppingRepository(database),
      outboxRepository: outbox, scopeId: scope,
    );
  });
  tearDown(() => database.close());

  Future<void> seedCommandBatches() async {
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '牛奶', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    for (final entry in {'batch-a': 10, 'batch-b': 8}.entries) {
      await inventory.applyRemoteProductBatch(
        batchId: entry.key,
        payload: {'product_id': 'product', 'quantity': entry.value},
        version: 1, updatedAt: DateTime.utc(2026),
      );
    }
    await outbox.ensureState(scopeId: scope);
  }

  NasSyncPullChange inventoryCommand({
    String id = 'command', String command = 'consume_allocated',
    String entityId = 'batch-a',
    int cursor = 21, int version = 7, List<Object?>? allocations,
    Map<String, dynamic> resultFields = const {},
  }) => NasSyncPullChange(
    changeId: id, cursor: cursor, operation: 'inventory_command',
    entity: 'product_batches', entityId: entityId, version: version,
    command: command,
    payload: {
      ...resultFields,
      'command': command, 'operation_id': 'operation-$id',
      'allocations': allocations ?? [
        {'batch_id': 'batch-a', 'quantity': 3, 'before_quantity': 10,
          'final_quantity': 7, 'before_version': 6, 'after_version': version},
        {'batch_id': 'batch-b', 'quantity': 2, 'before_quantity': 8,
          'final_quantity': 6, 'before_version': 2, 'after_version': 3},
      ],
    },
  );

  Future<void> expectCommandUnchanged(String id) async {
    final a = (await inventory.getBatchRecord('batch-a'))!;
    final b = (await inventory.getBatchRecord('batch-b'))!;
    expect([a.remainingQuantity, a.initialQuantity, a.serverVersion], [10, 10, 1]);
    expect([b.remainingQuantity, b.initialQuantity, b.serverVersion], [8, 8, 1]);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: id), isFalse);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect(await database.select(database.stockMovements).get(), isEmpty);
    expect(await outbox.listOutbox(scopeId: scope), isEmpty);
  }

  test('库存、采购及 outbox 必须共享数据库，防止跨库伪原子性', () async {
    final other = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(other.close);
    expect(() => SyncBusinessAdapter(
      inventoryRepository: inventory,
      shoppingRepository: ShoppingRepository(other),
      outboxRepository: outbox,
      scopeId: scope,
    ), throwsArgumentError);
    expect(() => SyncBusinessAdapter(
      inventoryRepository: InventoryRepository(other),
      shoppingRepository: ShoppingRepository(database),
      outboxRepository: outbox,
      scopeId: scope,
    ), throwsArgumentError);
  });

  test('逆序 snapshot 固定按分类、商品、批次、采购、提醒依赖落库', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    final items = await inventory.loadInventory();
    expect(items.single.category, '食品');
    expect(items.single.totalStock, 2);
    expect(items.single.lowStockThreshold, 3);
    expect(ReminderRules.candidates(items).single.type, ReminderType.lowStock);
    expect((await database.select(database.shoppingEntries).get()).single.productId, 'product');
    // The policy is a consumed business overlay, not a product entity version edit.
    expect((await inventory.getProductRecord('product'))!.lowStockThreshold, 1);
  });

  test('同一 snapshot 重复应用不重复数据或生成库存流水', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    expect(await database.select(database.products).get(), hasLength(1));
    expect(await database.select(database.productBatches).get(), hasLength(1));
    expect(await database.select(database.shoppingEntries).get(), hasLength(1));
    expect(await database.select(database.stockMovements).get(), isEmpty);
    expect((await inventory.loadInventory()).single.lowStockThreshold, 3);
  });

  test('snapshot 整体预校验发现非法结构时没有任何写入', () async {
    final invalid = snapshot()..['shopping_items'] = 'not an array';
    await expectLater(adapter.applyRemoteSnapshot(invalid, 10), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('snapshot 重复 ID、未知实体、无效版本都显式失败', () async {
    final duplicate = snapshot();
    (duplicate['products'] as List).add({'id': 'product', 'name': '重复'});
    await expectLater(adapter.applyRemoteSnapshot(duplicate, 10), throwsFormatException);
    await expectLater(adapter.applyRemoteSnapshot({'unknown': []}, 10), throwsFormatException);
    await expectLater(adapter.applyRemoteSnapshot(snapshot(version: -1), 10), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('数据库在批次写入阶段失败会回滚之前分类及商品', () async {
    await database.customStatement('''
      CREATE TRIGGER fail_batch BEFORE INSERT ON product_batches
      BEGIN SELECT RAISE(ABORT, 'injected batch failure'); END
    ''');
    await expectLater(adapter.applyRemoteSnapshot(snapshot(), 10), throwsA(isA<Exception>()));
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
    expect(await database.select(database.shoppingEntries).get(), isEmpty);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('完成标记失败也回滚整个快照', () async {
    await expectLater(adapter.applyRemoteSnapshot(snapshot(), 10, onApplied: () async {
      throw StateError('injected completion failure');
    }), throwsStateError);
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('七天与 enabled=false 快照合法，开封提醒仍拒绝且不部分写入', () async {
    final supported = snapshot();
    final policy = (supported['reminder_settings'] as List).single as Map;
    policy['expiry_warning_days'] = 7;
    policy['enabled'] = false;
    await adapter.applyRemoteSnapshot(supported, 10);
    final record = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'policy',
    );
    expect((record!['payload'] as Map)['expiry_warning_days'], 7);
    expect((record['payload'] as Map)['enabled'], isFalse);
    final unsupported = snapshot(version: 2, quantity: 8);
    ((unsupported['reminder_settings'] as List).single as Map)['opened_warning_days'] = 3;
    await expectLater(adapter.applyRemoteSnapshot(unsupported, 20), throwsFormatException);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 2);
    expect((await inventory.getBatchRecord('batch'))!.serverVersion, 1);
  });

  test('snapshot 未知商品依赖、负数量提前拒绝', () async {
    final unknown = snapshot();
    ((unknown['product_batches'] as List).single as Map)['product_id'] = 'missing';
    await expectLater(adapter.applyRemoteSnapshot(unknown, 10), throwsFormatException);
    await expectLater(adapter.applyRemoteSnapshot(snapshot(quantity: -1), 10), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
  });

  test('较新 snapshot 数量与版本一起权威收敛且不产生流水', () async {
    await adapter.applyRemoteSnapshot(snapshot(quantity: 2), 10);
    await adapter.applyRemoteSnapshot(snapshot(version: 2, quantity: 8), 20);
    final batch = (await inventory.getBatchRecord('batch'))!;
    expect(batch.remainingQuantity, 8);
    expect(batch.serverVersion, 2);
    expect(await database.select(database.stockMovements).get(), isEmpty);
  });

  test('快照等待本地操作，不合并也不制造阻塞推送的新冲突', () async {
    await outbox.enqueue(const SyncOutboxDraft(
      changeId: 'local-product-change', scopeId: scope,
      operation: SyncOperation.entityUpsert, entity: 'products', entityId: 'product',
      idempotencyKey: 'local-product-change-idempotency', requestJson: '{}',
    ));
    await expectLater(adapter.applyRemoteSnapshot(snapshot(), 10), throwsA(isA<SyncRemoteChangeDeferred>()));
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.appSettings).get(), isEmpty);
    expect(await outbox.listOpenConflicts(scopeId: scope), isEmpty);
    expect(await database.select(database.syncOutbox).get(), hasLength(1));
  });

  test('分类增量更名映射字符串；旧版本和重复版本不覆盖', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    await adapter.applyRemoteChange(change('categories', 'category', {'name': '饮品'}));
    expect((await inventory.loadInventory()).single.category, '饮品');
    await adapter.applyRemoteChange(change('categories', 'category', {'name': '不应覆盖'}));
    await adapter.applyRemoteChange(change('categories', 'category', {'name': '旧分类'}, version: 1));
    expect((await inventory.loadInventory()).single.category, '饮品');
    await adapter.applyRemoteChange(change('categories', 'category', {}, version: 3, deleted: true));
    // Deleting the taxonomy never deletes a product or guesses a replacement.
    expect((await inventory.loadInventory()).single.category, '饮品');
  });

  test('未知分类引用不会展示 UUID 或伪造成功', () async {
    await expectLater(adapter.applyRemoteChange(change('products', 'product', {
      'name': '牛奶', 'category_id': 'missing',
    })), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
  });

  test('分类颜色与自定义排序无法映射时显式失败', () async {
    await expectLater(adapter.applyRemoteChange(change('categories', 'category', {
      'name': '食品', 'color': '#ffffff',
    })), throwsFormatException);
    await expectLater(adapter.applyRemoteChange(change('categories', 'category', {
      'name': '食品', 'sort_order': 1,
    })), throwsFormatException);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('提醒增量更新真实低库存阈值；删除恢复商品自身阈值', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    await adapter.applyRemoteChange(change('reminder_settings', 'policy', {'low_stock_threshold': 1}));
    expect((await inventory.loadInventory()).single.isLowStock, isFalse);
    await adapter.applyRemoteChange(change('reminder_settings', 'policy', {'low_stock_threshold': 5}, version: 1));
    expect((await inventory.loadInventory()).single.lowStockThreshold, 1);
    await adapter.applyRemoteChange(change('reminder_settings', 'policy', {}, version: 3, deleted: true));
    expect((await inventory.loadInventory()).single.lowStockThreshold, 1);
    final record = await outbox.getRemoteAuxiliaryEntity(scopeId: scope, entity: 'reminder_settings', entityId: 'policy');
    expect(record!['deleted_at'], isNotNull);
  });

  test('家庭默认阈值与商品覆盖按作用域读取，删除覆盖恢复家庭默认', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    await adapter.applyRemoteChange(change('reminder_settings', 'default', {
      'product_id': null, 'enabled': true, 'expiry_warning_days': 30,
      'low_stock_threshold': 5, 'opened_warning_days': null,
    }));
    expect((await inventory.loadInventory()).single.lowStockThreshold, 3);
    await adapter.applyRemoteChange(change('reminder_settings', 'policy', {}, version: 2, deleted: true));
    expect((await inventory.loadInventory()).single.lowStockThreshold, 5);
    expect((await InventoryRepository(database, syncScopeId: 'other').loadInventory()).single.lowStockThreshold, 1);
  });

  test('七天及关闭增量可应用；非空开封提醒仍拒绝并保留策略', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    await adapter.applyRemoteChange(change('reminder_settings', 'policy', {
      'product_id': 'product', 'enabled': false,
      'expiry_warning_days': 7, 'low_stock_threshold': 3,
    }, version: 2));
    await expectLater(adapter.applyRemoteChange(change('reminder_settings', 'policy', {
      'product_id': 'product', 'enabled': true,
      'expiry_warning_days': 7, 'opened_warning_days': 3,
    }, version: 3)), throwsFormatException);
    final record = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'policy',
    );
    expect(record!['version'], 2);
    expect((record['payload'] as Map)['enabled'], isFalse);
    expect((record['payload'] as Map)['expiry_warning_days'], 7);
  });

  test('version/date 的显式损坏值不静默退回游标或当前时间', () async {
    for (final invalidFields in <Map<String, dynamic>>[
      {'version': '1'}, {'version': null}, {'version': 1.5},
      {'updated_at': 123}, {'updated_at': null}, {'updated_at': 'not-a-date'},
      {'created_at': false}, {'created_at': '2026-02-30T00:00:00Z'},
      {'updated_at': '2026-10-03T25:00:00Z'},
    ]) {
      final invalid = snapshot();
      ((invalid['categories'] as List).single as Map).addAll(invalidFields);
      await expectLater(adapter.applyRemoteSnapshot(invalid, 10), throwsFormatException);
    }
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.appSettings).get(), isEmpty);
  });

  test('同版本商品重复 payload 不重绑分类，后续原分类更名仍能生效', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    await adapter.applyRemoteChange(change('products', 'product', {
      'name': '不应覆盖', 'category_id': 'unknown',
    }, version: 1));
    await adapter.applyRemoteChange(change('categories', 'category', {'name': '饮品'}));
    final product = (await inventory.loadInventory()).single;
    expect(product.name, '牛奶');
    expect(product.category, '饮品');
  });

  test('旧版仅 sync_aux 存档同版本不能伪装为已应用业务设置', () async {
    await inventory.applyRemoteProduct(
      productId: 'product', payload: {'name': '牛奶', 'category': '食品'},
      version: 1, updatedAt: DateTime.utc(2026),
    );
    const policy = <String, dynamic>{
      'product_id': 'product', 'enabled': true, 'expiry_warning_days': 30,
      'low_stock_threshold': 4, 'opened_warning_days': null,
    };
    await outbox.applyRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'policy',
      payload: policy, version: 1, updatedAt: DateTime.utc(2026),
    );
    expect((await inventory.loadInventory()).single.lowStockThreshold, 1);
    await adapter.applyRemoteChange(change('reminder_settings', 'policy', policy, version: 1));
    expect((await inventory.loadInventory()).single.lowStockThreshold, 4);
    final record = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'policy',
    );
    expect(record!['business_applied'], isTrue);
  });


  test('真实 final_quantity 契约采用每批次权威数量和版本，非主批次后续版本仍可应用', () async {
    await seedCommandBatches();
    // Local quantities deliberately differ from the server's before quantities.
    final command = inventoryCommand(allocations: [
      {'batch_id': 'batch-a', 'quantity': 3, 'before_quantity': 7,
        'final_quantity': 4, 'before_version': 6, 'after_version': 7},
      {'batch_id': 'batch-b', 'quantity': 2, 'before_quantity': 8,
        'final_quantity': 6, 'before_version': 2, 'after_version': 3},
    ]);
    await adapter.applyRemoteChange(command);
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 4);
    expect((await inventory.getBatchRecord('batch-a'))!.serverVersion, 7);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 6);
    expect((await inventory.getBatchRecord('batch-b'))!.serverVersion, 3);
    expect((await outbox.listAppliedChanges(scopeId: scope)).single.cursor, 21);
    expect((await outbox.getState(scope))!.pullCursor, 21);

    await adapter.applyRemoteChange(inventoryCommand(id: 'next-b', cursor: 22, version: 4, entityId: 'batch-b',
      allocations: [
        {'batch_id': 'batch-b', 'quantity': 1, 'final_quantity': 5, 'after_version': 4},
      ],
    ));
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 5);
    expect((await inventory.getBatchRecord('batch-b'))!.serverVersion, 4);
    await adapter.applyRemoteChange(command);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 5);
    expect((await outbox.getState(scope))!.pullCursor, 22);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(2));
    expect(await database.select(database.stockMovements).get(), isEmpty);
  });

  test('缺失批次或重复 batch 的整条结果拒绝，不改库存、版本、receipt 或游标', () async {
    await seedCommandBatches();
    for (final invalid in <Map<String, dynamic>>[
      {'batch_id': 'missing', 'quantity': 1, 'final_quantity': 1, 'after_version': 2},
      {'batch_id': 'batch-a', 'quantity': 1, 'final_quantity': 6, 'after_version': 8},
      {'batch_id': ' batch-a ', 'quantity': 1, 'final_quantity': 6, 'after_version': 8},
    ]) {
      await expectLater(adapter.applyRemoteChange(inventoryCommand(allocations: [
        {'batch_id': 'batch-a', 'quantity': 3, 'final_quantity': 7, 'after_version': 7},
        invalid,
      ])), throwsFormatException);
      await expectCommandUnchanged('command');
    }
  });

  test('任一 allocation 缺权威数量或版本、数值非法都拒绝整条命令', () async {
    await seedCommandBatches();
    final valid = <String, dynamic>{
      'batch_id': 'batch-b', 'quantity': 2, 'final_quantity': 6, 'after_version': 3,
    };
    for (final invalid in <Map<String, dynamic>>[
      {...valid}..remove('final_quantity'),
      {...valid}..remove('after_version'),
      {...valid, 'final_quantity': null},
      {...valid, 'after_version': null},
      {...valid, 'final_quantity': -1},
      {...valid, 'after_version': 0},
      {...valid, 'after_version': -1},
      {...valid, 'final_quantity': 6.5},
      {...valid, 'after_version': '3'},
      {...valid, 'after_quantity': 'bad', 'version': 3},
      {...valid, 'after_quantity': null},
      {...valid, 'after_version': null, 'version': 3},
      {...valid, 'after_version': 'bad', 'version': 3},
      {...valid, 'quantity': 0},
      {...valid, 'quantity': -1},
    ]) {
      await expectLater(adapter.applyRemoteChange(inventoryCommand(
        resultFields: {'quantity': 999, 'version': 999},
        allocations: [
          {'batch_id': 'batch-a', 'quantity': 3, 'final_quantity': 7, 'after_version': 7},
          invalid,
        ],
      )), throwsFormatException);
      await expectCommandUnchanged('command');
    }
  });

  test('空 allocation 或非列表/非对象结构拒绝，不写入 receipt 或业务数据', () async {
    await seedCommandBatches();
    for (final invalid in <Object?>[null, 'invalid', {}, [], ['invalid'], [{1: 'invalid'}]]) {
      await expectLater(adapter.applyRemoteChange(NasSyncPullChange(
        changeId: 'command', cursor: 21, operation: 'inventory_command',
        entity: 'product_batches', entityId: 'batch-a', version: 7,
        command: 'consume_allocated', payload: {'allocations': invalid},
      )), throwsFormatException);
      await expectCommandUnchanged('command');
    }
  });

  test('兼容 after_quantity 与 allocation version 别名，权威零数量不会被当作缺失', () async {
    await seedCommandBatches();
    await adapter.applyRemoteChange(inventoryCommand(allocations: [
      {'batch_id': 'batch-a', 'quantity': 10, 'after_quantity': 0, 'version': 7},
      {'batch_id': 'batch-b', 'quantity': 8, 'remaining_quantity': 0, 'after_version': 3},
    ]));
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 0);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 0);
    expect((await inventory.getBatchRecord('batch-a'))!.isDiscarded, isFalse);
    expect((await inventory.getBatchRecord('batch-b'))!.isDiscarded, isFalse);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(1));
  });

  test('多批次第二批次真实写失败后回滚，撤除故障重试成功且回放不重复扣减', () async {
    await seedCommandBatches();
    final command = inventoryCommand();
    await database.customStatement('''
      CREATE TRIGGER fail_second_inventory_command
      BEFORE UPDATE ON product_batches WHEN OLD.id = 'batch-b'
      BEGIN SELECT RAISE(ABORT, 'injected second batch failure'); END
    ''');
    await expectLater(adapter.applyRemoteChange(command), throwsA(predicate<Object>(
      (error) => error.toString().contains('injected second batch failure'),
    )));
    await expectCommandUnchanged('command');
    await database.customStatement('DROP TRIGGER fail_second_inventory_command');
    await adapter.applyRemoteChange(command);
    await adapter.applyRemoteChange(command);
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 7);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 6);
    expect((await inventory.getBatchRecord('batch-b'))!.serverVersion, 3);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(1));
    expect((await outbox.getState(scope))!.pullCursor, 21);
  });

  test('多批次 receipt 写入真实失败时全部回滚，重试和重放不重复扣减', () async {
    await seedCommandBatches();
    final command = inventoryCommand();
    await database.customStatement('''
      CREATE TRIGGER fail_command_receipt BEFORE INSERT ON sync_applied_changes
      BEGIN SELECT RAISE(ABORT, 'injected receipt failure'); END
    ''');
    await expectLater(adapter.applyRemoteChange(command), throwsA(predicate<Object>(
      (error) => error.toString().contains('injected receipt failure'),
    )));
    await expectCommandUnchanged('command');
    await database.customStatement('DROP TRIGGER fail_command_receipt');
    await adapter.applyRemoteChange(command);
    await adapter.applyRemoteChange(command);
    final a = (await inventory.getBatchRecord('batch-a'))!;
    final b = (await inventory.getBatchRecord('batch-b'))!;
    expect([a.remainingQuantity, a.initialQuantity], [7, 10]);
    expect([b.remainingQuantity, b.initialQuantity], [6, 8]);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(1));
    expect((await outbox.getState(scope))!.pullCursor, 21);
  });

  test('真实单批次 restock：游标写失败回滚 receipt 与补充，重试回放不重复增加初始库存', () async {
    await seedCommandBatches();
    final command = inventoryCommand(command: 'restock', allocations: [
      {'batch_id': 'batch-a', 'quantity': 3, 'final_quantity': 13, 'after_version': 7},
    ]);
    await database.customStatement('''
      CREATE TRIGGER fail_command_cursor BEFORE UPDATE ON sync_states
      WHEN NEW.pull_cursor > OLD.pull_cursor
      BEGIN SELECT RAISE(ABORT, 'injected cursor failure'); END
    ''');
    await expectLater(adapter.applyRemoteChange(command), throwsA(predicate<Object>(
      (error) => error.toString().contains('injected cursor failure'),
    )));
    await expectCommandUnchanged('command');
    await database.customStatement('DROP TRIGGER fail_command_cursor');
    await adapter.applyRemoteChange(command);
    await adapter.applyRemoteChange(command);
    final a = (await inventory.getBatchRecord('batch-a'))!;
    expect([a.remainingQuantity, a.initialQuantity, a.serverVersion], [13, 13, 7]);
    final b = (await inventory.getBatchRecord('batch-b'))!;
    expect([b.remainingQuantity, b.initialQuantity, b.serverVersion], [8, 8, 1]);
    expect(await outbox.listAppliedChanges(scopeId: scope), hasLength(1));
    expect((await outbox.getState(scope))!.pullCursor, 21);
  });

  test('依赖 blocked 的库存命令仍需保护，不可绕过冲突检查', () async {
    await seedCommandBatches();
    await outbox.enqueue(const SyncOutboxDraft(
      changeId: 'blocked-local-command', scopeId: scope,
      operation: SyncOperation.inventoryCommand, status: SyncOutboxStatus.blocked,
      idempotencyKey: 'blocked-local-command-key', requestJson: '{}',
    ));
    final command = inventoryCommand();
    await expectLater(adapter.applyRemoteChange(command),
      throwsA(isA<SyncRemoteChangeDeferred>()));
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 10);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 8);
    expect(await outbox.hasAppliedChange(scopeId: scope, changeId: command.changeId), isFalse);
    expect((await outbox.getState(scope))!.pullCursor, 0);
    expect((await outbox.listOpenConflicts(scopeId: scope)).single.outboxChangeId,
      'blocked-local-command');
    expect((await outbox.listOutbox(scopeId: scope)).single.status, SyncOutboxStatus.blocked);
  });

  test('预检后出现本地 pending：事务重检回滚且冲突记录留存、重试不重复冲突', () async {
    await seedCommandBatches();
    final racing = RacingOutboxRepository(database)..injectPendingCommand = true;
    final racingAdapter = SyncBusinessAdapter(
      inventoryRepository: inventory, shoppingRepository: ShoppingRepository(database),
      outboxRepository: racing, scopeId: scope,
    );
    final command = inventoryCommand();
    for (var attempt = 0; attempt < 2; attempt++) {
      await expectLater(racingAdapter.applyRemoteChange(command),
        throwsA(isA<SyncRemoteChangeDeferred>()));
      expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 10);
      expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 8);
      expect(await racing.hasAppliedChange(scopeId: scope, changeId: command.changeId), isFalse);
      expect((await racing.getState(scope))!.pullCursor, 0);
      final conflict = (await racing.listOpenConflicts(scopeId: scope)).single;
      expect(conflict.outboxChangeId, 'racing-local-command');
      expect(conflict.reason, 'REMOTE_INVENTORY_COMMAND_WITH_PENDING_LOCAL_CHANGE');
    }
    // Models a local pending operation being explicitly cancelled/rejected.
    await racing.markRejected(
      changeId: 'racing-local-command',
      errorCode: 'TEST_REJECTED',
      errorMessage: 'test local operation was rejected',
    );
    await racingAdapter.applyRemoteChange(command);
    await racingAdapter.applyRemoteChange(command);
    expect((await inventory.getBatchRecord('batch-a'))!.remainingQuantity, 7);
    expect((await inventory.getBatchRecord('batch-b'))!.remainingQuantity, 6);
    expect(await racing.listAppliedChanges(scopeId: scope), hasLength(1));
  });

  test('提醒快照先处理 tombstone 后处理乱序 replacement upsert', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    final replacement = snapshot(version: 2);
    replacement['reminder_settings'] = [
      {
        'id': 'replacement-policy',
        'product_id': 'product',
        'enabled': true,
        'expiry_warning_days': 30,
        'low_stock_threshold': 5,
        'opened_warning_days': null,
        'version': 2,
      },
      {
        'id': 'policy',
        'product_id': 'product',
        'deleted_at': '2026-10-06T00:00:00Z',
        'version': 2,
      },
    ];

    await adapter.applyRemoteSnapshot(replacement, 20);

    expect((await inventory.loadInventory()).single.lowStockThreshold, 5);
    final oldPolicy = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope,
      entity: 'reminder_settings',
      entityId: 'policy',
    );
    expect(oldPolicy!['deleted_at'], isNotNull);
    final newPolicy = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope,
      entity: 'reminder_settings',
      entityId: 'replacement-policy',
    );
    expect(newPolicy!['business_applied'], isTrue);
    await adapter.applyRemoteSnapshot(replacement, 20);
    expect((await inventory.loadInventory()).single.lowStockThreshold, 5);
  });

  test('提醒 replacement 写失败须回滚先前 tombstone，完成回调不触发且可以重试', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    final replacement = <String, dynamic>{'reminder_settings': [
      {'id': 'replacement-policy', 'product_id': 'product', 'enabled': true,
        'expiry_warning_days': 30, 'low_stock_threshold': 5, 'version': 2},
      {'id': 'policy', 'product_id': 'product', 'version': 2,
        'deleted_at': '2026-10-06T00:00:00Z'},
    ]};
    await database.customStatement('''
      CREATE TRIGGER fail_replacement_policy BEFORE INSERT ON app_settings
      WHEN NEW.key = 'reminder_sync_policy:family-a:replacement-policy'
      BEGIN SELECT RAISE(ABORT, 'injected replacement failure'); END
    ''');
    var completed = false;
    await expectLater(adapter.applyRemoteSnapshot(replacement, 20,
      onApplied: () async { completed = true; },
    ), throwsA(predicate<Object>(
      (error) => error.toString().contains('injected replacement failure'),
    )));
    expect(completed, isFalse);
    expect((await inventory.loadInventory()).single.lowStockThreshold, 3);
    final previous = await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'policy',
    );
    expect(previous!['version'], 1);
    expect(previous['deleted_at'], isNull);
    expect(await outbox.getRemoteAuxiliaryEntity(
      scopeId: scope, entity: 'reminder_settings', entityId: 'replacement-policy',
    ), isNull);
    await database.customStatement('DROP TRIGGER fail_replacement_policy');
    await adapter.applyRemoteSnapshot(replacement, 20,
      onApplied: () async { completed = true; },
    );
    expect(completed, isTrue);
    expect((await inventory.loadInventory()).single.lowStockThreshold, 5);
  });

  test('已删除分类不能被新商品通过历史名称重新绑定', () async {
    await adapter.applyRemoteChange(change('categories', 'category', {'name': '食品'}, version: 1));
    await adapter.applyRemoteChange(change('categories', 'category', {}, deleted: true));
    await expectLater(adapter.applyRemoteChange(change('products', 'new-product', {
      'name': '牛奶', 'category_id': 'category',
    })), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
    final invalid = snapshot();
    ((invalid['categories'] as List).single as Map)['deleted_at'] = '2026-10-03T00:00:00Z';
    await expectLater(adapter.applyRemoteSnapshot(invalid, 10), throwsFormatException);
    expect(await database.select(database.products).get(), isEmpty);
  });

  test('同版本快照矫正数量与 initial_quantity；增量仍不可覆盖数量', () async {
    await adapter.applyRemoteSnapshot(snapshot(quantity: 2), 10);
    await adapter.applyRemoteChange(change('product_batches', 'batch', {
      'product_id': 'product', 'quantity': 90, 'initial_quantity': 90,
    }, version: 1));
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 2);
    final fixed = snapshot(quantity: 8);
    ((fixed['product_batches'] as List).single as Map)['initial_quantity'] = 12;
    await adapter.applyRemoteSnapshot(fixed, 10);
    var batch = (await inventory.getBatchRecord('batch'))!;
    expect([batch.remainingQuantity, batch.initialQuantity, batch.serverVersion], [8, 12, 1]);
    await adapter.applyRemoteSnapshot(fixed, 10);
    await adapter.applyRemoteChange(change('product_batches', 'batch', {
      'product_id': 'product', 'quantity': 99,
    }, version: 2));
    batch = (await inventory.getBatchRecord('batch'))!;
    expect([batch.remainingQuantity, batch.initialQuantity, batch.serverVersion], [8, 12, 2]);
    expect(await database.select(database.stockMovements).get(), isEmpty);
  });

  test('更旧快照不能回退批次版本或库存，即使快照专用模式启用', () async {
    await adapter.applyRemoteSnapshot(snapshot(version: 3, quantity: 8), 30);
    await adapter.applyRemoteSnapshot(snapshot(version: 2, quantity: 2), 20);
    final batch = (await inventory.getBatchRecord('batch'))!;
    expect([batch.remainingQuantity, batch.serverVersion], [8, 3]);
  });

  test('已有批次的快照缺数量也整批拒绝，不仅新批次要求权威数量', () async {
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    final missing = snapshot(version: 2);
    ((missing['product_batches'] as List).single as Map).remove('quantity');
    await expectLater(adapter.applyRemoteSnapshot(missing, 20), throwsFormatException);
    expect((await inventory.getBatchRecord('batch'))!.serverVersion, 1);
  });

  for (final status in [SyncOutboxStatus.pending, SyncOutboxStatus.inFlight,
    SyncOutboxStatus.blocked, SyncOutboxStatus.conflict, SyncOutboxStatus.rejected]) {
    test('scope 任意本地 ${status.name} 操作阻止快照，即使与快照实体不同', () async {
      await outbox.enqueue(SyncOutboxDraft(
        changeId: 'unrelated-local-edit', scopeId: scope,
        operation: SyncOperation.inventoryCommand, status: status,
        idempotencyKey: 'unrelated-local-edit-key', requestJson: '{}',
      ));
      var completed = false;
      await expectLater(adapter.applyRemoteSnapshot(snapshot(), 10,
        onApplied: () async { completed = true; }), throwsA(isA<SyncRemoteChangeDeferred>()));
      expect(completed, isFalse);
      expect(await database.select(database.products).get(), isEmpty);
      expect((await outbox.listOutbox(scopeId: scope)).single.status, status);
    });
  }

  test('未关联 outbox 的 open/deferred 冲突也保护整个 scope', () async {
    final id = await outbox.recordConflict(const SyncConflictDraft(
      scopeId: scope, changeId: 'unresolved-remote', entity: 'products',
      entityId: 'other-product', reason: 'VERSION_CONFLICT',
    ));
    await expectLater(adapter.applyRemoteSnapshot(snapshot(), 10), throwsA(isA<SyncRemoteChangeDeferred>()));
    await outbox.resolveConflict(id: id, status: SyncConflictStatus.deferred);
    await expectLater(adapter.applyRemoteSnapshot(snapshot(), 10), throwsA(isA<SyncRemoteChangeDeferred>()));
    expect(await database.select(database.products).get(), isEmpty);
    await outbox.resolveConflict(id: id, status: SyncConflictStatus.resolved);
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 2);
  });

  test('其他 scope 的操作不阻塞本 scope 的权威快照', () async {
    await outbox.enqueue(const SyncOutboxDraft(
      changeId: 'other-scope-edit', scopeId: 'other-family',
      operation: SyncOperation.inventoryCommand,
      idempotencyKey: 'other-family-idempotency', requestJson: '{}',
    ));
    await adapter.applyRemoteSnapshot(snapshot(), 10);
    expect((await inventory.getBatchRecord('batch'))!.remainingQuantity, 2);
  });

  test('preflight 后事务前到达的 pending 阻止任何写入并保留本地操作', () async {
    final racing = RacingOutboxRepository(database)..injectPendingCommand = true;
    final guarded = SyncBusinessAdapter(
      inventoryRepository: inventory, shoppingRepository: ShoppingRepository(database),
      outboxRepository: racing, scopeId: scope,
    );
    await expectLater(guarded.applyRemoteSnapshot(snapshot(), 10), throwsA(isA<SyncRemoteChangeDeferred>()));
    expect(await database.select(database.products).get(), isEmpty);
    expect((await outbox.listOutbox(scopeId: scope)).single.changeId, 'racing-local-command');
    expect(await outbox.listOpenConflicts(scopeId: scope), isEmpty);
  });

  test('快照写入期间新增本地操作，最终复检回滚全部业务和完成标记', () async {
    final racing = LateSnapshotEditRepository(database);
    final guarded = SyncBusinessAdapter(
      inventoryRepository: inventory, shoppingRepository: ShoppingRepository(database),
      outboxRepository: racing, scopeId: scope,
    );
    var completed = false;
    await expectLater(guarded.applyRemoteSnapshot(snapshot(), 10,
      onApplied: () async { completed = true; }), throwsA(isA<SyncRemoteChangeDeferred>()));
    expect(completed, isFalse);
    expect(await database.select(database.products).get(), isEmpty);
    expect(await database.select(database.productBatches).get(), isEmpty);
    // The injected edit belonged to the rolled-back write transaction too.
    expect(await outbox.listOutbox(scopeId: scope), isEmpty);
  });

}
