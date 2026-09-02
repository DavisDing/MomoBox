import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/status_badge.dart';

class ProductDetailScreen extends ConsumerWidget {
  const ProductDetailScreen({super.key, required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final inventory = ref.watch(inventoryProvider);
    return Scaffold(
      appBar: AppBar(title: const Text('商品详情')),
      body: inventory.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => _DetailMessage(
          icon: Icons.error_outline,
          message: '商品详情加载失败：$error',
          actionLabel: '重试',
          onAction: () => ref.invalidate(inventoryProvider),
        ),
        data: (items) {
          final item = _findItem(items, productId);
          if (item == null) {
            return const _DetailMessage(
              icon: Icons.inventory_2_outlined,
              message: '这个商品可能已经不存在了。',
            );
          }
          return _ProductDetailBody(item: item);
        },
      ),
    );
  }

  InventoryItem? _findItem(List<InventoryItem> items, String id) {
    for (final item in items) {
      if (item.id == id) return item;
    }
    return null;
  }
}

class _ProductDetailBody extends ConsumerWidget {
  const _ProductDetailBody({required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final fefoAvailableQuantity = item.activeBatches
        .where((batch) => batch.expiryStatus != ExpiryStatus.expired)
        .fold<int>(0, (sum, batch) => sum + batch.remainingQuantity);
    final datedBatches = item.batches
        .where((batch) => batch.expiryDate != null)
        .toList(growable: false)
      ..sort((left, right) => left.expiryDate!.compareTo(right.expiryDate!));
    final undatedBatches = item.batches
        .where((batch) => batch.expiryDate == null)
        .toList(growable: false);

    return ListView(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
      children: [
        _ProductOverview(item: item),
        const SizedBox(height: 16),
        FilledButton.icon(
          onPressed: fefoAvailableQuantity == 0
              ? null
              : () => _consumeByFefo(
                    context,
                    ref,
                    maxQuantity: fefoAvailableQuantity,
                  ),
          icon: const Icon(Icons.remove),
          label: Text('按最早到期优先消耗（最多 $fefoAvailableQuantity ${item.unit}）'),
        ),
        const SizedBox(height: 24),
        _SectionTitle(
          title: '批次',
          subtitle: '有到期日的批次按到期日升序排列；未设置效期的批次单独归类。',
        ),
        const SizedBox(height: 10),
        if (datedBatches.isNotEmpty) ...[
          const _BatchGroupHeader(
            icon: Icons.event_available_outlined,
            title: '有到期日',
          ),
          const SizedBox(height: 8),
          ...datedBatches.map((batch) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _BatchCard(item: item, batch: batch),
              )),
        ],
        if (undatedBatches.isNotEmpty) ...[
          if (datedBatches.isNotEmpty) const SizedBox(height: 10),
          const _BatchGroupHeader(
            icon: Icons.event_busy_outlined,
            title: '未设置效期',
          ),
          const SizedBox(height: 8),
          ...undatedBatches.map((batch) => Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: _BatchCard(item: item, batch: batch),
              )),
        ],
        if (item.batches.isEmpty) const Text('暂无批次记录。'),
        const SizedBox(height: 18),
        const _SectionTitle(title: '变动历史'),
        const SizedBox(height: 8),
        _MovementHistory(productId: item.id),
      ],
    );
  }

  Future<void> _consumeByFefo(
    BuildContext context,
    WidgetRef ref, {
    required int maxQuantity,
  }) async {
    final quantity = await _showQuantityDialog(
      context,
      title: '按最早到期优先消耗',
      quantityLabel: '消耗数量',
      confirmLabel: '确认消耗',
      unit: item.unit,
      maxQuantity: maxQuantity,
    );
    if (quantity == null || !context.mounted) return;

    try {
      await ref.read(inventoryServiceProvider).consume(item.id, quantity);
      if (context.mounted) {
        _showMessage(context, '已消耗 ${item.name} $quantity ${item.unit}。');
      }
    } catch (error) {
      if (context.mounted) _showMessage(context, '消耗失败：$error');
    }
  }
}

class _ProductOverview extends StatelessWidget {
  const _ProductOverview({required this.item});

  final InventoryItem item;

  @override
  Widget build(BuildContext context) {
    final nearestBatch = item.nearestDatedBatch;
    final theme = Theme.of(context);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(item.name, style: theme.textTheme.headlineSmall),
                      const SizedBox(height: 6),
                      Text(
                        '库存 ${item.totalStock} ${item.unit}',
                        style: theme.textTheme.titleMedium,
                      ),
                    ],
                  ),
                ),
                StatusBadge(
                  status: item.overallExpiryStatus,
                  days: nearestBatch?.daysUntilExpiry,
                ),
              ],
            ),
            if (item.isLowStock) ...[
              const SizedBox(height: 10),
              Text(
                '库存偏低：当前 ${item.totalStock} ${item.unit}，阈值 ${item.lowStockThreshold} ${item.unit}',
                style: TextStyle(
                  color: theme.colorScheme.error,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ],
            const SizedBox(height: 16),
            const Divider(height: 1),
            const SizedBox(height: 10),
            _InfoRow(label: '分类', value: item.category),
            _InfoRow(label: '品牌', value: _textOrPlaceholder(item.brand)),
            _InfoRow(label: '规格', value: _textOrPlaceholder(item.specification)),
            _InfoRow(label: '条码', value: _textOrPlaceholder(item.barcode)),
            _InfoRow(label: '存放位置', value: _textOrPlaceholder(item.location)),
            _InfoRow(label: '计量单位', value: item.unit),
            _InfoRow(label: '低库存阈值', value: '${item.lowStockThreshold} ${item.unit}'),
          ],
        ),
      ),
    );
  }
}

