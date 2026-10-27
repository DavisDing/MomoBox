import '../widgets/momo_glass_components.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/inventory_models.dart';
import '../../domain/inventory/product_categories.dart';
import '../controllers/providers.dart';
import '../widgets/app_feedback.dart';
import '../widgets/intake_sheet.dart';

class ShoppingScreen extends ConsumerStatefulWidget {
  const ShoppingScreen({super.key});

  @override
  ConsumerState<ShoppingScreen> createState() => _ShoppingScreenState();
}

class _ShoppingScreenState extends ConsumerState<ShoppingScreen> {
  static const _categories = ProductCategories.values;

  final Set<String> _selectedIds = {};
  String _category = '全部';
  bool _busy = false;

  @override
  Widget build(BuildContext context) {
    final shopping = ref.watch(shoppingProvider);
    return Scaffold(
      appBar: MomoGlassAppBar(
        title: const Text('待采买清单'),
        actions: [
          IconButton(
            tooltip: '新增采购项',
            onPressed: _busy ? null : _showAddEntry,
            icon: const Icon(Icons.add_shopping_cart),
          ),
        ],
      ),
      body: shopping.when(
        loading: () => const Center(child: CircularProgressIndicator()),
        error: (error, _) => Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('采购清单加载失败：$error', textAlign: TextAlign.center),
              const SizedBox(height: 12),
                  MomoCapsuleButton(
                onPressed: () => ref.invalidate(shoppingProvider),
                    label: '重试',
                    isPrimary: false,
                    icon: const Icon(Icons.refresh),
              ),
            ],
          ),
        ),
        data: (entries) {
          final categories = {'全部', ...entries.map((e) => e.category ?? '未分类')}.toList();
          final activeCategory = categories.contains(_category) ? _category : '全部';
          final visible = entries.where((entry) =>
              activeCategory == '全部' || (entry.category ?? '未分类') == activeCategory).toList();
          final selected = visible.where((entry) => _selectedIds.contains(entry.id)).toList();
          return Column(
            children: [
              if (entries.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: DropdownButton<String>(
                      value: activeCategory,
                      items: categories.map((category) => DropdownMenuItem(
                        value: category,
                        child: Text(category == '全部' ? '全部类别' : category),
                      )).toList(),
                      onChanged: _busy ? null : (value) => setState(() => _category = value ?? '全部'),
                    ),
                  ),
                ),
              Expanded(
                child: entries.isEmpty
                    ? const Center(child: Text('暂无待采买物品。'))
                    : visible.isEmpty
                        ? const Center(child: Text('该类别暂无采购项。'))
                        : ListView(
                            padding: const EdgeInsets.all(16),
                            children: [
                              _section('待购买', visible.where((e) => !e.isCompleted)),
                              _section('已完成', visible.where((e) => e.isCompleted)),
                            ],
                          ),
              ),
              if (selected.isNotEmpty)
                SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
                    child: Wrap(
                      alignment: WrapAlignment.spaceBetween,
                      spacing: 12,
                      runSpacing: 8,
                      children: [
                        MomoCapsuleButton(
                          onPressed: _busy ? null : () {
                            setState(() {
                              final ids = visible.map((e) => e.id).toSet();
                              if (ids.every(_selectedIds.contains)) {
                                _selectedIds.removeAll(ids);
                              } else {
                                _selectedIds.addAll(ids);
                              }
                            });
                          },
                          label:
                              visible.every((e) => _selectedIds.contains(e.id)) ? '取消全选' : '全选',
                          isPrimary: false,
                        ),

                        MomoCapsuleButton(
                          onPressed: _busy ? null : () => _intakeSelected(selected),
                          label: _busy ? '入库中' : '入库（${selected.length}）',
                          icon: const Icon(Icons.inventory_2_outlined),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          );
        },
      ),
    );
  }

