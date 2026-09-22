import 'dart:convert';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  test('模型只能提议白名单动作和正整数数量', () {
    String envelope(Map<String, Object?> action) =>
        jsonEncode({'reply': '待确认', 'action': action});
    final data = <String, Object?>{
      'kind': 'consume',
      'productId': 'p',
      'quantity': 2,
    };
    expect(AiInventoryAction.parse(envelope(data))?.quantity, 2);
    for (final quantity in [0, -1, 1.5, '2', 1000001, null]) {
      expect(
        AiInventoryAction.parse(envelope({...data, 'quantity': quantity})),
        isNull,
      );
    }
    expect(
      AiInventoryAction.parse(envelope({...data, 'kind': 'execute_sql'})),
      isNull,
    );
    expect(
      AiInventoryAction.parse(envelope({...data, 'kind': 'discard'})),
      isNull,
    );
    expect(AiInventoryAction.displayText(envelope(data)), contains('尚未执行'));
  });

  test('报废确认后数量变化拒绝执行，事务校验不删除新补充的库存', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = SettingsRepository(db);
    final inventory = InventoryService(InventoryRepository(db));
    final actions = AiInventoryActionService(settings, inventory);
    await settings.setValue(AiInventoryActionService.permissionKey, 'true');
    final id = await inventory.intake(
      const IntakeDraft(name: '牛奶', category: '食品生鲜', quantity: 3),
    );
    final batch =
        (await inventory.watchInventory().first).single.batches.single;
    final action = AiInventoryAction(
      kind: 'discard',
      productId: id,
      batchId: batch.id,
    );
    final description = await actions.describe(action);
    await inventory.replenishBatch(batch.id, 2);
    await expectLater(
      actions.execute(action, confirmedDescription: description),
      throwsStateError,
    );
    await expectLater(
      inventory.discardBatch(batch.id, expectedRemainingQuantity: 3),
      throwsStateError,
    );
    expect((await inventory.watchInventory().first).single.totalStock, 5);
  });

  test('默认拒绝写入；授权后复用库存事务；撤权、错误批次及超量均拒绝', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final settings = SettingsRepository(db);
    final inventory = InventoryService(InventoryRepository(db));
    final actions = AiInventoryActionService(settings, inventory);
    final id = await inventory.intake(
      const IntakeDraft(name: '牛奶', category: '食品生鲜', quantity: 3),
    );
    final consume = AiInventoryAction(
      kind: 'consume',
      productId: id,
      quantity: 1,
    );
    await expectLater(actions.execute(consume), throwsStateError);
    expect((await inventory.watchInventory().first).single.totalStock, 3);
    await settings.setValue(AiInventoryActionService.permissionKey, 'true');
    expect(await actions.describe(consume), contains('牛奶'));
    expect((await inventory.watchInventory().first).single.totalStock, 3);
    await actions.execute(consume);
    expect((await inventory.watchInventory().first).single.totalStock, 2);
    await expectLater(
      actions.execute(
        AiInventoryAction(kind: 'consume', productId: id, quantity: 99),
      ),
      throwsStateError,
    );
    await expectLater(
      actions.execute(
        AiInventoryAction(
          kind: 'replenish',
          productId: id,
          batchId: 'wrong',
          quantity: 1,
        ),
      ),
      throwsStateError,
    );
    final batch =
        (await inventory.watchInventory().first).single.batches.single;
    await actions.execute(
      AiInventoryAction(
        kind: 'replenish',
        productId: id,
        batchId: batch.id,
        quantity: 2,
      ),
    );
    expect((await inventory.watchInventory().first).single.totalStock, 4);
    await settings.setValue(AiInventoryActionService.permissionKey, 'false');
    await expectLater(actions.execute(consume), throwsStateError);
    await settings.setValue(AiInventoryActionService.permissionKey, 'true');
    await actions.execute(
      AiInventoryAction(kind: 'discard', productId: id, batchId: batch.id),
    );
    expect((await inventory.watchInventory().first).single.totalStock, 0);
    await expectLater(
      actions.execute(
        AiInventoryAction(
          kind: 'replenish',
          productId: id,
          batchId: batch.id,
          quantity: 2,
        ),
      ),
      throwsStateError,
    );
  });
}
