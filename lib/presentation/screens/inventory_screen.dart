import '../widgets/momo_mobile_layout.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/momo_components.dart';
import '../../app/momo_typography.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../widgets/app_feedback.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/inventory/inventory_sorting.dart';
import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/intake_sheet.dart';
import '../widgets/status_badge.dart';
import '../widgets/momo_product_image.dart';

class InventoryScreen extends ConsumerStatefulWidget {
  const InventoryScreen({super.key});

  @override
  ConsumerState<InventoryScreen> createState() => _InventoryScreenState();
}

class _InventoryScreenState extends ConsumerState<InventoryScreen> {
  String _query = '';
  String _category = '全部';
  bool _showAnomalies = false;
  InventorySortOption _sortOption = InventorySortOption.expirySoonest;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _openIntake() => showModalBottomSheet<void>(
    context: context, isScrollControlled: true, useSafeArea: true,
    builder: (_) => const IntakeSheet(),
  );

  @override
  Widget build(BuildContext context) {
    final inventory = ref.watch(inventoryProvider);
    final summary = ref.watch(reminderSummaryProvider);
    final insets = MomoMobileLayout.pageInsets(context);
    return Scaffold(
      body: SafeArea(
        left: false, right: false, bottom: false,
        child: inventory.when(
          loading: () => const Center(child: CircularProgressIndicator()),
          error: (error, _) => _ErrorState(
            message: '本地数据库暂时不可用，请重试。',
            onRetry: () => ref.invalidate(inventoryProvider),
          ),
          data: (items) {
            final categories = {'全部', ...items.map((item) => item.category)}.toList();
            final activeCategory = categories.contains(_category) ? _category : '全部';
            final filtered = items.where((item) {
              final normalized = _query.trim().toLowerCase();
              final matchesQuery = normalized.isEmpty ||
                  [item.name, item.brand, item.location, item.barcode]
                      .whereType<String>()
                      .any((value) => value.toLowerCase().contains(normalized));
              final matchesCategory = activeCategory == '全部' || item.category == activeCategory;
              final matchesAnomaly = !_showAnomalies || item.isLowStock ||
                  item.overallExpiryStatus == ExpiryStatus.expiring ||
                  item.overallExpiryStatus == ExpiryStatus.expired;
              return matchesQuery && matchesCategory && matchesAnomaly;
            }).toList();
            final sorted = sortInventoryItems(filtered, _sortOption);
            final columns = sorted.length.clamp(1, 3);
            final filterHeight = (MediaQuery.textScalerOf(context)
                .scale(MomoTextSize.body) * 1.4 + 28).clamp(56.0, double.infinity);
            return RefreshIndicator(
              onRefresh: () async => ref.invalidate(inventoryProvider),
              child: CustomScrollView(
                key: const PageStorageKey('inventory-page'),
                physics: const AlwaysScrollableScrollPhysics(),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                slivers: [
                  SliverPadding(
                    padding: insets,
                    sliver: SliverToBoxAdapter(child: Column(children: [
                      MomoHouseholdBar(onPressed: () => context.go('/settings')),
                      MomoPageHeader(
                      title: '家里的物品',
                      subtitle: Text('${items.length} 种物品'),
                      actions: [
                        _SortSelector(current: _sortOption,
                          onSelected: (value) => setState(() => _sortOption = value)),
                        IconButton.filled(
                          tooltip: '入库', onPressed: _openIntake,
                          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    )])),
                  ),
                  SliverPadding(
                    padding: insets.add(const EdgeInsets.only(bottom: 16)),
                    sliver: SliverToBoxAdapter(child: MomoSearchField(
                      hintText: '搜索物品、品牌或位置',
                      controller: _searchController, focusNode: _searchFocusNode,
                      onChanged: (value) => setState(() => _query = value),
                      suffixIcon: _query.isEmpty ? null : IconButton(
                        tooltip: '清除搜索', icon: const Icon(Icons.cancel_rounded, size: 20),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _query = '');
                        },
                      ),
                    )),
                  ),
                  SliverPadding(
                    padding: insets.add(const EdgeInsets.only(bottom: 12)),
                    sliver: SliverToBoxAdapter(child: _InventoryFilterSummary(
                      summary: summary, selected: _showAnomalies, visibleCount: sorted.length,
                      onTap: () => setState(() {
                        _showAnomalies = !_showAnomalies;
                        _category = '全部'; _query = ''; _searchController.clear();
                        _searchFocusNode.unfocus();
                      }),
                    )),
                  ),
                  SliverPersistentHeader(
                    pinned: true,
                    delegate: _StickyFilterHeaderDelegate(
                      height: filterHeight,
                      child: ClipRect(child: BackdropFilter(
                        enabled: !MediaQuery.highContrastOf(context) && !MediaQuery.accessibleNavigationOf(context),
                        filter: ImageFilter.blur(sigmaX: 16, sigmaY: 16),
                        child: ColoredBox(
                          color: Theme.of(context).scaffoldBackgroundColor.withValues(
                            alpha: MediaQuery.highContrastOf(context) || MediaQuery.accessibleNavigationOf(context) ? 1 : 0.92),
                          child: SingleChildScrollView(
                            scrollDirection: Axis.horizontal,
                            padding: insets,
                            child: Row(children: [
                              for (final category in categories) Padding(
                                padding: const EdgeInsets.only(right: 8),
                                child: ChoiceChip(
                                  label: Text(category),
                                  selected: activeCategory == category,
                                  onSelected: (_) => setState(() => _category = category),
                                ),
                              ),
                            ]),
                          ),
                        ),
                      )),
                    ),
                  ),
                  if (sorted.isEmpty)
                    SliverToBoxAdapter(child: _EmptyInventory(
                      hasItems: items.isNotEmpty, onAdd: items.isEmpty ? _openIntake : null,
                    ))
                  else SliverPadding(
                    padding: insets.add(const EdgeInsets.only(top: 12)),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Row(
                            key: ValueKey('inventory-row-$index'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var column = 0; column < columns; column++) ...[
                                if (column > 0) const SizedBox(width: 8),
                                Expanded(
                                  child: index * columns + column < sorted.length
                                      ? _InventoryCard(
                                          key: ValueKey(sorted[index * columns + column].id),
                                          item: sorted[index * columns + column],
                                          columns: columns,
                                        )
                                      : const SizedBox.shrink(),
                                ),
                              ],
                            ],
                          ),
                        );
                      }, childCount: (sorted.length / columns).ceil()),
                    ),
                  ),
                  SliverToBoxAdapter(child: SizedBox(height: 20 + MomoDockInsets.bottomOf(context))),
                ],
              ),
            );
          },
        ),
      ),
    );
  }
}

