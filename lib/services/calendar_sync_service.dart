import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import '../domain/models/chore_models.dart';
import '../domain/models/inventory_models.dart';

/// 日历同步选项
enum CalendarSyncRange {
  days30(30, '近 30 天'),
  days60(60, '近 60 天'),
  days90(90, '近 90 天'),
  all(365, '全部时间 (1年内)');

  const CalendarSyncRange(this.days, this.label);
  final int days;
  final String label;
}

class CalendarSyncOptions {
  const CalendarSyncOptions({
    this.range = CalendarSyncRange.days60,
    this.includeExpiring = true,
    this.includeExpired = true,
    this.includeLowStock = true,
    this.includeChores = true,
  });

  final CalendarSyncRange range;
  final bool includeExpiring;
  final bool includeExpired;
  final bool includeLowStock;
  final bool includeChores;
}

class CalendarSyncService {
  /// 生成 iCalendar (.ics) 内容
  static String buildIcsContent({
    required List<InventoryItem> items,
    required CalendarSyncOptions options,
    List<ChoreItem> chores = const [],
    DateTime? now,
  }) {
    final reference = now ?? DateTime.now();
    final today = DateTime(reference.year, reference.month, reference.day);
    final limitDate = today.add(Duration(days: options.range.days));

    final buffer = StringBuffer();
    buffer.writeln('BEGIN:VCALENDAR');
    buffer.writeln('VERSION:2.0');
    buffer.writeln('PRODID:-//MomoBox//Household Inventory Calendar//CN');
    buffer.writeln('CALSCALE:GREGORIAN');
    buffer.writeln('METHOD:PUBLISH');
    buffer.writeln('X-WR-CALNAME:嬷嬷的小箱子备忘');
    buffer.writeln('X-WR-TIMEZONE:Asia/Shanghai');

    final dtStamp = _formatUtc(DateTime.now().toUtc());

    // 1. 处理库存商品的临期、过期与低库存
    for (final item in items) {
      // (1) 低库存补充提醒
      if (options.includeLowStock && item.isLowStock) {
        final uid = 'momobox-lowstock-${item.id}@momobox.local';
        final tomorrow = today.add(const Duration(days: 1));
        final dateStr = _formatDateOnly(tomorrow);
        final nextDateStr = _formatDateOnly(tomorrow.add(const Duration(days: 1)));

        buffer.writeln('BEGIN:VEVENT');
        buffer.writeln('UID:$uid');
        buffer.writeln('DTSTAMP:$dtStamp');
        buffer.writeln('DTSTART;VALUE=DATE:$dateStr');
        buffer.writeln('DTEND;VALUE=DATE:$nextDateStr');
        buffer.writeln('SUMMARY:[补货提醒] ${item.name} 库存偏低');
        buffer.writeln(
          'DESCRIPTION:物品：${item.name}\\n当前库存：${item.totalStock} ${item.unit}\\n预警阈值：${item.lowStockThreshold} ${item.unit}\\n存放位置：${item.location ?? '未标注'}\\n请及时补充库存。',
        );
        buffer.writeln('BEGIN:VALARM');
        buffer.writeln('ACTION:DISPLAY');
        buffer.writeln('DESCRIPTION:[补货提醒] ${item.name} 库存偏低');
        buffer.writeln('TRIGGER:PT9H'); // 当天早晨9点
        buffer.writeln('END:VALARM');
        buffer.writeln('END:VEVENT');
      }

      // (2) 批次到期与临期处理
      for (final batch in item.batches) {
        if (batch.isDiscarded || batch.remainingQuantity <= 0 || batch.expiryDate == null) {
          continue;
        }

        final expiryDay = DateTime(
          batch.expiryDate!.year,
          batch.expiryDate!.month,
          batch.expiryDate!.day,
        );

        // 如果超出了用户选择的时间范围，且不在过期范围内，则跳过
        if (expiryDay.isAfter(limitDate)) continue;

        final isExpired = expiryDay.isBefore(today);

        // 已过期事项
        if (isExpired) {
          if (!options.includeExpired) continue;
          final uid = 'momobox-expired-${batch.id}@momobox.local';
          final dateStr = _formatDateOnly(today);
          final nextDateStr = _formatDateOnly(today.add(const Duration(days: 1)));

          buffer.writeln('BEGIN:VEVENT');
          buffer.writeln('UID:$uid');
          buffer.writeln('DTSTAMP:$dtStamp');
          buffer.writeln('DTSTART;VALUE=DATE:$dateStr');
          buffer.writeln('DTEND;VALUE=DATE:$nextDateStr');
          buffer.writeln('SUMMARY:[已过期] ${item.name} (批次:${batch.batchNo ?? '默认'})');
          buffer.writeln(
            'DESCRIPTION:物品：${item.name}\\n到期日：${_formatDisplayDate(expiryDay)}\\n剩余数量：${batch.remainingQuantity} ${item.unit}\\n位置：${item.location ?? '未标注'}\\n物品已过期，请及时清理或更换。',
          );
          buffer.writeln('BEGIN:VALARM');
          buffer.writeln('ACTION:DISPLAY');
          buffer.writeln('DESCRIPTION:[已过期] ${item.name}');
          buffer.writeln('TRIGGER:PT9H');
          buffer.writeln('END:VALARM');
          buffer.writeln('END:VEVENT');
        } else {
          // 临期/未到期事项
          if (!options.includeExpiring) continue;
          final uid = 'momobox-expiring-${batch.id}@momobox.local';
          final dateStr = _formatDateOnly(expiryDay);
          final nextDateStr = _formatDateOnly(expiryDay.add(const Duration(days: 1)));

          buffer.writeln('BEGIN:VEVENT');
          buffer.writeln('UID:$uid');
          buffer.writeln('DTSTAMP:$dtStamp');
          buffer.writeln('DTSTART;VALUE=DATE:$dateStr');
          buffer.writeln('DTEND;VALUE=DATE:$nextDateStr');
          buffer.writeln('SUMMARY:[到期提醒] ${item.name} 批次到期');
          buffer.writeln(
            'DESCRIPTION:物品：${item.name}\\n批次：${batch.batchNo ?? '默认'}\\n到期日：${_formatDisplayDate(expiryDay)}\\n剩余数量：${batch.remainingQuantity} ${item.unit}\\n位置：${item.location ?? '未标注'}\\n请尽快使用完毕。',
          );
          // 提前3天和当天均提醒
          buffer.writeln('BEGIN:VALARM');
          buffer.writeln('ACTION:DISPLAY');
          buffer.writeln('DESCRIPTION:[即将到期] ${item.name}');
          buffer.writeln('TRIGGER:-P3D'); // 提前3天
          buffer.writeln('END:VALARM');
          buffer.writeln('BEGIN:VALARM');
          buffer.writeln('ACTION:DISPLAY');
          buffer.writeln('DESCRIPTION:[今日到期] ${item.name}');
          buffer.writeln('TRIGGER:PT9H'); // 当天上午9点
          buffer.writeln('END:VALARM');
          buffer.writeln('END:VEVENT');
        }
      }
    }

    // 2. 处理周期家务提醒 (换床单、洗浴巾、换滤芯等)
    if (options.includeChores) {
      for (final chore in chores) {
        if (!chore.isEnabled) continue;

        final uid = 'momobox-chore-${chore.id}@momobox.local';
        final dueDate = DateTime(
          chore.nextDueDate.year,
          chore.nextDueDate.month,
          chore.nextDueDate.day,
        );
        final dateStr = _formatDateOnly(dueDate);
        final nextDateStr = _formatDateOnly(dueDate.add(const Duration(days: 1)));

        buffer.writeln('BEGIN:VEVENT');
        buffer.writeln('UID:$uid');
        buffer.writeln('DTSTAMP:$dtStamp');
        buffer.writeln('DTSTART;VALUE=DATE:$dateStr');
        buffer.writeln('DTEND;VALUE=DATE:$nextDateStr');
        buffer.writeln('SUMMARY:[周期家务] ${chore.title}');
        buffer.writeln(
          'DESCRIPTION:周期家务：${chore.title}\\n类别：${chore.category}\\n循环频率：${chore.repeatDescription}\\n备注：${chore.notes ?? '定期维护维护良好卫生习惯'}',
        );

        // 添加标准 RRULE 循环规则
        final rrule = switch (chore.repeatInterval) {
          ChoreRepeatInterval.daily => 'RRULE:FREQ=DAILY;INTERVAL=1',
          ChoreRepeatInterval.weekly => 'RRULE:FREQ=WEEKLY;INTERVAL=1',
          ChoreRepeatInterval.biweekly => 'RRULE:FREQ=WEEKLY;INTERVAL=2',
          ChoreRepeatInterval.monthly => 'RRULE:FREQ=MONTHLY;INTERVAL=1',
          ChoreRepeatInterval.quarterly => 'RRULE:FREQ=MONTHLY;INTERVAL=3',
        };
        buffer.writeln(rrule);

        buffer.writeln('BEGIN:VALARM');
        buffer.writeln('ACTION:DISPLAY');
        buffer.writeln('DESCRIPTION:[家务提醒] ${chore.title}');
        buffer.writeln('TRIGGER:PT9H');
        buffer.writeln('END:VALARM');
        buffer.writeln('END:VEVENT');
      }
    }

    buffer.writeln('END:VCALENDAR');
    return buffer.toString();
  }

