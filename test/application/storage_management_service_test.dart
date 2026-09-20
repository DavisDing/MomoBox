import 'dart:io';

import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_usage_service.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/media_service.dart';
import 'package:momo_box/application/storage_management_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/barcode_cache_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/media_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/shopping_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/recognition_models.dart';
import 'package:momo_box/services/local_ocr_service.dart';
import 'package:momo_box/services/media_storage_service.dart';

void main() {
  test('一键清理仅删除缓存、日志、无用图片，保留业务数据与近期草稿', () async {
    final database = AppDatabase.forTesting(NativeDatabase.memory());
    final directory = await Directory.systemTemp.createTemp(
      'momobox-cleanup-test-',
    );
    addTearDown(() async {
      await database.close();
      await directory.delete(recursive: true);
    });
    final mediaDir = await Directory('${directory.path}/media').create();
    final backup = await File(
      '${directory.path}/backup.json',
    ).writeAsString('backup');
    final cache = BarcodeCacheRepository(database);
    final settings = SettingsRepository(database);
    final mediaRepo = MediaRepository(database);
    final storage = _TestMediaStorage(mediaDir);
    final service = StorageManagementService(
      cache,
      storage,
      MediaService(mediaRepo, storage, LocalOcrService()),
      settings,
    );
    await InventoryService(
      InventoryRepository(database),
    ).intake(const IntakeDraft(name: '保留商品', category: '食品生鲜', quantity: 3));
    await ShoppingRepository(
      database,
    ).addOrMerge(itemName: '保留采购', targetQuantity: 2, reason: '手动');
    await settings.setValue('ai_config', 'preserved');
    await settings.setValue(AiUsageService.storageKey, '[{"model":"test"}]');
    await cache.save(
      const BarcodeLookupResult(barcode: '123', source: 'test'),
      expiresAt: DateTime.now().add(const Duration(days: 1)),
    );
    final products = await database.select(database.products).get();
    final batches = await database.select(database.productBatches).get();
    final movements = await database.select(database.stockMovements).get();
    final shopping = await database.select(database.shoppingEntries).get();

    Future<MediaAsset> asset(
      String name,
      String entityType, {
      bool missing = false,
    }) async {
      final file = File('${mediaDir.path}/$name.jpg');
      if (!missing) await file.writeAsString(name);
      return mediaRepo.create(
        entityType: entityType,
        entityId: products.single.id,
        type: MediaAssetType.productImage,
        localPath: file.path,
        mimeType: 'image/jpeg',
        sizeBytes: 1,
        sha256: name,
      );
    }

    final productImage = await asset('product', 'product');
    final recentDraft = await asset('recent', 'intake_draft');
    final oldDraft = await asset('old', 'intake_draft');
    await (database.update(database.mediaAssets)
      ..where((row) => row.id.equals(oldDraft.id))).write(
      MediaAssetsCompanion(
        createdAt: Value(DateTime.now().subtract(const Duration(days: 2))),
      ),
    );
    await asset('missing', 'product', missing: true);
    final orphan = await File(
      '${mediaDir.path}/orphan.jpg',
    ).writeAsString('orphan');

    final report = await service.cleanAll();
    expect(report.barcodeEntries, 1);
    expect(report.media.deletedFiles, 2);
    expect(report.media.deletedMetadata, 2);
    expect((await cache.usage()).entries, 0);
    expect(await settings.getValue(AiUsageService.storageKey), '[]');
    expect(await settings.getValue('ai_config'), 'preserved');
    expect(await database.select(database.products).get(), products);
    expect(await database.select(database.productBatches).get(), batches);
    expect(await database.select(database.stockMovements).get(), movements);
    expect(await database.select(database.shoppingEntries).get(), shopping);
    expect(await File(productImage.localPath).exists(), isTrue);
    expect(await File(recentDraft.localPath).exists(), isTrue);
    expect(await File(oldDraft.localPath).exists(), isFalse);
    expect(await orphan.exists(), isFalse);
    expect(await backup.readAsString(), 'backup');
    final second = await service.cleanAll();
    expect(second.barcodeEntries, 0);
    expect(second.media.deletedFiles, 0);
    expect(second.media.deletedMetadata, 0);
  });
}

class _TestMediaStorage extends MediaStorageService {
  _TestMediaStorage(this.directory);
  final Directory directory;

  @override
  Future<Set<String>> existingPaths() async => {
    await for (final entity in directory.list())
      if (entity is File) entity.path,
  };
}
