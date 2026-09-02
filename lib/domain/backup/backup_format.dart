import 'dart:convert';

class BackupFormat {
  static const formatName = 'momobox-backup';
  static const supportedVersion = 1;
  static const requiredSections = [
    'products',
    'batches',
    'stock_movements',
    'shopping_entries',
    'settings',
  ];

  static const _requiredStringFields = <String, List<String>>{
    'products': ['id', 'name', 'category', 'unit', 'created_at', 'updated_at'],
    'batches': [
      'id',
      'product_id',
      'date_source',
      'date_precision',
      'created_at',
      'updated_at',
    ],
    'stock_movements': ['id', 'product_id', 'type', 'created_at'],
    'shopping_entries': [
      'id',
      'item_name',
      'reason',
      'created_at',
      'updated_at',
    ],
    'settings': ['key', 'value', 'updated_at'],
  };

  static const _nullableStringFields = <String, List<String>>{
    'products': ['brand', 'specification', 'barcode', 'location'],
    'batches': ['batch_no', 'production_date', 'expiry_date'],
    'stock_movements': ['batch_id', 'note'],
    'shopping_entries': ['product_id', 'category'],
    'settings': [],
  };

  static const _requiredIntFields = <String, List<String>>{
    'products': ['low_stock_threshold'],
    'batches': ['initial_quantity', 'remaining_quantity'],
    'stock_movements': ['quantity'],
    'shopping_entries': ['target_quantity'],
    'settings': [],
  };

  static const _requiredBoolFields = <String, List<String>>{
    'products': [],
    'batches': ['is_opened', 'is_discarded'],
    'stock_movements': [],
    'shopping_entries': ['is_completed'],
    'settings': [],
  };

  static const _dateFields = <String, List<String>>{
    'products': ['created_at', 'updated_at'],
    'batches': ['production_date', 'expiry_date', 'created_at', 'updated_at'],
    'stock_movements': ['created_at'],
    'shopping_entries': ['created_at', 'updated_at'],
    'settings': ['updated_at'],
  };

  static Map<String, dynamic> parse(String content) {
    Object? decoded;
    try {
      decoded = jsonDecode(content);
    } on FormatException {
      throw const FormatException('备份 JSON 格式错误。');
    }
    if (decoded is! Map<String, dynamic>) {
      throw const FormatException('不是有效的 MomoBox JSON 备份文件。');
    }
    if (decoded['format'] != formatName) {
      throw const FormatException('不是有效的 MomoBox JSON 备份文件。');
    }
    if (decoded['version'] is! int || decoded['version'] != supportedVersion) {
      throw const FormatException('当前版本不支持该备份格式。');
    }
    for (final section in requiredSections) {
      if (decoded[section] is! List<dynamic>) {
        throw FormatException('备份文件缺少或损坏 "$section" 数据段。');
      }
    }
    return Map<String, dynamic>.from(decoded);
  }

  static List<Map<String, dynamic>> records(
    Map<String, dynamic> document,
    String section,
  ) {
    if (!requiredSections.contains(section)) {
      throw ArgumentError.value(section, 'section', '不是受支持的备份数据段。');
    }
    final source = document[section];
    if (source is! List<dynamic>) {
      throw FormatException('备份文件缺少或损坏 "$section" 数据段。');
    }

    final records = <Map<String, dynamic>>[];
    for (var index = 0; index < source.length; index++) {
      final raw = source[index];
      if (raw is! Map<String, dynamic>) {
        throw FormatException('备份文件的 "$section" 第 ${index + 1} 条记录格式错误。');
      }
      final record = Map<String, dynamic>.from(raw);
      _validateRecord(section, record, index + 1);
      records.add(record);
    }
    return List.unmodifiable(records);
  }

  static void _validateRecord(
    String section,
    Map<String, dynamic> record,
    int index,
  ) {
    for (final field in _requiredStringFields[section]!) {
      final value = record[field];
      if (value is! String || value.trim().isEmpty) {
        _recordError(section, index, '“$field”必须是非空文本。');
      }
    }
    for (final field in _nullableStringFields[section]!) {
      final value = record[field];
      if (value != null && value is! String) {
        _recordError(section, index, '“$field”必须是文本或 null。');
      }
    }
    for (final field in _requiredIntFields[section]!) {
      if (record[field] is! int) {
        _recordError(section, index, '“$field”必须是整数。');
      }
    }
    for (final field in _requiredBoolFields[section]!) {
      if (record[field] is! bool) {
        _recordError(section, index, '“$field”必须是布尔值。');
      }
    }
    for (final field in _dateFields[section]!) {
      final value = record[field];
      if (value != null && (value is! String || DateTime.tryParse(value) == null)) {
        _recordError(section, index, '“$field”必须是 ISO 8601 日期时间或 null。');
      }
    }
    _validateInventoryValues(section, record, index);
  }

  static void _validateInventoryValues(
    String section,
    Map<String, dynamic> record,
    int index,
  ) {
    switch (section) {
      case 'products':
        if ((record['low_stock_threshold'] as int) < 1) {
          _recordError(section, index, '“low_stock_threshold”必须大于 0。');
        }
      case 'batches':
        final initial = record['initial_quantity'] as int;
        final remaining = record['remaining_quantity'] as int;
        if (initial < 1 || remaining < 0 || remaining > initial) {
          _recordError(
            section,
            index,
            '批次数量必须满足 initial_quantity > 0 且 0 ≤ remaining_quantity ≤ initial_quantity。',
          );
        }
        if (record['is_discarded'] as bool && remaining != 0) {
          _recordError(section, index, '已报废批次的 remaining_quantity 必须为 0。');
        }
      case 'stock_movements':
        if ((record['quantity'] as int) == 0) {
          _recordError(section, index, '“quantity”不能为 0。');
        }
      case 'shopping_entries':
        if ((record['target_quantity'] as int) < 1) {
          _recordError(section, index, '“target_quantity”必须大于 0。');
        }
      case 'settings':
        return;
    }
  }

  static Never _recordError(String section, int index, String reason) =>
      throw FormatException('备份文件的 "$section" 第 $index 条记录格式错误：$reason');
}
