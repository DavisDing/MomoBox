import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';
import '../widgets/intake_sheet.dart';

class ShoppingScreen extends ConsumerWidget {
  const ShoppingScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final shopping = ref.watch(shoppingProvider);
    return Scaffold(
      appBar: AppBar(
        title: const Text('待采买清单'),
        actions: [
          IconButton(
            tooltip: '新增采购项',
            onPressed: () => _showAddEntry(context, ref),
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
              OutlinedButton.icon(
                onPressed: () => ref.invalidate(shoppingProvider),
                icon: const Icon(Icons.refresh),
                label: const Text('重试'),
              ),
            ],
          ),
        ),
        data: (entries) {
          if (entries.isEmpty) return const Center(child: Text('暂无待采买物品。'));
          final pending = entries.where((entry) => !entry.isCompleted).toList();
          final completed = entries.where((entry) => entry.isCompleted).toList();
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              _EntrySection(title: '待购买', entries: pending),
              _EntrySection(title: '已完成', entries: completed),
            ],
          );
        },
      ),
    );
  }

  Future<void> _showAddEntry(BuildContext context, WidgetRef ref) async {
    final name = TextEditingController();
    final quantity = TextEditingController(text: '1');
    final reason = TextEditingController(text: '手动添加');
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('新增采购项'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(controller: name, decoration: const InputDecoration(labelText: '物品名称')),
            const SizedBox(height: 8),
            TextField(controller: quantity, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: '数量')),
            const SizedBox(height: 8),
            TextField(controller: reason, decoration: const InputDecoration(labelText: '来源 / 原因')),
          ],
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final count = int.tryParse(quantity.text);
              try {
                await ref.read(shoppingServiceProvider).addOrMerge(
                      itemName: name.text,
                      targetQuantity: count ?? 0,
                      reason: reason.text,
                    );
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              } catch (error) {
                if (dialogContext.mounted) {
                  ScaffoldMessenger.of(dialogContext).showSnackBar(SnackBar(content: Text('$error')));
                }
              }
            },
            child: const Text('添加'),
          ),
        ],
      ),
    );
    name.dispose();
    quantity.dispose();
    reason.dispose();
  }
}

class _EntrySection extends ConsumerWidget {
  const _EntrySection({required this.title, required this.entries});
  final String title;
  final List<ShoppingEntry> entries;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (entries.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 18),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: Theme.of(context).textTheme.titleMedium),
          const SizedBox(height: 6),
          ...entries.map(
            (entry) => Card(
              child: ListTile(
                leading: Checkbox(
                  value: entry.isCompleted,
                  onChanged: (value) async {
                    final completed = value ?? false;
                    await ref.read(shoppingServiceProvider).setCompleted(entry.id, completed);
                    if (!completed || !context.mounted) return;
                    await showModalBottomSheet<void>(
                      context: context,
                      isScrollControlled: true,
                      useSafeArea: true,
                      builder: (_) => IntakeSheet(
                        initialName: entry.itemName,
                        initialCategory: entry.category,
                        initialQuantity: entry.targetQuantity,
                      ),
                    );
                  },
                ),
                title: Text(entry.itemName, style: TextStyle(decoration: entry.isCompleted ? TextDecoration.lineThrough : null)),
                subtitle: Text('${entry.targetQuantity} 件 · ${entry.reason}'),
                trailing: IconButton(
                  tooltip: '删除',
                  onPressed: () => ref.read(shoppingServiceProvider).delete(entry.id),
                  icon: const Icon(Icons.delete_outline),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
