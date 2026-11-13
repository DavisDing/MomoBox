import '../../domain/models/nas_ai_model.dart';
import 'dart:async';
import '../../application/legacy_client_settings_cleanup.dart';
import '../../data/nas/nas_api_client.dart';
import 'nas_setup_controller.dart';
import '../../application/ai_inventory_action_service.dart';
import '../../application/ai_fallback_executor.dart';
import '../../application/ai_conversation_store.dart';
import '../../application/home_environment_service.dart';
import '../../domain/models/home_environment.dart';
import '../../domain/models/smart_home_models.dart' show HaConnectionStatus;
import 'smart_home_controller.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/widgets.dart' show WidgetsBinding, AppLifecycleState;
import 'package:uuid/uuid.dart';

import '../../application/ai_assistant_service.dart';
import '../../application/ai_draft_service.dart';
import '../../application/ai_usage_service.dart';
import '../../application/backup_service.dart';
import '../../application/barcode_lookup_service.dart';
import '../../application/calendar_refresh_scheduler.dart';
import '../../application/inventory_service.dart';
import '../../application/initial_import_service.dart';
import '../../application/inventory_statistics_service.dart';
import '../../application/manual_qa_service.dart';
import '../../application/media_service.dart';
import '../../application/backend_processing_service.dart';
import '../../application/backend_processing_error.dart';
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
import '../../data/repositories/initial_import_repository.dart';
import '../../data/repositories/media_repository.dart';
import '../../data/repositories/nas_smart_home_repository.dart';
import '../../data/repositories/reminder_repository.dart';
import '../../data/repositories/settings_repository.dart';
import '../../data/repositories/shopping_repository.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../../data/repositories/sync_workspace_repository.dart';
import '../../data/nas/nas_sync_api.dart';
import '../../data/nas/nas_api_error.dart';
import '../../domain/inventory/calendar_date.dart';
import '../../domain/inventory/reminder_rules.dart';
import '../../domain/models/ai_usage_models.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/initial_import_models.dart';
import '../../domain/models/recognition_models.dart';
import '../../domain/models/sync_models.dart';
import '../../services/local_notification_service.dart';
import '../../services/media_storage_service.dart';
import '../../application/chore_service.dart';
import '../../domain/models/chore_models.dart';

final databaseProvider = Provider<AppDatabase>((ref) {
  final database = AppDatabase();
  ref.onDispose(database.close);
  return database;
});

final Provider<void Function()> nasWriteAccessGuardProvider =
    Provider<void Function()>((ref) {
      var active = true;
      ref.onDispose(() => active = false);
      return () {
        if (!active ||
            ref.read(nasAppAccessProvider) != NasAppAccess.connected) {
          throw StateError('NAS 暂不可达，当前只能查看缓存；恢复连接后可继续修改。');
        }
      };
    });

final inventoryRepositoryProvider = Provider<InventoryRepository>((ref) {
  final database = ref.watch(databaseProvider);
  final familyId = ref.watch(syncWorkspaceAccessProvider).asData?.value.owner?.familyId;
  return InventoryRepository(
    database,
    outbox: SyncOutboxRepository(database),
    syncScopeId: familyId,
    syncScopeResolver: SyncWorkspaceRepository(database).localMutationScope,
    assertWritable:ref.watch(nasWriteAccessGuardProvider),
  );
});

final inventoryServiceProvider = Provider<InventoryService>(
  (ref) => InventoryService(ref.watch(inventoryRepositoryProvider)),
);

final inventoryProvider = StreamProvider<List<InventoryItem>>(
  (ref) => ref.watch(inventoryServiceProvider).watchInventory(),
);

final calendarClockProvider = Provider<DateTime Function()>((ref) => DateTime.now);

final calendarRefreshSchedulerProvider = Provider<CalendarRefreshScheduler>((ref) {
  final scheduler = CalendarRefreshScheduler(
    clock: ref.watch(calendarClockProvider),
    onRefresh: () {
      ref.invalidate(inventoryProvider);
      ref.invalidate(inventoryStatisticsProvider);
    },
  );
  ref.onDispose(scheduler.dispose);
  return scheduler;
});

