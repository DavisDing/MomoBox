import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/product_categories.dart';
import 'package:momo_box/domain/models/ai_action.dart';
import 'package:momo_box/domain/recognition/ai_draft_parser.dart';

void main() {
  test('分类选项稳定且无重复，不使用第一项作为默认值', () {
    expect(ProductCategories.values.toSet().length, ProductCategories.values.length);
    expect(ProductCategories.fallback, '其他物品');
    expect(ProductCategories.canonical('零食'), '零食饮料');
    expect(ProductCategories.canonical(' 休闲食品 '), '零食饮料');
    expect(ProductCategories.canonical('未支持分类'), isNull);
  });

  for (final category in [null, '零食', '食品生鲜', '药品保健']) {
    test('一包薯片生成零食草稿，建议分类=$category，不编造其他字段', () {
      final action = AiInventoryAction.fromJson({
        'kind': 'intake', 'name': '薯片', 'quantity': 1,
        if (category != null) 'category': category,
      })!;
      final draft = action.intakeDraft;
      expect(draft.name, '薯片');
      expect(draft.quantity, 1);
      expect(draft.category, '零食饮料');
      expect(draft.brand, isNull);
      expect(draft.specification, isNull);
      expect(draft.productionDate, isNull);
      expect(draft.expiryDate, isNull);
      expect(draft.shelfLifeAmount, isNull);
      final summary = AiInventoryAction.displayText(jsonEncode({'action': action.toJson()}));
      expect(summary, contains('薯片 × 1 件'));
      expect(summary, contains('分类：零食饮料'));
      expect(summary, contains('尚未执行'));
    });
  }

  test('用户给出的品牌规格数量进入草稿，保留真实值', () {
    final draft = AiInventoryAction.fromJson({
      'kind': 'intake', 'name': '薯片', 'quantity': 2,
      'brand': '用户提供品牌', 'specification': '70g/袋',
      'location': '零食柜',
    })!.intakeDraft;
    expect(draft.quantity, 2);
    expect(draft.brand, '用户提供品牌');
    expect(draft.specification, '70g/袋');
    expect(draft.location, '零食柜');
    expect(draft.category, '零食饮料');
  });

  test('未知名称无分类时保持中性默认，不猜药品或换算数量', () {
    expect(ProductCategories.forSuggestion(name: '待确认物品'), '其他物品');
    expect(ProductCategories.suggestForName('苹果手机'), isNull);
    for (final name in ['宠物饼干', '巧克力味香薰', '薯片玩具', '维生素软糖']) {
      expect(ProductCategories.suggestForName(name), isNull);
    }
    expect(ProductCategories.forSuggestion(name: '宠物饼干', category: '宠物用品'), '宠物用品');
    expect(ProductCategories.forSuggestion(name: '维生素C', category: '药品保健'), '药品保健');
    expect(AiInventoryAction.fromJson({
      'kind': 'intake', 'name': '薯片', 'quantity': '一包',
    }), isNull);
  });

  test('OCR 和助手使用相同分类映射，空解析不凭空制造内容', () {
    const parser = AiDraftParser();
    expect(parser.parse('{"name":"薯片","category":"零食"}').category, '零食饮料');
    expect(parser.parse('{"name":"薯片","category":"药品保健"}').category, '零食饮料');
    expect(parser.parse('{"name":"薯片"}').category, '零食饮料');
    expect(parser.parse('{}').isEmpty, isTrue);
    expect(parser.parse('{"name":"未知物品"}').category, isNull);
  });
}
