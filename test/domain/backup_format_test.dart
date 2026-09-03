import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/backup/backup_format.dart';

Map<String, Object?> validDocument() => {
      'format': BackupFormat.formatName,
      'version': BackupFormat.supportedVersion,
      'products': [],
      'batches': [],
      'stock_movements': [],
      'shopping_entries': [],
      'settings': [],
      'reminder_acknowledgements': [],
      'barcode_lookup_cache': [],
    };

Map<String, Object?> validProduct() => {
      'id': 'product-1',
      'name': '维生素 C',
      'category': '药品保健',
      'brand': null,
      'specification': null,
      'barcode': null,
      'location': null,
      'unit': '件',
      'low_stock_threshold': 1,
      'created_at': '2026-09-02T08:00:00.000',
      'updated_at': '2026-09-02T08:00:00.000',
    };

void main() {
  test('接受完整的当前版本备份结构', () {
    final document = BackupFormat.parse(jsonEncode(validDocument()));
    expect(BackupFormat.records(document, 'products'), isEmpty);
  });

  test('拒绝无效 JSON、错误备份头、错误版本或缺少必需数据段', () {
    expect(() => BackupFormat.parse('{'), throwsA(isA<FormatException>()));
    expect(
      () => BackupFormat.parse(jsonEncode({...validDocument(), 'format': 'other'})),
      throwsA(isA<FormatException>()),
    );
    expect(
      () => BackupFormat.parse(jsonEncode({...validDocument(), 'version': 1.0})),
      throwsA(isA<FormatException>()),
    );
    final missingProducts = validDocument()..remove('products');
    expect(
      () => BackupFormat.parse(jsonEncode(missingProducts)),
      throwsA(isA<FormatException>()),
    );
  });

  test('拒绝非对象、缺字段、错误字段类型或错误库存约束的备份记录', () {
    final nonObject = validDocument()..['products'] = ['not-a-record'];
    expect(
      () => BackupFormat.records(BackupFormat.parse(jsonEncode(nonObject)), 'products'),
      throwsA(isA<FormatException>()),
    );

    final missingField = validProduct()..remove('name');
    final wrongType = validProduct()..['low_stock_threshold'] = '1';
    final negativeStock = validProduct()..['low_stock_threshold'] = 0;
    for (final product in [missingField, wrongType, negativeStock]) {
      final document = validDocument()..['products'] = [product];
      expect(
        () => BackupFormat.records(BackupFormat.parse(jsonEncode(document)), 'products'),
        throwsA(isA<FormatException>()),
      );
    }
  });
  test('v1 备份缺少提醒确认段时按空列表兼容导入', () {
    final legacy = validDocument()
      ..['version'] = 1
      ..remove('reminder_acknowledgements');
    final document = BackupFormat.parse(jsonEncode(legacy));
    expect(BackupFormat.records(document, 'reminder_acknowledgements'), isEmpty);
  });

  test('校验提醒确认记录的必填字段和日期', () {
    final invalid = validDocument()
      ..['reminder_acknowledgements'] = [
        {
          'reminder_key': 'product-1:low-stock',
          'fingerprint': 'threshold:1',
          'acknowledged_at': 'not-a-date',
        },
      ];
    expect(
      () => BackupFormat.records(BackupFormat.parse(jsonEncode(invalid)), 'reminder_acknowledgements'),
      throwsA(isA<FormatException>()),
    );
  });
}