final shoppingRepositoryProvider = Provider<ShoppingRepository>((ref) {
  final database = ref.watch(databaseProvider);
  final familyId = ref.watch(syncWorkspaceAccessProvider).asData?.value.owner?.familyId;
  return ShoppingRepository(
    database,
    outbox: SyncOutboxRepository(database),
    syncScopeId: familyId,
    syncScopeResolver: SyncWorkspaceRepository(database).localMutationScope,
    assertWritable:ref.watch(nasWriteAccessGuardProvider),
  );
});

final shoppingServiceProvider = Provider<ShoppingService>(
  (ref) => ShoppingService(ref.watch(shoppingRepositoryProvider),
    inventory: ref.watch(inventoryRepositoryProvider)),
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
  (ref) => BackupRepository(
    ref.watch(databaseProvider),
    assertWritable: ref.watch(nasWriteAccessGuardProvider),
  ),
);

final backupServiceProvider = Provider<BackupService>(
  (ref) => BackupService(
    ref.watch(backupRepositoryProvider),
    synchronizeAfterRestore: () =>
        ref.read(nasSetupProvider.notifier).prepare(),
  ),
);

final reminderRepositoryProvider = Provider<ReminderRepository>(
  (ref) => ReminderRepository(ref.watch(databaseProvider)),
);

final reminderServiceProvider = Provider<ReminderService>(
  (ref) => ReminderService(ref.watch(reminderRepositoryProvider),assertWritable:ref.watch(nasWriteAccessGuardProvider)),
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
    backendResolver: ref.watch(backendResolverProvider),
    fallbackExecutor: AiFallbackExecutor(
      backendResolver: ref.watch(backendResolverProvider),
      modelReader: () async {
        final identity = ref.read(syncWorkspaceIdentityProvider);
        if (identity == null) return null;
        return ref
            .read(settingsRepositoryProvider)
            .getValue(nasAiSelectionKey(identity));
      },
    ),
  );
  ref.onDispose(service.close);
  return service;
});

final inventoryStatisticsServiceProvider = Provider<InventoryStatisticsService>(
  (ref) => InventoryStatisticsService(ref.watch(databaseProvider)),
);

final inventoryStatisticsProvider = StreamProvider.autoDispose.family<InventoryStatistics, int>(
  (ref, days) {
    final database = ref.watch(databaseProvider);
    final service = ref.watch(inventoryStatisticsServiceProvider);
    return database.customSelect(
      'SELECT 1',
      readsFrom: {database.stockMovements, database.products},
    ).watch().asyncMap((_) => service.load(days: days));
  },
);

final mediaStorageServiceProvider = Provider<MediaStorageService>(
  (ref) => MediaStorageService(),
);

final backendResolverProvider = Provider<BackendResolver>(
  (ref) => () async {
    final selected =
        (await ref.read(settingsRepositoryProvider).getValue(nasServerUrlKey))
            ?.trim()
            .isNotEmpty ==
        true;
    if (!selected) {
      throw const BackendProcessingSetupException('请先填写 NAS 服务地址并登录。');
    }
    final account = ref.read(nasAccountProvider);
    if (!account.isAuthenticated || !account.family.hasFamily) {
      throw const BackendProcessingSetupException(
        '已选择 NAS 处理，请先在 NAS 设置中登录并创建或加入家庭。',
      );
    }
    final access = await ref.read(syncWorkspaceAccessProvider.future);
    if (!access.canSync) {
      throw const BackendProcessingSetupException(
        '家庭连接尚未自动完成，请在 NAS 设置中重试连接。已有数据归属不一致时需先核对原账号。',
      );
    }
    final api = ref.read(nasSyncApiProvider);
    if (api == null) {
      throw const BackendProcessingSetupException(
        'NAS 设备连接尚未就绪，请在 NAS 设置中重试连接。',
      );
    }
    final family = ref.read(nasAccountProvider).family.familyId!;
    final mode = await SyncOutboxRepository(ref.read(databaseProvider))
        .getConfirmedBootstrapMode(family);
    if (mode != 'join_and_merge' && mode != 'create_new_family') {
      throw const BackendProcessingSetupException(
        'NAS 正在自动初始化，请稍候；若持续失败请重试连接。',
      );
    }
    api.assertCurrentSession();
    return api;
  },
);

