import '../../app/momo_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'app_feedback.dart';

import '../../services/calendar_sync_service.dart';
import '../controllers/providers.dart';

class CalendarSyncDialog extends ConsumerStatefulWidget {
  const CalendarSyncDialog({super.key});

  static Future<void> show(BuildContext context) {
    return showDialog(
      context: context,
      builder: (context) => const CalendarSyncDialog(),
    );
  }

  @override
  ConsumerState<CalendarSyncDialog> createState() => _CalendarSyncDialogState();
}

class _CalendarSyncDialogState extends ConsumerState<CalendarSyncDialog> {
  CalendarSyncRange _range = CalendarSyncRange.days60;
  bool _includeExpiring = true;
  bool _includeExpired = true;
  bool _includeLowStock = true;
  bool _includeChores = true;
  bool _isExporting = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return AlertDialog(
      title: Row(
        children: [
          Icon(Icons.calendar_month_rounded, color: theme.colorScheme.primary, size: 24),
          const SizedBox(width: 8),
          const Expanded(child: Text('同步提醒到日历')),
        ],
      ),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '生成标准日历日程 (.ics)，一键导入系统自带日历。支持在桌面与锁屏日程中实时掌握家中物品与家务状态。',
              style: TextStyle(fontSize: MomoTextSize.body, color: theme.colorScheme.onSurfaceVariant),
            ),
            const SizedBox(height: 16),
            const Text(
              '选择时间范围：',
              style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                _buildRangeChip(CalendarSyncRange.days30),
                _buildRangeChip(CalendarSyncRange.days60),
                _buildRangeChip(CalendarSyncRange.days90),
                _buildRangeChip(CalendarSyncRange.all),
              ],
            ),
            const SizedBox(height: 16),
            const Text(
              '选择同步内容：',
              style: TextStyle(fontSize: MomoTextSize.body, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('临期物品预警 (到期前及当天提醒)'),
              value: _includeExpiring,
              onChanged: (val) => setState(() => _includeExpiring = val ?? true),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('已过期物品待清理'),
              value: _includeExpired,
              onChanged: (val) => setState(() => _includeExpired = val ?? true),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('低库存需补充物品'),
              value: _includeLowStock,
              onChanged: (val) => setState(() => _includeLowStock = val ?? true),
            ),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              title: const Text('周期循环家务 (床单/浴巾/滤芯等)'),
              value: _includeChores,
              onChanged: (val) => setState(() => _includeChores = val ?? true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _isExporting ? null : () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        FilledButton.icon(
          onPressed: _isExporting ? null : _handleSync,
          icon: _isExporting
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Icon(Icons.sync_alt_rounded, size: 18),
          label: Text(_isExporting ? '生成中...' : '导出并加入日历'),
        ),
      ],
    );
  }

  Widget _buildRangeChip(CalendarSyncRange range) {
    final isSelected = _range == range;
    return ChoiceChip(
      label: Text(range.label, style: const TextStyle(fontSize: MomoTextSize.caption)),
      selected: isSelected,
      onSelected: (selected) {
        if (selected) {
          setState(() => _range = range);
        }
      },
    );
  }

  Future<void> _handleSync() async {
    setState(() => _isExporting = true);
    try {
      final items = ref.read(inventoryProvider).valueOrNull ?? [];
      final chores = ref.read(choresProvider).valueOrNull ?? [];

      final options = CalendarSyncOptions(
        range: _range,
        includeExpiring: _includeExpiring,
        includeExpired: _includeExpired,
        includeLowStock: _includeLowStock,
        includeChores: _includeChores,
      );

      await CalendarSyncService.exportAndShareCalendar(
        items: items,
        options: options,
        chores: chores,
      );

      if (mounted) {
        Navigator.pop(context);
        showAppSnackBar(context,
          const SnackBar(content: Text('已生成日历文件，请在弹出的系统菜单中选择“添加到日历”')),
        );
      }
    } catch (e) {
      if (mounted) {
        showAppSnackBar(context,
          SnackBar(content: Text('日历同步失败：$e')),
        );
      }
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }
}
