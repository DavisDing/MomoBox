import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/services/local_ocr_service.dart';

void main() {
  late Directory temporaryDirectory;
  late LocalOcrService service;

  setUp(() async {
    temporaryDirectory = await Directory.systemTemp.createTemp('momobox-ocr-test-');
    service = LocalOcrService();
  });

  tearDown(() => temporaryDirectory.delete(recursive: true));

  test('拒绝不存在的图片文件', () async {
    final path = '${temporaryDirectory.path}/missing.jpg';

    await expectLater(
      service.extractText(path),
      throwsA(
        isA<LocalOcrException>().having(
          (error) => error.message,
          'message',
          '图片文件已丢失，无法识别。',
        ),
      ),
    );
  });

  test('拒绝空图片文件', () async {
    final image = File('${temporaryDirectory.path}/empty.jpg');
    await image.create();

    await expectLater(
      service.extractText(image.path),
      throwsA(
        isA<LocalOcrException>().having(
          (error) => error.message,
          'message',
          '图片文件为空，请重新添加后识别。',
        ),
      ),
    );
  });
}
