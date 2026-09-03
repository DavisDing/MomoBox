import 'dart:convert';

import '../models/recognition_models.dart';

class AiDraftParser {
  const AiDraftParser();

  IntakeDraftSuggestion parse(String content) {
    final decoded = jsonDecode(_jsonObject(content));
    if (decoded is! Map<String, dynamic>) throw const FormatException('AI 未返回对象形式的草稿。');
    final productionDate = _parseDate(decoded['production_date']);
    final expiryDate = _parseDate(decoded['expiry_date']);
    final precision = stringOrNull(decoded['date_precision']);
    if (precision != null && !const {'day', 'month', 'unknown'}.contains(precision)) {
      throw const FormatException('AI 返回了不支持的日期精度。');
    }
    final shelfLife = decoded['shelf_life_amount'];
    final shelfLifeAmount = shelfLife is int ? shelfLife : int.tryParse('$shelfLife');
    final shelfLifeUnit = _parseShelfLifeUnit(decoded['shelf_life_unit']);
    if (shelfLifeAmount != null && shelfLifeAmount < 1) {
      throw const FormatException('AI 返回的保质期必须大于 0。');
    }
    return IntakeDraftSuggestion(
      name: stringOrNull(decoded['name']),
      brand: stringOrNull(decoded['brand']),
      specification: stringOrNull(decoded['specification']),
      category: stringOrNull(decoded['category']),
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
    return switch (raw) {
      'day' => ShelfLifeUnit.days,
      'month' => ShelfLifeUnit.months,
      _ => throw const FormatException('AI 返回了不支持的保质期单位。'),
    };
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
    final date = DateTime.tryParse(raw);
    if (date == null) throw FormatException('AI 返回的日期无效：$raw');
    return DateTime(date.year, date.month, date.day);
  }
}
