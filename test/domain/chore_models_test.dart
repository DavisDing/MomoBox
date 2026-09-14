import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/chore_models.dart';

void main() {
  group('ChoreItem 周期推算与状态测试', () {
    final baseToday = DateTime(2026, 9, 14);

    test('每周与每两周循环模式计算正确', () {
      final weeklyChore = ChoreItem(
        id: 'c1',
        title: '洗浴巾',
        category: '个人卫生',
        repeatInterval: ChoreRepeatInterval.weekly,
        nextDueDate: baseToday.add(const Duration(days: 7)),
      );

      expect(weeklyChore.intervalDays, 7);
      expect(weeklyChore.repeatDescription, '每周');
      expect(weeklyChore.daysUntil(today: baseToday), 7);
      expect(weeklyChore.isDue(today: baseToday), isFalse);

      // 打卡完成推算下个周期
      final nextWeekly = weeklyChore.complete(completionDate: baseToday);
      expect(nextWeekly.nextDueDate, DateTime(2026, 9, 21));
      expect(nextWeekly.lastCompletedDate, baseToday);

      final biweeklyChore = ChoreItem(
        id: 'c2',
        title: '换床单被罩',
        category: '家居清洁',
        repeatInterval: ChoreRepeatInterval.biweekly,
        nextDueDate: baseToday.subtract(const Duration(days: 1)),
      );
      expect(biweeklyChore.intervalDays, 14);
      expect(biweeklyChore.isDue(today: baseToday), isTrue);
      expect(biweeklyChore.daysUntil(today: baseToday), -1);

      final nextBiweekly = biweeklyChore.complete(completionDate: baseToday);
      expect(nextBiweekly.nextDueDate, DateTime(2026, 9, 28));
    });

    test('按天与按月模式计算正确', () {
      final dailyChore = ChoreItem(
        id: 'c3',
        title: '擦桌面',
        category: '家居清洁',
        repeatInterval: ChoreRepeatInterval.daily,
        nextDueDate: baseToday,
      );
      expect(dailyChore.intervalDays, 1);
      expect(dailyChore.isDue(today: baseToday), isTrue);

      final nextDaily = dailyChore.complete(completionDate: baseToday);
      expect(nextDaily.nextDueDate, DateTime(2026, 9, 15));

      final monthlyChore = ChoreItem(
        id: 'c4',
        title: '换滤芯',
        category: '耗材更换',
        repeatInterval: ChoreRepeatInterval.monthly,
        nextDueDate: baseToday.add(const Duration(days: 30)),
      );
      expect(monthlyChore.intervalDays, 30);
      expect(monthlyChore.repeatDescription, '每月');
    });

    test('JSON 序列化与反序列化完整且一致', () {
      final item = ChoreItem(
        id: 'test-1',
        title: '清洗窗帘',
        category: '家居清洁',
        repeatInterval: ChoreRepeatInterval.quarterly,
        nextDueDate: DateTime(2026, 12, 1),
        notes: '拆卸前标记挂钩位置',
      );

      final json = item.toJson();
      final restored = ChoreItem.fromJson(json);

      expect(restored.id, item.id);
      expect(restored.title, item.title);
      expect(restored.category, item.category);
      expect(restored.repeatInterval, item.repeatInterval);
      expect(restored.notes, item.notes);
      expect(restored.nextDueDate, item.nextDueDate);
    });
  });
}
