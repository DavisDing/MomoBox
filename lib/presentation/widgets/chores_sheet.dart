import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_feedback.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/chore_models.dart';
import '../controllers/providers.dart';

class ChoresSheet extends ConsumerStatefulWidget {
  const ChoresSheet({super.key});

  static void show(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (context) => const ChoresSheet(),
    );
  }

  @override
  ConsumerState<ChoresSheet> createState() => _ChoresSheetState();
}

class _ChoresSheetState extends ConsumerState<ChoresSheet> {
  String _searchKeyword = '';
  String _selectedCategory = '全部';

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final theme = Theme.of(context);
    final choresAsync = ref.watch(choresProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.88,
      minChildSize: 0.5,
      maxChildSize: 0.95,
      expand: false,
      builder: (context, scrollController) {
        return Column(
          children: [
            // 拖拽条
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 10, bottom: 8),
                width: 36,
                height: 4,
                decoration: BoxDecoration(
                  color: Colors.grey.withValues(alpha: 0.4),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
            ),
            // 顶栏
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: Row(
                children: [
                  Icon(Icons.repeat_rounded, color: palette.primary, size: 24),
                  const SizedBox(width: 8),
                  const Text(
                    '周期循环提醒',
                    style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  IconButton(
                    tooltip: '添加新提醒',
                    icon: Icon(Icons.add_circle_outline_rounded, color: palette.primary),
                    onPressed: () => _showChoreEditDialog(context),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),

            // 搜索与分类过滤栏（查）
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '搜索周期提醒事项或备注...',
                  prefixIcon: const Icon(Icons.search, size: 20),
                  suffixIcon: _searchKeyword.isNotEmpty
                      ? IconButton(
                          icon: const Icon(Icons.clear, size: 18),
                          onPressed: () => setState(() => _searchKeyword = ''),
                        )
                      : null,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  isDense: true,
                  border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
                ),
                onChanged: (val) => setState(() => _searchKeyword = val.trim()),
              ),
            ),
            const SizedBox(height: 6),

            // 分类筛选小胶囊
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: ['全部', '家居清洁', '个人卫生', '耗材更换', '设备维护'].map((cat) {
                  final isSelected = _selectedCategory == cat;
                  return Padding(
                    padding: const EdgeInsets.only(right: 8),
                    child: FilterChip(
                      label: Text(cat, style: const TextStyle(fontSize: 12)),
                      selected: isSelected,
                      visualDensity: VisualDensity.compact,
                      selectedColor: palette.primary.withValues(alpha: 0.18),
                      onSelected: (_) => setState(() => _selectedCategory = cat),
                    ),
                  );
                }).toList(),
              ),
            ),

            const SizedBox(height: 6),
            const Divider(height: 1),

            // 列表
            Expanded(
              child: choresAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败：$e')),
                data: (allChores) {
                  // 根据搜索词和类别过滤（查）
                  final chores = allChores.where((item) {
                    final matchCategory = _selectedCategory == '全部' || item.category == _selectedCategory;
                    final matchKeyword = _searchKeyword.isEmpty ||
                        item.title.contains(_searchKeyword) ||
                        (item.notes != null && item.notes!.contains(_searchKeyword));
                    return matchCategory && matchKeyword;
                  }).toList();

                  if (chores.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle_outline_rounded, size: 48, color: Colors.grey),
                          const SizedBox(height: 12),
                          Text(
                            _searchKeyword.isNotEmpty || _selectedCategory != '全部'
                                ? '未找到符合条件的周期提醒'
                                : '暂无周期提醒',
                            style: const TextStyle(color: Colors.grey),
                          ),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: () => _showChoreEditDialog(context),
                            child: const Text('添加一项（如换床单、洗浴巾）'),
                          ),
                        ],
                      ),
                    );
                  }

                  return ListView.separated(
                    controller: scrollController,
                    padding: const EdgeInsets.all(16),
                    itemCount: chores.length,
                    separatorBuilder: (_, __) => const SizedBox(height: 12),
                    itemBuilder: (context, index) {
                      final item = chores[index];
                      final isDue = item.isDue();
                      final days = item.daysUntil();

                      return Card(
                        elevation: 0,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(16),
                          side: BorderSide(
                            color: isDue
                                ? palette.secondary.withValues(alpha: 0.6)
                                : theme.dividerColor.withValues(alpha: 0.2),
                            width: isDue ? 1.5 : 1,
                          ),
                        ),
                        child: InkWell(
                          borderRadius: BorderRadius.circular(16),
                          onTap: () => _showChoreEditDialog(context, item: item),
                          child: Padding(
                            padding: const EdgeInsets.all(12),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Row(
                                  children: [
                                    Container(
                                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                                      decoration: BoxDecoration(
                                        color: palette.primary.withValues(alpha: 0.12),
                                        borderRadius: BorderRadius.circular(6),
                                      ),
                                      child: Text(
                                        item.category,
                                        style: TextStyle(
                                          fontSize: 11,
                                          fontWeight: FontWeight.bold,
                                          color: palette.primary,
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 8),
                                    Expanded(
                                      child: Text(
                                        item.title,
                                        style: TextStyle(
                                          fontSize: 15,
                                          fontWeight: FontWeight.bold,
                                          decoration: item.isEnabled ? null : TextDecoration.lineThrough,
                                          color: item.isEnabled ? null : Colors.grey,
                                        ),
                                      ),
                                    ),
                                    // 打卡完成按钮
                                    FilledButton.tonalIcon(
                                      style: FilledButton.styleFrom(
                                        visualDensity: VisualDensity.compact,
                                        padding: const EdgeInsets.symmetric(horizontal: 10),
                                      ),
                                      icon: const Icon(Icons.check, size: 16),
                                      label: const Text('已完成', style: TextStyle(fontSize: 12)),
                                      onPressed: () async {
                                        await ref.read(choreServiceProvider).completeChore(item.id);
                                        if (context.mounted) {
                                          showAppSnackBar(context,
                                            SnackBar(
                                              content: Text('已完成「${item.title}」，下一次提醒将于 ${item.intervalDays} 天后。'),
                                              duration: const Duration(seconds: 2),
                                            ),
                                          );
                                        }
                                      },
                                    ),
                                    const SizedBox(width: 4),
                                    // 更多操作菜单（编辑、开关、删除）
                                    PopupMenuButton<String>(
                                      icon: const Icon(Icons.more_vert_rounded, size: 20, color: Colors.grey),
                                      padding: EdgeInsets.zero,
                                      onSelected: (action) async {
                                        if (action == 'edit') {
                                          _showChoreEditDialog(context, item: item);
                                        } else if (action == 'toggle') {
                                          await ref.read(choreServiceProvider).toggleChore(item.id, !item.isEnabled);
                                        } else if (action == 'delete') {
                                          _confirmDeleteChore(context, item);
                                        }
                                      },
                                      itemBuilder: (_) => [
                                        const PopupMenuItem(
                                          value: 'edit',
                                          child: Row(
                                            children: [
                                              Icon(Icons.edit_outlined, size: 18),
                                              SizedBox(width: 8),
                                              Text('编辑详情'),
                                            ],
                                          ),
                                        ),
                                        PopupMenuItem(
                                          value: 'toggle',
                                          child: Row(
                                            children: [
                                              Icon(item.isEnabled ? Icons.pause_circle_outline : Icons.play_circle_outline, size: 18),
                                              const SizedBox(width: 8),
                                              Text(item.isEnabled ? '暂停提醒' : '启用提醒'),
                                            ],
                                          ),
                                        ),
                                        const PopupMenuItem(
                                          value: 'delete',
                                          child: Row(
                                            children: [
                                              Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                              SizedBox(width: 8),
                                              Text('删除提醒', style: TextStyle(color: Colors.red)),
                                            ],
                                          ),
                                        ),
                                      ],
                                    ),
                                  ],
                                ),
                                const SizedBox(height: 8),
                                Row(
                                  children: [
                                    Icon(Icons.update_rounded, size: 14, color: theme.hintColor),
                                    const SizedBox(width: 4),
                                    Text(
                                      '频率：${item.repeatDescription}',
                                      style: TextStyle(fontSize: 12, color: theme.hintColor),
                                    ),
                                    const Spacer(),
                                    Text(
                                      isDue
                                          ? (days < 0 ? '已逾期 ${-days} 天' : '今日待办')
                                          : '还有 $days 天到期',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        color: isDue ? Colors.redAccent : palette.primary,
                                      ),
                                    ),
                                  ],
                                ),
                                if (item.notes != null && item.notes!.isNotEmpty) ...[
                                  const SizedBox(height: 4),
                                  Text(
                                    item.notes!,
                                    style: TextStyle(fontSize: 12, color: theme.hintColor),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      );
                    },
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  /// 确认删除周期提醒
  void _confirmDeleteChore(BuildContext context, ChoreItem item) {
    showDialog<void>(
      context: context,
      builder: (dialogCtx) => AlertDialog(
        title: const Text('删除周期提醒'),
        content: Text('确定要删除周期提醒「${item.title}」吗？此操作无法撤销。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogCtx),
            child: const Text('取消'),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () async {
              Navigator.pop(dialogCtx);
              await ref.read(choreServiceProvider).deleteChore(item.id);
              if (context.mounted) {
                showAppSnackBar(context,
                  SnackBar(content: Text('已删除「${item.title}」')),
                );
              }
            },
            child: const Text('删除'),
          ),
        ],
      ),
    );
  }

  /// 添加（增）或编辑（改）周期提醒
  void _showChoreEditDialog(BuildContext context, {ChoreItem? item}) {
    final isEditing = item != null;
    final titleController = TextEditingController(text: item?.title ?? '');
    final notesController = TextEditingController(text: item?.notes ?? '');
    var category = item?.category ?? '家居清洁';
    var interval = item?.repeatInterval ?? ChoreRepeatInterval.weekly;
    DateTime nextDueDate = item?.nextDueDate ?? DateTime.now().add(const Duration(days: 7));

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: Text(
            isEditing ? '编辑周期提醒' : '添加周期提醒',
            style: const TextStyle(fontSize: 17, fontWeight: FontWeight.bold),
          ),
          content: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: titleController,
                  decoration: const InputDecoration(
                    labelText: '事项名称 *',
                    hintText: '如：更换床单、清洗浴巾、换滤芯',
                  ),
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  isExpanded: true,
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '类别'),
                  items: const [
                    DropdownMenuItem(value: '家居清洁', child: Text('家居清洁', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: '个人卫生', child: Text('个人卫生', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: '耗材更换', child: Text('耗材更换', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: '设备维护', child: Text('设备维护', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => category = val);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ChoreRepeatInterval>(
                  isExpanded: true,
                  initialValue: interval,
                  decoration: const InputDecoration(labelText: '重复周期'),
                  items: const [
                    DropdownMenuItem(value: ChoreRepeatInterval.daily, child: Text('每天', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: ChoreRepeatInterval.weekly, child: Text('每周 (7天)', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: ChoreRepeatInterval.biweekly, child: Text('每两周 (14天)', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: ChoreRepeatInterval.monthly, child: Text('每月 (30天)', overflow: TextOverflow.ellipsis)),
                    DropdownMenuItem(value: ChoreRepeatInterval.quarterly, child: Text('每季度 (90天)', overflow: TextOverflow.ellipsis)),
                  ],
                  onChanged: (val) {
                    if (val != null) {
                      setDialogState(() {
                        interval = val;
                        // 自动调整下一次到期时间预设
                        final days = switch (val) {
                          ChoreRepeatInterval.daily => 1,
                          ChoreRepeatInterval.weekly => 7,
                          ChoreRepeatInterval.biweekly => 14,
                          ChoreRepeatInterval.monthly => 30,
                          ChoreRepeatInterval.quarterly => 90,
                        };
                        nextDueDate = DateTime.now().add(Duration(days: days));
                      });
                    }
                  },
                ),
                const SizedBox(height: 12),
                // 下一次提醒日期选择
                InkWell(
                  onTap: () async {
                    final picked = await showDatePicker(
                      context: context,
                      initialDate: nextDueDate,
                      firstDate: DateTime.now().subtract(const Duration(days: 365)),
                      lastDate: DateTime.now().add(const Duration(days: 3650)),
                    );
                    if (picked != null) {
                      setDialogState(() => nextDueDate = picked);
                    }
                  },
                  borderRadius: BorderRadius.circular(8),
                  child: InputDecorator(
                    decoration: const InputDecoration(
                      labelText: '下次提醒日期',
                      suffixIcon: Icon(Icons.calendar_today_outlined, size: 18),
                    ),
                    child: Text(
                      '${nextDueDate.year}-${nextDueDate.month.toString().padLeft(2, "0")}-${nextDueDate.day.toString().padLeft(2, "0")}',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: notesController,
                  decoration: const InputDecoration(
                    labelText: '备注说明',
                    hintText: '注意事项或操作要点',
                  ),
                ),
              ],
            ),
          ),
          actions: [
            if (isEditing)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () {
                  Navigator.pop(dialogContext);
                  _confirmDeleteChore(context, item);
                },
                child: const Text('删除'),
              ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final title = titleController.text.trim();
                if (title.isEmpty) return;

                if (isEditing) {
                  await ref.read(choreServiceProvider).updateChore(
                        id: item.id,
                        title: title,
                        category: category,
                        repeatInterval: interval,
                        nextDueDate: nextDueDate,
                        notes: notesController.text.trim(),
                      );
                } else {
                  await ref.read(choreServiceProvider).addChore(
                        title: title,
                        category: category,
                        repeatInterval: interval,
                        nextDueDate: nextDueDate,
                        notes: notesController.text.trim(),
                      );
                }

                if (dialogContext.mounted) {
                  Navigator.pop(dialogContext);
                }
              },
              child: const Text('保存'),
            ),
          ],
        ),
      ),
    );
  }
}
