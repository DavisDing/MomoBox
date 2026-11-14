import '../inventory/product_categories.dart';
import 'inventory_models.dart';

/// Omitted fields are retained. Only an explicit null clears an optional field.
/// Stock, dates, ownership, units and service configuration cannot be patched.
class ProductDetailsPatch {
  ProductDetailsPatch._(this.values);

  static const labels = <String, String>{
    'name': '名称',
    'category': '分类',
    'brand': '品牌',
    'specification': '规格',
    'location': '存放位置',
    'barcode': '条码',
  };
  final Map<String, String?> values;

  factory ProductDetailsPatch.fromJson(Map<String, Object?> fields) {
    if (fields.isEmpty || fields.keys.any((key) => !labels.containsKey(key))) {
      throw const FormatException('请选择要修改的物品资料字段。');
    }
    final values = <String, String?>{};
    for (final entry in fields.entries) {
      final value = entry.value;
      if (value == null && entry.key != 'name' && entry.key != 'category') {
        values[entry.key] = null;
        continue;
      }
      if (value is! String ||
          value.trim().isEmpty ||
          value.contains('\x00') ||
          value.runes.length > (entry.key == 'name' ? 255 : 1000)) {
        throw FormatException(
          '${labels[entry.key]}无效；未知字段请省略，清空可选字段请明确指定 null。',
        );
      }
      values[entry.key] =
          entry.key == 'category'
              ? ProductCategories.validateAiCategory(value)!
              : value.trim();
    }
    return ProductDetailsPatch._(Map.unmodifiable(values));
  }

  static Map<String, String?> snapshot(InventoryItem item) => {
    'name': item.name,
    'category': item.category,
    'brand': item.brand,
    'specification': item.specification,
    'location': item.location,
    'barcode': item.barcode,
  };

  String changesFrom(Map<String, String?> before) => values.entries
      .where((entry) => entry.value != before[entry.key])
      .map(
        (entry) =>
            '${labels[entry.key]}：${before[entry.key] ?? '未填写'} → ${entry.value ?? '清空'}',
      )
      .join('\n');
}
