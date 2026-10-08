import '../../application/ai_inventory_action_service.dart';
import '../../application/ai_fallback_executor.dart';
import '../../application/ai_conversation_store.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';

import '../../application/ai_assistant_service.dart';
import '../../application/ai_draft_service.dart';
import '../../application/ai_usage_service.dart';
import '../../application/backup_service.dart';
import '../../application/barcode_lookup_service.dart';
import '../../application/inventory_service.dart';
import '../../application/inventory_statistics_service.dart';
import '../../application/manual_qa_service.dart';
import '../../application/media_service.dart';
import '../../application/nas_connection_service.dart';
import '../../application/nas_auth_service.dart';
import '../../presentation/controllers/nas_account_controller.dart';
import '../../services/nas_credentials_service.dart';
import '../../application/reminder_service.dart';
import '../../application/settings_service.dart';
import '../../application/storage_management_service.dart';
import '../../application/sync_engine.dart';
import '../../application/sync_scheduler.dart';
import '../../application/network_status_source.dart';
import '../../application/shopping_service.dart';
import '../../core/database/app_database.dart';
import '../../data/repositories/backup_repository.dart';
import '../../data/repositories/barcode_cache_repository.dart';
import '../../data/repositories/inventory_repository.dart';
import '../../data/repositories/media_repository.dart';
import '../../data/repositories/reminder_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/shopping_repository.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../../data/nas/nas_sync_api.dart';
import '../../domain/inventory/reminder_rules.dart';
import '../../domain/models/ai_usage_models.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/recognition_models.dart';
import '../../domain/models/sync_models.dart';
import '../../services/local_notification_service.dart';
import '../../services/local_ocr_service.dart';
import '../../services/media_storage_service.dart';
import '../../services/secure_settings_service.dart';
import '../../application/chore_service.dart';
import '../../domain/models/chore_models.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) {
  final database = ref.watch(databaseProvider);
  final familyId = ref.watch(nasAccountProvider).family.familyId;
  return InventoryRepository(
    database,
    outbox: SyncOutboxRepository(database),
    syncScopeId: familyId,
  );
});

final inventoryServiceProvider = Provider<InventoryService>(
  (ref) => InventoryService(ref.watch(inventoryRepositoryProvider)),
);

final inventoryProvider = StreamProvider<List<InventoryItem>>(
  (ref) => ref.watch(inventoryServiceProvider).watchInventory(),
);

final shoppingRepositoryProvider = Provider<ShoppingRepository>((ref) {
  final database = ref.watch(databaseProvider);
  final familyId = ref.watch(nasAccountProvider).family.familyId;
  return ShoppingRepository(
    database,
    outbox: SyncOutboxRepository(database),
    syncScopeId: familyId,
  );
});

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

/// Stable identifier for this local installation. It is intentionally kept in
/// the ordinary local settings table (not in the NAS account) so the same
/// device can be identified across app restarts while remaining usable in
/// offline-only mode.
const syncLocalWorkspaceIdKey = 'sync_local_workspace_id';

final localWorkspaceIdProvider = FutureProvider<String>((ref) async {
  final settings = ref.watch(settingsServiceProvider);
  final stored = (await settings.getValue(syncLocalWorkspaceIdKey))?.trim();
  if (stored != null && stored.isNotEmpty) return stored;

  final generated = const Uuid().v4();
  await settings.setValue(syncLocalWorkspaceIdKey, generated);
  return generated;
});

final syncStateProvider = StreamProvider.family<SyncStateModel?, String>((ref, scopeId) {
  return SyncOutboxRepository(ref.watch(databaseProvider)).watchState(scopeId);
});

final syncConflictsProvider = FutureProvider.family<List<SyncConflictEntry>, String>((ref, scopeId) {
  return SyncOutboxRepository(ref.watch(databaseProvider)).listOpenConflicts(scopeId: scopeId);
});

final themeNameProvider = StreamProvider<String?>(
  (ref) => ref.watch(settingsServiceProvider).watchValue('theme'),
);

