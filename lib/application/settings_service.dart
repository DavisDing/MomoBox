import '../data/repositories/settings_repository.dart';

class SettingsService {
  SettingsService(this._repository);

  final SettingsRepository _repository;

  Stream<String?> watchValue(String key) => _repository.watchValue(key);

  Future<void> setValue(String key, String value) =>
      _repository.setValue(key, value);
}