  /// 导出并调起系统共享/日历应用
  static Future<ShareResult> exportAndShareCalendar({
    required List<InventoryItem> items,
    required CalendarSyncOptions options,
    List<ChoreItem> chores = const [],
  }) async {
    final icsString = buildIcsContent(
      items: items,
      options: options,
      chores: chores,
    );

    final tempDir = await getTemporaryDirectory();
    final file = File('${tempDir.path}/momobox_reminders.ics');
    await file.writeAsString(icsString);

    return Share.shareXFiles(
      [XFile(file.path, mimeType: 'text/calendar', name: 'momobox_reminders.ics')],
      subject: '嬷嬷的小箱子-日历日程',
      text: '已生成日历日程，轻点直接添加到您的系统日历中。',
    );
  }

  static String _formatDateOnly(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    return '$y$m$d';
  }

  static String _formatUtc(DateTime date) {
    final y = date.year.toString().padLeft(4, '0');
    final m = date.month.toString().padLeft(2, '0');
    final d = date.day.toString().padLeft(2, '0');
    final h = date.hour.toString().padLeft(2, '0');
    final min = date.minute.toString().padLeft(2, '0');
    final s = date.second.toString().padLeft(2, '0');
    return '$y$m${d}T$h$min${s}Z';
  }

  static String _formatDisplayDate(DateTime date) {
    return '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';
  }
}