const homeSectionOrderKey = 'home_section_order';
const defaultHomeSectionOrder = <String>[
  'quick_intake',
  'alert_summary',
  'shopping_summary',
  'chores_card',
  'smart_home_quick',
];

List<String> normalizeHomeSectionOrder(String? value) {
  if (value == null || value.trim().isEmpty) {
    return List<String>.unmodifiable(defaultHomeSectionOrder);
  }

  final knownSections = defaultHomeSectionOrder.toSet();
  final seen = <String>{};
  final normalized = <String>[];
  for (final rawKey in value.split(',')) {
    final key = rawKey.trim();
    if (knownSections.contains(key) && seen.add(key)) {
      normalized.add(key);
    }
  }
  normalized.addAll(defaultHomeSectionOrder.where(seen.add));
  return List<String>.unmodifiable(normalized);
}

double normalizeFontScale(String? value) {
  final scale = double.tryParse(value ?? '');
  if (scale == null || !scale.isFinite || scale < 0.8 || scale > 1.6) {
    return 1.0;
  }
  return scale;
}

final homeSectionOrderProvider = StreamProvider<List<String>>((ref) {
  return ref
      .watch(settingsServiceProvider)
      .watchValue(homeSectionOrderKey)
      .map(normalizeHomeSectionOrder);
});

