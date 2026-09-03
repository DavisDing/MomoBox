import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/backup_service.dart';
import '../../application/ai_draft_service.dart';
import '../../application/barcode_lookup_service.dart';
import '../../application/inventory_service.dart';
import '../../application/media_service.dart';
import '../../application/settings_service.dart';
import '../../application/reminder_service.dart';
import '../../application/shopping_service.dart';
import '../../core/database/app_database.dart';
import '../../data/repositories/barcode_cache_repository.dart';
import '../../data/repositories/backup_repository.dart';
import '../../data/repositories/media_repository.dart';
import '../../data/repositories/inventory_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/reminder_repository.dart';
import '../../data/repositories/shopping_repository.dart';
import '../../domain/inventory/reminder_rules.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/recognition_models.dart';
import '../../services/local_notification_service.dart';
import '../../services/local_ocr_service.dart';
import '../../services/media_storage_service.dart';
import '../../services/secure_settings_service.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final inventoryRepositoryProvider = Provider<InventoryRepository>(
  (ref) => InventoryRepository(ref.watch(databaseProvider)),
);

final inventoryServiceProvider = Provider<InventoryService>(
  (ref) => InventoryService(ref.watch(inventoryRepositoryProvider)),
);

final inventoryProvider = StreamProvider<List<InventoryItem>>(
  (ref) => ref.watch(inventoryServiceProvider).watchInventory(),
);

final shoppingRepositoryProvider = Provider<ShoppingRepository>(
  (ref) => ShoppingRepository(ref.watch(databaseProvider)),
);

final shoppingServiceProvider = Provider<ShoppingService>(
  (ref) => ShoppingService(ref.watch(shoppingRepositoryProvider)),
);

final shoppingProvider = StreamProvider<List<ShoppingEntry>>(
  (ref) => ref.watch(shoppingServiceProvider).watchEntries(),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final settingsServiceProvider = Provider<SettingsService>(
  (ref) => SettingsService(ref.watch(settingsRepositoryProvider)),
);

final themeNameProvider = StreamProvider<String?>(
  (ref) => ref.watch(settingsServiceProvider).watchValue('theme'),
);

final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepository(ref.watch(databaseProvider)),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(ref.watch(backupRepositoryProvider)),
);

final reminderRepositoryProvider = Provider<ReminderRepository>(
  (ref) => ReminderRepository(ref.watch(databaseProvider)),
);

final reminderServiceProvider = Provider<ReminderService>(
  (ref) => ReminderService(ref.watch(reminderRepositoryProvider)),
);

final reminderAcknowledgementsProvider = StreamProvider<List<ReminderAcknowledgement>>(
  (ref) => ref.watch(reminderServiceProvider).watchAcknowledgements(),
);

final reminderSummaryProvider = Provider<ReminderSummary>((ref) {
  final items = ref.watch(inventoryProvider).valueOrNull ?? const <InventoryItem>[];
  final acknowledgements = ref.watch(reminderAcknowledgementsProvider).valueOrNull ??
      const <ReminderAcknowledgement>[];
  final visible = ReminderRules.sortByUrgency(
    ReminderRules.visibleCandidates(items, acknowledgements),
  );
  return ReminderSummary(
    expired: visible
        .where((candidate) => candidate.type == ReminderType.expired)
        .map((candidate) => candidate.item)
        .toList(growable: false),
    expiring: visible
        .where((candidate) => candidate.type == ReminderType.expiring)
        .map((candidate) => candidate.item)
        .toList(growable: false),
    lowStock: visible
        .where((candidate) => candidate.type == ReminderType.lowStock)
        .map((candidate) => candidate.item)
        .toList(growable: false),
  );
});


final barcodeCacheRepositoryProvider = Provider<BarcodeCacheRepository>(
  (ref) => BarcodeCacheRepository(ref.watch(databaseProvider)),
);

final barcodeLookupServiceProvider = Provider<BarcodeLookupService>(
  (ref) => BarcodeLookupService(
    ref.watch(barcodeCacheRepositoryProvider),
    ref.watch(settingsServiceProvider),
  ),
);

final mediaRepositoryProvider = Provider<MediaRepository>(
  (ref) => MediaRepository(ref.watch(databaseProvider)),
);

final mediaStorageServiceProvider = Provider<MediaStorageService>(
  (ref) => MediaStorageService(),
);

final localOcrServiceProvider = Provider<LocalOcrService>(
  (ref) => LocalOcrService(),
);

final mediaServiceProvider = Provider<MediaService>(
  (ref) => MediaService(
    ref.watch(mediaRepositoryProvider),
    ref.watch(mediaStorageServiceProvider),
    ref.watch(localOcrServiceProvider),
  ),
);

final mediaAssetsProvider = StreamProvider.family<List<MediaAsset>, ({String entityType, String entityId})>(
  (ref, target) => ref.watch(mediaServiceProvider).watchForEntity(
        entityType: target.entityType,
        entityId: target.entityId,
      ),
);

final secureSettingsServiceProvider = Provider<SecureSettingsService>(
  (ref) => SecureSettingsService(),
);

final aiDraftServiceProvider = Provider<AiDraftService>(
  (ref) => AiDraftService(
    ref.watch(settingsRepositoryProvider),
    ref.watch(secureSettingsServiceProvider),
  ),
);

final localNotificationServiceProvider = Provider<LocalNotificationService>((ref) {
  return LocalNotificationService();
});
