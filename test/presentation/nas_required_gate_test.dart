import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/nas_setup_controller.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/nas_required_gate.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

class _Connection extends NasConnectionService {
  _Connection(super.settings, {this.url = ''});
  final String url;
  @override
  Future<NasConnectionState> loadState() async => NasConnectionState(
    status: NasConnectionStatus.unavailable,
    serverUrl: url,
  );
  @override
  Future<NasHealthResult> checkHealth(String serverUrl) async =>
      const NasHealthResult(status: NasConnectionStatus.unavailable);
}

class _SignedOut extends NasAccountController {
  _SignedOut(SettingsService settings)
    : super(
        settings: settings,
        connection: _Connection(settings),
        credentials: NasCredentialsService(),
      );
}

class _FailedSetup extends NasSetupController {
  _FailedSetup(AppDatabase db, NasAccountController account)
    : super(
        database: db,
        accountReader: () => account,
        refreshAccess: () async {},
        workspaceReady: () async {},
        engineReader: () => null,
        importReader: () => null,
      ) {
    state = NasSetupState(
      NasSetupStatus.failed,
      message: List.filled(20, '数据冲突，原数据已保留。').join(),
    );
  }
  @override
  void changed() {}
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));
  testWidgets(
    'failed setup keeps diagnostics accessible on a narrow screen with large text',
    (tester) async {
      await tester.binding.setSurfaceSize(const Size(320, 640));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final settings = SettingsService(SettingsRepository(db));
      final account = _SignedOut(settings);
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nasAccountProvider.overrideWith((ref) => account),
          nasConnectionServiceProvider.overrideWith(
            (ref) => _Connection(settings),
          ),
          nasSetupProvider.overrideWith((ref) => _FailedSetup(db, account)),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder:
                (context, child) => MediaQuery(
                  data: MediaQuery.of(
                    context,
                  ).copyWith(textScaler: const TextScaler.linear(2)),
                  child: NasRequiredGate(child: child!),
                ),
            home: const Text('business data'),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(tester.takeException(), isNull);
      await tester.ensureVisible(find.text('查看连接与同步状态'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('查看连接与同步状态'));
      await tester.pumpAndSettle();
      expect(find.text('连接与同步状态'), findsOneWidget);
      expect(find.text('business data'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container.dispose();
      var closed = false;
      final closing = db.close().then((_) => closed = true);
      for (var i = 0; i < 200 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(closed, isTrue);
      await closing;
    },
  );
  testWidgets(
    'fresh installation cannot enter any business screen before NAS setup',
    (tester) async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final settings = SettingsService(SettingsRepository(db));
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nasAccountProvider.overrideWith((ref) => _SignedOut(settings)),
          nasConnectionServiceProvider.overrideWith(
            (ref) => _Connection(settings),
          ),
        ],
      );
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            builder: (context, child) => NasRequiredGate(child: child!),
            home: const Text('business data'),
          ),
        ),
      );
      for (var i = 0; i < 8; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 5)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(find.text('连接家庭 NAS 后开始使用'), findsOneWidget);
      expect(find.text('business data'), findsNothing);
      expect(find.text('NAS 服务器地址'), findsOneWidget);
      expect(find.textContaining('本地模式'), findsNothing);
      expect(Navigator.of(tester.element(find.text('NAS 服务器地址'))), isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      container.dispose();
      var closed = false;
      final closing = db.close().then((_) => closed = true);
      for (var i = 0; i < 200 && !closed; i++) {
        await tester.runAsync(
          () => Future<void>.delayed(const Duration(milliseconds: 2)),
        );
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(closed, isTrue);
      await closing;
    },
  );
  testWidgets(
    'offline banner preserves scroll state and reconnect does not remount business content',
    (tester) async {
      final access = StateProvider((ref) => NasAppAccess.connected);
      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            nasAppAccessProvider.overrideWith((ref) => ref.watch(access)),
          ],
          child: MaterialApp(
            home: NasRequiredGate(
              child: ListView(
                children: List.generate(
                  60,
                  (i) => SizedBox(height: 50, child: Text('row $i')),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.drag(find.byType(ListView), const Offset(0, -350));
      await tester.pumpAndSettle();
      final scroll = tester.state<ScrollableState>(find.byType(Scrollable));
      final position = scroll.position.pixels;
      final container = ProviderScope.containerOf(
        tester.element(find.byType(NasRequiredGate)),
      );
      container.read(access.notifier).state = NasAppAccess.cached;
      await tester.pump();
      expect(find.text('NAS 连接未就绪 · 正在查看缓存'), findsOneWidget);
      expect(
        identical(
          tester.state<ScrollableState>(find.byType(Scrollable)),
          scroll,
        ),
        isTrue,
      );
      expect(scroll.position.pixels, position);
      container.read(access.notifier).state = NasAppAccess.connected;
      await tester.pump();
      expect(scroll.position.pixels, position);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
  test(
    'cache access requires endpoint, secure user ID, durable family and completed setup; logout removes access',
    () async {
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      final settings = SettingsService(SettingsRepository(db));
      final api = NasApiClient('https://nas.example');
      final endpoint = api.serverIdentity;
      api.close();
      final credentials = NasCredentialsService();
      await credentials.save(
        const NasAuthResponse(
          user: NasUser(
            id: 'owner',
            email: 'owner@example.test',
            nickname: 'owner',
          ),
          accessToken: 'session',
          refreshToken: 'refresh',
          expiresIn: 900,
        ),
        serverIdentity: endpoint,
      );
      final identity = SyncWorkspaceIdentity(
        endpoint: endpoint,
        userId: 'owner',
        familyId: 'family',
      );
      await SyncWorkspaceRepository(db).bind(identity, isCurrent: () => true);
      await SettingsRepository(
        db,
      ).setValue('nas_setup_complete', identity.encode());
      final container = ProviderContainer(
        overrides: [
          databaseProvider.overrideWithValue(db),
          nasAccountProvider.overrideWith((ref) => _SignedOut(settings)),
          nasConnectionServiceProvider.overrideWith(
            (ref) => _Connection(settings, url: 'https://nas.example'),
          ),
          nasCredentialsServiceProvider.overrideWithValue(credentials),
        ],
      );
      final connection = container.listen(nasConnectionProvider, (_, __) {});
      try {
        for (
          var i = 0;
          i < 100 && container.read(nasConnectionProvider).serverUrl.isEmpty;
          i++
        ) {
          await Future<void>.delayed(const Duration(milliseconds: 5));
        }
        expect(await container.read(nasCachedAccessProvider.future), isTrue);
        await credentials.clear();
        container.invalidate(nasCachedAccessProvider);
        expect(await container.read(nasCachedAccessProvider.future), isFalse);
      } finally {
        connection.close();
        container.dispose();
        await db.close();
      }
    },
  );
}
