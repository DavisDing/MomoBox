import '../support/memory_settings_repository.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/data/repositories/mock_smart_home_repository.dart';
import 'package:momo_box/domain/models/smart_home_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/home_assistant_settings_screen.dart';
import 'package:momo_box/presentation/screens/nas_settings_screen.dart';
import 'package:momo_box/presentation/widgets/ai_assistant_dialog.dart';

void main() {
  testWidgets('洗衣液问题走真实服务入口，不再返回固定的两瓶库存', (tester) async {
    final service = _ControlledAssistant();
    await _pumpAssistant(tester, service);
    await _ask(tester, '还有多少洗衣液？');
    expect(service.questions, ['还有多少洗衣液？']);
    service.reply.complete('真实库存为 7 瓶');
    await tester.pumpAndSettle();
    expect(find.text('真实库存为 7 瓶'), findsOneWidget);
    expect(find.textContaining('批次 20260810'), findsNothing);
  });

  testWidgets('设备、消耗和混合计划请求明确未执行', (tester) async {
    final service = _ControlledAssistant();
    await _pumpAssistant(tester, service);
    for (final question in ['打开电视', '吃了两片感冒药', '我要洗衣服']) {
      await _ask(tester, question);
      await tester.pumpAndSettle();
    }
    expect(service.questions, isEmpty);
    expect(find.textContaining('未扣减库存或写入记录'), findsOneWidget);
    expect(find.textContaining('未发送设备指令，也未扣减耗材'), findsWidgets);
    expect(find.textContaining('变动记录已写入'), findsNothing);
    expect(find.textContaining('计划执行完成'), findsNothing);
  });

  for (final fail in [false, true]) {
    testWidgets('切换会话后，${fail ? '错误' : '回复'}仍归属原会话', (tester) async {
      final service = _ControlledAssistant();
      await _pumpAssistant(tester, service);
      await _ask(tester, '查询原会话库存');
      final historyBefore = service.histories.single.toList();
      await tester.tap(find.byTooltip('新建会话'));
      await tester.pump();
      if (fail) {
        service.reply.completeError(StateError('401 secret-must-not-be-shown'));
      } else {
        service.reply.complete('原会话的真实回复');
      }
      await tester.pumpAndSettle();
      final reply = fail ? find.textContaining('本次请求失败') : find.text('原会话的真实回复');
      expect(reply, findsNothing);
      expect(service.histories.single, historyBefore);
      await tester.tap(find.byTooltip('历史会话'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查询原会话库存'));
      await tester.pumpAndSettle();
      expect(reply, findsOneWidget);
      expect(find.textContaining('secret-must-not-be-shown'), findsNothing);
      expect(find.textContaining('当前已作为本地智能指令处理'), findsNothing);
    });
  }

  for (final clearLast in [false, true]) {
    testWidgets('${clearLast ? '清空最后一个' : '删除原'}会话后丢弃在途回复', (tester) async {
      final service = _ControlledAssistant();
      await _pumpAssistant(tester, service);
      await _ask(tester, '待删除请求');
      if (!clearLast) {
        await tester.tap(find.byTooltip('新建会话'));
        await tester.pump();
      }
      await tester.tap(find.byTooltip('历史会话'));
      // Start the sheet transition, then advance it without waiting for the
      // still-pending request's continuously animating spinner to settle.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      final historyList = find.descendant(
        of: find.byType(BottomSheet),
        matching: find.byType(ListView),
      );
      expect(historyList, findsOneWidget);
      final sessionTitle = find.descendant(
        of: historyList,
        matching: find.text('待删除请求'),
      );
      final row = find.ancestor(of: sessionTitle, matching: find.byType(Row)).first;
      final deleteBtn = find.descendant(of: row, matching: find.byIcon(Icons.delete_outline));
      // scrollUntilVisible requires the ListView's inner Scrollable, not the
      // ListView itself. Scope it to the sheet instead of the chat viewport.
      await tester.scrollUntilVisible(
        deleteBtn,
        200,
        scrollable: find.descendant(
          of: historyList,
          matching: find.byType(Scrollable),
        ),
      );
      expect(deleteBtn.hitTestable(), findsOneWidget);
      await tester.tap(deleteBtn);
      await tester.pump();
      if (clearLast) {
        expect(find.text('新对话'), findsOneWidget);
      }
      service.reply.complete('不应该出现的旧回复');
      await tester.pumpAndSettle();
      expect(find.text('不应该出现的旧回复'), findsNothing);
      // Close the history sheet by selecting the only remaining session.
      await tester.tap(find.descendant(
        of: historyList,
        matching: find.text(clearLast ? '新对话' : '新会话 2'),
      ));
      await tester.pumpAndSettle();
      if (clearLast) {
        // The composer sits behind the history route. Verify it only after the
        // sheet closes, when the reset dialog is active and has rebuilt.
        final sendButton = tester.widget<IconButton>(
          find.widgetWithIcon(IconButton, Icons.send_rounded),
        );
        expect(sendButton.onPressed, isNotNull);
      }
      expect(find.text('不应该出现的旧回复'), findsNothing);
      expect(tester.takeException(), isNull);
    });
  }

  for (final timeout in [false, true]) {
    testWidgets('${timeout ? '超时' : '未配置服务'}不会伪装成本地处理成功', (tester) async {
      final service = _ControlledAssistant();
      await _pumpAssistant(tester, service);
      await _ask(tester, '查询库存');
      service.reply.completeError(timeout ? TimeoutException('timeout') : StateError('未配置'));
      await tester.pumpAndSettle();
      expect(find.textContaining('本次请求失败，未执行任何库存或设备操作'), findsOneWidget);
      expect(find.textContaining('重试'), findsOneWidget);
      expect(find.textContaining('当前已作为本地智能指令处理'), findsNothing);
    });
  }

  test('未实现的连接默认不能显示在线或已同步', () {
    final repository = MockSmartHomeRepository();
    expect(repository.nasOnline, isFalse);
    expect(repository.haStatus, HaConnectionStatus.unconfigured);
  });

  for (final nas in [true, false]) {
    testWidgets('${nas ? 'NAS' : 'HA'}连接按钮不返回假成功', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 1100));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(ProviderScope(
        overrides: [themeNameProvider.overrideWith((ref) => Stream.value('default'))],
        child: MaterialApp(home: nas ? const NasSettingsScreen() : const HomeAssistantSettingsScreen()),
      ));
      await tester.pumpAndSettle();
      final button = find.text(nas ? '测试并保存 NAS 连接' : '校验 Token 并保存');
      await tester.ensureVisible(button);
      await tester.tap(button);
      await tester.pumpAndSettle();
      if (nas) {
        expect(find.textContaining('请输入有效的 NAS 地址'), findsWidgets);
      } else {
        expect(find.textContaining('当前版本尚未支持'), findsWidgets);
      }
      expect(find.textContaining('连接测试成功'), findsNothing);
      expect(find.textContaining('校验成功'), findsNothing);
    });
  }
}

Future<void> _pumpAssistant(WidgetTester tester, _ControlledAssistant service) async {
  await tester.binding.setSurfaceSize(const Size(1000, 1100));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final settings = MemorySettingsRepository();
  addTearDown(settings.close);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      settingsRepositoryProvider.overrideWithValue(settings),
      themeNameProvider.overrideWith((ref) => Stream.value('default')),
      aiAssistantServiceProvider.overrideWithValue(service),
    ],
    child: const MaterialApp(home: Scaffold(body: AiAssistantDialog())),
  ));
  await tester.pumpAndSettle();
}

Future<void> _ask(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.tap(find.byIcon(Icons.send_rounded));
  await tester.pump();
  await tester.pump();
}

class _ControlledAssistant implements AiAssistantService {
  final reply = Completer<String>();
  final questions = <String>[];
  final histories = <List<ChatMessage>>[];
  int _requestSequence = 0;

  @override
  String createRequestToken() => 'test-request-${++_requestSequence}';

  @override
  Future<String> ask(
    String question,
    List<ChatMessage> history, {
    String? requestToken,
  }) {
    questions.add(question);
    histories.add(history);
    return reply.future;
  }
}