  Widget _section(String title, Iterable<ShoppingEntry> entries) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          ...entries.map((entry) => MomoGlassCard(
              padding: EdgeInsets.zero,
              margin: const EdgeInsets.only(bottom: 8),
              child: ListTile(
              contentPadding: const EdgeInsets.only(left: 4, right: 4),
              leading: Checkbox(
                value: _selectedIds.contains(entry.id),
                onChanged: _busy ? null : (value) => setState(() {
                  if (value == true) {
                    _selectedIds.add(entry.id);
                  } else {
                    _selectedIds.remove(entry.id);
                  }
                }),
              ),
              title: Text(entry.itemName),
              subtitle: Text('${entry.targetQuantity} 件 · ${entry.category ?? '未分类'} · ${entry.reason}'),
              trailing: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    tooltip: '编辑入库',
                    onPressed: _busy ? null : () => _openIntake(entry),
                    icon: const Icon(Icons.edit_outlined),
                  ),
                  IconButton(
                    tooltip: '删除',
                    onPressed: _busy ? null : () async {
                      try {
                        await ref.read(shoppingServiceProvider).delete(entry.id);
                        if (mounted) {
                                    setState(() => _selectedIds.remove(entry.id));
                      }
                                } catch (error) {
                        if (mounted) {
                                    showAppSnackBar(context, SnackBar(content: Text('删除失败：$error')));
                                  }
                                }
                    },
                    icon: const Icon(Icons.delete_outline),
                  ),
                ],
              ),
            ),
          )),
        ],
      ),
    );
  }

  Future<void> _openIntake(ShoppingEntry entry) async {
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => IntakeSheet(
        initialName: entry.itemName,
        initialCategory: entry.category,
        initialQuantity: entry.targetQuantity,
        onIntake: (draft, mergeProductId) => ref.read(shoppingServiceProvider)
            .intakePurchasedEntry(entry, draft, mergeProductId: mergeProductId),
        onIntakeSuccess: (_) {
          if (mounted) setState(() => _selectedIds.remove(entry.id));
        },
      ),
    );
  }

  Future<void> _intakeSelected(List<ShoppingEntry> selected) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      final inventory = await ref.read(inventoryRepositoryProvider).loadInventory();
      final plans = <_IntakePlan>[];
      for (final entry in selected) {
        final linked = entry.productId == null ? null : inventory.where((item) => item.id == entry.productId).firstOrNull;
        if (entry.productId != null && linked == null) {
          throw StateError('${entry.itemName} 关联的库存商品已不存在，请单独编辑入库。');
        }
        final draft = IntakeDraft(
          name: linked?.name ?? entry.itemName,
          category: linked?.category ?? entry.category ?? '其他物品',
          quantity: entry.targetQuantity,
          brand: linked?.brand,
          specification: linked?.specification,
          barcode: linked?.barcode,
          location: linked?.location,
          unit: linked?.unit ?? '件',
          lowStockThreshold: linked?.lowStockThreshold ?? 1,
        );
        String? mergeId = linked?.id;
        if (mergeId == null) {
          final matches = await ref.read(inventoryServiceProvider).findMatchingProducts(draft);
          if (!mounted) return;
          if (matches.isNotEmpty) {
            mergeId = await showDialog<String>(
              context: context,
              builder: (dialogContext) => SimpleDialog(
                title: Text('「${entry.itemName}」可能已在库存中'),
                children: [
                  ...matches.map((candidate) => SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, candidate.id),
                    child: Text('新增批次至 ${candidate.name} · ${candidate.category}'),
                  )),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext, '__new__'),
                    child: const Text('新建独立商品'),
                  ),
                  SimpleDialogOption(
                    onPressed: () => Navigator.pop(dialogContext),
                    child: const Text('取消本次入库'),
                  ),
                ],
              ),
            );
            if (!mounted || mergeId == null) return;
            if (mergeId == '__new__') mergeId = null;
          }
        }
        plans.add(_IntakePlan(entry, draft, mergeId));
      }
      if (!mounted) return;
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          title: const Text('确认批量入库'),
          content: Text('将 ${plans.length} 项采购商品分别记为新批次；原有库存不会覆盖。本次批次不设置生产/到期日期，仍可参与库存和消耗，但不产生效期提醒。如需填写日期，请取消后逐项使用右侧“编辑入库”。'),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext, false), child: const Text('取消')),
                MomoCapsuleButton(onPressed: () => Navigator.pop(dialogContext, true),
                  label: '确认入库',
                ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      var count = 0;
      for (final plan in plans) {
        // Commit each item separately; its stock and list removal are atomic.
        await ref.read(shoppingServiceProvider).intakePurchasedEntry(
          plan.entry, plan.draft, mergeProductId: plan.mergeId,
        );
        count++;
        if (mounted) setState(() => _selectedIds.remove(plan.entry.id));
      }
      if (mounted) {
        showAppSnackBar(context, SnackBar(content: Text('已将 $count 项商品按新批次入库。')));
    }
    } catch (error) {
      if (mounted) {
        showAppSnackBar(context, SnackBar(content: Text('入库中断，已成功的项目不回滚；请检查剩余清单：$error')));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _showAddEntry() async {
    final name = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final reason = TextEditingController(text: '手动添加');
    String category = '其他物品';
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('新增采购项'),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(controller: name, decoration: const InputDecoration(labelText: '物品名称')),
                const SizedBox(height: 8),
                TextField(controller: quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '数量')),
                const SizedBox(height: 8),
                DropdownButtonFormField<String>(
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '类别'),
                  items: _categories.map((value) => DropdownMenuItem(value: value, child: Text(value))).toList(),
                  onChanged: (value) => setDialogState(() => category = value ?? '其他物品'),
                ),
                const SizedBox(height: 8),
                TextField(controller: reason, decoration: const InputDecoration(labelText: '来源 / 原因')),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
                    MomoCapsuleButton(
              onPressed: () async {
                try {
                  await ref.read(shoppingServiceProvider).addOrMerge(
                    itemName: name.text,
                    targetQuantity: int.tryParse(quantity.text) ?? 0,
                    reason: reason.text,
                    category: category,
                  );
                  if (dialogContext.mounted) {
                            Navigator.pop(dialogContext);
                          }
                        } catch (error) {
                  if (dialogContext.mounted) {
                            showAppSnackBar(dialogContext, SnackBar(content: Text('$error')));
                }
              }
                      },
                      label: '添加',
            ),
          ],
        ),
      ),
    );
    name.dispose();
    quantity.dispose();
    reason.dispose();
  }
}

class _IntakePlan {
  const _IntakePlan(this.entry, this.draft, this.mergeId);
  final ShoppingEntry entry;
  final IntakeDraft draft;
  final String? mergeId;
}
