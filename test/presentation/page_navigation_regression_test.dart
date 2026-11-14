import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_assistant_service.dart';
import 'package:momo_box/application/ai_conversation_store.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/domain/models/home_environment.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/smart_home_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/controllers/smart_home_controller.dart';
import 'package:momo_box/presentation/screens/assistant_screen.dart';
import 'package:momo_box/presentation/screens/inventory_screen.dart';
import 'package:momo_box/presentation/screens/smart_home_screen.dart';

import '../support/memory_settings_repository.dart';

const _summary = ReminderSummary(expired: [], expiring: [], lowStock: []);

InventoryItem _item(int index) => InventoryItem(
  id: 'product-$index',
  name: '测试物品 $index',
  category: '其他物品',
  brand: null,
  specification: null,
  barcode: null,
  location: '储物柜',
  unit: '件',
  lowStockThreshold: 1,
  batches: [
    InventoryBatch(
      id: 'batch-$index',
      productId: 'product-$index',
      batchNo: null,
      initialQuantity: 3,
      remainingQuantity: 3,
      isDiscarded: false,
      expiryDate: null,
      productionDate: null,
    ),
  ],
);

AiSession _conversation() => AiSession(
  id: 'saved',
  title: '已有长会话',
  createdAt: DateTime.utc(2026),
  messages: List.generate(
    40,
    (index) => ChatMessage(
      id: 'message-$index',
      role: index.isEven ? 'user' : 'assistant',
      content:
          index == 39
              ? '最新消息\n${List.filled(35, '最新回复的详细内容').join('\n')}\n回复结尾'
              : '历史消息 $index\n${List.filled(index % 4 + 1, '不同长度的历史记录').join('\n')}',
      timestamp: DateTime.utc(2026, 11, 13, 0, index),
    ),
  ),
);

class _DelayedSettings extends MemorySettingsRepository {
  final archive = Completer<String?>();
  @override
  Future<String?> getValue(String key) =>
      key == AiConversationStore.storageKey
          ? archive.future
          : super.getValue(key);
}

class _StaticHome extends SmartHomeController {
  _StaticHome(super.repository, HaConnectionStatus status)
    : super(nasAddress: 'https://nas.example') {
    state = SmartHomeState(
      devices: const [],
      logs: const [],
      haStatus: status,
      haAddress: 'http://ha.local:8123',
      nasAddress: 'https://nas.example',
      nasOnline: true,
    );
  }
  @override
  Future<void> refresh() async {}
}

