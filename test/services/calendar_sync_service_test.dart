import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/chore_models.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/services/calendar_sync_service.dart';

void main() {
  group('CalendarSyncService 生成标准 iCalendar (.ics) 日历日程', () {
    final baseToday = DateTime(2026, 9, 14);

    final testItems = [
      // 1. 低库存商品
      InventoryItem(
        id: 'prod-low',
        name: '纸巾',
        category: '生活日用',
        brand: null,
        specification: null,
        barcode: null,
        location: '客厅柜子',
        unit: '件',
        lowStockThreshold: 5,
        batches: [
          InventoryBatch(
            id: 'batch-low-1',
            productId: 'prod-low',
            batchNo: null,
            initialQuantity: 10,
            remainingQuantity: 2,
            isDiscarded: false,
            expiryDate: null,
            productionDate: null,
          ),
        ],
      ),
      // 2. 临期商品 (在近30天内到期)
      InventoryItem(
        id: 'prod-expiring',
        name: '鲜牛奶',
        category: '食品生鲜',
        brand: null,
        specification: null,
        barcode: null,
        location: '冰箱二层',
        unit: '件',
        lowStockThreshold: 0,
        batches: [
          InventoryBatch(
            id: 'batch-milk-1',
            productId: 'prod-expiring',
            batchNo: '20260910',
            initialQuantity: 1,
            remainingQuantity: 1,
            isDiscarded: false,
            expiryDate: baseToday.add(const Duration(days: 3)),
            productionDate: null,
          ),
        ],
      ),
      // 3. 远期商品 (80天后到期，30天范围应排除，90天范围应包含)
      InventoryItem(
        id: 'prod-far',
        name: '常温酸奶',
        category: '食品生鲜',
        brand: null,
        specification: null,
        barcode: null,
        location: null,
        unit: '件',
        lowStockThreshold: 1,
        batches: [
          InventoryBatch(
            id: 'batch-yogurt-1',
            productId: 'prod-far',
            batchNo: null,
            initialQuantity: 6,
            remainingQuantity: 4,
            isDiscarded: false,
            expiryDate: baseToday.add(const Duration(days: 80)),
            productionDate: null,
          ),
        ],
      ),
      // 4. 已过期商品
      InventoryItem(
        id: 'prod-expired',
        name: '面包',
        category: '食品生鲜',
        brand: null,
        specification: null,
        barcode: null,
        location: null,
        unit: '件',
        lowStockThreshold: 0,
        batches: [
          InventoryBatch(
            id: 'batch-bread-1',
            productId: 'prod-expired',
            batchNo: null,
            initialQuantity: 1,
            remainingQuantity: 1,
            isDiscarded: false,
            expiryDate: baseToday.subtract(const Duration(days: 2)),
            productionDate: null,
          ),
        ],
      ),
    ];

    final testChores = [
      ChoreItem(
        id: 'chore-sheets',
        title: '换床单被罩',
        category: '家居清洁',
        repeatInterval: ChoreRepeatInterval.biweekly,
        nextDueDate: baseToday.add(const Duration(days: 5)),
        notes: '60度高温清洗杀菌',
      ),
    ];

    test('在近30天范围内导出日历', () {
      final ics30 = CalendarSyncService.buildIcsContent(
        items: testItems,
        options: const CalendarSyncOptions(
          range: CalendarSyncRange.days30,
          includeExpiring: true,
          includeExpired: true,
          includeLowStock: true,
          includeChores: true,
        ),
        chores: testChores,
        now: baseToday,
      );

      // 验证基础日历结构
      expect(ics30, contains('BEGIN:VCALENDAR'));
      expect(ics30, contains('VERSION:2.0'));
      expect(ics30, contains('X-WR-CALNAME:嬷嬷的小箱子备忘'));

      // 验证低库存提醒
      expect(ics30, contains('SUMMARY:[补货提醒] 纸巾 库存偏低'));
      expect(ics30, contains('预警阈值：5 件'));

      // 验证临期提醒 (鲜牛奶)
      expect(ics30, contains('SUMMARY:[到期提醒] 鲜牛奶 批次到期'));

      // 验证已过期提醒 (面包)
      expect(ics30, contains('SUMMARY:[已过期] 面包'));

      // 80天后的酸奶不应该出现在近30天选项中
      expect(ics30, isNot(contains('常温酸奶')));

      // 验证周期家务及 RRULE
      expect(ics30, contains('SUMMARY:[周期家务] 换床单被罩'));
      expect(ics30, contains('RRULE:FREQ=WEEKLY;INTERVAL=2'));

      // All four kinds retain an all-day event with a 9-hour AFTER-start alarm.
      final events = ics30.split('BEGIN:VEVENT').skip(1).toList();
      expect(events, hasLength(4));
      for (final event in events) {
        final date = RegExp(r'DTSTART;VALUE=DATE:(\d{4})(\d{2})(\d{2})')
            .firstMatch(event)!;
        final start = DateTime(
          int.parse(date.group(1)!), int.parse(date.group(2)!), int.parse(date.group(3)!),
        );
        expect(event, contains('TRIGGER:PT9H'));
        expect(event, isNot(contains('TRIGGER:-PT9H')));
        final alarm = start.add(const Duration(hours: 9));
        expect(alarm.day, start.day);
        expect(alarm.hour, 9);
      }
      expect(ics30, contains('TRIGGER:-P3D')); // Existing advance alarm remains.
      expect(ics30, contains('END:VCALENDAR'));
    });

    test('转义动态文本并使用标准 CRLF 行结束符', () {
      final item = InventoryItem(
        id: 'prod-special',
        name: '牛奶,特价;A\\B\n注入',
        category: '食品生鲜',
        brand: null,
        specification: null,
        barcode: null,
        location: '冷藏\r\nX-TEST:bad',
        unit: '盒,装',
        lowStockThreshold: 2,
        batches: [
          InventoryBatch(
            id: 'batch-special',
            productId: 'prod-special',
            batchNo: 'B,1;\\换行\nX-BATCH:bad',
            initialQuantity: 1,
            remainingQuantity: 1,
            isDiscarded: false,
            expiryDate: baseToday.add(const Duration(days: 3)),
            productionDate: null,
          ),
        ],
      );
      final chore = ChoreItem(
        id: 'chore-special',
        title: '清洁,厨房;A\\B\nX-CHORE:bad',
        category: '家居\r\nX-CATEGORY:bad',
        repeatInterval: ChoreRepeatInterval.weekly,
        nextDueDate: baseToday,
        notes: '备注,一;二\\三\nX-NOTE:bad',
      );

      final ics = CalendarSyncService.buildIcsContent(
        items: [item],
        options: const CalendarSyncOptions(),
        chores: [chore],
        now: baseToday,
      );

      expect(
        ics,
        contains(r'SUMMARY:[补货提醒] 牛奶\,特价\;A\\B\n注入 库存偏低'),
      );
      expect(ics, contains(r'批次：B\,1\;\\换行\nX-BATCH:bad'));
      expect(ics, contains(r'存放位置：冷藏\nX-TEST:bad'));
      expect(ics, contains(r'备注：备注\,一\;二\\三\nX-NOTE:bad'));
      expect(ics, isNot(contains('\r\nX-TEST:bad')));
      expect(ics, isNot(contains('\r\nX-BATCH:bad')));
      expect(ics, isNot(contains('\r\nX-CHORE:bad')));
      expect(ics, isNot(contains('\r\nX-CATEGORY:bad')));
      expect(ics, isNot(contains('\r\nX-NOTE:bad')));
      expect(ics.replaceAll('\r\n', ''), isNot(contains('\n')));
      expect(ics.replaceAll('\r\n', ''), isNot(contains('\r')));
    });

    test('在近90天范围内导出日历应包含远期商品', () {
      final ics90 = CalendarSyncService.buildIcsContent(
        items: testItems,
        options: const CalendarSyncOptions(
          range: CalendarSyncRange.days90,
          includeExpiring: true,
          includeExpired: false, // 排除已过期
          includeLowStock: false, // 排除低库存
          includeChores: false,
        ),
        chores: testChores,
        now: baseToday,
      );

      // 包含近期的鲜牛奶和80天后的常温酸奶
      expect(ics90, contains('SUMMARY:[到期提醒] 鲜牛奶 批次到期'));
      expect(ics90, contains('SUMMARY:[到期提醒] 常温酸奶 批次到期'));

      // 已过期和低库存被排除
      expect(ics90, isNot(contains('[已过期] 面包')));
      expect(ics90, isNot(contains('[补货提醒] 纸巾')));
      expect(ics90, isNot(contains('[周期家务]')));
    });
  });
}
