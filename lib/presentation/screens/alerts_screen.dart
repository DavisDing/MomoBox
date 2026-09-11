import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/inventory/reminder_rules.dart';
import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/status_badge.dart';

class AlertsScreen extends ConsumerStatefulWidget {
  const AlertsScreen({this.initialFilter, super.key});

  /// 支持从首页点击不同卡片携带初始过滤条件：'expired' | 'expiring' | 'low_stock'
  final String? initialFilter;

  @override
  ConsumerState<AlertsScreen> createState() => _AlertsScreenState();
}

class _AlertsScreenState extends ConsumerState<AlertsScreen> {
  late String _currentFilter;

  @override
  void initState() {
    super.initState();
    _currentFilter = widget.initialFilter ?? 'all';
  }

  @override
  Widget build(BuildContext context) {
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
          final hasAlerts =
              summary.expired.isNotEmpty || summary.expiring.isNotEmpty || summary.lowStock.isNotEmpty;
          if (!hasAlerts) return const _EmptyAlerts();

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _AlertDashboard(
                summary: summary,
                activeFilter: _currentFilter,
                onFilterSelected: (filter) {
                  setState(() {
                    _currentFilter = filter;
                  });
                },
              ),
              const SizedBox(height: 16),

              // 过滤条件筛选胶囊
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    ChoiceChip(
                      label: Text('全部提醒 (${summary.expired.length + summary.expiring.length + summary.lowStock.length})'),
                      selected: _currentFilter == 'all',
                      onSelected: (val) => setState(() => _currentFilter = 'all'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('已过期 (${summary.expired.length})'),
                      selected: _currentFilter == 'expired',
                      onSelected: (val) => setState(() => _currentFilter = val ? 'expired' : 'all'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('临期 (${summary.expiring.length})'),
                      selected: _currentFilter == 'expiring',
                      onSelected: (val) => setState(() => _currentFilter = val ? 'expiring' : 'all'),
                    ),
                    const SizedBox(width: 8),
                    ChoiceChip(
                      label: Text('低库存 (${summary.lowStock.length})'),
                      selected: _currentFilter == 'low_stock',
                      onSelected: (val) => setState(() => _currentFilter = val ? 'low_stock' : 'all'),
                    ),
                  ],
                ),
              ),

              const SizedBox(height: 20),

              if (_currentFilter == 'all' || _currentFilter == 'expired')
                _AlertSection(
                  title: '已过期',
                  color: Colors.red,
                  items: summary.expired,
                  type: ReminderType.expired,
                  suggestion: '建议：尽快核对并报废，避免继续使用。',
                ),

              if (_currentFilter == 'all' || _currentFilter == 'expiring')
                _AlertSection(
                  title: '30 天内临期',
                  color: Colors.orange,
                  items: summary.expiring,
                  type: ReminderType.expiring,
                  suggestion: '建议：优先使用临近到期批次，必要时加入采购。',
                ),

              if (_currentFilter == 'all' || _currentFilter == 'low_stock')
                _AlertSection(
                  title: '低库存',
                  color: Colors.blue,
                  items: summary.lowStock,
                  type: ReminderType.lowStock,
                  showStock: true,
                  suggestion: '建议：确认用量后及时补货，避免断货。',
                ),
            ],
          );
        },
      ),
    );
  }
}

class _EmptyAlerts extends StatelessWidget {
  const _EmptyAlerts();

  @override
  Widget build(BuildContext context) => Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('✨', style: TextStyle(fontSize: 48)),
            const SizedBox(height: 12),
            Text('当前无待处理提醒。', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 4),
            const Text('库存与效期状态都很安心。'),
          ],
        ),
      );
}

class _AlertDashboard extends StatelessWidget {
  const _AlertDashboard({
    required this.summary,
    required this.activeFilter,
    required this.onFilterSelected,
  });

  final ReminderSummary summary;
  final String activeFilter;
  final ValueChanged<String> onFilterSelected;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final expiringSoon = summary.expiringWithinDays(3);
    final (mascot, message, color) = switch ((summary.expired.isNotEmpty, expiringSoon > 0)) {
      (true, _) => ('🚨', '发现过期物品，请优先处理。', theme.colorScheme.error),
      (false, true) => ('⏰', '有物品即将到期，记得优先使用。', Colors.orange),
      _ => ('🧺', '留意库存，按需补货即可。', theme.colorScheme.primary),
    };