void main() {
  for (final width in [320.0, 390.0]) {
    testWidgets('inventory uses 1/2/3 columns by visible count at width $width', (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 844);
      addTearDown(tester.view.reset);
      for (final count in [1, 2, 3, 4, 6, 7]) {
        await tester.pumpWidget(ProviderScope(key: ValueKey(count), overrides: [
          inventoryProvider.overrideWith((ref) => Stream.value(List.generate(count, _item))),
          reminderSummaryProvider.overrideWithValue(_summary),
          mediaAssetsProvider.overrideWith((ref, target) => Stream.value(const [])),
        ], child: const MaterialApp(home: InventoryScreen())));
        await tester.pumpAndSettle();
        final columns = count.clamp(1, 3);
        final first = find.byKey(const ValueKey('inventory-card-product-0'));
        final firstRect = tester.getRect(first);
        expect(find.text('$count 种物品'), findsOneWidget);
        expect(tester.getSize(find.byKey(const ValueKey('inventory-photo-product-0'))).height, columns == 1 ? 72 : columns == 2 ? 80 : 64);
        for (var index = 1; index < columns; index++) {
          final rect = tester.getRect(find.byKey(ValueKey('inventory-card-product-$index')));
          expect(rect.top, closeTo(firstRect.top, .01));
          expect(rect.width, closeTo(firstRect.width, .01));
          expect(rect.left, closeTo(firstRect.left + index * (firstRect.width + 8), .01));
        }
        if (count > columns) {
          final nextRect = tester.getRect(find.byKey(ValueKey('inventory-card-product-$columns')));
          expect(nextRect.top, greaterThan(firstRect.bottom));
          expect(nextRect.left, closeTo(firstRect.left, .01));
          expect(nextRect.width, closeTo(firstRect.width, .01));
        }
        if (columns > 1) {
          expect(firstRect.height, lessThan(250));
          expect(tester.getSize(find.byKey(const ValueKey('inventory-consume-product-0'))), const Size(44, 44));
          expect(tester.getSize(find.byKey(const ValueKey('inventory-more-product-0'))), const Size(44, 44));
        }
        expect(tester.takeException(), isNull);
      }
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }

  testWidgets(
    'entering and re-entering a long conversation shows its latest end',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(430, 900);
      addTearDown(tester.view.reset);
      final settings = MemorySettingsRepository();
      addTearDown(settings.close);
      settings.values[AiConversationStore.storageKey] = jsonEncode({
        'currentId': 'saved',
        'sessions': [_conversation().toJson()],
      });
      final store = AiConversationStore(settings);
      await store.load();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(settings),
            aiConversationStoreProvider.overrideWith((ref) => store),
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            aiConfigurationStatusProvider.overrideWith(
              (ref) => Stream.value(false),
            ),
          ],
          child: MaterialApp(
            home: Builder(
              builder:
                  (context) => Scaffold(
                    body: TextButton(
                      onPressed:
                          () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => const AssistantScreen(),
                            ),
                          ),
                      child: const Text('打开助手'),
                    ),
                  ),
            ),
          ),
        ),
      );
      Future<void> open() async {
        await tester.tap(find.text('打开助手'));
        await tester.pumpAndSettle();
        final scroll =
            find
                .descendant(
                  of: find.byType(AssistantScreen),
                  matching: find.byType(Scrollable),
                )
                .first;
        expect(tester.state<ScrollableState>(scroll).position.pixels, 0);
        final latest = find.byKey(const ValueKey('message-39'));
        expect(latest, findsOneWidget);
        expect(
          tester.getBottomLeft(latest).dy,
          closeTo(tester.getBottomLeft(scroll).dy - 16, 1),
        );
      }

      await open();
      final scroll =
          find
              .descendant(
                of: find.byType(AssistantScreen),
                matching: find.byType(Scrollable),
              )
              .first;
      await tester.drag(scroll, const Offset(0, 500));
      await tester.pumpAndSettle();
      expect(
        tester.state<ScrollableState>(scroll).position.pixels,
        greaterThan(0),
      );
      Navigator.of(tester.element(find.byType(AssistantScreen))).pop();
      await tester.pumpAndSettle();
      await open();
      expect(store.currentId, 'saved');
      expect(store.current.messages, hasLength(40));
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'an empty conversation keeps its introduction visible with large text',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 600);
      addTearDown(tester.view.reset);
      final settings = MemorySettingsRepository();
      addTearDown(settings.close);
      final store = AiConversationStore(settings);
      await store.load();
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            settingsRepositoryProvider.overrideWithValue(settings),
            aiConversationStoreProvider.overrideWith((ref) => store),
            aiInventoryPermissionProvider.overrideWith(
              (ref) => Stream.value(false),
            ),
            selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
            aiConfigurationStatusProvider.overrideWith(
              (ref) => Stream.value(false),
            ),
          ],
          child: MaterialApp(
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: child!,
                ),
            home: const AssistantScreen(),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll =
          find
              .descendant(
                of: find.byType(AssistantScreen),
                matching: find.byType(Scrollable),
              )
              .first;
      final introduction = find.text('YOUR EVERYDAY COMPANION');
      expect(
        tester.getTopLeft(introduction).dy,
        greaterThanOrEqualTo(tester.getTopLeft(scroll).dy),
      );
      expect(
        tester.getBottomLeft(introduction).dy,
        lessThan(tester.getBottomLeft(scroll).dy),
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets('late archive loading also starts at the latest message', (
    tester,
  ) async {
    final settings = _DelayedSettings();
    addTearDown(settings.close);
    final store = AiConversationStore(settings);
    final loading = store.load();
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(settings),
          aiConversationStoreProvider.overrideWith((ref) => store),
          selectedAiModelProvider.overrideWith((ref) => Stream.value(null)),
          aiConfigurationStatusProvider.overrideWith(
            (ref) => Stream.value(false),
          ),
        ],
        child: const MaterialApp(home: AssistantScreen()),
      ),
    );
    await tester.pump();
    settings.archive.complete(
      jsonEncode({
        'currentId': 'saved',
        'sessions': [_conversation().toJson()],
      }),
    );
    await loading;
    await tester.pumpAndSettle();
    final scroll =
        find
            .descendant(
              of: find.byType(AssistantScreen),
              matching: find.byType(Scrollable),
            )
            .first;
    expect(tester.state<ScrollableState>(scroll).position.pixels, 0);
    expect(find.byKey(const ValueKey('message-39')), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  for (final entry
      in {
        HaConnectionStatus.online: 'HA 已连接',
        HaConnectionStatus.offline: 'HA 离线',
        HaConnectionStatus.stale: 'HA 状态过期',
        HaConnectionStatus.syncing: '同步中',
        HaConnectionStatus.unconfigured: 'HA 未配置',
      }.entries) {
    testWidgets('home displays ${entry.value} without connection controls', (
      tester,
    ) async {
      final api = NasApiClient('https://nas.example');
      addTearDown(api.close);
      final repository = NasSmartHomeRepository.withSession(
        api,
        isSessionCurrent: () => true,
      );
      addTearDown(repository.close);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            smartHomeControllerProvider.overrideWith(
              (ref) => _StaticHome(repository, entry.key),
            ),
            homeEnvironmentProvider.overrideWith(
              (ref) => const AsyncData(HomeEnvironment()),
            ),
            environmentClockProvider.overrideWith(
              (ref) => Stream.value(DateTime.utc(2026)),
            ),
          ],
          child: const MaterialApp(home: SmartHomeScreen()),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text(entry.value), findsOneWidget);
      expect(find.text('连接设置'), findsNothing);
      expect(find.text('打开连接配置'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}
