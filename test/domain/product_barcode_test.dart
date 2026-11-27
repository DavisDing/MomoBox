import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/domain/recognition/product_barcode.dart';

void main() {
  test('GS1 元素字符串、人眼文本和 Digital Link 解析相同批次且无需网络', () {
    const inputs = [
      '010950600013435210ABC\u001d17271231',
      '(01)09506000134352(10)ABC(17)271231',
      'https://example.test/01/09506000134352/10/ABC?17=271231',
    ];
    for (final input in inputs) {
      final scan =
          ProductBarcode.parse(input, elementString: true, year: 2026)!;
      expect(scan.number, '9506000134352');
      expect(scan.batchNo, 'ABC');
      expect(scan.expiryDate, DateTime(2027, 12, 31));
    }
  });

  test('不把无效 GTIN、错误日期或最佳食用期当作到期日', () {
    expect(ProductBarcode.parse('(01)09506000134353(17)271231'), isNull);
    expect(
      ProductBarcode.parse(
        '(01)09506000134352(17)270231',
        year: 2026,
      )?.expiryDate,
      isNull,
    );
    expect(
      ProductBarcode.parse(
        '(01)09506000134352(15)271231',
        year: 2026,
      )?.expiryDate,
      isNull,
    );
    expect(ProductBarcode.parse('https://example.test/banana'), isNull);
    expect(ProductBarcode.parse('9506000134352')?.hasBatchData, isFalse);
  });
}
