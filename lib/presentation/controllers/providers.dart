import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/inventory_service.dart';
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
  (ref) => ref.watch(inventoryRepositoryProvider).watchInventory(),
);

final shoppingRepositoryProvider = Provider<ShoppingRepository>(
  (ref) => ShoppingRepository(ref.watch(databaseProvider)),
);

final shoppingProvider = StreamProvider<List<ShoppingEntry>>(
  (ref) => ref.watch(shoppingRepositoryProvider).watchEntries(),
);

final settingsRepositoryProvider = Provider<SettingsRepository>(
  (ref) => SettingsRepository(ref.watch(databaseProvider)),
);

final themeNameProvider = StreamProvider<String?>(
  (ref) => ref.watch(settingsRepositoryProvider).watchValue('theme'),
);

final backupRepositoryProvider = Provider<BackupRepository>(
  (ref) => BackupRepository(ref.watch(databaseProvider)),
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
