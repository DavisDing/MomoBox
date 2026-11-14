import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/assistant_screen.dart';
import 'package:momo_box/presentation/widgets/assistant_message_body.dart';

import '../support/memory_settings_repository.dart';

Future<void> _pumpBody(
  WidgetTester tester,
  String content, {
  double width = 390,
  double scale = 1,
  Brightness brightness = Brightness.light,
}) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 844);
  await tester.pumpWidget(
    MaterialApp(
      theme: buildMomoTheme(MomoPalette.defaultPalette, brightness),
      builder:
          (context, child) => MediaQuery(
            data: MediaQuery.of(
              context,
            ).copyWith(textScaler: TextScaler.linear(scale)),
            child: child!,
          ),
      home: Scaffold(
        body: SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: AssistantMessageBody(content: content),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

Iterable<TextSpan> _spans(InlineSpan span) sync* {
  if (span is TextSpan) {
    yield span;
    for (final child in span.children ?? <InlineSpan>[]) {
      yield* _spans(child);
    }
  }
}

Iterable<TextSpan> _renderedSpans(WidgetTester tester) => tester
    .widgetList<SelectableText>(find.byType(SelectableText))
    .expand(
      (text) =>
          _spans(text.textSpan ?? TextSpan(text: text.data, style: text.style)),
    );

const _formatted = '''# 家庭库存

**重点**、*强调*、~~删除~~和 `sensor.temperature`

- 牛奶
- 面包

1. 核对数量
2. 核对日期

> 优先处理临期物品

- [x] 已查看
- [ ] 待确认

第一行
第二行

---

[查看帮助](https://example.com/help)
''';

void main() {
  testWidgets(
    'copy preserves complete text across bold and inline code spans',
    (tester) async {
      addTearDown(tester.view.reset);
      String? copiedText;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') {
            copiedText = (call.arguments as Map)['text'] as String;
          }
          if (call.method == 'Clipboard.getData') return {'text': copiedText};
          if (call.method == 'Clipboard.hasStrings') {
            return {'value': copiedText != null};
          }
          return null;
        },
      );
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          SystemChannels.platform,
          null,
        ),
      );
      await _pumpBody(tester, '**牛奶** 共 `2` 件');
      final editable = tester.state<EditableTextState>(
        find.byType(EditableText),
      );
      editable.selectAll(SelectionChangedCause.toolbar);
      await tester.pump();
      editable.copySelection(SelectionChangedCause.toolbar);
      await tester.pump();
      expect((await Clipboard.getData(Clipboard.kTextPlain))?.text, '牛奶 共 2 件');
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('renders selectable Markdown styles instead of literal markers', (
    tester,
  ) async {
    addTearDown(tester.view.reset);
    await _pumpBody(tester, jsonEncode({'reply': _formatted, 'action': null}));
    final spans = _renderedSpans(tester).toList();
    expect(
      spans.any(
        (span) =>
            span.text == '重点' && span.style?.fontWeight == FontWeight.bold,
      ),
      isTrue,
    );
    expect(
      spans.any(
        (span) =>
            span.text == '强调' && span.style?.fontStyle == FontStyle.italic,
      ),
      isTrue,
    );
    expect(
      spans.any(
        (span) =>
            span.text == '删除' &&
            span.style?.decoration == TextDecoration.lineThrough,
      ),
      isTrue,
    );
    expect(
      spans.any(
        (span) =>
            span.text == 'sensor.temperature' &&
            span.style?.fontFamily == 'monospace',
      ),
      isTrue,
    );
    expect(find.text('家庭库存'), findsOneWidget);
    expect(find.text('牛奶'), findsOneWidget);
    expect(find.textContaining('第一行\n第二行'), findsOneWidget);
    expect(find.textContaining('**重点**'), findsNothing);
    expect(find.textContaining('"action"'), findsNothing);
    expect(
      tester.widget<MarkdownBody>(find.byType(MarkdownBody)).selectable,
      isTrue,
    );
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 3.4]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'wide table/code stay within $width at $scale / ${brightness.name}',
          (tester) async {
            addTearDown(tester.view.reset);
            final longName = List.filled(14, '很长的设备或物品名称').join();
            final content = '''## 来源明细

- **库存说明**：$longName
- [x] 已核对传感器状态

> 普通读取说明，保留来源与时间。

| 物品 | 位置 | 传感器 | 更新时间 |
| --- | --- | --- | --- |
| $longName | 储物柜 | sensor.temperature | 2026-11-13 |

```yaml
entity_id: ${List.filled(40, 'sensor.long_name').join('_')}
```

普通说明结尾
''';
            await _pumpBody(
              tester,
              content,
              width: width,
              scale: scale,
              brightness: brightness,
            );
            expect(tester.takeException(), isNull);
            final body = tester.getRect(find.byType(AssistantMessageBody));
            expect(body.left, greaterThanOrEqualTo(16));
            expect(body.right, lessThanOrEqualTo(width - 16));
            final horizontal =
                tester
                    .widgetList<SingleChildScrollView>(
                      find.byType(SingleChildScrollView),
                    )
                    .where(
                      (scroll) => scroll.scrollDirection == Axis.horizontal,
                    )
                    .toList();
            expect(horizontal, hasLength(2));
            for (final scroll in horizontal) {
              expect(
                scroll.controller!.position.maxScrollExtent,
                greaterThan(0),
              );
              scroll.controller!.jumpTo(80);
              await tester.pump();
              expect(scroll.controller!.offset, 80);
            }
            // Each block owns its scroll position; moving one cannot move the other.
            horizontal.first.controller!.jumpTo(120);
            await tester.pump();
            expect(horizontal.last.controller!.offset, 80);
            final markdown = tester.widget<MarkdownBody>(
              find.byType(MarkdownBody),
            );
            expect(markdown.styleSheet!.textScaler!.scale(14), 14 * scale);
            expect(
              markdown.styleSheet!.p!.color,
              buildMomoTheme(
                MomoPalette.defaultPalette,
                brightness,
              ).colorScheme.onSurface,
            );
            expect(tester.takeException(), isNull);
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  testWidgets(
    'image Markdown stays a user-opened link, never a network or local image',
    (tester) async {
      addTearDown(tester.view.reset);
      await _pumpBody(
        tester,
        '![网页图片](https://example.com/image.png)\n\n![本地图片](file:///private/secret.png)',
      );
      expect(find.byType(Image), findsNothing);
      expect(find.text('查看图片：网页图片'), findsOneWidget);
      final local = find.ancestor(
        of: find.text('查看图片：本地图片'),
        matching: find.byType(TextButton),
      );
      expect(tester.widget<TextButton>(local).onPressed, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  for (final success in [true, false]) {
    testWidgets(
      'web links open externally with a visible launch result; success=$success',
      (tester) async {
        addTearDown(tester.view.reset);
        final launches = <MethodCall>[];
        const channel = MethodChannel('plugins.flutter.io/url_launcher');
        tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          (call) async {
            launches.add(call);
            return success;
          },
        );
        addTearDown(
          () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
            channel,
            null,
          ),
        );
        await _pumpBody(tester, '[查看帮助](https://example.com/help)');
        expect(launches, isEmpty);
        await tester.tap(find.text('查看帮助'));
        await tester.pumpAndSettle();
        expect(launches, hasLength(1));
        expect(launches.single.arguments['url'], 'https://example.com/help');
        expect(launches.single.arguments['useWebView'], isFalse);
        expect(launches.single.arguments['useSafariVC'], isFalse);
        expect(
          find.textContaining('无法打开链接'),
          success ? findsNothing : findsOneWidget,
        );
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'unsupported link schemes cannot invoke another app or an assistant action',
    (tester) async {
      addTearDown(tester.view.reset);
      final launches = <MethodCall>[];
      const channel = MethodChannel('plugins.flutter.io/url_launcher');
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (
        call,
      ) async {
        launches.add(call);
        return true;
      });
      addTearDown(
        () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
          channel,
          null,
        ),
      );
      await _pumpBody(tester, '[配置操作](momobox://consume?quantity=1)');
      await tester.tap(find.text('配置操作'));
      await tester.pumpAndSettle();
      expect(launches, isEmpty);
      expect(find.textContaining('仅支持打开 HTTP'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'real stored conversation renders Markdown and preserves the original proposal guard',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 1000);
      addTearDown(tester.view.reset);
      final settings = MemorySettingsRepository();
      addTearDown(settings.close);
      final store = AiConversationStore(settings);
      await store.load();
      const userText = '**用户输入保留原文**';
      final reply = jsonEncode({
        'reply': '## 当前库存\n\n**牛奶** 共 2 件',
        'action': null,
      });
      final proposal = jsonEncode({
        'reply': '**已经执行**',
        'action': {'kind': 'set_theme', 'value': 'sky'},
      });
      final now = DateTime.now();
      store.current.messages.addAll([
        ChatMessage(
          id: 'user',
          role: 'user',
          content: userText,
          timestamp: now,
        ),
        ChatMessage(
          id: 'reply',
          role: 'assistant',
          content: reply,
          timestamp: now,
        ),
        ChatMessage(
          id: 'proposal',
          role: 'assistant',
          content: proposal,
          timestamp: now,
        ),
      ]);
      await store.save();
      final archive = settings.values[AiConversationStore.storageKey];
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(settings),
            aiConversationStoreProvider.overrideWith((ref) => store),
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            aiConfigurationStatusProvider.overrideWith(
              (ref) => Stream.value(false),
            ),
            aiInventoryPermissionProvider.overrideWith(
              (ref) => Stream.value(true),
            ),
          ],
          child: const MaterialApp(home: AssistantScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('当前库存'), findsOneWidget);
      expect(find.text(userText), findsOneWidget);
      expect(find.text('查看并确认操作'), findsOneWidget);
      expect(find.textContaining('操作建议已生成，尚未执行'), findsOneWidget);
      expect(find.text('已经执行'), findsNothing);
      expect(store.actionReceipts, isEmpty);
      expect(settings.values[AiConversationStore.storageKey], archive);
      expect(store.current.messages.last.content, proposal);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}
