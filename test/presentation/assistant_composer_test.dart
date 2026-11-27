import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/assistant_screen.dart';

import '../support/memory_settings_repository.dart';

void main() {
  testWidgets('点历史会话里的消息或留白会收起键盘且保留草稿', (tester) async {
    final store = await _pumpAssistant(tester);
    final origin = store.current.id;
    store.create();
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('历史会话'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('新对话'));
    await tester.pumpAndSettle();
    expect(store.currentId, origin);

    final composer = find.byType(TextField);
    await tester.enterText(composer, '草稿内容');
    for (final message in ['用户消息', '库存回复', null]) {
      await tester.tap(composer);
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isTrue);
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      if (message == null) {
        await tester.tapAt(
          tester.getTopLeft(find.byType(ListView)) + const Offset(12, 12),
        );
      } else {
        await tester.tap(find.text(message));
      }
      await tester.pumpAndSettle();
      expect(tester.widget<TextField>(composer).focusNode!.hasFocus, isFalse);
      expect(tester.testTextInput.isVisible, isFalse);
      tester.view.resetViewInsets();
      await tester.pumpAndSettle();
      expect(tester.testTextInput.isVisible, isFalse);
      expect(tester.widget<TextField>(composer).controller!.text, '草稿内容');
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('输入框随多行文字增长，受行数和键盘上方高度限制', (tester) async {
    await _pumpAssistant(tester);
    final composer = find.byType(TextField);
    double height() => tester.getSize(composer).height;

    await tester.enterText(composer, '第一行');
    await tester.pumpAndSettle();
    final singleLine = height();
    await tester.enterText(composer, '第一行\n第二行\n第三行');
    await tester.pumpAndSettle();
    expect(height(), greaterThan(singleLine));

    final longText = List.filled(12, '一行内容').join('\n');
    await tester.enterText(composer, longText);
    await tester.pumpAndSettle();
    final maxHeight = height();
    await tester.enterText(composer, '$longText\n末尾');
    await tester.pumpAndSettle();
    expect(height(), maxHeight);
    expect(tester.widget<TextField>(composer).controller!.text, endsWith('末尾'));

    tester.view.viewInsets = const FakeViewPadding(bottom: 570);
    await tester.pumpAndSettle();
    expect(height(), lessThan(maxHeight));
    final scrollable = find.descendant(
      of: composer,
      matching: find.byType(Scrollable),
    );
    expect(
      tester.state<ScrollableState>(scrollable).position.maxScrollExtent,
      greaterThan(0),
    );
    expect(tester.takeException(), isNull);
  });
}

Future<AiConversationStore> _pumpAssistant(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(430, 844);
  addTearDown(tester.view.reset);
  final settings = MemorySettingsRepository();
  final store = AiConversationStore(settings);
  await store.load();
  final now = DateTime.now();
  store.current.messages.addAll([
    ChatMessage(id: 'user', role: 'user', content: '用户消息', timestamp: now),
    ChatMessage(
      id: 'reply',
      role: 'assistant',
      content: '库存回复',
      timestamp: now,
    ),
  ]);
  addTearDown(settings.close);
  addTearDown(() => tester.pumpWidget(const SizedBox.shrink()));
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        settingsRepositoryProvider.overrideWithValue(settings),
        aiConversationStoreProvider.overrideWith((ref) => store),
        selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
      ],
      child: const MaterialApp(home: AssistantScreen()),
    ),
  );
  await tester.pumpAndSettle();
  return store;
}
