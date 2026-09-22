import 'dart:async';
import 'package:momo_box/data/repositories/settings_repository.dart';

class MemorySettingsRepository implements SettingsRepository {
  final values = <String, String>{};
  final changes = StreamController<String>.broadcast();
  bool failWrites = false;
  @override
  Future<String?> getValue(String key) async => values[key];
  @override
  Future<void> setValue(String key, String value) async {
    if (failWrites) throw StateError('disk unavailable');
    values[key] = value;
    changes.add(key);
  }

  @override
  Stream<String?> watchValue(String key) async* {
    yield values[key];
    yield* changes.stream
        .where((changed) => changed == key)
        .map((_) => values[key]);
  }

  Future<void> close() => changes.close();
}