final fontScaleProvider = StreamProvider<double>(
  (ref) => ref
      .watch(settingsServiceProvider)
      .watchValue('font_scale')
      .map(normalizeFontScale),
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

final manualQaServiceProvider = Provider<ManualQaService>((ref) {
  final service = ManualQaService(
    ref.watch(mediaRepositoryProvider),
    ref.watch(settingsRepositoryProvider),
    ref.watch(secureSettingsServiceProvider),
  );
  ref.onDispose(service.close);
  return service;
});

final inventoryStatisticsServiceProvider = Provider<InventoryStatisticsService>(
  (ref) => InventoryStatisticsService(ref.watch(databaseProvider)),
);

final inventoryStatisticsProvider = FutureProvider.autoDispose.family<InventoryStatistics, int>(
  (ref, days) => ref.watch(inventoryStatisticsServiceProvider).load(days: days),
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

final aiUsageServiceProvider = Provider<AiUsageService>(
  (ref) => AiUsageService(ref.watch(settingsRepositoryProvider)),
);

final aiUsageLogsProvider = StreamProvider<List<AiUsageRecord>>(
  (ref) => ref.watch(aiUsageServiceProvider).watchLogs(),
);

final aiDraftServiceProvider = Provider<AiDraftService>(
  (ref) => AiDraftService(
    ref.watch(settingsRepositoryProvider),
    ref.watch(secureSettingsServiceProvider),
    usageService: ref.watch(aiUsageServiceProvider),
  ),
);

final aiAssistantServiceProvider = Provider<AiAssistantService>(
  (ref) => AiAssistantService(
    ref.watch(settingsRepositoryProvider),
    ref.watch(secureSettingsServiceProvider),
    ref.watch(inventoryRepositoryProvider),
    usageService: ref.watch(aiUsageServiceProvider),
  ),
);

final storageManagementServiceProvider = Provider<StorageManagementService>(
  (ref) => StorageManagementService(
    ref.watch(barcodeCacheRepositoryProvider),
    ref.watch(mediaStorageServiceProvider),
    ref.watch(mediaServiceProvider),
    ref.watch(settingsRepositoryProvider),
  ),
);

final localNotificationServiceProvider = Provider<LocalNotificationService>((ref) {
  return LocalNotificationService();
});


final choreServiceProvider = Provider<ChoreService>((ref) {
  return ChoreService(ref.watch(settingsRepositoryProvider));
});

final choresProvider = StreamProvider<List<ChoreItem>>((ref) {
  return ref.watch(choreServiceProvider).watchChores();
});

final aiConversationStoreProvider = ChangeNotifierProvider<AiConversationStore>((ref) {
  final store = AiConversationStore(ref.watch(settingsRepositoryProvider));
  store.load();
  return store;
});

final aiConnectionTestExecutorProvider = Provider<AiFallbackExecutor>((ref) {
  final executor = AiFallbackExecutor();
  ref.onDispose(executor.close);
  return executor;
});

final aiInventoryPermissionProvider = StreamProvider<bool>((ref) => ref
    .watch(settingsServiceProvider).watchValue('ai_allow_inventory_writes')
    .map((value) => value == 'true'));

// Configured does not imply reachable: the home page must never claim online
// based on a URL alone, nor reuse the mock smart-home status.
final aiConfigurationStatusProvider = StreamProvider<bool>((ref) => ref
    .watch(settingsServiceProvider).watchValue(AiDraftService.modelKey)
    .map((value) => value?.trim().isNotEmpty == true));

final aiInventoryActionServiceProvider = Provider<AiInventoryActionService>((ref) =>
    AiInventoryActionService(ref.watch(settingsRepositoryProvider), ref.watch(inventoryServiceProvider)));

class NasConnectionController extends StateNotifier<NasConnectionState> {
  NasConnectionController(this._service)
      : super(const NasConnectionState(status: NasConnectionStatus.unconfigured)) {
    load();
  }

  final NasConnectionService _service;

  Future<void> load() async {
    final loaded = await _service.loadState();
    if (!mounted) return;
    state = loaded;
    if (loaded.serverUrl.trim().isNotEmpty) {
      await refresh();
    }
  }

  Future<void> refresh({String? serverUrl, String? familyCode}) async {
    final hasExplicitServerUrl = serverUrl != null;
    final url = (serverUrl ?? state.serverUrl).trim();
    final code = (familyCode ?? state.familyCode).trim();
    // Keep a passive refresh with no saved URL unconfigured, but let an
    // explicit empty value from the settings form reach the service so the
    // user gets validation feedback instead of a misleading generic status.
    if (url.isEmpty && !hasExplicitServerUrl) {
      state = NasConnectionState(
        status: NasConnectionStatus.unconfigured,
        serverUrl: url,
        familyCode: code,
      );
      return;
    }
    state = state.copyWith(
      status: NasConnectionStatus.checking,
      serverUrl: url,
      familyCode: code,
      clearMessage: true,
    );
    final next = await _service.saveAndCheck(serverUrl: url, familyCode: code);
    if (mounted) state = next;
  }
}

final nasConnectionServiceProvider = Provider<NasConnectionService>((ref) {
  final service = NasConnectionService(ref.watch(settingsServiceProvider));
  ref.onDispose(service.close);
  return service;
});

final nasConnectionProvider = StateNotifierProvider<NasConnectionController, NasConnectionState>((ref) {
  return NasConnectionController(ref.watch(nasConnectionServiceProvider));
});


final nasCredentialsServiceProvider = Provider<NasCredentialsService>((ref) {
  return NasCredentialsService();
});

final nasAccountProvider = StateNotifierProvider<NasAccountController, NasAccountState>((ref) {
  final controller = NasAccountController(
    settings: ref.watch(settingsServiceProvider),
    connection: ref.watch(nasConnectionServiceProvider),
    credentials: ref.watch(nasCredentialsServiceProvider),
  );
  controller.restore();
  return controller;
});

/// A transport assembled only while the authenticated account has a live
/// NAS session. The provider owns the sibling client's HTTP lifecycle.
final nasSyncApiProvider = Provider<NasSyncApi?>((ref) {
  ref.watch(nasAccountProvider);
  final api = ref.read(nasAccountProvider.notifier).createSyncApi();
  if (api != null) ref.onDispose(api.close);
  return api;
});

/// Concrete sync engine wiring. Construction alone never starts a sync run.
/// Manual and App lifecycle requests share [syncSchedulerProvider]; execution,
/// backoff and durable conflict protection still belong to [SyncEngine].
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final account = ref.watch(nasAccountProvider);
  final api = ref.watch(nasSyncApiProvider);
  final localWorkspaceId = ref.watch(localWorkspaceIdProvider).valueOrNull;
  final familyId = account.family.familyId;
  final deviceId = account.devices.currentDeviceId;
  if (api == null ||
      !account.isAuthenticated ||
      familyId == null ||
      deviceId == null ||
      localWorkspaceId == null) {
    return null;
  }
  return SyncEngine.withBusinessAdapter(
    api: api,
    repository: SyncOutboxRepository(ref.watch(databaseProvider)),
    inventoryRepository: ref.watch(inventoryRepositoryProvider),
    shoppingRepository: ref.watch(shoppingRepositoryProvider),
    scopeId: familyId,
    deviceId: deviceId,
    familyId: familyId,
    localWorkspaceId: localWorkspaceId,
  );
});

