import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/status_badge.dart';

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _query = '';
  String _category = '全部';
  String _status = '全部';

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(inventoryProvider);
    final summary = ref.watch(reminderSummaryProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('嬷嬷的小箱子'),
            Text('单机模式 · 本地 SQLite', style: TextStyle(fontSize: 12, fontWeight: FontWeight.normal)),
          ],
        ),
      ),
      body: inventory.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _ErrorState(message: '本地数据库暂时不可用：$error'),
        data: (items) {
          final categories = {'全部', ...items.map((item) => item.category)}.toList();
          final filtered = items.where((item) {
            final normalized = _query.trim().toLowerCase();
            final matchesQuery = normalized.isEmpty ||
                [item.name, item.brand, item.location, item.barcode]
                    .whereType<String>()
                    .any((value) => value.toLowerCase().contains(normalized));
            final matchesCategory = _category == '全部' || item.category == _category;
            final matchesStatus = switch (_status) {
              '临期' => item.overallExpiryStatus == ExpiryStatus.expiring,
              '已过期' => item.overallExpiryStatus == ExpiryStatus.expired,
              '低库存' => item.isLowStock,
              _ => true,
            };
            return matchesQuery && matchesCategory && matchesStatus;
          }).toList();

          return RefreshIndicator(
            onRefresh: () async => ref.invalidate(inventoryProvider),
            child: ListView(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 104),
              children: [
                _SummaryCard(summary: summary),
                const SizedBox(height: 14),
                TextField(
                  decoration: const InputDecoration(
                    hintText: '搜索名称、品牌、位置或条码',
                    prefixIcon: Icon(Icons.search),
                  ),
                  onChanged: (value) => setState(() => _query = value),
                ),
                const SizedBox(height: 12),
                _FilterRow(
                  values: categories,
                  current: _category,
                  onChanged: (value) => setState(() => _category = value),
                ),
                const SizedBox(height: 8),
                _FilterRow(
                  values: const ['全部', '临期', '已过期', '低库存'],
                  current: _status,
                  onChanged: (value) => setState(() => _status = value),
                ),
                const SizedBox(height: 12),
                if (filtered.isEmpty)
                  _EmptyInventory(hasItems: items.isNotEmpty)
                else
                  ...filtered.map((item) => Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: _InventoryCard(item: item),
                      )),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _SummaryCard extends StatelessWidget {
  const _SummaryCard({required this.summary});
  final ReminderSummary summary;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Card(
      color: theme.colorScheme.primaryContainer,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            const Text('📦', style: TextStyle(fontSize: 36)),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                '有 ${summary.expiring.length + summary.expired.length} 项效期提醒，${summary.lowStock.length} 项库存偏低。',
                style: theme.textTheme.titleSmall,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterRow extends StatelessWidget {
  const _FilterRow({required this.values, required this.current, required this.onChanged});
  final List<String> values;
  final String current;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        children: values
            .map(
              (value) => Padding(
                padding: const EdgeInsets.only(right: 8),
                child: ChoiceChip(
                  label: Text(value),
                  selected: current == value,
                  onSelected: (_) => onChanged(value),
                ),
              ),
            )
            .toList(),
      ),
    );
  }
}

class _InventoryCard extends ConsumerWidget {
  const _InventoryCard({required this.item});
  final InventoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final batch = item.nearestDatedBatch;
    return Card(
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => showModalBottomSheet<void>(
          context: context,
          isScrollControlled: true,
          builder: (_) => _ItemDetailSheet(item: item),
        ),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 48,
                height: 48,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.secondaryContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(_categoryEmoji(item.category), style: const TextStyle(fontSize: 24)),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(item.name, style: Theme.of(context).textTheme.titleMedium),
                    const SizedBox(height: 3),
                    Text(
                      '${item.totalStock} ${item.unit} · ${item.location ?? '未设置位置'} · ${item.batches.length} 个批次',
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                    if (item.isLowStock) ...[
                      const SizedBox(height: 5),
                      const Text('库存偏低', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold, fontSize: 12)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 8),
              StatusBadge(status: item.overallExpiryStatus, days: batch?.daysUntilExpiry),
            ],
          ),
        ),
      ),
    );
  }
}

