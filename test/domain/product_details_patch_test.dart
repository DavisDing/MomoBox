import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/models/ai_action.dart';
import 'package:momo_box/domain/models/product_details_patch.dart';

void main() {
  AiInventoryAction? parse(Map<String, Object?> fields) =>
      AiInventoryAction.parse(
        jsonEncode({
          'reply': '已替你修改好了',
          'action': {
            'kind': 'product_update',
            'productId': 'real-id',
            ...fields,
          },
        }),
      );

  test('资料修改只保留明确字段，规范分类并允许明确清空可选资料', () {
    final action =
        parse({'category': '药品', 'brand': null, 'location': ' 药箱 '})!;
    expect(action.arguments, {
      'category': '药品保健',
      'brand': null,
      'location': '药箱',
    });
    expect(action.arguments.containsKey('specification'), isFalse);
    expect(
      AiInventoryAction.fromJson(action.toJson())!.toJson(),
      action.toJson(),
    );
    final display = AiInventoryAction.displayText(
      jsonEncode({'reply': '已替你修改好了', 'action': action.toJson()}),
    );
    expect(display, contains('尚未修改'));
    expect(display, contains('品牌 → 清空'));
    expect(display, isNot(contains('已替你修改好了')));
    final patch = ProductDetailsPatch.fromJson(action.arguments);
    expect(
      patch.changesFrom({'category': '零食饮料', 'brand': '旧品牌', 'location': null}),
      '分类：零食饮料 → 药品保健\n品牌：旧品牌 → 清空\n存放位置：未填写 → 药箱',
    );
    expect(() => patch.values['name'] = '篡改', throwsUnsupportedError);
  });

  test('空修改、非法分类、必填清空及非文字不可执行', () {
    for (final fields in <Map<String, Object?>>[
      {},
      {'category': null},
      {'name': null},
      {'category': '随便的新分类'},
      {'brand': ''},
      {'location': '  '},
      {'name': 123},
      {'brand': false},
      {
        'specification': ['一盒'],
      },
      {'name': '坏\x00名称'},
      {'name': '物' * 256},
      {'brand': '牌' * 1001},
    ]) {
      expect(parse(fields), isNull, reason: fields.keys.join(','));
    }
    // NAS counts Unicode characters, including supplementary-plane text.
    expect(parse({'name': '🧴' * 255}), isNotNull);
  });

  test('资料操作不能夹带库存、日期、单位、家庭或任意设置', () {
    for (final field in [
      'quantity',
      'expiryDate',
      'productionDate',
      'unit',
      'lowStockThreshold',
      'familyId',
      'serverVersion',
      'deletedAt',
      'sql',
      'apiKey',
    ]) {
      expect(parse({'category': '药品保健', field: '不允许'}), isNull, reason: field);
    }
    expect(
      AiInventoryAction.fromJson({
        'kind': 'product_update',
        'category': '药品保健',
      }),
      isNull,
    );
    expect(
      AiInventoryAction.parse(
        '```json\n${jsonEncode({
          'action': parse({'brand': '新品牌'})!.toJson(),
        })}\n```',
      ),
      isNull,
    );
  });
}
