import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/assistant_screen.dart';

import '../support/memory_settings_repository.dart';

void main() {
  testWidgets('助手修改资料显示真实差异，取消不改，确认后保存且不能重复提交', (tester) async {
    final fixture = await _Fixture.create(tester);
    final id = await fixture.inventory.intake(
      const IntakeDraft(
        name: '急支糖浆',
        category: '零食饮料',
        quantity: 2,
        brand: '原品牌',
        specification: '100ml',
        location: '餐边柜',
      ),
    );
    await fixture.pump(tester, {
      'kind': 'product_update',
      'productId': id,
      'category': '药品保健',
      'brand': '新品牌',
      'specification': '120ml',
      'location': '药箱',
    });
    await tester.tap(find.text('查看并确认操作'));
    await _flush(tester);
    expect(find.text('确认修改物品资料'), findsOneWidget);
    expect(find.textContaining('分类：零食饮料 → 药品保健'), findsOneWidget);
    expect(find.textContaining('品牌：原品牌 → 新品牌'), findsOneWidget);
    expect(find.textContaining('规格：100ml → 120ml'), findsOneWidget);
    expect(find.textContaining('存放位置：餐边柜 → 药箱'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await _flush(tester);
    await tester.runAsync(() async {
      expect(
        (await fixture.inventory.watchInventory().first).single.category,
        '零食饮料',
      );
    });
    expect(fixture.store.actionReceipts, isEmpty);
    await tester.tap(find.text('查看并确认操作'));
    await _flush(tester);
    await tester.tap(find.text('确认执行'));
    await _flush(tester);
    await tester.runAsync(() async {
      final item = (await fixture.inventory.watchInventory().first).single;
      expect(
        [item.category, item.brand, item.specification, item.location],
        ['药品保健', '新品牌', '120ml', '药箱'],
      );
      expect(item.totalStock, 2);
    });
    expect(fixture.store.actionReceipts['proposal'], '已执行');
    expect(
      fixture.store.current.messages.last.content,
      contains('已更新「急支糖浆」的资料'),
    );
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '已执行'))
          .onPressed,
      isNull,
    );
    expect(
      fixture.settings.values[AiConversationStore.storageKey],
      contains('已更新'),
    );
    expect(tester.takeException(), isNull);
  });

  for (final pending in [false, true]) {
    testWidgets('设备${pending ? '状态待核实' : '已开启'}写回会话，不能复用操作前off或重复提交', (
      tester,
    ) async {
      final fixture = await _Fixture.create(tester);
      var commands = 0;
      fixture.actions = AiInventoryActionService(
        fixture.settings,
        fixture.inventory,
        describeDevice: (_) async => '打开「床头灯」。\n操作前状态：已关闭（off）。',
        executeDevice: (_) async {
          commands++;
          if (pending) throw StateError('指令已接受，设备尚未确认目标状态，请核实后再操作。');
          return '已打开「床头灯」。\n设备反馈：已开启（on）。';
        },
      );
      await fixture.pump(tester, {
        'kind': 'device_control',
        'id': 'ha::light.bedside',
        'command': 'turn_on',
      });
      await tester.tap(find.text('查看并确认操作'));
      await _flush(tester);
      expect(find.text('确认控制设备'), findsOneWidget);
      expect(commands, 0);
      await tester.tap(find.text('确认执行'));
      await _flush(tester);
      expect(commands, 1);
      final completion = fixture.store.current.messages.last.content;
      expect(completion, isNot(contains('off')));
      expect(completion, isNot(contains('操作前状态')));
      expect(completion, contains(pending ? '设备尚未确认目标状态' : '设备反馈：已开启（on）'));
      if (pending) {
        expect(completion, isNot(contains('已打开')));
        expect(fixture.store.actionReceipts['proposal'], contains('执行结果未确认'));
        expect(
          fixture.settings.values[AiConversationStore.storageKey],
          contains('设备尚未确认目标状态'),
        );
      } else {
        expect(fixture.store.actionReceipts['proposal'], '已执行');
      }
      expect(find.text('查看并确认操作'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }
}

Future<void> _flush(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 100)),
  );
  await tester.pumpAndSettle();
}

class _Fixture {
  _Fixture(this.db, this.settings, this.inventory, this.store)
    : actions = AiInventoryActionService(settings, inventory);
  final AppDatabase db;
  final MemorySettingsRepository settings;
  final InventoryService inventory;
  final AiConversationStore store;
  AiInventoryActionService actions;

  static Future<_Fixture> create(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = MemorySettingsRepository();
    final store = AiConversationStore(settings);
    await store.load();
    addTearDown(() => tester.runAsync(db.close));
    addTearDown(settings.close);
    addTearDown(() async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpAndSettle();
    });
    return _Fixture(
      db,
      settings,
      InventoryService(InventoryRepository(db)),
      store,
    );
  }

  Future<void> pump(WidgetTester tester, Map<String, Object?> action) async {
    store.current.messages.clear();
    store.current.messages.add(
      ChatMessage(
        id: 'proposal',
        role: 'assistant',
        content: jsonEncode({'reply': '尚未执行', 'action': action}),
        timestamp: DateTime.now(),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          nasAppAccessProvider.overrideWithValue(NasAppAccess.connected),
          legacyClientCleanupProvider.overrideWith((ref) async {}),
          selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
          aiConfigurationStatusProvider.overrideWith(
            (ref) => Stream.value(false),
          ),
          aiInventoryPermissionProvider.overrideWith(
            (ref) => Stream.value(true),
          ),
          databaseProvider.overrideWithValue(db),
          settingsRepositoryProvider.overrideWithValue(settings),
          inventoryServiceProvider.overrideWithValue(inventory),
          aiConversationStoreProvider.overrideWith((ref) => store),
          aiInventoryActionServiceProvider.overrideWithValue(actions),
        ],
        child: const MaterialApp(home: AssistantScreen()),
      ),
    );
    await _flush(tester);
  }
}
