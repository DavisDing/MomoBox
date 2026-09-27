import 'package:drift/drift.dart';

import '../core/database/app_database.dart';

class InventoryStatisticsPoint {
  const InventoryStatisticsPoint({
    required this.date,
    required this.consumed,
    required this.intake,
    required this.discarded,
  });

  final DateTime date;
  final int consumed;
  final int intake;
  final int discarded;

  int get activity => consumed + intake + discarded;
}

class InventoryProductStatistic {
  const InventoryProductStatistic({
    required this.productId,
    required this.productName,
    required this.unit,
    required this.consumed,
  });

  final String productId;
  final String productName;
  final String unit;
  final int consumed;
}

class InventoryStatistics {
  const InventoryStatistics({
    required this.from,
    required this.to,
    required this.points,
    required this.products,
  });

  final DateTime from;
  final DateTime to;
  final List<InventoryStatisticsPoint> points;
  final List<InventoryProductStatistic> products;

  int get consumed => points.fold(0, (sum, point) => sum + point.consumed);
  int get intake => points.fold(0, (sum, point) => sum + point.intake);
  int get discarded => points.fold(0, (sum, point) => sum + point.discarded);
}

/// Reads stock movements directly from local SQLite. No network or paid
/// analytics service is involved. The UI can render the returned points with
/// CustomPainter, keeping the dependency footprint unchanged.
class InventoryStatisticsService {
  InventoryStatisticsService(this._database);

  final AppDatabase _database;

  Future<InventoryStatistics> load({int days = 30, DateTime? now}) async {
    final safeDays = days.clamp(1, 365);
    final end = (now ?? DateTime.now()).toLocal();
    final start = DateTime(end.year, end.month, end.day).subtract(Duration(days: safeDays - 1));
    final rows = await _database.customSelect(
      '''
      SELECT sm.created_at, sm.type, sm.quantity, sm.product_id,
             COALESCE(p.name, '已删除商品') AS product_name,
             COALESCE(p.unit, '件') AS product_unit
      FROM stock_movements sm
      LEFT JOIN products p ON p.id = sm.product_id
      WHERE sm.created_at >= ? AND sm.created_at < ?
      ORDER BY sm.created_at ASC
      ''',
      variables: [Variable.withDateTime(start), Variable.withDateTime(end.add(const Duration(days: 1)))],
      readsFrom: {_database.stockMovements, _database.products},
    ).get();

    final pointsByDay = <DateTime, _MutablePoint>{};
    for (var index = 0; index < safeDays; index++) {
      final date = DateTime(start.year, start.month, start.day).add(Duration(days: index));
      pointsByDay[date] = _MutablePoint(date);
    }
    final productConsumed = <String, _MutableProduct>{};

    for (final row in rows) {
      final timestamp = row.read<DateTime>('created_at').toLocal();
      final date = DateTime(timestamp.year, timestamp.month, timestamp.day);
      final point = pointsByDay.putIfAbsent(date, () => _MutablePoint(date));
      final type = row.read<String>('type');
      final quantity = row.read<int>('quantity').abs();
      if (type == 'consume') {
        point.consumed += quantity;
        final productId = row.read<String>('product_id');
        final product = productConsumed.putIfAbsent(
          productId,
          () => _MutableProduct(
            productId,
            row.read<String>('product_name'),
            row.read<String>('product_unit'),
          ),
        );
        product.consumed += quantity;
      } else if (type == 'intake' || type == 'adjustment') {
        point.intake += quantity;
      } else if (type == 'discard') {
        point.discarded += quantity;
      }
    }

    final points = pointsByDay.values
        .map(
          (point) => InventoryStatisticsPoint(
            date: point.date,
            consumed: point.consumed,
            intake: point.intake,
            discarded: point.discarded,
          ),
        )
        .toList(growable: false);
    final products = productConsumed.values
        .map(
          (product) => InventoryProductStatistic(
            productId: product.productId,
            productName: product.productName,
            unit: product.unit,
            consumed: product.consumed,
          ),
        )
        .toList()
      ..sort((a, b) => b.consumed.compareTo(a.consumed));

    return InventoryStatistics(
      from: start,
      to: end,
      points: points,
      products: List<InventoryProductStatistic>.unmodifiable(products),
    );
  }
}

class _MutablePoint {
  _MutablePoint(this.date);
  final DateTime date;
  int consumed = 0;
  int intake = 0;
  int discarded = 0;
}

class _MutableProduct {
  _MutableProduct(this.productId, this.productName, this.unit);
  final String productId;
  final String productName;
  final String unit;
  int consumed = 0;
}