final backendProcessingServiceProvider = Provider<BackendProcessingService>(
  (ref) => BackendProcessingService(
    ref.watch(databaseProvider),
    ref.watch(mediaRepositoryProvider),
    ref.watch(mediaStorageServiceProvider),
    resolveApi: ref.watch(backendResolverProvider),
    scopeId: () => ref.read(nasAccountProvider).family.familyId,
  ),
);

final backendAiExecutorProvider = Provider<AiFallbackExecutor>((ref) {
  final executor = AiFallbackExecutor(
    backendResolver: ref.watch(backendResolverProvider),
    modelReader: () async {
      final identity = ref.read(syncWorkspaceIdentityProvider);
      if (identity == null) return null;
      return ref
          .read(settingsRepositoryProvider)
          .getValue(nasAiSelectionKey(identity));
    },
  );
  ref.onDispose(executor.close);
  return executor;
});

final mediaServiceProvider = Provider<MediaService>(
  (ref) => MediaService(
    ref.watch(mediaRepositoryProvider),
    ref.watch(mediaStorageServiceProvider),
    backend: ref.watch(backendProcessingServiceProvider),
    assertWritable: ref.watch(nasWriteAccessGuardProvider),
  ),
);

final mediaAssetsProvider = StreamProvider.family<List<MediaAsset>, ({String entityType, String entityId})>(
  (ref, target) => ref.watch(mediaServiceProvider).watchForEntity(
        entityType: target.entityType,
        entityId: target.entityId,
      ),
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
    usageService: ref.watch(aiUsageServiceProvider),
    fallbackExecutor: ref.watch(backendAiExecutorProvider),
  ),
);

final aiAssistantServiceProvider = Provider<AiAssistantService>(
  (ref) => AiAssistantService(
    ref.watch(settingsRepositoryProvider),
    ref.watch(inventoryRepositoryProvider),
    usageService: ref.watch(aiUsageServiceProvider),
    actionService: ref.watch(aiInventoryActionServiceProvider),
    fallbackExecutor: ref.watch(backendAiExecutorProvider),
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
  return ChoreService(ref.watch(settingsRepositoryProvider),assertWritable:ref.watch(nasWriteAccessGuardProvider));
});

final choresProvider = StreamProvider<List<ChoreItem>>((ref) {
  return ref.watch(choreServiceProvider).watchChores();
});

final aiConversationStoreProvider = ChangeNotifierProvider<AiConversationStore>((ref) {
  final store = AiConversationStore(ref.watch(settingsRepositoryProvider));
  store.load();
  return store;
});

final aiInventoryPermissionProvider = StreamProvider<bool>((ref) => ref
    .watch(settingsServiceProvider).watchValue('ai_allow_inventory_writes')
    .map((value) => value != 'false'));

// Configured does not imply reachable: the home page must never claim online
// based on a URL alone, nor reuse the mock smart-home status.
String nasAiSelectionKey(SyncWorkspaceIdentity identity) =>
    'nas_ai_model:${identity.encode()}';
final selectedAiModelProvider = StreamProvider<String?>((ref) {
  final identity = ref.watch(syncWorkspaceIdentityProvider);
  if (identity == null) return Stream.value(null);
  return ref
      .watch(settingsRepositoryProvider)
      .watchValue(nasAiSelectionKey(identity));
});
final nasAiModelsProvider = FutureProvider<List<NasAiModel>>((ref) async {
  ref.watch(nasSyncApiProvider);
  final api = await ref.watch(backendResolverProvider)();
  if (api == null) throw const BackendProcessingSetupException('请先连接 NAS。');
  final result = await api.processingRequest('/ai/models', method: 'GET');
  api.assertCurrentSession();
  return NasAiModel.parse(result['models']);
});
final aiConfigurationStatusProvider = StreamProvider<bool>((ref) async* {
  final api = ref.watch(nasSyncApiProvider);
  if (api == null) {
    yield false;
    return;
  }
  try {
    final capability = await api.processingRequest(
      '/capabilities',
      method: 'GET',
    );
    yield capability['backend_ai'] == true;
  } catch (_) {
    yield false;
  }
});

final nasSmartHomeRepositoryProvider = Provider<NasSmartHomeRepository>((ref) {
  ref.watch(nasAccountProvider.select((account) => (
    account.status,
    account.auth.user?.id,
    account.family.status,
    account.family.current,
  )));
  final repository = ref.read(nasAccountProvider.notifier)
      .createHomeAssistantRepository();
  ref.onDispose(repository.close);
  return repository;
});

