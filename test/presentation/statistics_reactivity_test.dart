import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/inventory_statistics_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/statistics_screen.dart';

void main() {
  test('统计 provider 保持订阅时随真实入库和消耗刷新', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final container = ProviderContainer(
      overrides: [databaseProvider.overrideWithValue(database)],
    );
    final inventory = InventoryRepository(database);
    Completer<InventoryStatistics>? nextResult;
    bool Function(InventoryStatistics)? matches;
    final subscription = container.listen(inventoryStatisticsProvider(7), (
      _,
      value,
    ) {
      final statistics = value.asData?.value;
      if (statistics != null &&
          matches?.call(statistics) == true &&
          nextResult != null &&
          !nextResult.isCompleted) {
        nextResult.complete(statistics);
      }
    });
    try {
      expect(
        (await container.read(inventoryStatisticsProvider(7).future)).intake,
        0,
      );
      nextResult = Completer<InventoryStatistics>();
      matches = (value) => value.intake == 3;
      final productId = await inventory.createProductWithBatch(
        const IntakeDraft(name: '实时统计', category: '其他物品', quantity: 3),
      );
      expect(
        (await nextResult.future.timeout(const Duration(seconds: 5))).intake,
        3,
      );
      nextResult = Completer<InventoryStatistics>();
      matches = (value) => value.consumed == 1;
      await inventory.consumeByFefo(productId, 1);
      final consumed = await nextResult.future.timeout(
        const Duration(seconds: 5),
      );
      expect(consumed.consumed, 1);
      expect(consumed.products.single.productName, '实时统计');
    } finally {
      subscription.close();
      container.dispose();
      await database.close();
    }
  });

  testWidgets('每日图表为读屏提供逐日数值且保留可见图形', (tester) async {
    await tester.binding.setSurfaceSize(const Size(800, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final semantics = tester.ensureSemantics();
    try {
      final value = InventoryStatistics(
        from: DateTime(2026, 10, 22),
        to: DateTime(2026, 10, 23),
        points: [
          InventoryStatisticsPoint(
            date: DateTime(2026, 10, 22),
            consumed: 1,
            intake: 3,
            discarded: 0,
          ),
          InventoryStatisticsPoint(
            date: DateTime(2026, 10, 23),
            consumed: 2,
            intake: 0,
            discarded: 1,
          ),
        ],
        products: const [],
      );
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            inventoryStatisticsProvider(
              7,
            ).overrideWith((ref) => Stream.value(value)),
          ],
          child: const MaterialApp(home: StatisticsScreen(initialDays: 7)),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('每日库存变动'), findsOneWidget);
      expect(find.byType(CustomPaint), findsWidgets);
      final labels = <String>[];
      void collect(SemanticsNode node) {
        labels.add(node.label);
        node.visitChildren((child) {
          collect(child);
          return true;
        });
      }

      collect(
        tester.getSemantics(
          find.byKey(const Key('inventory-statistics-chart')),
        ),
      );
      expect(labels, contains('2026-10-22，消耗 1 件，入库或调整 3 件，报废 0 件'));
      expect(labels, contains('2026-10-23，消耗 2 件，入库或调整 0 件，报废 1 件'));
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      semantics.dispose();
    }
  });
}
