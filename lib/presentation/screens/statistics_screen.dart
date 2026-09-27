import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/inventory_statistics_service.dart';
import '../controllers/providers.dart';

/// 本地库存变动统计。数据直接来自 Drift，不依赖网络、NAS 或付费分析服务。
class StatisticsScreen extends ConsumerStatefulWidget {
  const StatisticsScreen({super.key, this.initialDays = 30});

  final int initialDays;

  @override
  ConsumerState<StatisticsScreen> createState() => _StatisticsScreenState();
}

class _StatisticsScreenState extends ConsumerState<StatisticsScreen> {
  late int _days = _normalizeDays(widget.initialDays);

  @override
  Widget build(BuildContext context) {
    final statistics = ref.watch(inventoryStatisticsProvider(_days));
    return Scaffold(
      appBar: AppBar(
        title: const Text('库存统计'),
        actions: [
          IconButton(
            tooltip: '刷新',
            onPressed: () => ref.invalidate(inventoryStatisticsProvider(_days)),
            icon: const Icon(Icons.refresh),
          ),
        ],
      ),
      body: statistics.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _StatisticsMessage(
          icon: Icons.error_outline,
          message: '统计加载失败：$error',
          actionLabel: '重试',
          onAction: () => ref.invalidate(inventoryStatisticsProvider(_days)),
        ),
        data: (value) => RefreshIndicator(
          onRefresh: () async => ref.invalidate(inventoryStatisticsProvider(_days)),
          child: ListView(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
            children: [
              _PeriodSelector(
                days: _days,
                onChanged: (days) => setState(() => _days = days),
              ),
              const SizedBox(height: 12),
              _SummaryCards(statistics: value),
              const SizedBox(height: 18),
              _StatisticsChart(points: value.points),
              const SizedBox(height: 18),
              _TopConsumedProducts(products: value.products),
              const SizedBox(height: 8),
              Text(
                '统计范围：${_dateText(value.from)} 至 ${_dateText(value.to)}。入库包含入库和库存调整，消耗与报废按库存变动记录汇总。',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

int _normalizeDays(int value) {
  if (value <= 7) return 7;
  if (value <= 30) return 30;
  return 90;
}

class _PeriodSelector extends StatelessWidget {
  const _PeriodSelector({required this.days, required this.onChanged});

  final int days;
  final ValueChanged<int> onChanged;

  @override
  Widget build(BuildContext context) => SegmentedButton<int>(
        segments: const [
          ButtonSegment(value: 7, label: Text('7 天')),
          ButtonSegment(value: 30, label: Text('30 天')),
          ButtonSegment(value: 90, label: Text('90 天')),
        ],
        selected: {days},
        onSelectionChanged: (values) => onChanged(values.first),
      );
}

class _SummaryCards extends StatelessWidget {
  const _SummaryCards({required this.statistics});

  final InventoryStatistics statistics;

  @override
  Widget build(BuildContext context) => GridView.count(
        crossAxisCount: 3,
        shrinkWrap: true,
        physics: const NeverScrollableScrollPhysics(),
        mainAxisSpacing: 8,
        crossAxisSpacing: 8,
        childAspectRatio: 1.35,
        children: [
          _SummaryCard(label: '消耗', value: statistics.consumed, icon: Icons.remove_circle_outline, color: Colors.blue),
          _SummaryCard(label: '入库/调整', value: statistics.intake, icon: Icons.add_circle_outline, color: Colors.green),
          _SummaryCard(label: '报废', value: statistics.discarded, icon: Icons.delete_outline, color: Colors.orange),
        ],
      );
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.label, required this.value, required this.icon, required this.color});

  final String label;
  final int value;
  final IconData icon;
  final Color color;

  @override
  Widget build(BuildContext context) => Card(
        margin: EdgeInsets.zero,
        child: Padding(
          padding: const EdgeInsets.all(10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(icon, size: 20, color: color),
              const Spacer(),
              Text('$value', style: Theme.of(context).textTheme.titleLarge),
              Text(label, style: Theme.of(context).textTheme.bodySmall),
            ],
          ),
        ),
      );
}

class _StatisticsChart extends StatelessWidget {
  const _StatisticsChart({required this.points});

  final List<InventoryStatisticsPoint> points;

  @override
  Widget build(BuildContext context) {
    final colors = [
      Theme.of(context).colorScheme.primary,
      Colors.green,
      Colors.orange,
    ];
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 14, 14, 12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('每日库存变动', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            Wrap(
              spacing: 14,
              runSpacing: 4,
              children: [
                _Legend(color: colors[0], label: '消耗'),
                _Legend(color: colors[1], label: '入库/调整'),
                _Legend(color: colors[2], label: '报废'),
              ],
            ),
            const SizedBox(height: 12),
            SizedBox(
              height: 220,
              width: double.infinity,
              child: points.every((point) => point.activity == 0)
                  ? const Center(child: Text('当前范围内暂无库存变动记录。'))
                  : CustomPaint(painter: _StatisticsChartPainter(points: points, colors: colors)),
            ),
          ],
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.color, required this.label});

  final Color color;
  final String label;

  @override
  Widget build(BuildContext context) => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          DecoratedBox(
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: const SizedBox.square(dimension: 8),
          ),
          const SizedBox(width: 5),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      );
}

class _StatisticsChartPainter extends CustomPainter {
  _StatisticsChartPainter({required this.points, required this.colors});

  final List<InventoryStatisticsPoint> points;
  final List<Color> colors;

  @override
  void paint(Canvas canvas, Size size) {
    if (points.isEmpty || size.width <= 0 || size.height <= 0) return;
    const left = 34.0;
    const right = 8.0;
    const top = 8.0;
    const bottom = 24.0;
    final chart = Rect.fromLTRB(left, top, size.width - right, size.height - bottom);
    final maxValue = math.max(1, points.fold<int>(0, (max, point) => math.max(
      max,
      math.max(point.consumed, math.max(point.intake, point.discarded)),
    ).toInt())).toDouble();
    final gridPaint = Paint()..color = Colors.grey.withValues(alpha: 0.22)..strokeWidth = 1;
    final axisPaint = Paint()..color = Colors.grey.withValues(alpha: 0.55)..strokeWidth = 1;
    final labelStyle = const TextStyle(fontSize: 10, color: Colors.grey);

    for (var index = 0; index <= 4; index++) {
      final y = chart.top + chart.height * index / 4;
      canvas.drawLine(Offset(chart.left, y), Offset(chart.right, y), gridPaint);
      final value = ((4 - index) * maxValue / 4).round();
      _paintText(canvas, '$value', Offset(0, y - 6), labelStyle, width: left - 5);
    }
    canvas.drawLine(Offset(chart.left, chart.top), Offset(chart.left, chart.bottom), axisPaint);
    canvas.drawLine(Offset(chart.left, chart.bottom), Offset(chart.right, chart.bottom), axisPaint);

    final xStep = points.length <= 1 ? 0.0 : chart.width / (points.length - 1);
    final series = <List<int>>[
      points.map((point) => point.consumed).toList(growable: false),
      points.map((point) => point.intake).toList(growable: false),
      points.map((point) => point.discarded).toList(growable: false),
    ];
    for (var seriesIndex = 0; seriesIndex < series.length; seriesIndex++) {
      final paint = Paint()
        ..color = colors[seriesIndex]
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round;
      final path = Path();
      for (var index = 0; index < points.length; index++) {
        final x = chart.left + index * xStep;
        final y = chart.bottom - chart.height * series[seriesIndex][index] / maxValue;
        if (index == 0) {
          path.moveTo(x, y);
        } else {
          path.lineTo(x, y);
        }
        canvas.drawCircle(Offset(x, y), 2.5, Paint()..color = colors[seriesIndex]);
      }
      canvas.drawPath(path, paint);
    }

    final labelStep = math.max(1, (points.length / 5).ceil()).toInt();
    for (var index = 0; index < points.length; index += labelStep) {
      final x = chart.left + index * xStep;
      final label = '${points[index].date.month}/${points[index].date.day}';
      _paintText(canvas, label, Offset(x - 15, chart.bottom + 6), labelStyle, width: 32);
    }
    if (points.isNotEmpty && (points.length - 1) % labelStep != 0) {
      final index = points.length - 1;
      final x = chart.left + index * xStep;
      _paintText(canvas, '${points[index].date.month}/${points[index].date.day}', Offset(x - 15, chart.bottom + 6), labelStyle, width: 32);
    }
  }

  @override
  bool shouldRepaint(covariant _StatisticsChartPainter oldDelegate) =>
      oldDelegate.points != points || oldDelegate.colors != colors;
}

void _paintText(Canvas canvas, String text, Offset offset, TextStyle style, {required double width}) {
  final painter = TextPainter(
    text: TextSpan(text: text, style: style),
    textDirection: TextDirection.ltr,
    maxLines: 1,
  )..layout(maxWidth: width);
  painter.paint(canvas, offset);
}

class _TopConsumedProducts extends StatelessWidget {
  const _TopConsumedProducts({required this.products});

  final List<InventoryProductStatistic> products;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('消耗最多的商品', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 6),
              if (products.isEmpty) const Text('当前范围内暂无消耗记录。'),
              for (final product in products.take(10))
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: CircleAvatar(child: Text('${products.indexOf(product) + 1}')),
                  title: Text(product.productName),
                  trailing: Text('${product.consumed} ${product.unit}'),
                ),
            ],
          ),
        ),
      );
}

class _StatisticsMessage extends StatelessWidget {
  const _StatisticsMessage({required this.icon, required this.message, this.actionLabel, this.onAction});

  final IconData icon;
  final String message;
  final String? actionLabel;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 42),
              const SizedBox(height: 12),
              Text(message, textAlign: TextAlign.center),
              if (actionLabel != null && onAction != null) ...[
                const SizedBox(height: 12),
                OutlinedButton(onPressed: onAction, child: Text(actionLabel!)),
              ],
            ],
          ),
        ),
      );
}

String _dateText(DateTime value) => '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