final smartHomeControllerProvider =
    StateNotifierProvider<SmartHomeController, SmartHomeState>((ref) {
      final serverUrl = ref.watch(
        nasConnectionProvider.select((connection) => connection.serverUrl),
      );
      return SmartHomeController(
        ref.watch(nasSmartHomeRepositoryProvider),
        nasAddress: serverUrl,
        assertWritable: ref.watch(nasWriteAccessGuardProvider),
        role: ref.watch(
          nasAccountProvider.select(
            (account) => account.family.current?.membership.role,
          ),
        ),
      );
    });

final aiInventoryActionServiceProvider = Provider<AiInventoryActionService>((ref) =>
    AiInventoryActionService(ref.watch(settingsRepositoryProvider), ref.watch(inventoryServiceProvider),
      shopping: ref.watch(shoppingServiceProvider),
      chores: ref.watch(choreServiceProvider),
      reminders: ref.watch(reminderServiceProvider),
      deviceContext: () => ref.read(smartHomeControllerProvider.notifier).assistantContext(),
      describeDevice: (action) => ref.read(smartHomeControllerProvider.notifier).describeAssistantCommand(action),
      executeDevice: (action) => ref.read(smartHomeControllerProvider.notifier).executeAssistantCommand(action),
    ));

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
    if (hasExplicitServerUrl || !state.isConnected) {
      state = state.copyWith(status:NasConnectionStatus.checking,serverUrl:url,familyCode:code,clearMessage:true);
    }
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

final legacyClientCleanupProvider = FutureProvider<void>(
  (ref) => LegacyClientSettingsCleanup(ref.watch(databaseProvider)).run(),
);

final nasSetupProvider =
    StateNotifierProvider<NasSetupController, NasSetupState>((ref) {
      final controller = NasSetupController(
        database: ref.read(databaseProvider),
        accountReader: () => ref.read(nasAccountProvider.notifier),
        refreshAccess: () async {
          ref.invalidate(syncWorkspaceBindingProvider);
          await ref.read(syncWorkspaceBindingProvider.future);
          ref.invalidate(syncWorkspaceAccessProvider);
          await ref.read(syncWorkspaceAccessProvider.future);
        },
        workspaceReady: () async {
          await ref.read(localWorkspaceIdProvider.future);
        },
        engineReader: () => ref.read(syncEngineProvider),
        importReader: () => ref.read(initialImportServiceProvider),
        onReady: () => ref.invalidate(nasCachedAccessProvider),
      );
      ref.listen(
        nasAccountProvider.select(
          (account) => (
            account.status,
            account.auth.user?.id,
            account.family.status,
            account.family.familyId,
            account.devices.status,
          ),
        ),
        (_, __) {
          Future.microtask(() {
            if (controller.mounted) controller.changed();
          });
        },
      );
      Future.microtask(() {
        if (controller.mounted) controller.changed();
      });
      return controller;
    });

enum NasAppAccess { setup, connected, cached }

final nasCachedAccessProvider = FutureProvider<bool>((ref) async {
  ref.watch(
    nasAccountProvider.select(
      (account) => (account.status, account.auth.user?.id),
    ),
  );
  final url = ref.watch(
    nasConnectionProvider.select((connection) => connection.serverUrl),
  );
  if (url.isEmpty) return false;
  final client = NasApiClient(url);
  final endpoint = client.serverIdentity;
  client.close();
  final credentials = await ref
      .read(nasCredentialsServiceProvider)
      .readForServer(endpoint);
  if (credentials?.userId == null) return false;
  final owner = await SyncWorkspaceRepository(ref.read(databaseProvider))
      .readOwner();
  final complete = await ref
      .read(settingsRepositoryProvider)
      .getValue('nas_setup_complete');
  return owner != null &&
      owner.userId == credentials!.userId &&
      owner.endpoint == endpoint &&
      complete == owner.encode();
});
final nasAppAccessProvider = Provider<NasAppAccess>((ref) {
  final setup = ref.watch(nasSetupProvider);
  final account = ref.watch(nasAccountProvider);
  final connected = ref.watch(nasConnectionProvider).isConnected;
  final cached = ref.watch(nasCachedAccessProvider).valueOrNull == true;
  final access = ref.watch(syncWorkspaceAccessProvider).asData?.value;
  final identity = ref.watch(syncWorkspaceIdentityProvider);
  if (account.isAuthenticated &&
      setup.status == NasSetupStatus.ready &&
      connected &&
      account.devices.status == NasDeviceStatus.ready &&
      account.devices.currentDeviceId != null &&
      access?.canSync == true &&
      identity != null &&
      access?.owner?.matches(identity) == true) {
    return NasAppAccess.connected;
  }
  if (cached) return NasAppAccess.cached;
  return NasAppAccess.setup;
});

