import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureSettingsService {
  static const aiApiKeyKey = 'ai_api_key';

  SecureSettingsService({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<String?> readAiApiKey() => _storage.read(key: aiApiKeyKey);

  Future<void> writeAiApiKey(String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) return;
    await _storage.write(key: aiApiKeyKey, value: normalized);
  }
}
