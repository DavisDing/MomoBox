import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/calendar_date_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/domain/inventory/calendar_date.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/application/ai_draft_service.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/domain/models/ai_usage_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/ai_usage_screen.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/widgets/ai_assistant_dialog.dart';
import 'package:momo_box/presentation/widgets/intake_sheet.dart';

import '../support/memory_settings_repository.dart';

class _PendingAssistant implements AiAssistantService {
  final reply = Completer<String>();
  @override
  String createRequestToken() => 'test';
  @override
  Future<String> ask(
    String question,
    List<ChatMessage> history, {
    String? requestToken,
  }) => reply.future;
}

void main() {
  testWidgets('薯片建议自动预填零食分类，确认前不写入，确认后按草稿落库', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final inventory = InventoryService(InventoryRepository(db));
    final store = AiConversationStore(settings);
    await store.load();
    store.current.messages.add(ChatMessage(
      id: 'chips-proposal', role: 'assistant', timestamp: DateTime.now(),
      content: jsonEncode({'action': {
        'kind': 'intake', 'name': '薯片', 'category': '零食饮料', 'quantity': 1,
      }}),
    ));
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db),
      settingsRepositoryProvider.overrideWithValue(settings),
      inventoryServiceProvider.overrideWithValue(inventory),
      aiConversationStoreProvider.overrideWith((ref) => store),
      aiInventoryActionServiceProvider.overrideWithValue(AiInventoryActionService(settings, inventory)),
    ], child: const MaterialApp(home: Scaffold(body: AiAssistantDialog()))));
    Future<void> flush() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }
    await flush();
    expect(find.textContaining('分类：零食饮料'), findsOneWidget);
    await tester.tap(find.text('查看并确认操作'));
    await flush();
    final name = find.byWidgetPredicate((widget) => widget is TextField &&
      widget.decoration?.labelText == '物品名称 *');
    expect(tester.widget<TextField>(name).controller!.text, '薯片');
    final category = tester.widget<DropdownButton<String>>(find.descendant(
      of: find.byType(DropdownButtonFormField<String>),
      matching: find.byType(DropdownButton<String>),
    ));
    expect(category.value, '零食饮料');
    await tester.runAsync(() async => expect(await inventory.watchInventory().first, isEmpty));
    // Opening a proposal locks it against duplicate confirmation routes;
    // that pending marker is not an execution receipt or an inventory write.
    expect(store.actionReceipts['chips-proposal'], '等待确认');
    final scroll = find.descendant(of: find.byType(IntakeSheet), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('确认入库'), 300, scrollable: scroll);
    await tester.tap(find.text('确认入库'));
    await _waitForCommittedIntake(tester, store, 'chips-proposal');
    await tester.runAsync(() async {
      final item = (await inventory.watchInventory().first).single;
      expect(item.name, '薯片');
      expect(item.category, '零食饮料');
      expect(item.totalStock, 1);
      expect(item.brand, isNull);
      expect(item.specification, isNull);
      expect(item.batches.single.expiryDate, isNull);
    });
    expect(store.actionReceipts['chips-proposal'], '已执行');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush();
  });

  testWidgets('AI 入库填入可编辑草稿，取消不写入，修改后确认才入库并保存回执', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final inventory = InventoryService(InventoryRepository(db));
    final store = AiConversationStore(settings);
    await store.load();
    store.current.messages.add(ChatMessage(id: 'intake-proposal', role: 'assistant',
      timestamp: DateTime.now(), content: jsonEncode({'action': {
        'kind': 'intake', 'name': '牛奶', 'category': '食品生鲜',
        'quantity': 2, 'expiryDate': '2027-01-01', 'location': '冰箱',
      }})));
    await tester.pumpWidget(ProviderScope(overrides: [
      databaseProvider.overrideWithValue(db),
      settingsRepositoryProvider.overrideWithValue(settings),
      inventoryServiceProvider.overrideWithValue(inventory),
      aiConversationStoreProvider.overrideWith((ref) => store),
      aiInventoryActionServiceProvider.overrideWithValue(AiInventoryActionService(settings, inventory)),
    ], child: const MaterialApp(home: Scaffold(body: AiAssistantDialog()))));
    Future<void> flush() async {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 200)));
      await tester.pumpAndSettle();
    }
    await flush();
    await tester.tap(find.text('查看并确认操作'));
    await flush();
    expect(find.byType(IntakeSheet), findsOneWidget);
    expect(find.text('牛奶'), findsOneWidget);
    await tester.runAsync(() async => expect(await inventory.watchInventory().first, isEmpty));
    await tester.binding.handlePopRoute();
    await flush();
    expect(store.actionReceipts.containsKey('intake-proposal'), isFalse);
    await tester.tap(find.text('查看并确认操作'));
    await flush();
    final name = find.byWidgetPredicate((widget) => widget is TextField &&
      widget.decoration?.labelText == '物品名称 *');
    await tester.enterText(name, '用户核对后的牛奶');
    final sheetScroll = find.descendant(of: find.byType(IntakeSheet), matching: find.byType(Scrollable)).first;
    await tester.scrollUntilVisible(find.text('确认入库'), 300, scrollable: sheetScroll);
    await tester.tap(find.text('确认入库'));
    await _waitForCommittedIntake(tester, store, 'intake-proposal');
    await tester.runAsync(() async {
      final item = (await inventory.watchInventory().first).single;
      expect(item.name, '用户核对后的牛奶');
      expect(item.totalStock, 2);
      expect(item.location, '冰箱');
      final batch = item.batches.single;
      expect(CalendarDate.encode(batch.expiryDate!), '2027-01-01');
      expect(await CalendarDateRepository(db).read(batch.id), {
        'produced_date': null,
        'expiry_date': '2027-01-01',
      });
    });
    expect(store.actionReceipts['intake-proposal'], '已执行');
    expect(find.text('已按你确认的草稿完成入库。'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await flush();
  });

  testWidgets('关闭并重新打开弹窗保留在途回复和历史，无需新增会话', (tester) async {
    final settings = MemorySettingsRepository();
    settings.values['ai_assistant_context_consent_v2'] = 'true';
    addTearDown(settings.close);
    final assistant = _PendingAssistant();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          aiAssistantServiceProvider.overrideWithValue(assistant),
        ],
        child: MaterialApp(
          home: Builder(
            builder:
                (context) => Scaffold(
                  body: TextButton(
                    onPressed: () => AiAssistantDialog.show(context),
                    child: const Text('打开助手'),
                  ),
                ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('打开助手'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '有哪些库存？');
    await tester.tap(find.byIcon(Icons.send_rounded));
    await tester.pump();
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pump(const Duration(seconds: 1));
    assistant.reply.complete('后台完成的库存回复');
    await tester.pumpAndSettle();
    await tester.tap(find.text('打开助手'));
    await tester.pumpAndSettle();
    expect(find.text('后台完成的库存回复'), findsOneWidget);
    expect(
      settings.values[AiConversationStore.storageKey],
      contains('后台完成的库存回复'),
    );
    expect(tester.takeException(), isNull);
  });

  testWidgets('用量明细分页、每页条数和过滤重置，汇总保持全部记录', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 850));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final logs = List.generate(
      45,
      (i) => AiUsageRecord(
        id: '$i',
        timestamp: DateTime.now(),
        model: 'model-$i',
        endpointType: 'chat',
        promptTokens: 1,
        completionTokens: 2,
        totalTokens: 3,
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          themeNameProvider.overrideWith((ref) => Stream.value('default')),
          aiUsageLogsProvider.overrideWith((ref) => Stream.value(logs)),
        ],
        child: const MaterialApp(home: AiUsageScreen()),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.text('1 / 3'), findsOneWidget);
    expect(find.text('45 次调用'), findsOneWidget);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    expect(find.text('2 / 3'), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-log-20')), findsOneWidget);
    expect(find.byKey(const ValueKey('ai-log-0')), findsNothing);
    await tester.tap(find.byType(DropdownButton<int>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('10 条').last);
    await tester.pumpAndSettle();
    expect(find.text('1 / 5'), findsOneWidget);
    await tester.tap(find.byTooltip('下一页'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('全部'));
    await tester.pumpAndSettle();
    expect(find.text('1 / 5'), findsOneWidget);
    expect(find.text('45 次调用'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('库存建议取消不写入，确认只执行一次并保存回执', (tester) async {
    await tester.binding.setSurfaceSize(const Size(430, 950));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final settings = MemorySettingsRepository();
    settings.values['ai_assistant_context_consent_v2'] = 'true';
    addTearDown(settings.close);
    settings.values[AiInventoryActionService.permissionKey] = 'true';
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final inventory = InventoryService(InventoryRepository(db));
    late String product;
    await tester.runAsync(() async {
      product = await inventory.intake(
        const IntakeDraft(name: '测试牛奶', category: '食品生鲜', quantity: 3),
      );
    });
    final store = AiConversationStore(settings);
    await store.load();
    store.current.messages.add(
      ChatMessage(
        id: 'proposal',
        role: 'assistant',
        timestamp: DateTime.now(),
        content: jsonEncode({
          'action': {'kind': 'consume', 'productId': product, 'quantity': 1},
        }),
      ),
    );
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          aiConversationStoreProvider.overrideWith((ref) => store),
          aiInventoryActionServiceProvider.overrideWithValue(
            AiInventoryActionService(settings, inventory),
          ),
        ],
        child: const MaterialApp(home: Scaffold(body: AiAssistantDialog())),
      ),
    );
    await tester.pumpAndSettle();
    Future<void> openConfirmation() async {
      await tester.tap(find.text('查看并确认操作'));
      await tester.runAsync(
        () async =>
            await Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认操作'), findsOneWidget);
    }

    await openConfirmation();
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect((await inventory.watchInventory().first).single.totalStock, 3);
    });
    await openConfirmation();
    await tester.tap(find.text('确认执行'));
    await tester.runAsync(
      () async => await Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      expect((await inventory.watchInventory().first).single.totalStock, 2);
    });
    expect(store.actionReceipts['proposal'], '已执行');
    expect(
      tester
          .widget<TextButton>(find.widgetWithText(TextButton, '已执行'))
          .onPressed,
      isNull,
    );
    expect(settings.values[AiConversationStore.storageKey], contains('已执行'));
    expect(tester.takeException(), isNull);
  });

  for (final overrideKey in [false, true]) {
    testWidgets('配置列表复制模型可取消，${overrideKey ? '替换' : '继承'}独立密钥并显式调整角色', (tester) async {
      await tester.binding.setSurfaceSize(const Size(390, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      FlutterSecureStorage.setMockInitialValues({
        'ai_api_key_profile_source': 'source-test-secret',
      });
      final settings = MemorySettingsRepository();
      addTearDown(settings.close);
      final source = <String, dynamic>{
        'id': 'source', 'name': '已配置服务', 'endpoint': 'https://configured.example/v1',
        'model': 'configured-model', 'endpointType': 'responses',
        AiDraftService.profileRoleKey: AiDraftService.primaryRole,
      };
      settings.values.addAll({
        AiDraftService.profilesKey: jsonEncode([source]),
        AiDraftService.activeProfileKey: 'source',
        AiDraftService.endpointKey: source['endpoint'] as String,
        AiDraftService.modelKey: source['model'] as String,
        AiDraftService.endpointTypeKey: 'responses',
      });
      await tester.pumpWidget(ProviderScope(overrides: [
        settingsRepositoryProvider.overrideWithValue(settings),
      ], child: const MaterialApp(home: AiSettingsScreen())));
      await tester.pumpAndSettle();
      final before = Map<String, String>.of(settings.values);
      final keysBefore = await const FlutterSecureStorage().readAll();

      await tester.tap(find.byTooltip('编辑配置'));
      await tester.pumpAndSettle();
      expect(find.text('复制为新配置'), findsNothing);
      expect(find.text('测试'), findsOneWidget);
      expect(find.text('取消'), findsOneWidget);
      expect(find.text('确定'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.enterText(find.byType(TextField).at(0), '未保存的修改');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(settings.values, before);
      expect(await const FlutterSecureStorage().readAll(), keysBefore);

      Future<void> openCopy() async {
        await tester.tap(find.byTooltip('配置操作'));
        await tester.pumpAndSettle();
        await tester.tap(find.text('复制配置'));
        await tester.pumpAndSettle();
        expect(find.text('复制 AI 模型服务'), findsOneWidget);
      }

      await openCopy();
      final fields = find.byType(TextField);
      expect(tester.widget<TextField>(fields.at(0)).controller!.text,
          '已配置服务 副本');
      expect(tester.widget<TextField>(fields.at(1)).controller!.text, source['endpoint']);
      expect(tester.widget<TextField>(fields.at(2)).controller!.text, source['model']);
      expect(tester.widget<TextField>(fields.at(3)).controller!.text, isEmpty);
      final selectors = find.byType(DropdownButtonFormField<String>);
      expect(tester.widget<DropdownButtonFormField<String>>(selectors.first).initialValue,
          AiDraftService.standbyRole);
      expect(tester.widget<DropdownButtonFormField<String>>(selectors.last).initialValue, 'responses');
      expect(settings.values, before);
      expect(await const FlutterSecureStorage().readAll(), keysBefore);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(settings.values, before);
      expect(await const FlutterSecureStorage().readAll(), keysBefore);

      await openCopy();
      await tester.enterText(find.byType(TextField).at(0), '复制的副服务');
      if (overrideKey) {
        await tester.enterText(find.byType(TextField).at(3), 'copy-test-secret');
      }
      await tester.tap(find.byType(DropdownButtonFormField<String>).first);
      await tester.pumpAndSettle();
      await tester.tap(find.text('副服务（主服务失败时调用）').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();

      final profiles = (jsonDecode(settings.values[AiDraftService.profilesKey]!) as List)
          .cast<Map<String, dynamic>>();
      expect(profiles, hasLength(2));
      expect(profiles.singleWhere((profile) => profile['id'] == 'source'), source);
      final copy = profiles.singleWhere((profile) => profile['id'] != 'source');
      expect(copy['name'], '复制的副服务');
      expect(copy['endpoint'], source['endpoint']);
      expect(copy['model'], source['model']);
      expect(copy['endpointType'], 'responses');
      expect(copy[AiDraftService.profileRoleKey], AiDraftService.secondaryRole);
      expect(settings.values[AiDraftService.activeProfileKey], 'source');
      expect(settings.values[AiDraftService.secondaryProfileIdKey], copy['id']);
      final keys = await const FlutterSecureStorage().readAll();
      expect(keys['ai_api_key_profile_source'], 'source-test-secret');
      expect(keys['ai_api_key_profile_${copy['id']}'],
          overrideKey ? 'copy-test-secret' : 'source-test-secret');
      expect(settings.values.values.any((value) => value.contains('test-secret')), isFalse);
      expect(copy.containsKey('_apiKeyDraft'), isFalse);
      expect(copy.containsKey('apiKey'), isFalse);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('新增配置测试仅请求草稿服务，不保存配置或密钥', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final settings = MemorySettingsRepository();
    settings.values['ai_assistant_context_consent_v2'] = 'true';
    addTearDown(settings.close);
    final requests = <http.Request>[];
    final executor = AiFallbackExecutor(
      client: MockClient((request) async {
        requests.add(request);
        return http.Response(
          jsonEncode({
            'choices': [
              {
                'message': {'content': 'OK'},
              },
            ],
          }),
          200,
        );
      }),
    );
    addTearDown(executor.close);
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          aiConnectionTestExecutorProvider.overrideWithValue(executor),
        ],
        child: const MaterialApp(home: AiSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final before = Map<String, String>.of(settings.values);
    await tester.tap(find.text('添加配置'));
    await tester.pumpAndSettle();
    final fields = find.byType(TextField);
    await tester.enterText(fields.at(1), 'https://draft.example/v1');
    await tester.enterText(fields.at(2), 'draft-model');
    await tester.enterText(fields.at(3), 'secret-test-key');
    await tester.tap(find.text('测试'));
    await tester.pumpAndSettle();
    expect(requests, hasLength(1));
    expect(requests.single.url.host, 'draft.example');
    expect(jsonDecode(requests.single.body)['model'], 'draft-model');
    expect(requests.single.headers['Authorization'], 'Bearer secret-test-key');
    expect(find.textContaining('测试通过'), findsOneWidget);
    expect(settings.values, before);
    expect(await const FlutterSecureStorage().readAll(), isEmpty);
    expect(tester.takeException(), isNull);
  });
}

Future<void> _waitForCommittedIntake(
  WidgetTester tester,
  AiConversationStore store,
  String proposalId,
) async {
  // SQLite uses real asynchronous work. pumpAndSettle only advances the fake
  // widget clock and can spin forever on the saving indicator before IO ends.
  for (var attempt = 0; attempt < 100; attempt++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 50)));
    await tester.pump(const Duration(milliseconds: 50));
    if (store.actionReceipts[proposalId] == '已执行' &&
        find.byType(IntakeSheet).evaluate().isEmpty) {
      await tester.pumpAndSettle();
      return;
    }
  }
  // Keep failures actionable; never treat a pending proposal as successful.
  expect(store.actionReceipts[proposalId], '已执行', reason: '入库必须完成真实写入并保存成功回执');
  expect(find.byType(IntakeSheet), findsNothing, reason: '保存完成后应关闭入库草稿');
}
