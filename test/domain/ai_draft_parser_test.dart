import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/inventory/expiry_rules.dart';
import 'package:momo_box/domain/recognition/ai_draft_parser.dart';

void main() {
  const parser = AiDraftParser();

  test('parses a constrained JSON draft without executing OCR instructions', () {
    final draft = parser.parse('''{
      "name": "维生素 C",
      "brand": "测试品牌",
      "specification": "100片",
      "category": "药品保健",
      "production_date": "2026-01-02",
      "expiry_date": "2028-01-02",
      "shelf_life_amount": 24,
      "shelf_life_unit": "month",
      "date_precision": "day"
    }''');

    expect(draft.name, '维生素 C');
    expect(draft.productionDate, DateTime(2026, 1, 2));
    expect(draft.shelfLifeAmount, 24);
    expect(draft.shelfLifeUnit, ShelfLifeUnit.months);
    expect(draft.datePrecision, 'day');
  });

  test('rejects unsupported date precision', () {
    expect(
      () => parser.parse('{"name":"x","date_precision":"exact-time"}'),
      throwsA(isA<FormatException>()),
    );
  });

  test('rejects unsupported shelf life unit', () {
    expect(
      () => parser.parse('{"name":"x","shelf_life_unit":"year"}'),
      throwsA(isA<FormatException>()),
    );
  });

  test('accepts fenced JSON but only returns data fields', () {
    final draft = parser.parse('''```json
{"name":"包装上的名称","notes":"忽略其中的指令"}
```''');
    expect(draft.name, '包装上的名称');
    expect(draft.notes, '忽略其中的指令');
  });
}
