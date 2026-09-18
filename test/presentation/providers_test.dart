import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/presentation/controllers/providers.dart';

void main() {
  group('normalizeHomeSectionOrder', () {
    test('空设置回退默认顺序', () {
      expect(normalizeHomeSectionOrder(null), defaultHomeSectionOrder);
      expect(normalizeHomeSectionOrder('   '), defaultHomeSectionOrder);
    });

    test('过滤未知模块、去重并补齐缺失模块', () {
      expect(
        normalizeHomeSectionOrder(
          'shopping_summary,unknown,quick_intake,shopping_summary',
        ),
        [
          'shopping_summary',
          'quick_intake',
          'alert_summary',
          'chores_card',
          'smart_home_quick',
        ],
      );
    });
  });

  group('normalizeFontScale', () {
    test('非法或越界值回退默认比例', () {
      for (final value in [
        null,
        '',
        'NaN',
        'Infinity',
        '-Infinity',
        '-1',
        '0',
        '100000',
      ]) {
        expect(normalizeFontScale(value), 1.0, reason: 'value=$value');
      }
    });

    test('保留合法比例和边界值', () {
      expect(normalizeFontScale('1.15'), 1.15);
      expect(normalizeFontScale('0.8'), 0.8);
      expect(normalizeFontScale('1.6'), 1.6);
    });
  });
}
