import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/domain/backup/backup_format.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

const original = SyncWorkspaceIdentity(endpoint: 'https://nas.example/api/v1', userId: 'user-a', familyId: 'family-a');

void main() {
  late AppDatabase database;
  late SyncWorkspaceRepository workspace;
  late SettingsRepository settings;
  late SyncOutboxRepository outbox;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    workspace = SyncWorkspaceRepository(database);
    settings = SettingsRepository(database);
    outbox = SyncOutboxRepository(database);
  });
  tearDown(() => database.close());

  Future<void> bind() => workspace.bind(original, isCurrent: () => true);

  test('空库不会自动绑定；单机仍能修改库存', () async {
    expect((await workspace.inspect(original)).status, SyncWorkspaceStatus.unbound);
    final inventory = InventoryRepository(database, outbox: outbox, syncScopeResolver: workspace.localMutationScope);
    await inventory.createProductWithBatch(const IntakeDraft(name: '米', category: '食品', quantity: 3, lowStockThreshold: 1));
    expect((await inventory.loadInventory()).single.totalStock, 3);
    expect(await workspace.readOwner(), isNull);
    expect(await database.select(database.syncOutbox).get(), isEmpty);
  });

  test('显式绑定可重复，业务数据及旧同步现场保持不变', () async {
    await outbox.ensureState(scopeId: original.familyId);
    final before = await database.select(database.syncStates).get();
    expect((await workspace.inspect(original)).status, SyncWorkspaceStatus.legacyReview);
    await bind();
    await bind();
    expect((await workspace.inspect(original)).canSync, isTrue);
    expect(await database.select(database.syncStates).get(), before);
    expect((await workspace.inspect(null)).owner!.familyId, original.familyId);
    expect((await workspace.inspect(null)).canSync, isFalse);
  });

  test('NAS scheme、host、port、path、账号、家庭任意变化暂停且不改绑', () async {
    await bind();
    for (final identity in [
      const SyncWorkspaceIdentity(endpoint: 'http://nas.example/api/v1', userId: 'user-a', familyId: 'family-a'),
      const SyncWorkspaceIdentity(endpoint: 'https://other.example/api/v1', userId: 'user-a', familyId: 'family-a'),
      const SyncWorkspaceIdentity(endpoint: 'https://nas.example:444/api/v1', userId: 'user-a', familyId: 'family-a'),
      const SyncWorkspaceIdentity(endpoint: 'https://nas.example/other/api/v1', userId: 'user-a', familyId: 'family-a'),
      const SyncWorkspaceIdentity(endpoint: 'https://nas.example/api/v1', userId: 'user-b', familyId: 'family-a'),
      const SyncWorkspaceIdentity(endpoint: 'https://nas.example/api/v1', userId: 'user-a', familyId: 'family-b'),
    ]) {
      expect((await workspace.inspect(identity)).status, SyncWorkspaceStatus.mismatch);
      await expectLater(workspace.bind(identity, isCurrent: () => true), throwsStateError);
      expect((await workspace.readOwner())!.matches(original), isTrue);
    }
    expect((await workspace.inspect(original)).canSync, isTrue);
  });

  test('另一个家庭旧现场不能因当前登录身份而被接管', () async {
    await outbox.ensureState(scopeId: 'other-family');
    expect((await workspace.inspect(original)).status, SyncWorkspaceStatus.blocked);
    await expectLater(bind(), throwsStateError);
    expect(await workspace.readOwner(), isNull);
  });

  test('旧版单scope离线操作保留原家庭，不采用当前账号家庭', () async {
    await outbox.ensureState(scopeId: 'old-family');
    final shopping = ShoppingRepository(database, outbox: outbox, syncScopeId: 'new-family',
        syncScopeResolver: workspace.localMutationScope);
    await shopping.addOrMerge(itemName: '牛奶', targetQuantity: 2, reason: '离线');
    final pending = await database.select(database.syncOutbox).get();
    expect(pending.single.scopeId, 'old-family');
    expect((await workspace.inspect(original)).canSync, isFalse);
  });

  test('多家庭旧现场的未定归属操作回滚，不影响已存库存与游标', () async {
    await outbox.ensureState(scopeId: 'old-a');
    await outbox.ensureState(scopeId: 'old-b');
    final shopping = ShoppingRepository(database, outbox: outbox, syncScopeResolver: workspace.localMutationScope);
    await expectLater(shopping.addOrMerge(itemName: '不能猜归属', targetQuantity: 1, reason: '测试'), throwsStateError);
    expect(await database.select(database.shoppingEntries).get(), isEmpty);
    expect(await database.select(database.syncOutbox).get(), isEmpty);
    expect((await database.select(database.syncStates).get()).length, 2);
  });

  test('绑定损坏或未知版本失败关闭，不清除现场', () async {
    for (final value in ['broken json', '{}', jsonEncode({'version': 2}),
      jsonEncode({'version': 1, 'endpoint': '', 'user_id': 'a', 'family_id': 'b'})]) {
      await settings.setValue(syncWorkspaceBindingKey, value);
      expect((await workspace.inspect(original)).status, SyncWorkspaceStatus.blocked);
      await expectLater(bind(), throwsStateError);
      expect(await settings.getValue(syncWorkspaceBindingKey), value);
      await expectLater(workspace.localMutationScope(), throwsFormatException);
    }
  });

  test('确认过程中身份改变回滚归属写入', () async {
    var calls = 0;
    await expectLater(workspace.bind(original, isCurrent: () => ++calls == 1), throwsStateError);
    expect(await workspace.readOwner(), isNull);
  });

  test('并发不同身份确认只能成功一个，不覆盖所有者', () async {
    const other = SyncWorkspaceIdentity(endpoint: 'https://other.example/api/v1', userId: 'b', familyId: 'family-b');
    final results = await Future.wait([
      workspace.bind(original, isCurrent: () => true).then((_) => true, onError: (_) => false),
      workspace.bind(other, isCurrent: () => true).then((_) => true, onError: (_) => false),
    ]);
    expect(results.where((ok) => ok).length, 1);
    expect(await workspace.readOwner(), isNotNull);
  });

  test('持有旧Repository及离线修改始终原归属入队，重启仍保留', () async {
    final held = ShoppingRepository(database, outbox: outbox, syncScopeId: 'wrong-family',
        syncScopeResolver: workspace.localMutationScope);
    await bind();
    await held.addOrMerge(itemName: '离线采购', targetQuantity: 2, reason: '暂停同步');
    expect((await database.select(database.syncOutbox).get()).single.scopeId, original.familyId);
    expect(await SyncWorkspaceRepository(database).localMutationScope(), original.familyId);
  });

  test('库存及库存命令离线同事务入原家庭队列，损坏归属不留下部分写入', () async {
    final held = InventoryRepository(database, outbox: outbox, syncScopeId: 'wrong-family',
        syncScopeResolver: workspace.localMutationScope);
    await bind();
    await held.createProductWithBatch(const IntakeDraft(name: '纸巾', category: '日用品', quantity: 3, lowStockThreshold: 1));
    final batch = (await database.select(database.productBatches).get()).single;
    await held.consumeBatch(batch.productId, batch.id, 1);
    expect((await database.select(database.syncOutbox).get()).map((row) => row.scopeId).toSet(), {'family-a'});
    expect((await database.select(database.productBatches).get()).single.remainingQuantity, 2);
    final before = await database.select(database.syncOutbox).get();
    await settings.setValue(syncWorkspaceBindingKey, 'corrupt');
    await expectLater(held.consumeBatch(batch.productId, batch.id, 1), throwsFormatException);
    expect((await database.select(database.productBatches).get()).single.remainingQuantity, 2);
    expect(await database.select(database.syncOutbox).get(), before);
  });

  test('工作区绑定不进入可移植JSON备份', () {
    expect(BackupFormat.isPortableSetting(syncWorkspaceBindingKey), isFalse);
  });
}
