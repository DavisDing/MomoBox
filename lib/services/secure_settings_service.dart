import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureSettingsService {
  static const aiApiKeyKey = 'ai_api_key';
  static const _aiProfileKeyPrefix = 'ai_api_key_profile_';

  SecureSettingsService({FlutterSecureStorage? storage}) : _storage = storage ?? const FlutterSecureStorage();

  final FlutterSecureStorage _storage;

  Future<String?> readAiApiKey() => _storage.read(key: aiApiKeyKey);

  Future<void> writeAiApiKey(String value) => _writeOrDelete(aiApiKeyKey, value);

  Future<void> deleteAiApiKey() => _storage.delete(key: aiApiKeyKey);

  Future<String?> readAiApiKeyForProfile(String profileId) =>
      _storage.read(key: '$_aiProfileKeyPrefix$profileId');

  Future<void> writeAiApiKeyForProfile(String profileId, String value) =>
      _writeOrDelete('$_aiProfileKeyPrefix$profileId', value);

  Future<void> deleteAiApiKeyForProfile(String profileId) =>
      _storage.delete(key: '$_aiProfileKeyPrefix$profileId');

  Future<void> _writeOrDelete(String key, String value) async {
    final normalized = value.trim();
    if (normalized.isEmpty) {
      await _storage.delete(key: key);
      return;
    }
    await _storage.write(key: key, value: normalized);
  }
}
