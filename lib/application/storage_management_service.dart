import 'dart:convert';
import 'dart:io';

import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import '../data/repositories/barcode_cache_repository.dart';
import '../data/repositories/settings_repository.dart';
import '../services/media_storage_service.dart';
import 'ai_usage_service.dart';
import 'media_service.dart';

class StorageUsage {
  const StorageUsage({
    required this.databaseBytes,
    required this.mediaBytes,
    required this.barcodeCacheBytes,
    required this.barcodeCacheEntries,
    required this.aiUsageLogBytes,
  });

  final int databaseBytes;
  final int mediaBytes;
  final int barcodeCacheBytes;
  final int barcodeCacheEntries;
  final int aiUsageLogBytes;

  /// The cache and AI log are stored inside the database, so do not add them
  /// again when displaying the actual on-device total.
  int get deviceTotalBytes => databaseBytes + mediaBytes;
}

class StorageManagementService {
  StorageManagementService(
    this._barcodeCache,
    this._mediaStorage,
    this._mediaService,
    this._settings,
  );

  final BarcodeCacheRepository _barcodeCache;
  final MediaStorageService _mediaStorage;
  final MediaService _mediaService;
  final SettingsRepository _settings;

  Future<StorageUsage> loadUsage() async {
    final documents = await getApplicationDocumentsDirectory();
    final databasePath = p.join(documents.path, 'momobox.sqlite');
    final databaseBytes = await _databaseBytes(databasePath);
    final mediaBytes = await _mediaStorage.totalBytes();
    final barcode = await _barcodeCache.usage();
    final aiLog = await _settings.getValue(AiUsageService.storageKey) ?? '';
    return StorageUsage(
      databaseBytes: databaseBytes,
      mediaBytes: mediaBytes,
      barcodeCacheBytes: barcode.bytes,
      barcodeCacheEntries: barcode.entries,
      aiUsageLogBytes: utf8.encode(aiLog).length,
    );
  }

  Future<int> clearExpiredBarcodeCache() => _barcodeCache.purgeExpired();

  Future<int> clearAllBarcodeCache() => _barcodeCache.clearAll();

  Future<void> clearAiUsageLogs() =>
      _settings.setValue(AiUsageService.storageKey, '[]');

  Future<MediaCleanupReport> cleanUnusedMedia() => _mediaService.reconcile();

  Future<int> _databaseBytes(String path) async {
    var total = 0;
    for (final suffix in ['', '-wal', '-shm']) {
      final file = File('$path$suffix');
      if (await file.exists()) total += await file.length();
    }
    return total;
  }
}
