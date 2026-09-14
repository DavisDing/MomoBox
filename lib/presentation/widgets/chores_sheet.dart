import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

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
  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final theme = Theme.of(context);
    final choresAsync = ref.watch(choresProvider);

    return DraggableScrollableSheet(
      initialChildSize: 0.85,
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
                    onPressed: () => _showAddChoreDialog(context),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // 列表
            Expanded(
              child: choresAsync.when(
                loading: () => const Center(child: CircularProgressIndicator()),
                error: (e, _) => Center(child: Text('加载失败：$e')),
                data: (chores) {
                  if (chores.isEmpty) {
                    return Center(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(Icons.check_circle_outline_rounded, size: 48, color: Colors.grey),
                          const SizedBox(height: 12),
                          const Text('暂无周期提醒', style: TextStyle(color: Colors.grey)),
                          const SizedBox(height: 8),
                          FilledButton.tonal(
                            onPressed: () => _showAddChoreDialog(context),
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
                                      style: const TextStyle(
                                        fontSize: 15,
                                        fontWeight: FontWeight.bold,
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
                                        ScaffoldMessenger.of(context).showSnackBar(
                                          SnackBar(
                                            content: Text('已完成「${item.title}」，下一次提醒将于 ${item.intervalDays} 天后。'),
                                            duration: const Duration(seconds: 2),
                                          ),
                                        );
                                      }
                                    },
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

  void _showAddChoreDialog(BuildContext context) {
    final titleController = TextEditingController();
    final notesController = TextEditingController();
    var category = '家居清洁';
    var interval = ChoreRepeatInterval.weekly;

    showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) => AlertDialog(
          title: const Text('添加周期提醒', style: TextStyle(fontSize: 17, fontWeight: FontWeight.bold)),
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
                  initialValue: category,
                  decoration: const InputDecoration(labelText: '类别'),
                  items: const [
                    DropdownMenuItem(value: '家居清洁', child: Text('家居清洁')),
                    DropdownMenuItem(value: '个人卫生', child: Text('个人卫生')),
                    DropdownMenuItem(value: '耗材更换', child: Text('耗材更换')),
                    DropdownMenuItem(value: '设备维护', child: Text('设备维护')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => category = val);
                  },
                ),
                const SizedBox(height: 12),
                DropdownButtonFormField<ChoreRepeatInterval>(
                  initialValue: interval,
                  decoration: const InputDecoration(labelText: '重复周期'),
                  items: const [
                    DropdownMenuItem(value: ChoreRepeatInterval.daily, child: Text('每天')),
                    DropdownMenuItem(value: ChoreRepeatInterval.weekly, child: Text('每周 (7天)')),
                    DropdownMenuItem(value: ChoreRepeatInterval.biweekly, child: Text('每两周 (14天)')),
                    DropdownMenuItem(value: ChoreRepeatInterval.monthly, child: Text('每月 (30天)')),
                    DropdownMenuItem(value: ChoreRepeatInterval.quarterly, child: Text('每季度 (90天)')),
                  ],
                  onChanged: (val) {
                    if (val != null) setDialogState(() => interval = val);
                  },
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
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                final title = titleController.text.trim();
                if (title.isEmpty) return;
                await ref.read(choreServiceProvider).addChore(
                      title: title,
                      category: category,
                      repeatInterval: interval,
                      notes: notesController.text.trim(),
                    );
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
