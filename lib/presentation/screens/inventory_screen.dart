import '../widgets/momo_mobile_layout.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/momo_components.dart';
import '../../app/momo_typography.dart';
import 'dart:ui';
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/inventory/inventory_sorting.dart';
import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/intake_sheet.dart';
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
                    sliver: SliverToBoxAdapter(child: MomoPageHeader(
                      title: '物品',
                      actions: [
                        _SortSelector(current: _sortOption,
                          onSelected: (value) => setState(() => _sortOption = value)),
                        IconButton.filled(
                          tooltip: '入库', onPressed: _openIntake,
                          style: IconButton.styleFrom(minimumSize: const Size(48, 48)),
                          icon: const Icon(Icons.add_rounded),
                        ),
                      ],
                    )),
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
                    padding: insets.add(const EdgeInsets.only(top: 8)),
                    sliver: SliverList(
                      delegate: SliverChildBuilderDelegate((context, index) {
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: Row(
                            key: ValueKey('inventory-row-$index'),
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              for (var column = 0; column < columns; column++) ...[
                                if (column > 0) const SizedBox(width: 6),
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

class _InventoryCard extends StatelessWidget {
  const _InventoryCard({required this.item, required this.columns, super.key});
  final InventoryItem item;
  final int columns;

  @override
  Widget build(BuildContext context) {
    final batch = item.nearestDatedBatch;
    final single = columns == 1;
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
    final location = item.location?.trim();
    final metaStyle = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    final name = Text(
      item.name,
      style: single ? theme.textTheme.titleMedium : theme.textTheme.titleSmall,
    );
    final stock = Text(
      '${item.totalStock} ${item.unit}',
      style: theme.textTheme.bodyMedium?.copyWith(fontWeight: FontWeight.w600),
    );
    final metadata = Text(
      [item.category, if (location != null && location.isNotEmpty) location]
          .join(' · '),
      style: metaStyle,
    );
    final alerts = Wrap(
      spacing: 6,
      runSpacing: 1,
      children: [
        if (item.isLowStock)
          Text('库存偏低', style: metaStyle?.copyWith(color: theme.colorScheme.error)),
        if (showExpiry)
          Text(expiryLabel, style: metaStyle?.copyWith(color: expiryColor)),
      ],
    );
    final photoSize = single ? 44.0 : columns == 2 ? 28.0 : 22.0;
    final thumbnail = SizedBox.square(
      key: ValueKey('inventory-photo-${item.id}'),
      dimension: photoSize,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(single ? 8 : 5),
        child: MomoProductImage(
          productId: item.id,
          placeholderIconSize: photoSize * .56,
        ),
      ),
    );
    return MomoCard(
      key: ValueKey('inventory-card-${item.id}'),
      onTap: () => context.push('/inventory/${item.id}'),
      padding: single
          ? const EdgeInsets.symmetric(horizontal: 8, vertical: 6)
          : const EdgeInsets.fromLTRB(6, 5, 6, 6),
      margin: EdgeInsets.zero,
      borderRadius: 14,
      child: single
          ? Row(
              children: [
                thumbnail,
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      name,
                      Wrap(
                        spacing: 6,
                        crossAxisAlignment: WrapCrossAlignment.center,
                        children: [stock, metadata],
                      ),
                      if (item.isLowStock || showExpiry) alerts,
                    ],
                  ),
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                name,
                const SizedBox(height: 2),
                Row(
                  children: [
                    thumbnail,
                    const SizedBox(width: 4),
                    Expanded(child: stock),
                  ],
                ),
                const SizedBox(height: 2),
                metadata,
                if (item.isLowStock || showExpiry) alerts,
              ],
            ),
    );
  }
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