Future<void> reconnectNas(WidgetRef ref) async {
  await ref.read(nasConnectionProvider.notifier).refresh();
  if (!ref.context.mounted || !ref.read(nasConnectionProvider).isConnected) {
    return;
  }
  final account = ref.read(nasAccountProvider);
  if (!account.isAuthenticated || !account.family.hasFamily) {
    await ref.read(nasAccountProvider.notifier).restore();
  }
  if (!ref.context.mounted) return;
  if (ref.read(nasSetupProvider).status != NasSetupStatus.ready) {
    await ref.read(nasSetupProvider.notifier).prepare();
  }
}

final syncWorkspaceIdentityProvider = Provider<SyncWorkspaceIdentity?>((ref) {
  final account = ref.watch(nasAccountProvider.select((account) => (
    authenticated: account.isAuthenticated,
    userId: account.auth.user?.id,
    familyId: account.family.familyId,
    familyStatus: account.family.status,
  )));
  final endpoint = ref.read(nasAccountProvider.notifier).serverIdentity;
  final userId = account.userId;
  final familyId = account.familyId;
  if (!account.authenticated || endpoint == null || userId == null || familyId == null ||
      account.familyStatus != NasFamilyStatus.available) {
    return null;
  }
  return SyncWorkspaceIdentity(endpoint: endpoint, userId: userId, familyId: familyId);
});

final syncWorkspaceBindingProvider = StreamProvider<String?>((ref) =>
    SyncWorkspaceRepository(ref.watch(databaseProvider)).watchBinding());

final syncWorkspaceAccessProvider = FutureProvider<SyncWorkspaceAccess>((ref) async {
  final identity = ref.watch(syncWorkspaceIdentityProvider);
  final database = ref.watch(databaseProvider);
  await ref.watch(syncWorkspaceBindingProvider.future);
  return SyncWorkspaceRepository(database).inspect(identity);
});

/// A transport assembled only while the authenticated account has a live
/// NAS session. The provider owns the sibling client's HTTP lifecycle.
final nasSyncApiProvider = Provider<NasSyncApi?>((ref) {
  // Token rotation updates the shared token provider in place. Rebuilding this
  // transport on every auth snapshot would cancel its retry and start a new
  // conflict request from the settings page, causing an endless 401 loop.
  final account = ref.watch(nasAccountProvider.select((account) => (
    status: account.status,
    userId: account.auth.user?.id,
    familyStatus: account.family.status,
    familyId: account.family.familyId,
    deviceStatus: account.devices.status,
    deviceId: account.devices.currentDeviceId,
  )));
  final identity = ref.watch(syncWorkspaceIdentityProvider);
  final value = ref.watch(syncWorkspaceAccessProvider);
  final access = value.asData?.value;
  if (account.deviceStatus != NasDeviceStatus.ready || account.deviceId == null ||
      identity == null || value.isLoading || access?.canSync != true ||
      access?.owner?.matches(identity) != true) {
    return null;
  }
  var active = true;
  ref.onDispose(() => active = false);
  final api = ref.read(nasAccountProvider.notifier).createSyncApi(isWorkspaceCurrent: () {
    if (!active) return false;
    final current = ref.read(syncWorkspaceIdentityProvider);
    final latest = ref.read(syncWorkspaceAccessProvider);
    return current != null && identity.matches(current) &&
        !latest.isLoading && latest.asData?.value.canSync == true &&
        latest.asData?.value.owner?.matches(current) == true;
  });
  if (api != null) {
    api.setProcessingGuard(() async {
      final configured = (await ref.read(settingsRepositoryProvider).getValue(nasServerUrlKey))?.trim();
      final mode = await SyncOutboxRepository(ref.read(databaseProvider)).getConfirmedBootstrapMode(identity.familyId);
      if (!active || configured == null || !api.matchesEndpoint(configured) ||
          (mode != 'join_and_merge' && mode != 'create_new_family')) {
        throw const BackendProcessingSetupException('后端处理模式已改变，请重新确认。');
      }
    });
    ref.onDispose(api.close);
  }
  return api;
});

