import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/nas_auth_service.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/domain/models/nas_family_device_models.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/sync_settings_screen.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

class Account extends NasAccountController {
  Account(SettingsService settings) : super(settings: settings,
      connection: NasConnectionService(settings), credentials: NasCredentialsService());
  String? endpoint;

  @override
  String? get serverIdentity => endpoint;

  void select({String server = 'https://nas.example/api/v1', String user = 'user-a', String family = 'family-a'}) {
    endpoint = server;
    state = NasAccountState(
      status: NasAccountStatus.authenticated,
      auth: NasAuthSnapshot(status: NasAuthStatus.authenticated,
          user: NasUser(id: user, email: 'fixture@example.invalid', nickname: '测试')),
      family: NasFamilyState(status: NasFamilyStatus.available,
          current: NasFamilyResponseDto(
            family: NasFamilyDto(id: family, name: '家庭', createdAt: DateTime.utc(2026)),
            membership: NasFamilyMembershipDto(familyId: family, role: 'owner'),
          )),
      devices: const NasDeviceState(status: NasDeviceStatus.ready, currentDeviceId: 'device'),
    );
  }

  void signOut() {
    endpoint = null;
    state = const NasAccountState.initial();
  }

  @override
  NasSyncApi? createSyncApi({bool Function()? isWorkspaceCurrent}) => NasSyncApi(
      endpoint!, accessToken: 'fixture-token', isSessionCurrent: isWorkspaceCurrent);
}

void main() {
  late AppDatabase db;
  late Account account;
  late ProviderContainer container;
  late ProviderSubscription<AsyncValue<SyncWorkspaceAccess>> subscription;

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = SettingsService(SettingsRepository(db));
    account = Account(settings)..select();
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      nasAccountProvider.overrideWith((ref) => account),
      localWorkspaceIdProvider.overrideWith((ref) async => 'local-device'),
    ]);
    subscription = container.listen(syncWorkspaceAccessProvider, (_, __) {});
    await container.read(localWorkspaceIdProvider.future);
  });
  tearDown(() async {
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

  Future<void> settle(WidgetTester tester) async {
    for (var turn = 0; turn < 15; turn++) {
      await tester.runAsync(() => Future<void>.delayed(Duration.zero));
      await tester.pump(Duration.zero);
    }
    await tester.pumpAndSettle();
  }

  testWidgets('数据归属确认显示完整身份，取消不写绑定、不启用同步', (tester) async {
    try {
      await tester.binding.setSurfaceSize(const Size(600, 1200));
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: SyncSettingsScreen())));
      await settle(tester);
      expect(find.text('确认本机数据归属'), findsOneWidget);
      await tester.tap(find.text('确认本机数据归属'));
      await tester.pumpAndSettle();
      expect(find.textContaining('https://nas.example/api/v1'), findsOneWidget);
      expect(find.textContaining('账号：user-a'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await settle(tester);
      expect(await tester.runAsync(() => SyncWorkspaceRepository(db).readOwner()), isNull);
      expect(container.read(syncEngineProvider), isNull);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await tester.binding.setSurfaceSize(null);
    }
  });

  testWidgets('确认弹窗期间身份变化拒绝旧确认，原身份重新确认后绑定', (tester) async {
    try {
      await tester.binding.setSurfaceSize(const Size(600, 1200));
      await tester.pumpWidget(UncontrolledProviderScope(container: container,
          child: const MaterialApp(home: SyncSettingsScreen())));
      await settle(tester);
      await tester.tap(find.text('确认本机数据归属'));
      await tester.pumpAndSettle();
      account.select(user: 'user-b');
      await tester.tap(find.text('确认属于此身份'));
      await settle(tester);
      expect(await tester.runAsync(() => SyncWorkspaceRepository(db).readOwner()), isNull);
      expect(find.textContaining('数据归属确认失败'), findsOneWidget);
      account.select();
      await settle(tester);
      await tester.tap(find.text('确认本机数据归属'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('确认属于此身份'));
      await settle(tester);
      final owner = await tester.runAsync(() => SyncWorkspaceRepository(db).readOwner());
      expect(owner!.userId, 'user-a');
      expect(find.text('确认本机数据归属'), findsNothing);
      expect(find.textContaining('首次同步模式仍需单独确认'), findsOneWidget);
    } finally {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(Duration.zero);
      await tester.binding.setSurfaceSize(null);
    }
  });
}
