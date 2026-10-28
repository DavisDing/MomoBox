import 'dart:convert';

import '../inventory/expiry_rules.dart';
import '../inventory/product_categories.dart';
import '../models/ai_action.dart';
import 'ai_draft_parser.dart';

/// Portable prompt context, not a provider-specific structured-output option.
/// Local parsers remain authoritative even if a model ignores this contract.
abstract final class AiIntakeContract {
  static Map<String, Object?> get _category => {
        'type': 'string',
        'enum': ProductCategories.values,
        'nullable': true,
        'unknown': 'null；不得自创分类、输出多个分类或返回分类别名',
      };

  static Map<String, Object?> get _actionText => {
        'type': 'string',
        'minLength': 1,
        'maxLength': AiInventoryAction.maxTextLength,
        'unknown': '省略字段；不要用空字符串或“未知”等占位文字',
      };

  static Map<String, Object?> get _positiveInteger => {
        'type': 'integer',
        'minimum': 1,
        'maximum': AiInventoryAction.maxPositiveInteger,
      };

  static const _ocrText = {'type': 'string', 'nullable': true};
  static const _date = {
    'type': 'string',
    'format': 'YYYY-MM-DD',
    'nullable': true,
    'rule': '必须是真实日历日期；日期不完整则 null，不补猜月份或日期',
  };

  /// Applies only to intake actions, not chore categories or other actions.
  static String get assistant => jsonEncode({
        'scope': 'action.kind=intake',
        'allowed_fields': ['kind', ...AiInventoryAction.schemas['intake']!],
        'required_fields': ['kind', 'name', 'quantity'],
        'fields': {
          'kind': {'type': 'string', 'enum': ['intake']},
          for (final key in [
            'name', 'brand', 'specification', 'barcode', 'location', 'batchNo',
          ])
            key: _actionText,
          'category': _category,
          'quantity': {..._positiveInteger, 'unit': '件'},
          for (final key in ['lowStockThreshold', 'shelfLifeAmount'])
            key: {..._positiveInteger, 'unknown': '省略字段，不能返回 null'},
          for (final key in ['productionDate', 'expiryDate'])
            key: {
              ..._date,
              'minYear': AiInventoryAction.minDateYear,
              'maxYear': AiInventoryAction.maxDateYear,
            },
          'shelfLifeUnit': {
            'type': 'string',
            'enum': ShelfLifeUnit.values.map((unit) => unit.name).toList(),
            'unknown': '省略字段',
          },
        },
        'rules': [
          '只返回 allowed_fields 中的字段；不要添加 unit 或 OCR 的蛇形字段名',
          'name 和 quantity 不明时追问，不生成不完整 action',
          'category 由模型语义判断且只能选 enum 内一个值；不确定返回 null',
          'expiryDate 不早于 productionDate；无 productionDate 时省略 shelfLifeAmount',
          '提供 shelfLifeAmount 时同时明确 shelfLifeUnit，不依赖应用默认单位',
          '其他未知可选字段省略；不得编造品牌、规格、批号、位置或日期',
        ],
      });

  /// OCR uses snake_case fields and day/month instead of days/months.
  static String get ocr => jsonEncode({
        'scope': 'ocr_intake_draft',
        'fields': {
          for (final key in ['name', 'brand', 'specification', 'batch_no', 'notes'])
            key: _ocrText,
          'category': _category,
          'production_date': _date,
          'expiry_date': _date,
          'shelf_life_amount': {
            'type': 'integer', 'minimum': 1, 'nullable': true,
          },
          'shelf_life_unit': {
            'type': 'string',
            'enum': AiDraftParser.shelfLifeUnits.keys.toList(),
            'nullable': true,
          },
          'date_precision': {
            'type': 'string',
            'enum': AiDraftParser.datePrecisions.toList(),
            'nullable': true,
          },
        },
        'rules': [
          '只输出 fields 中的字段，不添加 quantity、unit、action 或驼峰字段名',
          'category 由模型语义判断且只能选 enum 内一个值；不确定返回 null',
          '其他未知字段返回 null；不要用空字符串或“未知”等占位文字',
          'date_precision 不确定时为 unknown；只有年月时不得编造具体日',
          '保质期仅提取原文，单位不明返回 null，不自行换算天数或推算日期',
        ],
      });
}
