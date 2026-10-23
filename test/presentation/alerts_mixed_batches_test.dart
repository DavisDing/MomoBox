import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/alerts_screen.dart';
import 'package:momo_box/presentation/widgets/status_badge.dart';

void main() {
  InventoryItem mixedBatches() {
    final now = DateTime.now();
    return InventoryItem(
      id: 'mixed-product',
      name: '混合效期商品',
      category: '其他物品',
      brand: null,
      specification: null,
      barcode: null,
      location: null,
      unit: '件',
      lowStockThreshold: 1,
      batches: [
        InventoryBatch(
          id: 'expired-batch',
          productId: 'mixed-product',
          batchNo: '旧批次',
          initialQuantity: 2,
          remainingQuantity: 2,
          isDiscarded: false,
          productionDate: null,
          expiryDate: DateTime(now.year, now.month, now.day - 2),
        ),
        InventoryBatch(
          id: 'upcoming-batch',
          productId: 'mixed-product',
          batchNo: '新批次',
          initialQuantity: 2,
          remainingQuantity: 2,
          isDiscarded: false,
          productionDate: null,
          expiryDate: DateTime(now.year, now.month, now.day + 3),
        ),
      ],
    );
  }

  Future<void> mount(WidgetTester tester, String filter) async {
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          inventoryProvider.overrideWith(
            (ref) => Stream.value([mixedBatches()]),
          ),
          reminderAcknowledgementsProvider.overrideWith(
            (ref) => Stream.value([]),
          ),
        ],
        child: MaterialApp(home: AlertsScreen(initialFilter: filter)),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('旧过期批次不会使临期分组显示过期日期和徽章', (tester) async {
    await mount(tester, 'expiring');
    expect(find.text('混合效期商品'), findsOneWidget);
    expect(find.text('3 天后到期；建议优先使用该批次。'), findsOneWidget);
    final badge = tester.widget<StatusBadge>(find.byType(StatusBadge));
    expect(badge.status, ExpiryStatus.expiring);
    expect(badge.days, 3);
    expect(tester.takeException(), isNull);
  });

  testWidgets('过期分组仍展示旧批次，保留真实过期事实', (tester) async {
    await mount(tester, 'expired');
    expect(find.text('混合效期商品'), findsOneWidget);
    expect(find.textContaining('已于'), findsOneWidget);
    final badge = tester.widget<StatusBadge>(find.byType(StatusBadge));
    expect(badge.status, ExpiryStatus.expired);
    expect(badge.days, -2);
    expect(tester.takeException(), isNull);
  });
}