class _StickyFilterHeaderDelegate extends SliverPersistentHeaderDelegate {
  _StickyFilterHeaderDelegate({required this.child, required this.height});

  final Widget child;
  final double height;

  @override
  double get minExtent => height;

  @override
  double get maxExtent => height;

  @override
  Widget build(BuildContext context, double shrinkOffset, bool overlapsContent) => SizedBox.expand(child: child);

  @override
  bool shouldRebuild(covariant _StickyFilterHeaderDelegate oldDelegate) =>
      oldDelegate.child != child || oldDelegate.height != height;
}

class _InventoryFilterSummary extends StatelessWidget {
  const _InventoryFilterSummary({required this.summary, required this.selected, required this.onTap,
    required this.visibleCount});
  final ReminderSummary summary;
  final bool selected;
  final VoidCallback onTap;
  final int visibleCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final count = {...summary.expiring.map((item) => item.id),
      ...summary.expired.map((item) => item.id), ...summary.lowStock.map((item) => item.id)}.length;
    return Wrap(alignment: WrapAlignment.spaceBetween, crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12, children: [
        Text('${selected ? '关注物品' : '全部物品'} · $visibleCount', style: theme.textTheme.bodySmall),
        Tooltip(message: selected ? '查看全部物品' : '查看异常物品', child: TextButton.icon(
          onPressed: onTap, icon: const Icon(Icons.schedule_outlined, size: 16),
          label: Text(selected ? '查看全部物品' : '$count 件需要关注', style: theme.textTheme.bodySmall),
        )),
      ]);
  }
}

class _SortSelector extends StatelessWidget {
  const _SortSelector({required this.current, required this.onSelected});

  final InventorySortOption current;
  final ValueChanged<InventorySortOption> onSelected;