/// Concrete sync engine wiring. Construction alone never starts a sync run.
/// Manual and App lifecycle requests share [syncSchedulerProvider]; execution,
/// backoff and durable conflict protection still belong to [SyncEngine].
final syncEngineProvider = Provider<SyncEngine?>((ref) {
  final account = ref.watch(nasAccountProvider.select((account) => (
    authenticated: account.isAuthenticated,
    familyId: account.family.familyId,
    deviceId: account.devices.currentDeviceId,
  )));
  final api = ref.watch(nasSyncApiProvider);
  final localWorkspaceId = ref.watch(localWorkspaceIdProvider).valueOrNull;
  final familyId = account.familyId;
  final deviceId = account.deviceId;
  if (api == null ||
      !account.authenticated ||
      familyId == null ||
      deviceId == null ||
      localWorkspaceId == null) {
    return null;
  }
  final database = ref.watch(databaseProvider);
  return SyncEngine.withBusinessAdapter(
    api: api,
    repository: SyncOutboxRepository(database),
    inventoryRepository: ref.watch(inventoryRepositoryProvider),
    shoppingRepository: ref.watch(shoppingRepositoryProvider),
    scopeId: familyId,
    deviceId: deviceId,
    familyId: familyId,
    localWorkspaceId: localWorkspaceId,
    afterInventorySync: () async {
      final capability = await api.processingRequest('/capabilities', method: 'GET');
      Object? processingError;
      if (capability['operation_history'] == true) {
        try { await ref.read(backendProcessingServiceProvider).syncHistory(api); } catch (error) { processingError = error; }
      }
      if (capability['media_upload'] == true) {
        try { await ref.read(mediaServiceProvider).syncBackend(api); } catch (error) { processingError ??= error; }
      }
      if (processingError != null) throw StateError('历史或图片同步待恢复。');
    },
    prepareFeatureSupport: () async {
      try {
        final capability = await api.importCapabilities(deviceId: deviceId);
        CalendarDate.validateTimeZone(capability.familyTimeZone);
        await database.transaction(() async {
          api.assertCurrentSession();
          final settings = <String, String>{
            'sync_import_format:$familyId': '1',
            'sync_family_time_zone:$familyId': capability.familyTimeZone,
          };
          for (final entry in settings.entries) {
            final existing = await (database.select(database.appSettings)
              ..where((row) => row.key.equals(entry.key))).getSingleOrNull();
            if (existing?.value == entry.value) continue;
            await database.into(database.appSettings).insertOnConflictUpdate(
              AppSettingsCompanion.insert(key: entry.key, value: entry.value,
                updatedAt: DateTime.now().toUtc()));
          }
          api.assertCurrentSession();
        });
      } on NasApiError catch (error) {
        if (error.statusCode != 404) rethrow;
        api.assertCurrentSession();
        await (database.delete(database.appSettings)
          ..where((row) => row.key.equals('sync_import_format:$familyId'))).go();
      }
    },
  );
});

final initialImportServiceProvider = Provider<InitialImportService?>((ref) {
  final api = ref.watch(nasSyncApiProvider);
  final engine = ref.watch(syncEngineProvider);
  final identity = ref.watch(syncWorkspaceIdentityProvider);
  final workspaceId = ref.watch(localWorkspaceIdProvider).valueOrNull;
  final deviceId = ref.watch(nasAccountProvider.select((account) => account.devices.currentDeviceId));
  if (api == null || engine == null || identity == null || workspaceId == null || deviceId == null) {
    return null;
  }
  final service = InitialImportService(database: ref.watch(databaseProvider), api: api,
    engine: engine, identity: identity, deviceId: deviceId, localWorkspaceId: workspaceId);
  ref.onDispose(service.close);
  return service;
});

