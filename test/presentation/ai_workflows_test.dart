import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:momo_box/application/ai_inventory_action_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/domain/models/ai_usage_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/ai_usage_screen.dart';
import 'package:momo_box/presentation/screens/settings_screen.dart';
import 'package:momo_box/presentation/widgets/ai_assistant_dialog.dart';

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
  testWidgets('关闭并重新打开弹窗保留在途回复和历史，无需新增会话', (tester) async {
    final settings = MemorySettingsRepository();
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
      await tester.tap(find.text('查看并确认库存操作'));
      await tester.runAsync(
        () async =>
            await Future<void>.delayed(const Duration(milliseconds: 100)),
      );
      await tester.pumpAndSettle();
      expect(find.text('确认库存变更'), findsOneWidget);
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

  testWidgets('新增配置测试仅请求草稿服务，不保存配置或密钥', (tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    final settings = MemorySettingsRepository();
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
