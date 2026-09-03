import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';

class LocalOcrService {
  Future<String> extractText(String path) async {
    final recognizer = TextRecognizer(script: TextRecognitionScript.chinese);
    try {
      final result = await recognizer.processImage(InputImage.fromFilePath(path));
      return result.text.trim();
    } finally {
      await recognizer.close();
    }
  }
}
