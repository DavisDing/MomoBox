import 'dart:async';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/nas_auth_service.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/repositories/sync_workspace_repository.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/domain/models/nas_family_device_models.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/nas_setup_controller.dart';
import 'package:momo_box/services/nas_credentials_service.dart';
import '../support/memory_settings_repository.dart';

class _Account extends NasAccountController {
  _Account(SettingsService settings)
    : super(
        settings: settings,
        connection: NasConnectionService(settings),
        credentials: NasCredentialsService(),
      ) {
    select();
  }
  int creates = 0, devices = 0;
  bool inviteRequired = false;
  Completer<void>? deviceGate;
  @override
  String? get serverIdentity => 'https://nas.example/api/v1';
  void select({String user = 'owner', String? family}) {
    state = NasAccountState(
      status: NasAccountStatus.authenticated,
      auth: NasAuthSnapshot(
        status: NasAuthStatus.authenticated,
        user: NasUser(id: user, email: '$user@example.test', nickname: user),
      ),
      family:
          family == null
              ? const NasFamilyState()
              : NasFamilyState(
                status: NasFamilyStatus.available,
                current: NasFamilyResponseDto(
                  family: NasFamilyDto(
                    id: family,
                    name: '家庭',
                    createdAt: DateTime.utc(2026),
                  ),
                  membership: NasFamilyMembershipDto(
                    familyId: family,
                    role: user == 'owner' ? 'owner' : 'member',
                  ),
                ),
              ),
    );
  }

  @override
  Future<void> initializeFamily() async {
    creates++;
    if (!inviteRequired) select(family: 'family');
  }

  @override
  Future<void> prepareCurrentDevice() async {
    devices++;
    await deviceGate?.future;
    state = state.copyWith(
      devices: const NasDeviceState(
        status: NasDeviceStatus.ready,
        currentDeviceId: 'phone',
      ),
    );
  }
}

class _Engine extends SyncEngine {
  _Engine(this.db, this.api)
    : super(
        api: api,
        repository: SyncOutboxRepository(db),
        scopeId: 'family',
        deviceId: 'phone',
        applyRemoteChange: (_) async {},
      );
  final AppDatabase db;
  final NasSyncApi api;
  int bootstraps = 0, runs = 0;
  final modes = <String>[];
  SyncRunReport report = const SyncRunReport(
    pushed: 0,
    pulled: 0,
    skipped: false,
  );
  @override
  Future<NasSyncBootstrap> bootstrap() async {
    bootstraps++;
    return const NasSyncBootstrap(
      schemaVersion: 1,
      syncProtocolVersion: 1,
      serverCursor: 0,
      mergeRequired: false,
      availableModes: ['join_and_merge'],
    );
  }

  @override
  Future<NasSyncConfirmResult> confirmBootstrap({required String mode}) async {
    modes.add(mode);
    return const NasSyncConfirmResult(
      accepted: true,
      nextAction: 'pull_snapshot',
      serverCursor: 0,
    );
  }

  @override
  Future<SyncRunReport> runOnce({
    int maxPush = 100,
    int pullLimit = 100,
  }) async {
    runs++;
    return report;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase db;
  late _Account account;
  late _Engine engine;
  late NasSetupController setup;
  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final settings = MemorySettingsRepository();
    addTearDown(settings.close);
    account = _Account(SettingsService(settings));
    final api = NasSyncApi('https://nas.example');
    addTearDown(api.close);
    engine = _Engine(db, api);
    setup = NasSetupController(
      database: db,
      accountReader: () => account,
      refreshAccess: () async {},
      workspaceReady: () async {},
      engineReader: () => engine,
      importReader: () => null,
    );
  });
  tearDown(() async {
    setup.dispose();
    account.dispose();
    await db.close();
  });
  test(
    'first user creates household, registers device, binds workspace and confirms NAS data automatically',
    () async {
      await setup.prepare();
      expect(setup.state.status, NasSetupStatus.ready);
      expect(account.creates, 1);
      expect(account.devices, 1);
      expect(engine.modes, ['join_and_merge']);
      expect(engine.runs, 1);
      final owner = await SyncWorkspaceRepository(db).readOwner();
      expect(owner!.userId, 'owner');
      expect(owner.familyId, 'family');
    },
  );
  test(
    'invited household member joins existing data without creating another family',
    () async {
      account.select(user: 'member', family: 'family');
      await setup.prepare();
      expect(setup.state.status, NasSetupStatus.ready);
      expect(account.creates, 0);
      expect(engine.modes, ['join_and_merge']);
    },
  );
  test(
    'non-member is stopped for an invite before any device or synchronization request',
    () async {
      account.inviteRequired = true;
      await setup.prepare();
      expect(setup.state.status, NasSetupStatus.inviteRequired);
      expect(account.devices, 0);
      expect(engine.bootstraps, 0);
    },
  );
  test(
    'different durable owner is never silently rebound by automatic setup',
    () async {
      await SyncWorkspaceRepository(db).bind(
        const SyncWorkspaceIdentity(
          endpoint: 'https://old.example/api/v1',
          userId: 'old',
          familyId: 'old-family',
        ),
        isCurrent: () => true,
      );
      await setup.prepare();
      expect(setup.state.status, NasSetupStatus.failed);
      expect(engine.bootstraps, 0);
      expect(
        (await SyncWorkspaceRepository(db).readOwner())!.familyId,
        'old-family',
      );
    },
  );
  for (final report in [
    const SyncRunReport(
      pushed: 0,
      pulled: 0,
      skipped: true,
      reason: 'retry backoff is active',
    ),
    const SyncRunReport(pushed: 0, pulled: 0, skipped: false, deferred: 1),
    const SyncRunReport(
      pushed: 0,
      pulled: 0,
      skipped: false,
      hasMoreRemote: true,
    ),
  ]) {
    test(
      'incomplete first sync never records setup complete: ${report.reason}/${report.deferred}/${report.hasMoreRemote}',
      () async {
        engine.report = report;
        await setup.prepare();
        expect(setup.state.status, NasSetupStatus.failed);
        expect(
          await (db.select(db.appSettings)
            ..where((row) => row.key.equals('nas_setup_complete'))).get(),
          isEmpty,
        );
        expect(engine.runs, report.hasMoreRemote ? 8 : 1);
      },
    );
  }
  test(
    'session switch during device registration cannot bind old data or start its engine',
    () async {
      account.deviceGate = Completer<void>();
      final work = setup.prepare();
      while (account.devices == 0) {
        await Future<void>.delayed(Duration.zero);
      }
      account.select(user: 'another', family: 'other');
      account.deviceGate!.complete();
      await work;
      expect(await SyncWorkspaceRepository(db).readOwner(), isNull);
      expect(engine.bootstraps, 0);
    },
  );
}
