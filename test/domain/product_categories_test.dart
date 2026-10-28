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

  for (final entry in <String?, String>{
    null: '其他物品', '零食': '零食饮料', '食品生鲜': '食品生鲜', '药品保健': '药品保健',
  }.entries) {
    final category = entry.key;
    test('保留模型分类=$category，不按薯片关键词覆盖或补猜', () {
      final action = AiInventoryAction.fromJson({
        'kind': 'intake', 'name': '薯片', 'quantity': 1,
        if (category != null) 'category': category,
      })!;
      final draft = action.intakeDraft;
      expect(draft.name, '薯片');
      expect(draft.quantity, 1);
      expect(draft.category, entry.value);
      expect(draft.brand, isNull);
      expect(draft.specification, isNull);
      expect(draft.productionDate, isNull);
      expect(draft.expiryDate, isNull);
      expect(draft.shelfLifeAmount, isNull);
      final summary = AiInventoryAction.displayText(jsonEncode({'action': action.toJson()}));
      expect(summary, contains('薯片 × 1 件'));
      expect(summary, contains('分类：${entry.value}'));
      expect(summary, contains('尚未执行'));
    });
  }

  test('用户给出的品牌规格数量进入草稿，保留真实值', () {
    final draft = AiInventoryAction.fromJson({
      'kind': 'intake', 'name': '薯片', 'quantity': 2,
      'category': '零食饮料',
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
    expect(ProductCategories.forManualEntry(name: '待确认物品'), '其他物品');
    expect(ProductCategories.suggestForName('苹果手机'), isNull);
    for (final name in ['巧克力味香薰', '巧克力味香薰70g', '薯片玩具',
      '薯片玩具（蓝色）', '维生素软糖']) {
      expect(ProductCategories.suggestForName(name), isNull);
    }
    expect(ProductCategories.forManualEntry(name: '宠物饼干', category: '宠物用品'), '宠物用品');
    expect(ProductCategories.forManualEntry(name: '维生素C', category: '药品保健'), '药品保健');
    expect(AiInventoryAction.fromJson({
      'kind': 'intake', 'name': '薯片', 'quantity': '一包',
    }), isNull);
  });

  test('限定词只修正相关线索，不因单字或无关用途整条放弃', () {
    const cases = {
      '宠物零食薯片': '宠物用品',
      '猫粮饼干': '宠物用品',
      '宠物饼干': '宠物用品',
      '宠物湿巾': '宠物用品',
      '香薰湿巾': '纸品湿巾',
      '玩具收纳抽纸': '纸品湿巾',
      '药用湿巾': '纸品湿巾',
      '山药薯片': '零食饮料',
      '猫山王饼干': '零食饮料',
      '狗年饼干': '零食饮料',
    };
    for (final entry in cases.entries) {
      expect(ProductCategories.suggestForName(entry.key), entry.value,
        reason: entry.key);
    }
  });

  test('多分类冲突无本地赢家，同分类多词仍可给出唯一建议', () {
    for (final name in ['洗衣液湿巾', '湿巾洗衣液', '抽纸盒电池', '电池抽纸盒',
      '洗洁精灯泡', '灯泡洗洁精']) {
      expect(ProductCategories.suggestForName(name), isNull, reason: name);
      expect(ProductCategories.forManualEntry(name: name), '其他物品');
    }
    expect(ProductCategories.suggestForName('薯片饼干'), '零食饮料');
    expect(ProductCategories.forManualEntry(
      name: '洗衣液湿巾', category: '清洁用品',
    ), '家居清洁');
    expect(ProductCategories.forManualEntry(
      name: '洗衣液湿巾', category: '未知分类',
    ), '其他物品');
  });

  test('入库摘要按行展示可选字段，缺失字段不生成空行', () {
    final text = AiInventoryAction.displayText(jsonEncode({'action': {
      'kind': 'intake', 'name': '薯片', 'quantity': 1,
      'category': '零食饮料',
      'brand': '已提供品牌', 'specification': '70g/袋',
    }}));
    expect(text.split('\n'), [
      '入库草稿：薯片 × 1 件',
      '分类：零食饮料',
      '品牌：已提供品牌',
      '规格：70g/袋',
      '尚未执行，核对草稿后确认入库。',
    ]);
    final withoutBrand = AiInventoryAction.displayText(jsonEncode({'action': {
      'kind': 'intake', 'name': '薯片', 'quantity': 1, 'specification': '70g/袋',
    }}));
    expect(withoutBrand, isNot(contains('品牌：')));
    expect(withoutBrand, contains('规格：70g/袋'));
    expect(withoutBrand, isNot(contains('\n\n')));
  });

  test('OCR 仅规范化模型分类，名称不是应用补猜或重分类依据', () {
    const parser = AiDraftParser();
    expect(parser.parse('{"name":"薯片","category":"零食"}').category, '零食饮料');
    expect(parser.parse('{"name":"薯片","category":"药品保健"}').category, '药品保健');
    expect(parser.parse('{"name":"薯片","category":"食品生鲜"}').category, '食品生鲜');
    expect(parser.parse('{"name":"薯片"}').category, isNull);
    expect(parser.parse('{"name":"薯片","category":null}').category, isNull);
    expect(parser.parse('{}').isEmpty, isTrue);
    expect(parser.parse('{"name":"未知物品"}').category, isNull);
  });

  test('不支持的模型分类拒绝应用，不靠名称改成合法分类', () {
    const parser = AiDraftParser();
    for (final category in <Object>['未支持分类', 42, true, <String>[]]) {
      expect(() => parser.parse(jsonEncode({'name': '薯片', 'category': category})),
        throwsA(isA<FormatException>()));
      expect(AiInventoryAction.fromJson({
        'kind': 'intake', 'name': '薯片', 'quantity': 1, 'category': category,
      }), isNull);
    }
  });
}
