import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/status_badge.dart';

class AlertsScreen extends ConsumerWidget {
  const AlertsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(inventoryProvider);
    final summary = ref.watch(reminderSummaryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('效期与库存提醒')),
      body: inventory.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('提醒数据加载失败：$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(inventoryProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (_) {
          if (summary.expired.isEmpty && summary.expiring.isEmpty && summary.lowStock.isEmpty) {
            return const Center(child: Text('当前无待处理提醒。'));
          }
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AlertSection(title: '已过期', color: Colors.red, items: summary.expired),
              _AlertSection(title: '30 天内临期', color: Colors.orange, items: summary.expiring),
              _AlertSection(title: '低库存', color: Colors.blue, items: summary.lowStock, showStock: true),
            ],
          );
        },
      ),
    );
  }
}

class _AlertSection extends StatelessWidget {
  const _AlertSection({required this.title, required this.color, required this.items, this.showStock = false});
  final String title;
  final Color color;
  final List<InventoryItem> items;
  final bool showStock;

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text('$title · ${items.length}', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
          const SizedBox(height: 8),
          ...items.map((item) {
            final batch = item.nearestDatedBatch;
            return Card(
              child: ListTile(
                leading: Icon(showStock ? Icons.inventory_2_outlined : Icons.event_busy, color: color),
                title: Text(item.name),
                subtitle: Text(showStock ? '剩余 ${item.totalStock}，阈值 ${item.lowStockThreshold}' : '优先处理最近批次，避免继续消耗。'),
                trailing: showStock ? null : StatusBadge(status: item.overallExpiryStatus, days: batch?.daysUntilExpiry),
              ),
            );
          }),
        ],
      ),
    );
  }
}