class _ItemDetailSheet extends ConsumerWidget {
  const _ItemDetailSheet({required this.item});
  final InventoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return SafeArea(
      top: false,
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: .72,
        minChildSize: .5,
        builder: (context, controller) => Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(24)),
          child: ListView(
            controller: controller,
            padding: const EdgeInsets.all(20),
            children: [
              Text(item.name, style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 4),
              Text('${item.category} · ${item.totalStock} ${item.unit} · ${item.location ?? '未设置位置'}'),
              const SizedBox(height: 16),
              FilledButton.icon(
                onPressed: item.totalStock == 0
                    ? null
                    : () async {
                        try {
                          await ref.read(inventoryServiceProvider).consume(item.id, 1);
                          if (context.mounted) Navigator.pop(context);
                        } catch (error) {
                          if (context.mounted) {
                            ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
                          }
                        }
                      },
                icon: const Icon(Icons.remove),
                label: const Text('按最早到期优先消耗 1 件'),
              ),
              const SizedBox(height: 16),
              Text('批次', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              ...item.batches.map((batch) => _BatchTile(item: item, batch: batch)),
              const SizedBox(height: 16),
              Text('变动历史', style: Theme.of(context).textTheme.titleMedium),
              const SizedBox(height: 8),
              FutureBuilder<List<StockMovement>>(
                future: ref.read(inventoryRepositoryProvider).loadMovements(item.id),
                builder: (context, snapshot) {
                  if (snapshot.connectionState == ConnectionState.waiting) {
                    return const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()));
                  }
                  if (snapshot.hasError) return Text('历史加载失败：${snapshot.error}');
                  final movements = snapshot.data ?? const <StockMovement>[];
                  if (movements.isEmpty) return const Text('暂无变动记录。');
                  return Column(children: movements.take(20).map((movement) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(movement.quantity < 0 ? Icons.remove_circle_outline : Icons.add_circle_outline),
                    title: Text(movement.note ?? movement.type),
                    subtitle: Text(_dateTimeText(movement.createdAt)),
                    trailing: Text(movement.quantity > 0 ? '+${movement.quantity}' : '${movement.quantity}'),
                  )).toList());
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _BatchTile extends ConsumerWidget {
  const _BatchTile({required this.item, required this.batch});
  final InventoryItem item;
  final InventoryBatch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final expiry = batch.expiryDate == null ? '未设置效期' : _dateText(batch.expiryDate!);
    return Card(
      child: ListTile(
        title: Text('${batch.batchNo ?? '未填写批次'} · $expiry'),
        subtitle: Text('剩余 ${batch.remainingQuantity}/${batch.initialQuantity} ${item.unit}${batch.isDiscarded ? ' · 已报废' : ''}'),
        trailing: PopupMenuButton<String>(
          onSelected: (action) async {
            try {
              if (action == 'add') await ref.read(inventoryServiceProvider).replenishBatch(batch.id, 1);
              if (action == 'discard') await ref.read(inventoryServiceProvider).discardBatch(batch.id);
            } catch (error) {
              if (context.mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
            }
          },
          itemBuilder: (context) => [
            const PopupMenuItem(value: 'add', child: Text('+1 补充')),
            const PopupMenuItem(value: 'discard', child: Text('报废批次')),
          ],
        ),
      ),
    );
  }
}

class _EmptyInventory extends StatelessWidget {
  const _EmptyInventory({required this.hasItems});
  final bool hasItems;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            const Text('📦', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 10),
            Text(hasItems ? '没有符合筛选条件的物品' : '箱中空空如也，点击右下角开始入库。'),
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message});
  final String message;
  @override
  Widget build(BuildContext context) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(message)));
}

String _categoryEmoji(String category) => switch (category) {
      '药品保健' => '💊',
      '食品生鲜' => '🥛',
      '美妆个护' => '🧴',
      '母婴用品' => '🧸',
      _ => '📦',
    };

String _dateText(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _dateTimeText(DateTime value) => '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';