  @override
  Widget build(BuildContext context) {
    return PopupMenuButton<InventorySortOption>(
      tooltip: '排序：${current.label}',
      icon: const Icon(Icons.sort_rounded),
      onSelected: onSelected,
      position: PopupMenuPosition.under,
      itemBuilder: (context) => [
        for (final option in InventorySortOption.values)
          PopupMenuItem<InventorySortOption>(
            value: option,
            child: Row(children: [
              Expanded(child: Text(option.label)),
              if (option == current) const Icon(Icons.check_rounded, size: 20),
            ]),
          ),
      ],
    );
  }
}

class _InventoryCard extends ConsumerStatefulWidget {
  const _InventoryCard({required this.item, required this.columns, super.key});
  final InventoryItem item;
  final int columns;

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
    final single = widget.columns == 1;
    final canConsume = item.activeBatches.any(
      (candidate) => candidate.expiryStatus != ExpiryStatus.expired,
    );
    final canReplenish = item.batches.any(
      (candidate) => !candidate.isDiscarded,
    );
    final theme = Theme.of(context);
    final showExpiry =
        item.overallExpiryStatus == ExpiryStatus.expiring ||
        item.overallExpiryStatus == ExpiryStatus.expired;
    final expiryLabel = item.overallExpiryStatus == ExpiryStatus.expired
        ? '已过期'
        : batch?.daysUntilExpiry == 0
        ? '今日到期'
        : '${batch?.daysUntilExpiry} 天内到期';
    final expiryColor = item.overallExpiryStatus == ExpiryStatus.expired
        ? theme.colorScheme.error
        : theme.brightness == Brightness.dark
        ? Colors.orange.shade300
        : Colors.orange.shade900;
    final iconStyle = IconButton.styleFrom(
      minimumSize: const Size(44, 44),
      maximumSize: const Size(44, 44),
      padding: EdgeInsets.zero,
      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
    );
    Widget details() => Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          item.name,
          style: single
              ? theme.textTheme.titleMedium
              : theme.textTheme.titleSmall,
        ),
        const SizedBox(height: 4),
        Text(
          single
              ? '${item.totalStock} ${item.unit} · ${item.category}'
              : '${item.totalStock} ${item.unit}',
          style: theme.textTheme.bodyMedium?.copyWith(
            fontWeight: single ? null : FontWeight.w600,
          ),
        ),
        if (!single) ...[
          const SizedBox(height: 3),
          Text(
            item.category,
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (single || item.location?.trim().isNotEmpty == true) ...[
          const SizedBox(height: 4),
          Text(
            item.location ?? '未设置位置',
            style: theme.textTheme.bodySmall?.copyWith(
              color: theme.colorScheme.onSurfaceVariant,
            ),
          ),
        ],
        if (item.isLowStock)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '库存偏低',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.error,
              ),
            ),
          ),
        if (showExpiry)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: single
                ? StatusBadge(
                    status: item.overallExpiryStatus,
                    days: batch?.daysUntilExpiry,
                  )
                : Text(
                    expiryLabel,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: expiryColor,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
      ],
    );
    return MomoCard(
      key: ValueKey('inventory-card-${item.id}'),
      onTap: () => context.push('/inventory/${item.id}'),
      padding: EdgeInsets.zero,
      margin: EdgeInsets.zero,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (single)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SizedBox.square(
                    key: ValueKey('inventory-photo-${item.id}'),
                    dimension: 72,
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: MomoProductImage(productId: item.id),
                    ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(child: details()),
                ],
              ),
            )
          else ...[
            ClipRRect(
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(18),
              ),
              child: SizedBox(
                key: ValueKey('inventory-photo-${item.id}'),
                height: widget.columns == 3 ? 64 : 80,
                child: MomoProductImage(productId: item.id),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
              child: details(),
            ),
          ],
          if (single)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    alignment: WrapAlignment.spaceBetween,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: [
                      TextButton(
                        onPressed: canConsume && !_busy
                            ? () => _showConsumeDialog(context)
                            : null,
                        child: const Text('消耗'),
                      ),
                      IconButton(
                        tooltip: _actionsVisible ? '收起快捷操作' : '物品快捷操作',
                        onPressed: _busy
                            ? null
                            : () => setState(
                                () => _actionsVisible = !_actionsVisible,
                              ),
                        icon: Icon(
                          _actionsVisible
                              ? Icons.expand_less_rounded
                              : Icons.more_horiz_rounded,
                        ),
                      ),
                    ],
                  ),
                  if (_actionsVisible) ...[
                    const Divider(),
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
            )
          else
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 2),
              child: Wrap(
                alignment: WrapAlignment.spaceEvenly,
                children: [
                  IconButton(
                    key: ValueKey('inventory-consume-${item.id}'),
                    tooltip: '消耗',
                    style: iconStyle,
                    onPressed: canConsume && !_busy
                        ? () => _showConsumeDialog(context)
                        : null,
                    icon: const Icon(Icons.remove_circle_outline, size: 20),
                  ),
                  IconButton(
                    key: ValueKey('inventory-more-${item.id}'),
                    tooltip: '物品快捷操作',
                    style: iconStyle,
                    onPressed: _busy || _actionsVisible
                        ? null
                        : () => _showQuickActions(
                            context,
                            canConsume: canConsume,
                            canReplenish: canReplenish,
                          ),
                    icon: const Icon(Icons.more_horiz_rounded, size: 20),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Future<void> _showQuickActions(
    BuildContext context, {
    required bool canConsume,
    required bool canReplenish,
  }) async {
    setState(() => _actionsVisible = true);
    try {
      await showModalBottomSheet<void>(
        context: context,
        useSafeArea: true,
        isScrollControlled: true,
        builder: (sheetContext) => SingleChildScrollView(
          padding: const EdgeInsets.all(16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                item.name,
                style: Theme.of(sheetContext).textTheme.titleLarge,
              ),
              const SizedBox(height: 8),
              _QuickActions(
                busy: false,
                canConsume: canConsume,
                canReplenish: canReplenish,
                listLayout: true,
                onConsume: () {
                  Navigator.pop(sheetContext);
                  if (mounted) _consumeOne(context);
                },
                onReplenish: () {
                  Navigator.pop(sheetContext);
                  if (mounted) _replenishOne(context);
                },
                onShopping: () {
                  Navigator.pop(sheetContext);
                  if (mounted) _addToShopping(context);
                },
                onClose: () => Navigator.pop(sheetContext),
              ),
            ],
          ),
        ),
      );
    } finally {
      if (mounted) setState(() => _actionsVisible = false);
    }
  }

  Future<void> _showConsumeDialog(BuildContext context) async {
    if (_busy) return;
    final maxAvailable = item.activeBatches
        .where((b) => b.expiryStatus != ExpiryStatus.expired)
        .fold<int>(0, (sum, b) => sum + b.remainingQuantity);
    if (maxAvailable <= 0) return;

    final controller = TextEditingController(text: '1');
    int currentQuantity = 1;
    String? errorText;

    final result = await showDialog<int>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (dialogContext, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(24)),
          title: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.12),
                  shape: BoxShape.circle,
                ),
                child: Icon(Icons.inventory_2_outlined, color: Theme.of(context).colorScheme.primary, size: 20),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('消耗物品', style: const TextStyle(fontSize: MomoTextSize.section, fontWeight: FontWeight.bold)),
                    Text(item.name, style: TextStyle(fontSize: MomoTextSize.body, color: Theme.of(context).hintColor), maxLines: 1, overflow: TextOverflow.ellipsis),
                  ],
                ),
              ),
            ],
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                decoration: BoxDecoration(
                  color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Text('当前可用库存：', style: TextStyle(fontSize: MomoTextSize.body)),
                    Text('$maxAvailable ${item.unit}', style: const TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold)),
                  ],
                ),
              ),
              const SizedBox(height: 16),
              const Text('消耗数量', style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.w500)),
              const SizedBox(height: 8),
              Row(
                children: [
                  IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.remove, size: 18),
                    onPressed: currentQuantity > 1
                        ? () {
                            setDialogState(() {
                              currentQuantity--;
                              controller.text = currentQuantity.toString();
                              errorText = null;
                            });
                          }
                        : null,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      keyboardType: TextInputType.number,
                      textAlign: TextAlign.center,
                      style: const TextStyle(fontSize: MomoTextSize.title, fontWeight: FontWeight.bold),
                      decoration: InputDecoration(
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(vertical: 10),
                        suffixText: item.unit,
                        errorText: errorText,
                      ),
                      onChanged: (val) {
                        final parsed = int.tryParse(val.trim());
                        setDialogState(() {
                          if (parsed != null) {
                            currentQuantity = parsed;
                            errorText = (parsed > maxAvailable)
                                ? '不能超过可用库存 $maxAvailable'
                                : (parsed < 1 ? '数量需大于 0' : null);
                          }
                        });
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  IconButton.filledTonal(
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.add, size: 18),
                    onPressed: currentQuantity < maxAvailable
                        ? () {
                            setDialogState(() {
                              currentQuantity++;
                              controller.text = currentQuantity.toString();
                              errorText = null;
                            });
                          }
                        : null,
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text(
                '系统将优先扣减最早到期的批次。',
                style: TextStyle(fontSize: MomoTextSize.caption, color: Theme.of(context).hintColor),
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
                    MomoCapsuleButton(
              onPressed: () {
                final qty = int.tryParse(controller.text.trim());
                if (qty == null || qty < 1) {
                  setDialogState(() => errorText = '请输入大于 0 的整数');
                  return;
                }
                if (qty > maxAvailable) {
                  setDialogState(() => errorText = '不能超过可用库存 $maxAvailable');
                  return;
                }
                Navigator.pop(dialogContext, qty);
              },
                      label: '确认消耗',
                    ),
          ],
        ),
      ),
    );

    if (result == null || result < 1 || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(inventoryServiceProvider).consume(item.id, result);
      if (context.mounted) {
        showAppSnackBar(context,
          SnackBar(content: Text('已消耗 ${item.name} $result ${item.unit}（按最早到期优先扣减）。')),
        );
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, SnackBar(content: Text('消耗失败：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _consumeOne(BuildContext context) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await ref.read(inventoryServiceProvider).consume(item.id, 1);
      if (context.mounted) {
        showAppSnackBar(context,
          SnackBar(content: Text('已消耗 ${item.name} 1 ${item.unit}。')),
        );
        setState(() => _actionsVisible = false);
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, SnackBar(content: Text('快速消耗失败：$error')));
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
        showAppSnackBar(context,
          SnackBar(content: Text('已补充 ${item.name} 1 ${item.unit}。')),
        );
        setState(() => _actionsVisible = false);
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, SnackBar(content: Text('快速补充失败：$error')));
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
        showAppSnackBar(context,
          SnackBar(content: Text('已将 ${item.name} 加入采购清单。')),
        );
        setState(() => _actionsVisible = false);
      }
    } catch (error) {
      if (context.mounted) {
        showAppSnackBar(context, SnackBar(content: Text('加入采购失败：$error')));
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
    this.listLayout = false,
  });

  final bool listLayout;
  final bool busy;
  final bool canConsume;
  final bool canReplenish;
  final VoidCallback onConsume;
  final VoidCallback onReplenish;
  final VoidCallback onShopping;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    if (listLayout) {
      return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        ListTile(leading: const Icon(Icons.remove_circle_outline), title: const Text('快速消耗 1 件'),
          enabled: !busy && canConsume, onTap: busy || !canConsume ? null : onConsume),
        ListTile(leading: const Icon(Icons.add_circle_outline), title: const Text('快速补充 1 件'),
          enabled: !busy && canReplenish, onTap: busy || !canReplenish ? null : onReplenish),
        ListTile(leading: const Icon(Icons.add_shopping_cart_outlined), title: const Text('加入采购清单'),
          enabled: !busy, onTap: busy ? null : onShopping),
        TextButton(onPressed: busy ? null : onClose, child: const Text('关闭')),
      ]);
    }
    return Wrap(
      spacing: 8, runSpacing: 8,
      children: [
        TextButton.icon(
          onPressed: busy || !canConsume ? null : onConsume,
          icon: const Icon(Icons.remove_circle_outline), label: const Text('快速消耗 1 件'),
        ),
        TextButton.icon(
          onPressed: busy || !canReplenish ? null : onReplenish,
          icon: const Icon(Icons.add_circle_outline), label: const Text('快速补充 1 件'),
        ),
        TextButton.icon(
          onPressed: busy ? null : onShopping,
          icon: const Icon(Icons.add_shopping_cart_outlined), label: const Text('加入采购清单'),
        ),
        IconButton(tooltip: '收起快捷操作', onPressed: busy ? null : onClose,
          icon: const Icon(Icons.close_rounded)),
      ],
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
          MomoCapsuleButton(
                onPressed: onAdd,
            label: '开始入库',
            icon: const Icon(Icons.add_box_outlined),
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
          MomoCapsuleButton(
                onPressed: onRetry,
            label: '重试',
            isPrimary: false,
            icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
      );
}

String _dateText(DateTime date) => '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
