import 'dart:io';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class LocalOcrException implements Exception {
  const LocalOcrException(this.message);

  final String message;

  @override
  String toString() => message;
}

class LocalOcrService {
  Future<String> extractText(String path) async {
    final imageFile = File(path);
    if (!await imageFile.exists()) {
      throw const LocalOcrException('图片文件已丢失，无法识别。');
    }
    if (await imageFile.length() == 0) {
      throw const LocalOcrException('图片文件为空，请重新添加后识别。');
    }

    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(path));
      return result.text.trim();
    } catch (_) {
      // A Dart/plugin failure should stay inside the current intake flow. Native
      // process crashes still need Android logcat investigation.
      throw const LocalOcrException('这张图片暂时无法识别，请更换清晰图片或手动填写。');
    } finally {
      await recognizer.close();
    }
  }
}
