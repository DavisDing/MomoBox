import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_auth_service.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/sync_models.dart';
import 'package:momo_box/domain/models/nas_family_device_models.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/sync_settings_screen.dart';
import 'package:momo_box/presentation/screens/home_screen.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

class Account extends NasAccountController {
  Account(SettingsService settings)
    : super(
        settings: settings,
        connection: NasConnectionService(settings),
        credentials: NasCredentialsService(),
      );
  String? endpoint;
  int apiCreations = 0;
  int refreshCalls = 0;
  int conflictCalls = 0;
  bool rejectConflicts = false;
  bool allowSync = false;
  int pulls = 0;
  int preparations = 0;
  String token = 'initial-token';

  void rotateToken() {
    token = 'rotated-token';
    state = state.copyWith(
      auth: NasAuthSnapshot(
        status: NasAuthStatus.authenticated,
        user: state.auth.user,
        expiresAt: DateTime.utc(2026, 12),
      ),
    );
  }

  @override
  String? get serverIdentity => endpoint;

  void select({
    String server = 'https://nas.example/api/v1',
    String user = 'user-a',
    String family = 'family-a',
  }) {
    endpoint = server;
    state = NasAccountState(
      status: NasAccountStatus.authenticated,
      auth: NasAuthSnapshot(
        status: NasAuthStatus.authenticated,
        user: NasUser(
          id: user,
          email: 'fixture@example.invalid',
          nickname: '测试',
        ),
      ),
      family: NasFamilyState(
        status: NasFamilyStatus.available,
        current: NasFamilyResponseDto(
          family: NasFamilyDto(
            id: family,
            name: '家庭',
            createdAt: DateTime.utc(2026),
          ),
          membership: NasFamilyMembershipDto(familyId: family, role: 'owner'),
        ),
      ),
      devices: const NasDeviceState(
        status: NasDeviceStatus.ready,
        currentDeviceId: 'device',
      ),
    );
  }

  void signOut() {
    endpoint = null;
    state = const NasAccountState.initial();
  }

  void requireDevice() {
    state = state.copyWith(devices:const NasDeviceState(status:NasDeviceStatus.needsRegistration));
  }

  @override
  Future<void> prepareCurrentDevice() async {
    preparations++;
    state = state.copyWith(devices:const NasDeviceState(status:NasDeviceStatus.ready,currentDeviceId:'device'));
  }

  @override
  NasSyncApi? createSyncApi({bool Function()? isWorkspaceCurrent}) {
    apiCreations++;
    final api = NasSyncApi(
      endpoint!,
      accessTokenProvider: () => token,
      isSessionCurrent: isWorkspaceCurrent,
      client: MockClient((request) async {
        if (allowSync && request.url.path.endsWith('/sync/bootstrap')) {
          return http.Response(jsonEncode({'schema_version':1,'sync_protocol_version':1,'server_cursor':0,
            'merge_required':false,'available_modes':['join_and_merge','create_new_family','keep_local_only']}),200);
        }
        if (allowSync && request.url.path.endsWith('/sync/import/capabilities')) {
          return http.Response(jsonEncode({'import_format_version':1,'atomic_import':true,
            'history_archive':true,'calendar_dates':true,'max_records':1000,
            'max_request_bytes':1000000,'family_time_zone':'Asia/Shanghai'}), 200);
        }
        if (allowSync && request.url.path.endsWith('/capabilities')) {
          return http.Response('{"schema_version":1,"sync_protocol_version":1}', 200);
        }
        if (allowSync && request.url.path.endsWith('/sync/pull')) {
          pulls++;
          return http.Response('{"changes":[],"next_cursor":0,"has_more":false}', 200);
        }
        if (request.url.path.endsWith('/sync/conflicts')) {
          conflictCalls++;
          if (rejectConflicts ||
              request.headers['Authorization'] == 'Bearer initial-token') {
            return http.Response(
              jsonEncode({
                'error': {
                  'code': 'AUTH_INVALID_TOKEN',
                  'message': 'access token does not identify a device',
                },
              }),
              401,
            );
          }
          return http.Response(
            jsonEncode({'conflicts': [], 'has_more': false}),
            200,
          );
        }
        return http.Response('{}', 404);
      }),
    );
    api.setRefreshHandler(() async {
      refreshCalls++;
      rotateToken();
      return token;
    });
    return api;
  }
}

