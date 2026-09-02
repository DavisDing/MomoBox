import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/inventory/inventory_sorting.dart';
import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/intake_sheet.dart';
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
  InventorySortOption _sortOption = InventorySortOption.expirySoonest;

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
        error: (error, _) => _ErrorState(
          message: '本地数据库暂时不可用：$error',
          onRetry: () => ref.invalidate(inventoryProvider),
        ),
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
          final sorted = sortInventoryItems(filtered, _sortOption);

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
                Align(
                  alignment: Alignment.centerRight,
                  child: _SortSelector(
                    current: _sortOption,
                    onSelected: (value) => setState(() => _sortOption = value),
                  ),
                ),
                const SizedBox(height: 8),
                if (sorted.isEmpty)
                  _EmptyInventory(
                    hasItems: items.isNotEmpty,
                    onAdd: items.isEmpty
                        ? () => showModalBottomSheet<void>(
                              context: context,
                              isScrollControlled: true,
                              useSafeArea: true,
                              builder: (_) => const IntakeSheet(),
                            )
                        : null,
                  )
                else
                  ...sorted.map((item) => Padding(
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

class _SortSelector extends StatelessWidget {
  const _SortSelector({required this.current, required this.onSelected});

  final InventorySortOption current;
  final ValueChanged<InventorySortOption> onSelected;

  @override
  Widget build(BuildContext context) => PopupMenuButton<InventorySortOption>(
        tooltip: '选择排序方式',
        onSelected: onSelected,
        itemBuilder: (context) => InventorySortOption.values
            .map(
              (option) => PopupMenuItem(
                value: option,
                child: Row(
                  children: [
                    if (option == current)
                      const Icon(Icons.check, size: 18)
                    else
                      const SizedBox(width: 18),
                    const SizedBox(width: 8),
                    Text(option.label),
                  ],
                ),
              ),
            )
            .toList(growable: false),
        child: Chip(
          avatar: const Icon(Icons.sort, size: 18),
          label: Text('排序：${current.label}'),
        ),
      );
}

class _InventoryCard extends ConsumerStatefulWidget {
  const _InventoryCard({required this.item});
  final InventoryItem item;

  @override
  ConsumerState<_InventoryCard> createState() => _InventoryCardState();
}

class _InventoryCardState extends ConsumerState<_InventoryCard> {
  bool _actionsVisible = false;
  bool _busy = false;

  InventoryItem get item => widget.item;

  @override
  Widget build(BuildContext context) {
    final batch = item.nearestDatedBatch;
    final canConsume = item.activeBatches.any(
      (candidate) => candidate.expiryStatus != ExpiryStatus.expired,
    );
    final canReplenish = item.batches.any((candidate) => !candidate.isDiscarded);
    return GestureDetector(
      onHorizontalDragEnd: (details) {
        final velocity = details.primaryVelocity ?? 0;
        if (velocity < -80) {
          setState(() => _actionsVisible = true);
        } else if (velocity > 80) {
          setState(() => _actionsVisible = false);
        }
      },
      child: Row(
        children: [
          Expanded(
            child: Card(
              clipBehavior: Clip.antiAlias,
              child: InkWell(
                onTap: () {
                  if (_actionsVisible) {
                    setState(() => _actionsVisible = false);
                    return;
                  }
                  context.push('/inventory/${item.id}');
                },
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
            ),
          ),
          if (_actionsVisible) ...[
            const SizedBox(width: 4),
            _QuickActions(
              busy: _busy,
              canConsume: canConsume,
              canReplenish: canReplenish,
              onConsume: () => _consumeOne(context),
              onReplenish: () => _replenishOne(context),
              onShopping: () => _addToShopping(context),
              onClose: () => setState(() => _actionsVisible = false),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _consumeOne(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(inventoryServiceProvider).consume(item.id, 1);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已消耗 ${item.name} 1 ${item.unit}。')),
        );
        setState(() => _actionsVisible = false);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('快速消耗失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _replenishOne(BuildContext context) async {
    if (_busy) return;
    final candidates = item.batches.where((batch) => !batch.isDiscarded).toList(growable: false);
    if (candidates.isEmpty) return;
    final batch = candidates.length == 1 ? candidates.single : await _selectReplenishBatch(context, candidates);
    if (batch == null || !mounted) return;

    setState(() => _busy = true);
    try {
      await ref.read(inventoryServiceProvider).replenishBatch(batch.id, 1);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已补充 ${item.name} 1 ${item.unit}。')),
        );
        setState(() => _actionsVisible = false);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('快速补充失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _addToShopping(BuildContext context) async {
    if (_busy) return;
    final targetQuantity = item.lowStockThreshold > item.totalStock
        ? item.lowStockThreshold - item.totalStock
        : 1;
    setState(() => _busy = true);
    try {
      await ref.read(shoppingServiceProvider).addOrMerge(
            itemName: item.name,
            targetQuantity: targetQuantity,
            reason: '来自库存快捷操作',
            productId: item.id,
            category: item.category,
          );
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 ${item.name} 加入采购清单。')),
        );
        setState(() => _actionsVisible = false);
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('加入采购失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }
}

class _QuickActions extends StatelessWidget {
  const _QuickActions({
    required this.busy,
    required this.canConsume,
    required this.canReplenish,
    required this.onConsume,
    required this.onReplenish,
    required this.onShopping,
    required this.onClose,
  });

  final bool busy;
  final bool canConsume;
  final bool canReplenish;
  final VoidCallback onConsume;
  final VoidCallback onReplenish;
  final VoidCallback onShopping;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    return Card(
      margin: EdgeInsets.zero,
      color: colorScheme.surfaceContainerHighest,
      child: SizedBox(
        width: 156,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Expanded(
              child: IconButton(
                tooltip: '快速消耗 1 件',
                onPressed: busy || !canConsume ? null : onConsume,
                icon: const Icon(Icons.remove_circle_outline),
              ),
            ),
            Expanded(
              child: IconButton(
                tooltip: '快速补充 1 件',
                onPressed: busy || !canReplenish ? null : onReplenish,
                icon: const Icon(Icons.add_circle_outline),
              ),
            ),
            Expanded(
              child: IconButton(
                tooltip: '加入采购清单',
                onPressed: busy ? null : onShopping,
                icon: const Icon(Icons.add_shopping_cart_outlined),
              ),
            ),
            IconButton(
              tooltip: '收起快捷操作',
              onPressed: busy ? null : onClose,
              icon: const Icon(Icons.close, size: 18),
            ),
          ],
        ),
      ),
    );
  }
}

Future<InventoryBatch?> _selectReplenishBatch(
  BuildContext context,
  List<InventoryBatch> batches,
) {
  return showDialog<InventoryBatch>(
    context: context,
    builder: (dialogContext) => SimpleDialog(
      title: const Text('选择要补充的批次'),
      children: batches
          .map(
            (batch) => SimpleDialogOption(
              onPressed: () => Navigator.pop(dialogContext, batch),
              child: Text(
                '${batch.batchNo ?? '未填写批次'} · 剩余 ${batch.remainingQuantity} · ${batch.expiryDate == null ? '无到期日' : _dateText(batch.expiryDate!)}',
              ),
            ),
          )
          .toList(),
    ),
  );
}

class _EmptyInventory extends StatelessWidget {
  const _EmptyInventory({required this.hasItems, this.onAdd});
  final bool hasItems;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          children: [
            const Text('📦', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 10),
            Text(hasItems ? '没有符合筛选条件的物品' : '箱中空空如也'),
            if (!hasItems && onAdd != null) ...[
              const SizedBox(height: 12),
              FilledButton.icon(
                onPressed: onAdd,
                icon: const Icon(Icons.add_box_outlined),
                label: const Text('开始入库'),
              ),
            ],
          ],
        ),
      );
}

class _ErrorState extends StatelessWidget {
  const _ErrorState({required this.message, required this.onRetry});
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(message, textAlign: TextAlign.center),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: onRetry,
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
      );
}

String _categoryEmoji(String category) => switch (category) {
      '药品保健' => '💊',
      '食品生鲜' => '🥛',
      '美妆个护' => '🧴',
      '母婴用品' => '🧸',
      _ => '📦',
    };

String _dateText(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
