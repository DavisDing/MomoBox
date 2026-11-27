import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/inventory_statistics_service.dart';
import 'package:momo_box/application/shopping_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';

void main() {
  late AppDatabase db;
  late InventoryService inventory;
  late ShoppingService shopping;
  late SettingsRepository settings;
  late AiInventoryActionService actions;
  late _PlanningModel model;
  late AiAssistantService assistant;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final repository = InventoryRepository(db);
    inventory = InventoryService(repository);
    shopping = ShoppingService(ShoppingRepository(db), inventory: repository);
    settings = SettingsRepository(db);
    actions = AiInventoryActionService(settings, inventory, shopping: shopping);
    model = _PlanningModel();
    assistant = AiAssistantService(
      settings,
      repository,
      fallbackExecutor: model,
      actionService: actions,
      statistics: InventoryStatisticsService(db),
    );
  });
  tearDown(() => db.close());

  test('做饭按可用批次和待购量列缺料，仅写入勾选食材', () async {
    final eggs = await inventory.intake(
      const IntakeDraft(name: '鸡蛋', category: '食品生鲜', quantity: 1),
    );
    await inventory.intake(
      IntakeDraft(
        name: '鸡蛋',
        category: '食品生鲜',
        quantity: 10,
        expiryDate: DateTime(2020),
      ),
      mergeProductId: eggs,
    );
    await shopping.addOrMerge(
      itemName: '鸡蛋',
      targetQuantity: 1,
      reason: '手动添加',
    );
    model.output = {
      'meal': {
        'dish': '番茄炒蛋（2 人份）',
        'ingredients': [
          {'name': '鸡蛋', 'productId': eggs, 'amount': '3 个', 'quantity': 3},
          {'name': '番茄', 'amount': '2 个', 'quantity': 2},
          {'name': '油', 'amount': '15 毫升'},
        ],
      },
    };
    final response = await assistant.ask('我想做番茄炒蛋，买些什么？', []);
    final displayed = AiInventoryAction.displayText(response);
    expect(displayed, contains('可用 1 件，缺 2 件，已在采购清单 1 件，还需买 1 件'));
    expect(displayed, contains('油：菜谱需 15 毫升'));
    expect((await shopping.readEntries()).single.targetQuantity, 1);

    final action = AiInventoryAction.parse(response)!;
    final review = await actions.describePurchasePlan(action);
    expect(review.items, ['鸡蛋 × 1 件', '番茄 × 2 件']);
    await actions.executeWithResult(
      action,
      confirmedDescription: review.description,
      purchaseSelection: {0},
    );
    final saved = (await shopping.readEntries()).single;
    expect(saved.itemName, '鸡蛋');
    expect(saved.targetQuantity, 2);
    expect((await inventory.loadInventory()).single.availableQuantity, 1);
    await expectLater(
      actions.executeWithResult(
        action,
        confirmedDescription: review.description,
        purchaseSelection: {0},
      ),
      throwsStateError,
    );
  });

  test('确认后库存变化使旧选择失效，关闭操作建议仍可查看缺料', () async {
    model.output = {
      'meal': {
        'dish': '煮玉米',
        'ingredients': [
          {'name': '玉米', 'amount': '2 根', 'quantity': 2},
        ],
      },
    };
    final action = AiInventoryAction.parse(await assistant.ask('我想煮玉米', []))!;
    final description = await actions.describe(action);
    await inventory.intake(
      const IntakeDraft(name: '玉米', category: '食品生鲜', quantity: 1),
    );
    await expectLater(
      actions.execute(action, confirmedDescription: description),
      throwsStateError,
    );
    expect(await shopping.readEntries(), isEmpty);
    await settings.setValue(AiInventoryActionService.permissionKey, 'false');
    final readOnly = await assistant.ask('现在缺什么？', []);
    expect(AiInventoryAction.displayText(readOnly), contains('缺 1 件'));
    expect(AiInventoryAction.parse(readOnly), isNull);
  });

  test('补货建议使用消耗历史并扣掉已在采购清单的数量', () async {
    final capsules = await inventory.intake(
      const IntakeDraft(name: '咖啡胶囊', category: '粮油调味', quantity: 12),
    );
    await inventory.consume(capsules, 11);
    await shopping.addOrMerge(
      itemName: '咖啡胶囊',
      targetQuantity: 1,
      reason: '手动添加',
      productId: capsules,
    );
    model.output = {'restock': true};
    final response = await assistant.ask('这周该补哪些库存？', []);
    expect(AiInventoryAction.displayText(response), contains('建议买 1 件'));
    expect(AiInventoryAction.displayText(response), contains('近 30 天消耗 11 件'));
    expect(AiInventoryAction.parse(response)?.kind, 'restock_shop');
    expect((await shopping.readEntries()).single.targetQuantity, 1);
  });

  test('助手仅查询用户本轮提供的号码，支持匹配同一 GTIN 的填充形式', () async {
    await inventory.intake(
      const IntakeDraft(
        name: '牛奶',
        category: '食品生鲜',
        quantity: 1,
        barcode: '9506000134352',
      ),
    );
    model.output = {'barcodeLookup': '09506000134352'};
    expect(
      AiInventoryAction.displayText(
        await assistant.ask('条码 09506000134352 是什么？', []),
      ),
      contains('牛奶'),
    );
    expect(
      AiInventoryAction.displayText(await assistant.ask('是什么？', [])),
      contains('写出要查询的完整条码'),
    );
  });

  test('临期使用建议核对真实食材和批次，过滤已过期库存和不明商品', () async {
    final tomatoes = await inventory.intake(
      IntakeDraft(
        name: '番茄',
        category: '食品生鲜',
        quantity: 2,
        batchNo: 'T1',
        expiryDate: DateTime.now().add(const Duration(days: 2)),
      ),
    );
    final expired = await inventory.intake(
      IntakeDraft(
        name: '鸡蛋',
        category: '食品生鲜',
        quantity: 3,
        expiryDate: DateTime(2020),
      ),
    );
    model.output = {
      'expiryUse': {
        'days': 7,
        'ideas': [
          {
            'dish': '凉拌番茄',
            'productIds': [tomatoes],
          },
          {
            'dish': '番茄炒蛋',
            'productIds': [tomatoes, expired],
          },
        ],
      },
    };
    final result = AiInventoryAction.displayText(
      await assistant.ask('临期的东西能做什么？', []),
    );
    expect(result, contains('番茄 · 批号 T1'));
    expect(result, contains('凉拌番茄'));
    expect(result, isNot(contains('番茄炒蛋')));
  });

  test('一次确认多项消耗，失效确认不会执行其他项目', () async {
    final milk = await inventory.intake(
      const IntakeDraft(name: '牛奶', category: '食品生鲜', quantity: 3),
    );
    final detergent = await inventory.intake(
      const IntakeDraft(name: '洗碗块', category: '家居清洁', quantity: 3),
    );
    final action =
        AiInventoryAction.fromJson({
          'kind': 'consume_many',
          'items': [
            {'productId': milk, 'quantity': 1},
            {'productId': detergent, 'quantity': 2},
          ],
        })!;
    final description = await actions.describe(action);
    await inventory.consume(detergent, 1);
    await expectLater(
      actions.execute(action, confirmedDescription: description),
      throwsStateError,
    );
    expect(
      (await inventory.loadInventory())
          .firstWhere((item) => item.id == milk)
          .totalStock,
      3,
    );
    await actions.execute(
      action,
      confirmedDescription: await actions.describe(action),
    );
    final remaining = {
      for (final item in await inventory.loadInventory())
        item.id: item.totalStock,
    };
    expect(remaining, {milk: 2, detergent: 0});
  });

  test('小票批量入库任意一行失败时回滚先前写入', () async {
    await expectLater(
      inventory.intakeBatch([
        (
          draft: const IntakeDraft(name: '牛奶', category: '食品生鲜', quantity: 1),
          mergeProductId: null,
        ),
        (
          draft: const IntakeDraft(name: '纸巾', category: '纸品湿巾', quantity: 0),
          mergeProductId: null,
        ),
      ]),
      throwsArgumentError,
    );
    expect(await inventory.loadInventory(), isEmpty);
  });
}

class _PlanningModel extends AiFallbackExecutor {
  _PlanningModel() : super(backendResolver: () async => null);
  Map<String, Object?> output = {};

  @override
  Future<AiFallbackResponse> execute({
    required String systemPrompt,
    required String userPrompt,
    List<Map<String, String>> chatHistory = const [],
    double temperature = 0.2,
  }) async => AiFallbackResponse(
    content: jsonEncode(output),
    rawDecoded: const {},
    usedLevel: AiApiLevel.primary,
    model: 'test',
    actualProtocol: 'chat',
    traceLogs: const [],
  );
}