class _InfoRow extends StatelessWidget {
  const _InfoRow({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 5),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 82,
              child: Text(label, style: Theme.of(context).textTheme.bodySmall),
            ),
            Expanded(child: SelectableText(value)),
          ],
        ),
      );
}

class _SectionTitle extends StatelessWidget {
  const _SectionTitle({required this.title, this.subtitle});

  final String title;
  final String? subtitle;

  @override
  Widget build(BuildContext context) => Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleLarge),
          if (subtitle != null) ...[
            const SizedBox(height: 4),
            Text(subtitle!, style: Theme.of(context).textTheme.bodySmall),
          ],
        ],
      );
}

class _BatchGroupHeader extends StatelessWidget {
  const _BatchGroupHeader({required this.icon, required this.title});

  final IconData icon;
  final String title;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 18),
          const SizedBox(width: 6),
          Text(title, style: Theme.of(context).textTheme.titleMedium),
        ],
      );
}

class _BatchCard extends ConsumerWidget {
  const _BatchCard({required this.item, required this.batch});

  final InventoryItem item;
  final InventoryBatch batch;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final canConsume = batch.isAvailable && batch.expiryStatus != ExpiryStatus.expired;
    final canReplenish = !batch.isDiscarded;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(batch.batchNo ?? '未填写批次号', style: Theme.of(context).textTheme.titleSmall),
                  const SizedBox(height: 4),
                  Text('生产日期：${_dateOrPlaceholder(batch.productionDate)}'),
                  Text('到期日期：${_dateOrPlaceholder(batch.expiryDate)}'),
                  const SizedBox(height: 4),
                  Text('剩余 ${batch.remainingQuantity} / 初始 ${batch.initialQuantity} ${item.unit}'),
                  const SizedBox(height: 7),
                  _BatchStatus(status: _batchStatus(batch)),
                ],
              ),
            ),
            PopupMenuButton<_BatchAction>(
              tooltip: '批次操作',
              onSelected: (action) => _performAction(context, ref, action),
              itemBuilder: (context) => [
                PopupMenuItem(
                  value: _BatchAction.consume,
                  enabled: canConsume,
                  child: Text(canConsume ? '消耗指定数量' : '该批次不可消耗'),
                ),
                PopupMenuItem(
                  value: _BatchAction.replenish,
                  enabled: canReplenish,
                  child: Text(canReplenish ? '补充指定数量' : '已报废批次不能补充'),
                ),
                PopupMenuItem(
                  value: _BatchAction.discard,
                  enabled: !batch.isDiscarded,
                  child: Text(batch.isDiscarded ? '批次已报废' : '报废批次'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _performAction(
    BuildContext context,
    WidgetRef ref,
    _BatchAction action,
  ) async {
    try {
      switch (action) {
        case _BatchAction.consume:
          final quantity = await _showQuantityDialog(
            context,
            title: '消耗指定批次',
            quantityLabel: '消耗数量',
            confirmLabel: '确认消耗',
            unit: item.unit,
            maxQuantity: batch.remainingQuantity,
          );
          if (quantity == null || !context.mounted) return;
          await ref.read(inventoryServiceProvider).consumeBatch(item.id, batch.id, quantity);
          if (context.mounted) _showMessage(context, '已消耗 $quantity ${item.unit}。');
          return;
        case _BatchAction.replenish:
          final quantity = await _showQuantityDialog(
            context,
            title: '补充批次',
            quantityLabel: '补充数量',
            confirmLabel: '确认补充',
            unit: item.unit,
          );
          if (quantity == null || !context.mounted) return;
          await ref.read(inventoryServiceProvider).replenishBatch(batch.id, quantity);
          if (context.mounted) _showMessage(context, '已补充 $quantity ${item.unit}。');
          return;
        case _BatchAction.discard:
          final confirmed = await _showDiscardConfirmationDialog(
            context,
            item: item,
            batch: batch,
          );
          if (!confirmed || !context.mounted) return;
          await ref.read(inventoryServiceProvider).discardBatch(batch.id);
          if (context.mounted) _showMessage(context, '批次已报废。');
          return;
      }
    } catch (error) {
      if (context.mounted) _showMessage(context, '操作失败：$error');
    }
  }
}

enum _BatchAction { consume, replenish, discard }

class _BatchStatus extends StatelessWidget {
  const _BatchStatus({required this.status});

  final _BatchState status;

  @override
  Widget build(BuildContext context) {
    final colorScheme = Theme.of(context).colorScheme;
    final color = switch (status) {
      _BatchState.discarded || _BatchState.usedUp => colorScheme.outline,
      _BatchState.expired => colorScheme.error,
      _BatchState.expiring => Colors.orange,
      _BatchState.noExpiry => colorScheme.secondary,
      _BatchState.available => Colors.green,
    };
    return Text(
      status.label,
      style: TextStyle(color: color, fontWeight: FontWeight.w600, fontSize: 12),
    );
  }
}

enum _BatchState {
  available('在库'),
  expiring('临期'),
  expired('已过期'),
  usedUp('已用完'),
  discarded('已报废'),
  noExpiry('未设置效期');

  const _BatchState(this.label);

  final String label;
}

_BatchState _batchStatus(InventoryBatch batch) {
  if (batch.isDiscarded) return _BatchState.discarded;
  if (batch.remainingQuantity == 0) return _BatchState.usedUp;
  return switch (batch.expiryStatus) {
    ExpiryStatus.expired => _BatchState.expired,
    ExpiryStatus.expiring => _BatchState.expiring,
    ExpiryStatus.noExpiry => _BatchState.noExpiry,
    ExpiryStatus.safe => _BatchState.available,
  };
}

class _MovementHistory extends ConsumerWidget {
  const _MovementHistory({required this.productId});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) => FutureBuilder<List<StockMovement>>(
        future: ref.read(inventoryServiceProvider).loadMovements(productId),
        builder: (context, snapshot) {
          if (snapshot.connectionState == ConnectionState.waiting) {
            return const Center(child: Padding(padding: EdgeInsets.all(12), child: CircularProgressIndicator()));
          }
          if (snapshot.hasError) return Text('历史加载失败：${snapshot.error}');
          final movements = snapshot.data ?? const <StockMovement>[];
          if (movements.isEmpty) return const Text('暂无变动记录。');
          return Column(
            children: movements
                .take(20)
                .map(
                  (movement) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: Icon(
                      movement.quantity < 0 ? Icons.remove_circle_outline : Icons.add_circle_outline,
                    ),
                    title: Text(movement.note ?? movement.type),
                    subtitle: Text(_dateTimeText(movement.createdAt)),
                    trailing: Text(movement.quantity > 0 ? '+${movement.quantity}' : '${movement.quantity}'),
                  ),
                )
                .toList(growable: false),
          );
        },
      );
}

class _DetailMessage extends StatelessWidget {
  const _DetailMessage({
    required this.icon,
    required this.message,
    this.actionLabel,
    this.onAction,
  });

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

Future<int?> _showQuantityDialog(
  BuildContext context, {
  required String title,
  required String quantityLabel,
  required String confirmLabel,
  required String unit,
  int? maxQuantity,
}) async {
  final controller = TextEditingController(text: '1');
  try {
    return await showDialog<int>(
      context: context,
      builder: (context) {
        String? errorText;
        return StatefulBuilder(
          builder: (context, setState) => AlertDialog(
            title: Text(title),
            content: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.number,
              decoration: InputDecoration(
                labelText: maxQuantity == null
                    ? '$quantityLabel（$unit）'
                    : '$quantityLabel（最多 $maxQuantity $unit）',
                errorText: errorText,
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () {
                  final quantity = int.tryParse(controller.text.trim());
                  if (quantity == null || quantity < 1) {
                    setState(() => errorText = '请输入大于 0 的整数。');
                    return;
                  }
                  if (maxQuantity != null && quantity > maxQuantity) {
                    setState(() => errorText = '数量不能超过当前可消耗库存。');
                    return;
                  }
                  Navigator.pop(context, quantity);
                },
                child: Text(confirmLabel),
              ),
            ],
          ),
        );
      },
    );
  } finally {
    controller.dispose();
  }
}

Future<bool> _showDiscardConfirmationDialog(
  BuildContext context, {
  required InventoryItem item,
  required InventoryBatch batch,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('确认报废批次？'),
        content: Text(
          '${item.name} · ${batch.batchNo ?? '未填写批次'} 还剩 ${batch.remainingQuantity} ${item.unit}。报废后库存将清零且不能恢复。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('取消'),
          ),
          FilledButton.tonal(
            onPressed: () => Navigator.pop(context, true),
            child: const Text('确认报废'),
          ),
        ],
      ),
    ) ??
    false;

String _textOrPlaceholder(String? value) {
  final normalized = value?.trim();
  return normalized == null || normalized.isEmpty ? '未填写' : normalized;
}

String _dateOrPlaceholder(DateTime? date) => date == null ? '未设置效期' : _dateText(date);

String _dateText(DateTime date) =>
    '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

String _dateTimeText(DateTime value) =>
    '${_dateText(value)} ${value.hour.toString().padLeft(2, '0')}:${value.minute.toString().padLeft(2, '0')}';

void _showMessage(BuildContext context, String message) {
  ScaffoldMessenger.of(context)
    ..hideCurrentSnackBar()
    ..showSnackBar(SnackBar(content: Text(message)));
}