class _LocalConnection extends NasConnectionService {
  _LocalConnection(super.settings);
  @override
  Future<NasConnectionState> loadState() async => const NasConnectionState(status:NasConnectionStatus.unconfigured);
}

void main() {
  late AppDatabase db;
  late Account account;
  late ProviderContainer container;
  late ProviderSubscription<AsyncValue<SyncWorkspaceAccess>> subscription;
  late bool widgetOwnsCleanup;

  setUp(() async {
    widgetOwnsCleanup = false;
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = SettingsService(SettingsRepository(db));
    account = Account(settings)..select();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      nasAccountProvider.overrideWith((ref) => account),
      localWorkspaceIdProvider.overrideWith((ref) async => 'local-device'),
      nasConnectionServiceProvider.overrideWith((ref)=>_LocalConnection(settings)),
    ]);
    subscription = container.listen(syncWorkspaceAccessProvider, (_, __) {});
    await container.read(localWorkspaceIdProvider.future);
  });
  tearDown(() async {
    // Widget fixtures close while their fake async zone can still advance.
    if (widgetOwnsCleanup) return;
    subscription.close();
    container.dispose();
    await db.close();
  });

  Future<void> bind() async {
    await container.read(syncWorkspaceAccessProvider.future);
    await SyncWorkspaceRepository(db).bind(container.read(syncWorkspaceIdentityProvider)!, isCurrent: () => true);
    container.invalidate(syncWorkspaceAccessProvider);
    await container.read(syncWorkspaceAccessProvider.future);
  }

  test('未确认归属时引擎和冲突API均不可用，确认才就绪', () async {
    expect((await container.read(syncWorkspaceAccessProvider.future)).canBind, isTrue);
    expect(container.read(syncEngineProvider), isNull);
    expect(container.read(nasSyncApiProvider), isNull);
    await bind();
    expect(container.read(nasSyncApiProvider), isNotNull);
    expect(container.read(syncEngineProvider), isNotNull);
  });

  test('unrelated setting writes cannot replace the bound session or engine', () async {
    await bind();
    final api = container.read(nasSyncApiProvider)!;
    final engine = container.read(syncEngineProvider)!;
    final importer = container.read(initialImportServiceProvider);
    final identity = container.read(syncWorkspaceIdentityProvider);
    final settings = container.read(settingsRepositoryProvider);
    for (final key in ['sync_import_format:family-a', 'sync_processing_warning:family-a',
      'sync_backend_history_cursor:family-a', 'ai_usage_logs', 'theme_name']) {
      await settings.setValue(key, 'changed');
      // Allow Drift's table invalidations and Riverpod dependencies to settle.
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(container.read(syncWorkspaceAccessProvider).isLoading, isFalse);
      expect(identical(container.read(nasSyncApiProvider), api), isTrue);
      expect(identical(container.read(syncEngineProvider), engine), isTrue);
      expect(identical(container.read(initialImportServiceProvider), importer), isTrue);
      expect(identical(container.read(syncWorkspaceIdentityProvider), identity), isTrue);
      expect(api.assertCurrentSession, returnsNormally);
    }
    expect(account.apiCreations, 1);
  });

  test('successful pull and internal capability writes keep one engine without a restart loop', () async {
    await bind();
    account.allowSync = true;
    final outbox = SyncOutboxRepository(db);
    await container.read(settingsRepositoryProvider).setValue(nasServerUrlKey,'https://nas.example');
    await outbox.saveState(SyncStateModel(scopeId:'family-a', bootstrapStatus:SyncBootstrapStatus.ready,
      pullCursor:0,pushAckCursor:0,consecutiveFailures:0,updatedAt:DateTime.now(),
      serverSchemaVersion:1,syncProtocolVersion:1));
    await container.read(settingsRepositoryProvider).setValue('sync_bootstrap:family-a',
      jsonEncode({'mode':'join_and_merge'}));
    final engine = container.read(syncEngineProvider)!;
    for (var i = 0; i < 2; i++) {
      final result = await engine.runOnce();
      expect(result.skipped, isFalse);
      expect(result.postProcessingError, isNull);
      await Future<void>.delayed(const Duration(milliseconds:30));
      expect(identical(container.read(syncEngineProvider),engine),isTrue);
    }
    expect(account.pulls,2);
    expect(account.apiCreations,1);
    expect((await outbox.getState('family-a'))!.lastErrorMessage,isNull);
  });

  for (final reject in [false, true]) {
    test(
      '401 refresh preserves API/engine/import identity and bounds retry; persistent rejection=$reject',
      () async {
        await bind();
        account.rejectConflicts = reject;
        final api = container.read(nasSyncApiProvider)!;
        final engine = container.read(syncEngineProvider);
        final importer = container.read(initialImportServiceProvider);
        final identity = container.read(syncWorkspaceIdentityProvider);
        final pending = api.listConflicts(deviceId: 'device');
        if (reject) {
          await expectLater(pending, throwsA(isA<NasApiError>()));
        } else {
          expect((await pending).conflicts, isEmpty);
        }
        await Future<void>.delayed(Duration.zero);
        expect(identical(container.read(nasSyncApiProvider), api), isTrue);
        expect(identical(container.read(syncEngineProvider), engine), isTrue);
        expect(
          identical(container.read(initialImportServiceProvider), importer),
          isTrue,
        );
        expect(
          identical(container.read(syncWorkspaceIdentityProvider), identity),
          isTrue,
        );
        expect(container.read(syncWorkspaceAccessProvider).isLoading, isFalse);
        expect(account.apiCreations, 1);
        expect(account.refreshCalls, 1);
        expect(account.conflictCalls, 2);
      },
    );
  }

  test('同家庭换账号也阻断API/引擎；旧客户端不能继续，原身份返回后恢复', () async {
    await bind();
    final oldApi = container.read(nasSyncApiProvider)!;
    final oldEngine = container.read(syncEngineProvider)!;
    account.select(user: 'user-b');
    expect(container.read(nasSyncApiProvider), isNull);
    expect(container.read(syncEngineProvider), isNull);
    expect(oldApi.assertCurrentSession, throwsA(isA<NasApiError>()));
    await expectLater(oldEngine.runOnce(), throwsA(isA<NasApiError>()));
    expect((await container.read(syncWorkspaceAccessProvider.future)).status, SyncWorkspaceStatus.mismatch);
    account.select();
    await container.read(syncWorkspaceAccessProvider.future);
    expect(container.read(syncEngineProvider), isNotNull);
  });

  test('切NAS和家庭阻断，离线及错身份采购仍入原家庭队列', () async {
    await bind();
    final held = container.read(shoppingRepositoryProvider);
    account.select(server: 'https://other.example/api/v1', family: 'family-b');
    await container.read(syncWorkspaceAccessProvider.future);
    expect(container.read(syncEngineProvider), isNull);
    await held.addOrMerge(itemName: '保留原归属', targetQuantity: 2, reason: '离线');
    await container.read(shoppingRepositoryProvider).addOrMerge(itemName: '新身份下本机编辑', targetQuantity: 1, reason: '本机');
    account.signOut();
    await container.read(syncWorkspaceAccessProvider.future);
    await container.read(shoppingRepositoryProvider).addOrMerge(itemName: '登出后编辑', targetQuantity: 1, reason: '本机');
    expect((await db.select(db.syncOutbox).get()).map((row) => row.scopeId).toSet(), {'family-a'});
    expect((await db.select(db.shoppingEntries).get()).length, 3);
    expect((await SyncWorkspaceRepository(db).readOwner())!.familyId, 'family-a');
  });

  Future<void> settle(WidgetTester tester, Finder ready, {bool Function()? readyWhen}) async {
    // Drift transactions started by the UI continue in the fake async zone.
    // Advance it alongside the real event loop until the relevant UI state is
    // visible, before entering runAsync for a separate database assertion.
    for (var turn = 0; turn < 200; turn++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
      await tester.pump(const Duration(milliseconds: 16));
      if (ready.evaluate().length == 1 && (readyWhen?.call() ?? true)) return;
    }
    expect(ready, findsOneWidget, reason: '工作区操作未在有界等待内完成');
    expect(readyWhen?.call() ?? true, isTrue, reason: '工作区控件尚未就绪');
  }

  Future<void> tapButton(WidgetTester tester, Finder button, {bool bindingEntry = false}) async {
    final hittable = button.hitTestable();
    await settle(tester, hittable, readyWhen: () {
      if (tester.widget<ButtonStyleButton>(button).onPressed == null) return false;
      if (!bindingEntry) return true;
      final access = container.read(syncWorkspaceAccessProvider);
      return !access.isLoading && access.asData?.value.canBind == true &&
          find.byType(AlertDialog).evaluate().isEmpty;
    });
    await tester.tap(hittable);
  }

  Future<void> finishWidgetWork(WidgetTester tester, Future<void> work) async {
    var completed = false;
    Object? failure;
    final result = work.then<void>((_) { completed = true; },onError:(Object error) {
      failure = error;
      completed = true;
    });
    for (var i = 0; i < 200 && !completed; i++) {
      await tester.runAsync(()=>Future<void>.delayed(const Duration(milliseconds:1)));
      await tester.pump(const Duration(milliseconds:16));
    }
    expect(completed,isTrue,reason:'页面挂载后的异步数据库操作未在有界等待内完成');
    await result;
    if (failure != null) throw failure!;
  }

  Future<void> closeWidgetFixture(WidgetTester tester) async {
    try {
      await tester.pumpWidget(const SizedBox.shrink());
    } finally {
      try {
        subscription.close();
        container.dispose();
        var closed = false;
        Object? closeError;
        StackTrace? closeStack;
        final closing = db.close().then<void>((_) {
          closed = true;
        }, onError: (Object error, StackTrace stack) {
          closeError = error;
          closeStack = stack;
          closed = true;
        });
        // Closing Drift can await cancellations created in this fake zone.
        // Do not leave that work to tearDown after binding.postTest ends it.
        for (var turn = 0; turn < 200 && !closed; turn++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
          await tester.pump(const Duration(milliseconds: 16));
        }
        expect(closed, isTrue, reason: '工作区数据库关闭未在有界等待内完成');
        await closing;
        if (closeError != null) Error.throwWithStackTrace(closeError!, closeStack!);
      } finally {
        await tester.binding.setSurfaceSize(null);
      }
    }
  }

  testWidgets('one setup action prepares device and opens explicit first-sync choices even for an empty family', (tester) async {
    widgetOwnsCleanup = true;
    try {
      account.allowSync = true;
      account.requireDevice();
      await tester.binding.setSurfaceSize(const Size(600,1200));
      await tester.pumpWidget(UncontrolledProviderScope(container:container,
        child:const MaterialApp(home:SyncSettingsScreen())));
      await tapButton(tester,find.widgetWithText(FilledButton,'开始使用 NAS 同步'));
      await settle(tester,find.byType(AlertDialog));
      expect(account.preparations,1);
      await tapButton(tester,find.widgetWithText(FilledButton,'确认属于此身份'));
      await settle(tester,find.textContaining('请选择首次同步方式并确认'));
      expect(find.byType(RadioListTile<String>),findsNWidgets(3));
      expect(await tester.runAsync(()=>SyncOutboxRepository(db).getConfirmedBootstrapMode('family-a')),isNull);
      expect(find.textContaining('请选择首次同步方式并确认'),findsOneWidget);
      expect(tester.takeException(),isNull);
    } finally { await closeWidgetFixture(tester); }
  });

  testWidgets('today page keeps its scroll position while successful NAS sync writes internal settings', (tester) async {
    widgetOwnsCleanup = true;
    try {
      account.allowSync = true;
      await tester.runAsync(() async {
        await bind();
        final outbox = SyncOutboxRepository(db);
        await outbox.saveState(SyncStateModel(scopeId:'family-a',bootstrapStatus:SyncBootstrapStatus.ready,
          pullCursor:0,pushAckCursor:0,consecutiveFailures:0,updatedAt:DateTime.now(),
          serverSchemaVersion:1,syncProtocolVersion:1));
        await container.read(settingsRepositoryProvider).setValue('sync_bootstrap:family-a','{"mode":"join_and_merge"}');
        await container.read(settingsRepositoryProvider).setValue(nasServerUrlKey,'https://nas.example');
      });
      await tester.binding.setSurfaceSize(const Size(390,700));
      await tester.pumpWidget(UncontrolledProviderScope(container:container,
        child:const MaterialApp(home:HomeScreen())));
      await settle(tester,find.byType(CustomScrollView));
      final scrollable = find.descendant(of:find.byType(CustomScrollView),matching:find.byType(Scrollable));
      await tester.drag(find.byType(CustomScrollView),const Offset(0,-450));
      await settle(tester,find.byType(CustomScrollView),readyWhen:()=>container.read(choresProvider).hasValue);
      final scroll = tester.state<ScrollableState>(scrollable);
      final offset = scroll.position.pixels;
      expect(offset,greaterThan(100));
      final inventoryRepository = container.read(inventoryRepositoryProvider);
      final order = container.read(homeSectionOrderProvider).value;
      final engine = container.read(syncEngineProvider)!;
      for (var i = 0; i < 3; i++) {
        var skipped = true;
        await finishWidgetWork(tester,() async {
          final report = await engine.runOnce();
          skipped = report.skipped;
          await container.read(settingsRepositoryProvider).setValue('sync_processing_warning:family-a','round-$i');
          account.rotateToken();
        }());
        expect(skipped,isFalse);
        await tester.pump(const Duration(milliseconds:100));
        expect(find.byType(CustomScrollView),findsOneWidget);
        expect(identical(tester.state<ScrollableState>(scrollable),scroll),isTrue);
        expect(scroll.position.pixels,closeTo(offset,1));
        expect(container.read(inventoryProvider).isLoading,isFalse);
        expect(identical(container.read(inventoryRepositoryProvider),inventoryRepository),isTrue);
        expect(identical(container.read(homeSectionOrderProvider).value,order),isTrue);
        expect(identical(container.read(syncEngineProvider),engine),isTrue);
      }
      expect(account.pulls,3);
      expect(account.apiCreations,1);
      expect(tester.takeException(),isNull);
    } finally { await closeWidgetFixture(tester); }
  });

  for (final reject in [false, true]) {
    testWidgets('同步设置在401刷新后保持稳定，不重建冲突请求：持续拒绝=$reject', (tester) async {
      widgetOwnsCleanup = true;
      try {
        await tester.runAsync(bind);
        account.rejectConflicts = reject;
        final api = container.read(nasSyncApiProvider);
        await tester.binding.setSurfaceSize(const Size(600, 1200));
        await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: SyncSettingsScreen())));
        await settle(tester, reject
            ? find.textContaining('读取远端冲突失败：')
            : find.text('当前没有开放的远端冲突或待恢复回执。'));
        expect(account.refreshCalls, 1);
        expect(account.conflictCalls, 2);
        expect(account.apiCreations, 1);
        expect(identical(container.read(nasSyncApiProvider), api), isTrue);
        // Further account notifications/page frames must not restart an
        // already completed (including failed) conflict request.
        account.rotateToken();
        for (var i = 0; i < 20; i++) {
          await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 1)));
          await tester.pump(const Duration(milliseconds: 50));
        }
        expect(account.refreshCalls, 1);
        expect(account.conflictCalls, 2);
        expect(account.apiCreations, 1);
        if (reject) {
          expect(find.textContaining('当前登录尚未绑定同步设备'), findsOneWidget);
        }
        expect(tester.takeException(), isNull);
      } finally {
        await closeWidgetFixture(tester);
      }
    });
  }

  testWidgets('数据归属确认显示完整身份，取消不写绑定、不启用同步', (tester) async {
    widgetOwnsCleanup = true;
    try {
      await tester.binding.setSurfaceSize(const Size(600, 1200));
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: SyncSettingsScreen())));
      await settle(tester, find.text('确认本机数据归属'));
      expect(find.text('确认本机数据归属'), findsOneWidget);
      await tapButton(tester, find.widgetWithText(OutlinedButton, '确认本机数据归属'), bindingEntry: true);
      await settle(tester, find.byType(AlertDialog));
      expect(find.textContaining('https://nas.example/api/v1'), findsOneWidget);
      expect(find.textContaining('账号：user-a'), findsOneWidget);
      await tapButton(tester, find.widgetWithText(TextButton, '取消'));
      await settle(tester, find.text('确认本机数据归属'));
      expect(await tester.runAsync(() => SyncWorkspaceRepository(db).readOwner()), isNull);
      expect(container.read(syncEngineProvider), isNull);
    } finally {
      await closeWidgetFixture(tester);
    }
  });

  testWidgets('确认弹窗期间身份变化拒绝旧确认，原身份重新确认后绑定', (tester) async {
    widgetOwnsCleanup = true;
    try {
      await tester.binding.setSurfaceSize(const Size(600, 1200));
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: SyncSettingsScreen())));
      await settle(tester, find.text('确认本机数据归属'));
      await tapButton(tester, find.widgetWithText(OutlinedButton, '确认本机数据归属'), bindingEntry: true);
      await settle(tester, find.byType(AlertDialog));
      account.select(user: 'user-b');
      await tapButton(tester, find.widgetWithText(FilledButton, '确认属于此身份'));
      await settle(tester, find.textContaining('数据归属确认失败'));
      expect(await tester.runAsync(() => SyncWorkspaceRepository(db).readOwner()), isNull);
      expect(find.textContaining('数据归属确认失败'), findsOneWidget);
      account.select();
      await settle(tester, find.text('确认本机数据归属'));
      await tapButton(tester, find.widgetWithText(OutlinedButton, '确认本机数据归属'), bindingEntry: true);
      await settle(tester, find.byType(AlertDialog));
      await tapButton(tester, find.widgetWithText(FilledButton, '确认属于此身份'));
      await settle(tester, find.textContaining('本机数据归属已确认；'), readyWhen: () {
        final access = container.read(syncWorkspaceAccessProvider);
        final identity = container.read(syncWorkspaceIdentityProvider);
        return !access.isLoading && access.asData?.value.canSync == true &&
            identity != null && access.asData?.value.owner?.matches(identity) == true &&
            find.text('确认本机数据归属').evaluate().isEmpty;
      });
      final owner = await tester.runAsync(() => SyncWorkspaceRepository(db).readOwner());
      expect(owner!.userId, 'user-a');
      expect(find.text('确认本机数据归属'), findsNothing);
      expect(find.textContaining('首次同步模式仍需单独确认'), findsOneWidget);
    } finally {
      await closeWidgetFixture(tester);
    }
  });
}
