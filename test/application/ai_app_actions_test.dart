import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/chore_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/reminder_service.dart';
import 'package:momo_box/application/shopping_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/reminder_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  late AppDatabase db;
  late SettingsRepository settings;
  late InventoryService inventory;
  late ShoppingService shopping;
  late ChoreService chores;
  late ReminderService reminders;
  late AiInventoryActionService actions;
  AiInventoryAction action(Map<String, Object?> data) =>
      AiInventoryAction.parse(jsonEncode({'action': data}))!;
  Future<void> confirm(AiInventoryAction action) async => actions.execute(
    action, confirmedDescription: await actions.describe(action));

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    settings = SettingsRepository(db);
    inventory = InventoryService(InventoryRepository(db));
    shopping = ShoppingService(ShoppingRepository(db));
    chores = ChoreService(settings);
    reminders = ReminderService(ReminderRepository(db));
    actions = AiInventoryActionService(settings, inventory,
      shopping: shopping, chores: chores, reminders: reminders);
  });
  tearDown(() => db.close());

  test('新旧安装可提议，明确关闭仍拒绝；解析/描述/上下文不写业务数据', () async {
    final proposed = action({'kind': 'shopping_add', 'name': '纸巾', 'quantity': 3});
    expect(await actions.proposalsAllowed, isTrue);
    expect(await actions.describe(proposed), contains('增加 3 件'));
    await actions.contextSnapshot();
    expect(await shopping.watchEntries().first, isEmpty);
    expect(await chores.readSavedChores(), isEmpty);
    await settings.setValue(AiInventoryActionService.permissionKey, 'false');
    await expectLater(actions.describe(proposed), throwsStateError);
    expect(await shopping.watchEntries().first, isEmpty);
  });

  test('采购增量合并、完成、恢复与单条删除走真实服务，未入库', () async {
    final proposed = action({'kind': 'shopping_add', 'name': '纸巾', 'quantity': 3});
    await confirm(proposed);
    await confirm(proposed);
    var entry = (await shopping.watchEntries().first).single;
    expect(entry.targetQuantity, 6);
    await confirm(action({'kind': 'shopping_complete', 'id': entry.id, 'completed': true}));
    expect((await shopping.watchEntries().first).single.isCompleted, isTrue);
    await confirm(action({'kind': 'shopping_complete', 'id': entry.id, 'completed': false}));
    entry = (await shopping.watchEntries().first).single;
    expect(entry.isCompleted, isFalse);
    await confirm(action({'kind': 'shopping_delete', 'id': entry.id}));
    expect(await shopping.watchEntries().first, isEmpty);
    expect(await inventory.watchInventory().first, isEmpty);
  });

  test('确认后采购发生变化或用户撤权，旧确认无法写入', () async {
    final proposed = action({'kind': 'shopping_add', 'name': '纸巾', 'quantity': 3});
    final description = await actions.describe(proposed);
    await shopping.addOrMerge(itemName: '纸巾', targetQuantity: 2, reason: '手动添加');
    await expectLater(actions.execute(proposed, confirmedDescription: description), throwsStateError);
    expect((await shopping.watchEntries().first).single.targetQuantity, 2);
    final updated = await actions.describe(proposed);
    await settings.setValue(AiInventoryActionService.permissionKey, 'false');
    await expectLater(actions.execute(proposed, confirmedDescription: updated), throwsStateError);
    expect((await shopping.watchEntries().first).single.targetQuantity, 2);
  });

  for (final kind in ['shopping_add', 'shopping_complete', 'shopping_delete']) {
    test('$kind 确认后仅分类或原因变化也拒绝旧确认', () async {
      await shopping.addOrMerge(itemName: '纸巾', targetQuantity: 2, reason: '手动添加');
      final entry = (await shopping.watchEntries().first).single;
      final proposed = action(kind == 'shopping_add'
          ? {'kind': kind, 'name': '纸巾', 'quantity': 3}
          : {'kind': kind, 'id': entry.id,
              if (kind == 'shopping_complete') 'completed': true});
      for (final field in ['category', 'reason']) {
        final description = await actions.describe(proposed);
        await db.customStatement(
          'UPDATE shopping_entries SET $field = ? WHERE id = ?',
          ['已修改$field', entry.id],
        );
        await expectLater(actions.execute(proposed, confirmedDescription: description), throwsStateError);
        final unchanged = (await shopping.readEntries()).single;
        expect(unchanged.id, entry.id);
        expect(unchanged.targetQuantity, 2);
        expect(unchanged.isCompleted, isFalse);
        expect(field == 'category' ? unchanged.category : unchanged.reason, '已修改$field');
      }
      await confirm(proposed);
      final entries = await shopping.readEntries();
      if (kind == 'shopping_delete') {
        expect(entries, isEmpty);
      } else {
        expect(entries.single.targetQuantity, kind == 'shopping_add' ? 5 : 2);
        expect(entries.single.isCompleted, kind == 'shopping_complete');
        expect(entries.single.category, '已修改category');
        expect(entries.single.reason, '已修改reason');
      }
    });
  }

  test('家务新增、修改、完成、启停、删除有真实结果', () async {
    await confirm(action({'kind': 'chore_add', 'title': '清理冰箱', 'repeatInterval': 'weekly'}));
    var chore = (await chores.readSavedChores()).firstWhere((c) => c.title == '清理冰箱');
    await confirm(action({'kind': 'chore_update', 'id': chore.id, 'title': '整理冰箱', 'repeatInterval': 'monthly', 'notes': '检查保质期'}));
    chore = (await chores.readSavedChores()).firstWhere((c) => c.id == chore.id);
    expect(chore.title, '整理冰箱');
    await confirm(action({'kind': 'chore_complete', 'id': chore.id}));
    expect((await chores.readSavedChores()).firstWhere((c) => c.id == chore.id).lastCompletedDate, isNotNull);
    await confirm(action({'kind': 'chore_toggle', 'id': chore.id, 'enabled': false}));
    expect((await chores.readSavedChores()).firstWhere((c) => c.id == chore.id).isEnabled, isFalse);
    await confirm(action({'kind': 'chore_delete', 'id': chore.id}));
    expect((await chores.readSavedChores()).where((c) => c.id == chore.id), isEmpty);
  });

  test('处理提醒只确认提醒，不改库存；旧提醒不能重复处理', () async {
    final id = await inventory.intake(const IntakeDraft(name: '滤芯', category: '耗材更换', quantity: 1));
    final proposed = action({'kind': 'reminder_acknowledge', 'id': '$id:low-stock'});
    await confirm(proposed);
    expect((await reminders.watchAcknowledgements().first).single.reminderKey, '$id:low-stock');
    expect((await inventory.watchInventory().first).single.totalStock, 1);
    await expectLater(actions.describe(proposed), throwsStateError);
  });

  test('入库和文件/配置操作需走可编辑页面，执行器不接受直接写入', () async {
    for (final proposed in [
      action({'kind': 'intake', 'name': '牛奶', 'quantity': 2}),
      action({'kind': 'open_page', 'page': 'backup'}),
    ]) {
      await expectLater(confirm(proposed), throwsStateError);
    }
    expect(await inventory.watchInventory().first, isEmpty);
  });

  test('删库/SQL/越权字段/无效日期和错误数量拒绝；合规入库保留日期与元数据', () {
    for (final data in <Map<String, Object?>>[
      {'kind': 'drop_database'}, {'kind': 'execute_sql', 'sql': 'DELETE FROM products'},
      {'kind': 'intake', 'name': '牛奶', 'quantity': 2, 'mergeProductId': 'guessed'},
      {'kind': 'intake', 'name': '牛奶', 'quantity': 2, 'expiryDate': '2027-02-31'},
      {'kind': 'intake', 'name': '牛奶', 'quantity': 2, 'shelfLifeAmount': 5},
      {'kind': 'shopping_add', 'name': '纸巾', 'quantity': 0},
      {'kind': 'shopping_add', 'name': '纸巾', 'quantity': '3'},
      {'kind': 'set_theme', 'value': 'unknown'},
      {'kind': 'set_font_scale', 'value': 99},
      {'kind': 'device_control', 'id': 'lock.test', 'command': 'unlock'},
      {'kind': 'device_control', 'id': 'light.test', 'command': 'set_brightness', 'value': -1},
      {'kind': 'open_page', 'page': 'https://untrusted.example'},
    ]) {
      expect(AiInventoryAction.parse(jsonEncode({'action': data})), isNull, reason: '$data');
    }
    final draft = action({'kind': 'intake', 'name': '牛奶', 'quantity': 2,
      'productionDate': '2026-10-21', 'expiryDate': '2026-10-28', 'location': '冰箱'}).intakeDraft;
    expect(draft.expiryDate, DateTime(2026, 10, 28));
    expect(draft.location, '冰箱');
  });
}
