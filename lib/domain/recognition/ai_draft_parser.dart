import 'dart:convert';

import '../inventory/expiry_rules.dart';
import '../inventory/calendar_date.dart';
import '../inventory/product_categories.dart';
import '../models/recognition_models.dart';
import 'ai_intake_limits.dart';

typedef ReceiptLine = ({String name, int? quantity, String category});

class AiDraftParser {
  const AiDraftParser();

  // Wire values are singular here, unlike assistant action units.
  static const shelfLifeUnits = {
    'day': ShelfLifeUnit.days,
    'month': ShelfLifeUnit.months,
  };
  static const datePrecisions = {'day', 'month', 'unknown'};
  static const maxReceiptItems = 30;

  List<ReceiptLine> parseReceipt(String content) {
    final decoded = jsonDecode(_jsonObject(content));
    if (decoded is Map && decoded['truncated'] == true) {
      throw const FormatException('小票商品太多，请分段拍摄。');
    }
    final items = decoded is Map ? decoded['items'] : null;
    if (items is! List || items.isEmpty || items.length > maxReceiptItems) {
      throw const FormatException('未识别到可用的小票商品，或商品太多，请分段拍摄。');
    }
    return items.map((item) {
      if (item is! Map ||
          item.keys.any((key) => !const {'name', 'quantity', 'category'}.contains(key))) {
        throw const FormatException('小票商品格式无效。');
      }
      final name = stringOrNull(item['name']);
      final quantity = item['quantity'];
      if (name == null || name.runes.length > 255) {
        throw const FormatException('小票商品缺少可用名称。');
      }
      if (quantity != null &&
          (quantity is! int || quantity < 1 || quantity > AiIntakeLimits.maxQuantity)) {
        throw const FormatException('小票商品数量必须为有效的正整数件数。');
      }
      return (
        name: name,
        quantity: quantity as int?,
        category: ProductCategories.validateAiCategory(item['category']) ?? ProductCategories.fallback,
      );
    }).toList(growable: false);
  }

  IntakeDraftSuggestion parse(String content) {
    final decoded = jsonDecode(_jsonObject(content));
    if (decoded is! Map<String, dynamic>) throw const FormatException('AI 未返回对象形式的草稿。');
    final productionDate = _parseDate(decoded['production_date']);
    final expiryDate = _parseDate(decoded['expiry_date']);
    final precision = stringOrNull(decoded['date_precision']);
    if (precision != null && !datePrecisions.contains(precision)) {
      throw const FormatException('AI 返回了不支持的日期精度。');
    }
    final shelfLife = decoded['shelf_life_amount'];
    final shelfLifeAmount = shelfLife is int ? shelfLife : int.tryParse('$shelfLife');
    final shelfLifeUnit = _parseShelfLifeUnit(decoded['shelf_life_unit']);
    AiIntakeLimits.validateShelfLife(shelfLifeAmount, shelfLifeUnit);
    final name = stringOrNull(decoded['name']);
    return IntakeDraftSuggestion(
      name: name,
      brand: stringOrNull(decoded['brand']),
      specification: stringOrNull(decoded['specification']),
      category: ProductCategories.validateAiCategory(decoded['category']),
      batchNo: stringOrNull(decoded['batch_no']),
      productionDate: productionDate,
      expiryDate: expiryDate,
      shelfLifeAmount: shelfLifeAmount,
      shelfLifeUnit: shelfLifeUnit,
      datePrecision: precision,
      notes: stringOrNull(decoded['notes']),
    );
  }

  ShelfLifeUnit? _parseShelfLifeUnit(Object? value) {
    final raw = stringOrNull(value);
    if (raw == null) return null;
    final unit = shelfLifeUnits[raw];
    if (unit == null) throw const FormatException('AI 返回了不支持的保质期单位。');
    return unit;
  }

  String _jsonObject(String content) {
    final normalized = content.trim();
    if (normalized.startsWith('```')) {
      final firstBreak = normalized.indexOf('\n');
      final endFence = normalized.lastIndexOf('```');
      if (firstBreak < 0 || endFence <= firstBreak) throw const FormatException('AI 未返回有效 JSON。');
      return normalized.substring(firstBreak + 1, endFence).trim();
    }
    return normalized;
  }

  DateTime? _parseDate(Object? value) {
    final raw = stringOrNull(value);
    if (raw == null) return null;
    final DateTime date;
    try {
      date = CalendarDate.decode(raw);
    } on FormatException {
      throw FormatException('AI 返回的日期无效：$raw');
    }
    return DateTime(date.year, date.month, date.day);
  }
}