    return Card(
      color: theme.colorScheme.surfaceContainerHighest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text(mascot, style: const TextStyle(fontSize: 42)),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    message,
                    style: theme.textTheme.titleMedium?.copyWith(color: color),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  child: _StatTile(
                    label: '已过期',
                    value: summary.expired.length,
                    color: theme.colorScheme.error,
                    isSelected: activeFilter == 'expired',
                    onTap: () => onFilterSelected('expired'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatTile(
                    label: '3 天内到期',
                    value: expiringSoon,
                    color: Colors.orange,
                    isSelected: activeFilter == 'expiring',
                    onTap: () => onFilterSelected('expiring'),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: _StatTile(
                    label: '低库存',
                    value: summary.lowStock.length,
                    color: Colors.blue,
                    isSelected: activeFilter == 'low_stock',
                    onTap: () => onFilterSelected('low_stock'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({
    required this.label,
    required this.value,
    required this.color,
    this.isSelected = false,
    this.onTap,
  });

  final String label;
  final int value;
  final Color color;
  final bool isSelected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected ? color.withValues(alpha: 0.15) : Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          border: isSelected ? Border.all(color: color.withValues(alpha: 0.4)) : null,
        ),
        child: Column(
          children: [
            Text(
              '$value',
              style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                    color: color,
                    fontWeight: FontWeight.bold,
                  ),
            ),
            const SizedBox(height: 4),
            Text(label, style: Theme.of(context).textTheme.bodySmall),
          ],
        ),
      ),
    );
  }
}

class _AlertSection extends ConsumerWidget {
  const _AlertSection({
    required this.title,
    required this.color,
    required this.items,
    required this.type,
    required this.suggestion,
    this.showStock = false,
  });

  final String title;
  final Color color;
  final List<InventoryItem> items;
  final ReminderType type;
  final String suggestion;
  final bool showStock;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (items.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text('$title · ${items.length}', style: Theme.of(context).textTheme.titleMedium?.copyWith(color: color)),
              ),
              TextButton(
                onPressed: () => _acknowledgeAll(context, ref),
                child: const Text('全部标记已处理'),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(suggestion, style: Theme.of(context).textTheme.bodySmall),
          ),
          ...items.map((item) {
            final batch = item.nearestDatedBatch;
            return Card(
              child: ListTile(
                leading: IconButton(
                  tooltip: '标记已处理',
                  onPressed: () => _acknowledge(context, ref, item),
                  icon: const Icon(Icons.check_circle_outline),
                  color: color,
                ),
                title: Text(item.name),
                subtitle: Text(_itemSuggestion(item, batch)),
                trailing: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    IconButton(
                      tooltip: '加入采购',
                      onPressed: () => _addToShopping(context, ref, item),
                      icon: const Icon(Icons.add_shopping_cart_outlined),
                    ),
                    if (!showStock) StatusBadge(status: item.overallExpiryStatus, days: batch?.daysUntilExpiry),
                  ],
                ),
              ),
            );
          }),
        ],
      ),
    );
  }

  String _itemSuggestion(InventoryItem item, InventoryBatch? batch) {
    if (showStock) return '剩余 ${item.totalStock}，阈值 ${item.lowStockThreshold}；建议补货。';
    final days = batch?.daysUntilExpiry;
    if (days == null) return '请核对最近批次的效期。';
    if (days < 0) return '已于 ${_dateText(batch!.expiryDate!)} 到期；建议尽快处理。';
    if (days == 0) return '今天到期；建议优先使用或处理。';
    return '$days 天后到期；建议优先使用该批次。';
  }

  Future<void> _acknowledge(BuildContext context, WidgetRef ref, InventoryItem item) async {
    try {
      final candidate = _candidateFor(item);
      await ref.read(reminderServiceProvider).acknowledge(
            reminderKey: candidate.key,
            fingerprint: candidate.fingerprint,
          );
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('标记提醒失败：$error')),
        );
      }
    }
  }

  Future<void> _acknowledgeAll(BuildContext context, WidgetRef ref) async {
    try {
      final reminders = items.map((item) {
        final candidate = _candidateFor(item);
        return (reminderKey: candidate.key, fingerprint: candidate.fingerprint);
      });
      await ref.read(reminderServiceProvider).acknowledgeAll(reminders);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已将 $title 提醒标记为已处理。')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('批量标记失败：$error')),
        );
      }
    }
  }

  ReminderCandidate _candidateFor(InventoryItem item) =>
      ReminderRules.candidates([item]).firstWhere((candidate) => candidate.type == type);
}

Future<void> _addToShopping(
  BuildContext context,
  WidgetRef ref,
  InventoryItem item,
) async {
  final targetQuantity = item.lowStockThreshold > item.totalStock
      ? item.lowStockThreshold - item.totalStock
      : 1;
  try {
    await ref.read(shoppingServiceProvider).addOrMerge(
          itemName: item.name,
          targetQuantity: targetQuantity,
          reason: '来自库存提醒',
          productId: item.id,
          category: item.category,
        );
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已将${item.name}加入采购清单。')),
      );
    }
  } catch (error) {
    if (context.mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('加入采购清单失败：$error')),
      );
    }
  }
}

String _dateText(DateTime value) =>
    '${value.year.toString().padLeft(4, '0')}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