final initialImportProgressProvider = StreamProvider<InitialImportProgress?>((ref) async* {
  // Observe the durable owner even when signed out or using a different account.
  await ref.watch(syncWorkspaceBindingProvider.future);
  final database = ref.watch(databaseProvider);
  final owner = await SyncWorkspaceRepository(database).readOwner();
  if (owner == null) { yield null; return; }
  yield* InitialImportRepository(database).watchProgress(owner.familyId);
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

final publicWeatherServiceProvider = Provider<PublicWeatherService>((ref) {
  final service = PublicWeatherService();
  ref.onDispose(service.close);
  return service;
});

final homeEnvironmentConfigProvider = StreamProvider<HomeEnvironmentConfig>((ref) => ref
    .watch(settingsRepositoryProvider).watchValue(HomeEnvironmentConfig.settingsKey)
    .distinct().map(HomeEnvironmentConfig.decode));

// Only retained while the environment is visible. The weather service caches
// requests for ten minutes; this tick updates age/expiry without extra traffic.
final environmentClockProvider = StreamProvider.autoDispose<DateTime>((ref) async* {
  yield DateTime.now();
  yield* Stream.periodic(const Duration(minutes: 1), (_) => DateTime.now());
});

final environmentHaRefreshProvider = Provider.autoDispose<void>((ref) {
  final config = ref.watch(homeEnvironmentConfigProvider).valueOrNull;
  if (config == null || ![config.temperatureEntity, config.humidityEntity,
      config.outdoorEntity, config.weatherEntity].any((key) => key?.isNotEmpty == true)) {
    return;
  }
  ref.listen(environmentClockProvider, (previous, next) {
    if (!next.hasValue || next.valueOrNull == previous?.valueOrNull) return;
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return;
    // Refresh through the existing coalesced, authorized HA path so grants
    // revoked since the previous read are rechecked along with the values.
    unawaited(ref.read(smartHomeControllerProvider.notifier).refresh());
  });
});

// A separate provider per city retains only that city's weather during a
// refresh. HA permission/session changes are composed synchronously below,
// never retained through an AsyncValue belonging to the previous family.
final publicWeatherReadingProvider = FutureProvider.autoDispose.family<HomeEnvironment,
    ({String name, double latitude, double longitude})>((ref, place) async {
  ref.watch(environmentClockProvider);
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return const HomeEnvironment();
  return ref.watch(publicWeatherServiceProvider).current(
    WeatherPlace(place.name, place.latitude, place.longitude));
});

final homeEnvironmentProvider = Provider.autoDispose<AsyncValue<HomeEnvironment>>((ref) {
  ref.watch(environmentHaRefreshProvider);
  final config = ref.watch(homeEnvironmentConfigProvider).valueOrNull;
  if (config == null) return const AsyncData(HomeEnvironment());
  final home = ref.watch(smartHomeControllerProvider);
  final now = ref.watch(environmentClockProvider).valueOrNull ?? DateTime.now();
  final ha = environmentFromHa(config, home.entities, home.entityStates, now:now,
    staleEntityKeys:home.staleEntityIds,
    forceStale:!home.nasOnline || {HaConnectionStatus.offline,HaConnectionStatus.unconfigured}.contains(home.haStatus));
  final lifecycle = WidgetsBinding.instance.lifecycleState;
  if (lifecycle != null && lifecycle != AppLifecycleState.resumed) return AsyncData(ha);
  if (config.place == null ||
      (ha.outdoorTemperature != null && !ha.outdoorTemperature!.isStale(now) &&
       ha.apparentTemperature != null && !ha.apparentTemperature!.isStale(now))) {
    return AsyncData(ha);
  }
  final place = config.place!;
  final weather = ref.watch(publicWeatherReadingProvider((name:place.name,
    latitude:place.latitude, longitude:place.longitude)));
  if (weather.hasError) {
    return AsyncData(HomeEnvironment(indoorTemperature:ha.indoorTemperature, indoorHumidity:ha.indoorHumidity,
      outdoorTemperature:ha.outdoorTemperature, apparentTemperature:ha.apparentTemperature,
      message:'公共天气暂不可用，可下拉重试'));
  }
  final result = mergeHomeEnvironment(ha, weather.valueOrNull ?? const HomeEnvironment(), now);
  return weather.isLoading ? const AsyncLoading<HomeEnvironment>().copyWithPrevious(AsyncData(result)) : AsyncData(result);
});
