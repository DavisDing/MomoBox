import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/shopping_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/inventory_screen.dart';
import 'package:momo_box/presentation/screens/product_detail_screen.dart';

import '../support/memory_settings_repository.dart';

const _emptySummary = ReminderSummary(expired: [], expiring: [], lowStock: []);

InventoryItem _item(int index) => InventoryItem(
  id: 'product-$index',
  name: '厨房储物柜里的长名称物品 $index',
  category: '家居清洁',
  brand: null,
  specification: null,
  barcode: null,
  location: '厨房的第二层储物柜',
  unit: '件',
  lowStockThreshold: 3,
  batches: [
    InventoryBatch(
      id: 'batch-$index',
      productId: 'product-$index',
      batchNo: null,
      initialQuantity: 2,
      remainingQuantity: 2,
      isDiscarded: false,
      expiryDate: DateTime.now().add(const Duration(days: 2)),
      productionDate: null,
    ),
  ],
);

void main() {
  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0, 3.4]) {
      for (final brightness in Brightness.values) {
        testWidgets(
          'three columns retain long content and tappable cards at $width / $scale / ${brightness.name}',
          (tester) async {
            tester.view.devicePixelRatio = 1;
            tester.view.physicalSize = Size(width, 844);
            addTearDown(tester.view.reset);
            await tester.pumpWidget(
              ProviderScope(
                overrides: [
                  inventoryProvider.overrideWith(
                    (ref) => Stream.value(List.generate(3, _item)),
                  ),
                  reminderSummaryProvider.overrideWithValue(_emptySummary),
                  mediaAssetsProvider.overrideWith(
                    (ref, target) => Stream.value(const []),
                  ),
                ],
                child: MaterialApp(
                  theme: buildMomoTheme(MomoPalette.defaultPalette, brightness),
                  builder:
                      (context, child) => MediaQuery(
                        data: MediaQuery.of(
                          context,
                        ).copyWith(textScaler: TextScaler.linear(scale)),
                        child: child!,
                      ),
                  home: const InventoryScreen(),
                ),
              ),
            );
            await tester.pumpAndSettle();
            final scroll =
                find
                    .descendant(
                      of: find.byType(InventoryScreen),
                      matching: find.byType(Scrollable),
                    )
                    .first;
            final first = find.byKey(
              const ValueKey('inventory-card-product-0'),
            );
            await tester.scrollUntilVisible(first, 200, scrollable: scroll);
            await tester.pumpAndSettle();
            expect(tester.takeException(), isNull);
            final rect = tester.getRect(first);
            for (var index = 1; index < 3; index++) {
              final next = tester.getRect(
                find.byKey(ValueKey('inventory-card-product-$index')),
              );
              expect(next.top, closeTo(rect.top, .01));
              expect(next.width, closeTo(rect.width, .01));
              expect(
                next.right,
                lessThanOrEqualTo(width - (width < 360 ? 16 : 20) + .01),
              );
            }
            expect(find.text('厨房储物柜里的长名称物品 0'), findsOneWidget);
            expect(find.text('家居清洁 · 厨房的第二层储物柜'), findsNWidgets(3));
            expect(find.text('2 件'), findsNWidgets(3));
            expect(find.text('库存偏低'), findsNWidgets(3));
            expect(find.text('2 天内到期'), findsNWidgets(3));
            // Large, wrapped cards can extend below the viewport until scrolled.
            final target = first.hitTestable();
            for (var i = 0; i < 4 && target.evaluate().isEmpty; i++) {
              await tester.drag(scroll, const Offset(0, -160));
              await tester.pumpAndSettle();
            }
            expect(target, findsOneWidget);
            expect(
              find.descendant(of: first, matching: find.byType(IconButton)),
              findsNothing,
            );
            await tester.pumpWidget(const SizedBox.shrink());
          },
        );
      }
    }
  }

  testWidgets(
    'search uses the visible count and restores the original three-column layout',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inventoryProvider.overrideWith(
              (ref) => Stream.value(List.generate(4, _item)),
            ),
            reminderSummaryProvider.overrideWithValue(_emptySummary),
            mediaAssetsProvider.overrideWith(
              (ref, target) => Stream.value(const []),
            ),
          ],
          child: const MaterialApp(home: InventoryScreen()),
        ),
      );
      await tester.pumpAndSettle();
      final first = find.byKey(const ValueKey('inventory-card-product-0'));
      final originalWidth = tester.getSize(first).width;
      await tester.enterText(find.byType(TextField), '物品 0');
      await tester.pumpAndSettle();
      expect(find.text('全部物品 · 1'), findsOneWidget);
      expect(tester.getSize(first).width, greaterThan(originalWidth * 2));
      expect(
        tester.getSize(find.byKey(const ValueKey('inventory-photo-product-0'))),
        const Size(44, 44),
      );
      await tester.tap(find.byTooltip('清除搜索'));
      await tester.pumpAndSettle();
      expect(find.text('全部物品 · 4'), findsOneWidget);
      expect(tester.getSize(first).width, closeTo(originalWidth, .01));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'single card keeps full text and opens details at large text size',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 844);
      addTearDown(tester.view.reset);
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const InventoryScreen()),
          GoRoute(
            path: '/inventory/:id',
            builder:
                (_, state) =>
                    Scaffold(body: Text('详情：${state.pathParameters['id']}')),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inventoryProvider.overrideWith((ref) => Stream.value([_item(0)])),
            reminderSummaryProvider.overrideWithValue(_emptySummary),
            mediaAssetsProvider.overrideWith(
              (ref, target) => Stream.value(const []),
            ),
          ],
          child: MaterialApp.router(
            routerConfig: router,
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(3.4)),
                  child: child!,
                ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final scroll =
          find
              .descendant(
                of: find.byType(InventoryScreen),
                matching: find.byType(Scrollable),
              )
              .first;
      final card = find.byKey(const ValueKey('inventory-card-product-0'));
      await tester.scrollUntilVisible(card, 160, scrollable: scroll);
      await tester.pumpAndSettle();
      expect(find.text('厨房储物柜里的长名称物品 0'), findsOneWidget);
      expect(find.text('家居清洁 · 厨房的第二层储物柜'), findsOneWidget);
      expect(
        find.descendant(of: card, matching: find.byType(IconButton)),
        findsNothing,
      );
      await tester.tap(card);
      await tester.pumpAndSettle();
      expect(find.text('详情：product-0'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'three-column card opens the correct detail before stock or shopping changes',
    (tester) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(390, 844);
      addTearDown(tester.view.reset);
      final database = AppDatabase.forTesting(NativeDatabase.memory());
      final settings = MemorySettingsRepository();
      addTearDown(() => tester.runAsync(database.close));
      addTearDown(settings.close);
      final inventory = InventoryService(InventoryRepository(database));
      final shopping = ShoppingService(ShoppingRepository(database));
      final targetId = await inventory.intake(
        const IntakeDraft(
          name: '牛奶',
          category: '食品生鲜',
          quantity: 3,
          batchNo: '牛奶批次',
        ),
      );
      await inventory.intake(
        const IntakeDraft(name: '纸巾', category: '家居清洁', quantity: 3),
      );
      await inventory.intake(
        const IntakeDraft(name: '牙刷', category: '健康护理', quantity: 3),
      );
      final router = GoRouter(
        routes: [
          GoRoute(path: '/', builder: (_, _) => const InventoryScreen()),
          GoRoute(
            path: '/inventory/:id',
            builder:
                (_, state) =>
                    ProductDetailScreen(productId: state.pathParameters['id']!),
          ),
        ],
      );
      addTearDown(router.dispose);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            databaseProvider.overrideWithValue(database),
            settingsRepositoryProvider.overrideWithValue(settings),
            inventoryServiceProvider.overrideWithValue(inventory),
            shoppingServiceProvider.overrideWithValue(shopping),
            inventoryProvider.overrideWith((ref) => inventory.watchInventory()),
            reminderSummaryProvider.overrideWithValue(_emptySummary),
            mediaAssetsProvider.overrideWith(
              (ref, target) => Stream.value(const []),
            ),
          ],
          child: MaterialApp.router(routerConfig: router),
        ),
      );
      Future<void> flush() async {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 80)),
        );
        await tester.pumpAndSettle();
      }

      Future<int> targetStock() async {
        final items = await tester.runAsync(
          () => inventory.watchInventory().first,
        );
        expect(
          items!
              .where((item) => item.id != targetId)
              .every((item) => item.totalStock == 3),
          isTrue,
        );
        return items.firstWhere((item) => item.id == targetId).totalStock;
      }

      await flush();
      final card = find.byKey(ValueKey('inventory-card-$targetId'));
      expect(
        find.descendant(of: card, matching: find.byType(IconButton)),
        findsNothing,
      );
      await tester.tap(card);
      await flush();
      expect(find.byType(ProductDetailScreen), findsOneWidget);
      expect(find.text('牛奶'), findsOneWidget);
      expect(find.text('库存 3 件'), findsOneWidget);

      final scroll =
          find
              .descendant(
                of: find.byType(ProductDetailScreen),
                matching: find.byType(Scrollable),
              )
              .first;
      final consume = find.text('按最早到期优先消耗（最多 3 件）');
      await tester.scrollUntilVisible(consume, 160, scrollable: scroll);
      await flush();
      await tester.tap(consume);
      await flush();
      await tester.tap(find.text('取消'));
      await flush();
      expect(await targetStock(), 3);

      await tester.tap(consume);
      await flush();
      await tester.enterText(find.byType(TextField), '1');
      await tester.tap(find.text('确认消耗'));
      await flush();
      expect(await targetStock(), 2);

      final batchMenu = find.byTooltip('批次操作');
      await tester.scrollUntilVisible(batchMenu, 160, scrollable: scroll);
      await flush();
      await tester.tap(batchMenu);
      await flush();
      await tester.tap(find.text('补充指定数量'));
      await flush();
      await tester.enterText(find.byType(TextField), '1');
      await tester.tap(find.text('确认补充'));
      await flush();
      expect(await targetStock(), 3);

      final addToShopping = find.text('加入采购清单');
      await tester.scrollUntilVisible(addToShopping, -160, scrollable: scroll);
      await flush();
      await tester.tap(addToShopping);
      await flush();
      final entries = await tester.runAsync(
        () => shopping.watchEntries().first,
      );
      expect(entries!.single.productId, targetId);
      expect(entries.single.itemName, '牛奶');
      router.pop();
      await flush();
      expect(card, findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await flush();
    },
  );
}
