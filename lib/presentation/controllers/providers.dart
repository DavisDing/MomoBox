import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/backup_service.dart';
import '../../application/inventory_service.dart';
import '../../application/settings_service.dart';
import '../../application/shopping_service.dart';
import '../../core/database/app_database.dart';
import '../../data/repositories/backup_repository.dart';
import '../../data/repositories/inventory_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/shopping_repository.dart';
import '../../domain/inventory/expiry_rules.dart';
import '../../domain/models/inventory_models.dart';
import '../../services/local_notification_service.dart';

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

final reminderSummaryProvider = Provider<ReminderSummary>((ref) {
  final items = ref.watch(inventoryProvider).valueOrNull ?? const <InventoryItem>[];
  return ReminderSummary(
    expired: items
        .where((item) => item.overallExpiryStatus == ExpiryStatus.expired)
        .toList(growable: false),
    expiring: items
        .where((item) => item.overallExpiryStatus == ExpiryStatus.expiring)
        .toList(growable: false),
    lowStock: items.where((item) => item.isLowStock).toList(growable: false),
  );
});

final localNotificationServiceProvider = Provider<LocalNotificationService>((ref) {
  return LocalNotificationService();
});