final syncNetworkStatusSourceProvider = Provider<NetworkStatusSource>((ref) {
  final source = ConnectivityPlusNetworkStatusSource();
  ref.onDispose(source.dispose);
  return source;
});

/// Override before startup to tune/disable foreground polling, without UI changes.
final syncForegroundPullIntervalProvider = Provider<Duration?>((ref) =>
    const Duration(minutes: 1));

/// Stable policy owner shared by App lifecycle and the manual sync entry.
/// Listen rather than watch the engine/account: auth/provider rebuilds must not
/// create independent schedulers with independent timers.
final syncSchedulerProvider = Provider<SyncScheduler>((ref) {
  final scheduler = SyncScheduler(
    engineReader: () => ref.read(syncEngineProvider),
    networkStatusSource: ref.read(syncNetworkStatusSourceProvider),
    foregroundPullInterval: ref.read(syncForegroundPullIntervalProvider),
  );
  String? observedScope;
  Object? observedDatabase;
  void bindCurrentScope() {
    final account = ref.read(nasAccountProvider);
    final scopeId = account.isAuthenticated ? account.family.familyId : null;
    final database = ref.read(databaseProvider);
    if (observedScope == scopeId && identical(observedDatabase, database)) return;
    observedScope = scopeId;
    observedDatabase = database;
    scheduler.bindPendingChanges(
      scopeId != null
          ? SyncOutboxRepository(database)
              .watchPendingContentChanges(scopeId: scopeId)
          : null,
    );
  }

  ref.listen<SyncEngine?>(syncEngineProvider, (_, __) {
    bindCurrentScope();
    scheduler.onEngineChanged();
  });
  ref.listen<NasAccountState>(nasAccountProvider, (_, __) {
    bindCurrentScope();
  });
  ref.listen<AppDatabase>(databaseProvider, (_, __) {
    bindCurrentScope();
  });
  bindCurrentScope();
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

final nasAccountStatusProvider = Provider<NasAccountStatus>((ref) {
  return ref.watch(nasAccountProvider).status;
});

final nasAuthStateProvider = Provider<NasAuthSnapshot>((ref) {
  return ref.watch(nasAccountProvider).auth;
});

final nasFamilyStateProvider = Provider<NasFamilyState>((ref) {
  return ref.watch(nasAccountProvider).family;
});

final nasFamilyStatusProvider = Provider<NasFamilyStatus>((ref) {
  return ref.watch(nasFamilyStateProvider).status;
});

final nasDeviceStateProvider = Provider<NasDeviceState>((ref) {
  return ref.watch(nasAccountProvider).devices;
});

final nasDeviceStatusProvider = Provider<NasDeviceStatus>((ref) {
  return ref.watch(nasDeviceStateProvider).status;
});

final nasAccountLoadingProvider = Provider<bool>((ref) {
  return ref.watch(nasAccountProvider).isLoading;
});

final nasAccountErrorProvider = Provider<String?>((ref) {
  return ref.watch(nasAccountProvider).errorMessage;
});

final nasFamilyErrorProvider = Provider<String?>((ref) {
  final family = ref.watch(nasFamilyStateProvider);
  return family.errorMessage ?? family.membersErrorMessage;
});

final nasDeviceErrorProvider = Provider<String?>((ref) {
  return ref.watch(nasDeviceStateProvider).errorMessage;
});
