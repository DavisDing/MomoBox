import '../inventory/expiry_rules.dart';

/// Limits for new AI proposals only; manual entry and saved data are unchanged.
abstract final class AiIntakeLimits {
  static const maxQuantity = 9999;
  static const maxLowStockThreshold = 9999;
  static const maxShelfLifeDays = 3650;
  static const maxShelfLifeMonths = 120;

  static int maxShelfLife(ShelfLifeUnit unit) => unit == ShelfLifeUnit.months
      ? maxShelfLifeMonths
      : maxShelfLifeDays;

  static void validateShelfLife(int? amount, ShelfLifeUnit? unit) {
    if (amount == null) return;
    // An unknown OCR unit stays unknown; never use a months limit for days.
    final maximum = maxShelfLife(unit ?? ShelfLifeUnit.days);
    if (amount < 1 || amount > maximum) {
      if (unit == null) {
        throw FormatException('AI 未识别保质期单位，数值须为 1～$maximum；请核对单位后手动填写。');
      }
      final label = unit == ShelfLifeUnit.months ? '个月' : '天';
      throw FormatException('AI 返回的保质期须为 1～$maximum $label；请重新解析或手动填写。');
    }
  }
}
