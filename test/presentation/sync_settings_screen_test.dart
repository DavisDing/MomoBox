import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/nas_family_device_models.dart';
import 'package:momo_box/domain/models/nas_sync_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/sync_settings_screen.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

import '../support/memory_settings_repository.dart';

const _remote = NasSyncConflictDetail(
  conflictId: 'nas-conflict', changeId: 'edit', operation: 'entity_upsert',
  entity: 'products', entityId: 'product', reason: 'VERSION_CONFLICT',
  status: 'open', serverVersion: 1,
);

class _Account extends NasAccountController {
  _Account(SettingsService settings, NasConnectionService connection)
      : super(settings: settings, connection: connection, credentials: NasCredentialsService()) {
    state = state.copyWith(
      family: NasFamilyState(
        status: NasFamilyStatus.available,
        current: NasFamilyResponseDto(
          family: NasFamilyDto(id: 'family-a', name: '家庭', createdAt: DateTime.utc(2026)),
          membership: const NasFamilyMembershipDto(familyId: 'family-a', role: 'owner'),
        ),
      ),
      devices: const NasDeviceState(currentDeviceId: 'device'),
    );
  }
}

class _Api extends NasSyncApi {
  _Api() : super('https://nas.example');
  NasSyncConflictResolveResponse? receipt;
  Object? error;
  final requests = <NasSyncConflictResolveRequest>[];
  final listRequests = <({String? status, int offset})>[];
  List<NasSyncConflictDetail> openConflicts = [_remote];
  final resolvedPages = <int, NasSyncConflictListResponse>{};
  NasSyncConflictDetail? detail;
  int detailReads = 0;
  Object? detailError;
  final response = Completer<NasSyncConflictResolveResponse>();

  @override
  Future<NasSyncConflictListResponse> listConflicts({
    required String deviceId, String? status, int? limit, int offset = 0,
  }) async {
    listRequests.add((status: status, offset: offset));
    if (status == 'resolved') {
      return resolvedPages[offset] ?? const NasSyncConflictListResponse(conflicts: [], hasMore: false);
    }
    return NasSyncConflictListResponse(conflicts: openConflicts, hasMore: false);
  }

  @override
  Future<NasSyncConflictDetail> getConflict({required String deviceId, required String conflictId}) async {
    detailReads++;
    if (detailError != null) throw detailError!;
    return detail ?? receipt!.conflict;
  }

  @override
  Future<NasSyncConflictResolveResponse> resolveConflict(NasSyncConflictResolveRequest request) async {
    requests.add(request);
    if (error != null) throw error!;
    return receipt ?? await response.future;
  }
}

class _Engine extends SyncEngine {
  _Engine(_Api api, this.outbox) : super(
    api: api, repository: outbox, scopeId: 'family-a', deviceId: 'device',
    applyRemoteChange: (_) async {},
  );
  final SyncOutboxRepository outbox;
  int runs = 0;
  Object? error;
  bool consumeRefresh = false;

  @override
  Future<SyncRunReport> runOnce({int maxPush = 100, int pullLimit = 100}) async {
    runs++;
    // UI must settle durably BEFORE asking the engine to run.
    expect(await outbox.hasSnapshotBlockingChanges(scopeId: 'family-a'), isFalse);
    final token = await outbox.getConflictResolutionRefreshToken('family-a');
    expect(token, isNotNull);
    expect((await outbox.getByChangeId('edit'))!.status, SyncOutboxStatus.conflict);
    if (error != null) throw error!;
    if (consumeRefresh) {
      await outbox.clearConflictResolutionRefresh(scopeId: 'family-a', token: token!);
    }
    return const SyncRunReport(pushed: 0, pulled: 0, skipped: false);
  }
}

class _ReportEngine extends SyncEngine {
  _ReportEngine(_Api api, SyncOutboxRepository outbox, this.report) : super(
    api: api, repository: outbox, scopeId: 'family-a', deviceId: 'device',
    applyRemoteChange: (_) async {},
  );
  final SyncRunReport report;
  int runs = 0;

  @override
  Future<SyncRunReport> runOnce({int maxPush = 100, int pullLimit = 100}) async {
    runs++;
    return report;
  }
}

NasSyncConflictResolveResponse _resolved(String action, {bool accepted = true, String id = 'nas-conflict'}) =>
    NasSyncConflictResolveResponse(
      accepted: accepted,
      conflict: NasSyncConflictDetail(
        conflictId: id, changeId: 'edit', operation: 'entity_upsert',
        entity: 'products', entityId: 'product', reason: 'VERSION_CONFLICT',
        status: 'resolved', resolution: {'action': action}, serverVersion: 1,
      ),
    );

void main() {
  late AppDatabase database;
  late SyncOutboxRepository outbox;
  late _Api api;
  late _Engine engine;
  late MemorySettingsRepository settings;
  late NasConnectionService connection;
  late _Account account;
  late int conflictId;
  late ValueNotifier<bool> showScreen;

  setUp(() async {
    showScreen = ValueNotifier(true);
    database = AppDatabase.forTesting(NativeDatabase.memory());
    outbox = SyncOutboxRepository(database);
    api = _Api();
    engine = _Engine(api, outbox);
    settings = MemorySettingsRepository();
    final service = SettingsService(settings);
    connection = NasConnectionService(service);
    account = _Account(service, connection);
    await outbox.enqueue(const SyncOutboxDraft(
      changeId: 'edit', scopeId: 'family-a', operation: SyncOperation.entityUpsert,
      entity: 'products', entityId: 'product',
      idempotencyKey: 'original-conflict-key', requestJson: '{"name":"local"}',
    ));
    await outbox.markConflict(changeId: 'edit', conflict: const SyncConflictDraft(
      scopeId: 'family-a', changeId: 'edit', outboxChangeId: 'edit',
      entity: 'products', entityId: 'product', reason: 'VERSION_CONFLICT',
    ));
    conflictId = (await outbox.getConflictByChangeId(scopeId: 'family-a', changeId: 'edit'))!.id;
  });

  tearDown(() async {
    showScreen.dispose();
    api.close();
    connection.close();
    await settings.close();
    await database.close();
  });

  Future<void> mount(WidgetTester tester, {SyncEngine? configuredEngine}) async {
    await tester.binding.setSurfaceSize(const Size(600, 1200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(database),
        nasAccountProvider.overrideWith((ref) => account),
        nasSyncApiProvider.overrideWithValue(api),
        syncEngineProvider.overrideWithValue(configuredEngine ?? engine),
        localWorkspaceIdProvider.overrideWith((ref) async => 'workspace'),
      ],
      child: MaterialApp(home: ValueListenableBuilder<bool>(
        valueListenable: showScreen,
        builder: (_, show, _) => show ? const SyncSettingsScreen() : const SizedBox(),
      )),
    ));
    await tester.pumpAndSettle();
    // Open the first (remote) conflict, rather than the second local copy.
    await tester.tap(find.byType(ExpansionTile).first);
    await tester.pumpAndSettle();
  }

  testWidgets('manual bounded batch does not report full completion', (tester) async {
    final reporting = _ReportEngine(api, outbox, const SyncRunReport(
      pushed: 100, pulled: 0, skipped: false, deferred: 1, hasMorePending: true,
    ));
    await mount(tester, configuredEngine: reporting);
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    expect(reporting.runs, 1);
    expect(find.textContaining('尚未完成同步'), findsOneWidget);
    expect(find.textContaining('同步完成：'), findsNothing);
  });

  testWidgets('manual remote page boundary is not reported as complete', (tester) async {
    final reporting = _ReportEngine(api, outbox, const SyncRunReport(
      pushed: 0, pulled: 100, skipped: false, hasMoreRemote: true,
    ));
    await mount(tester, configuredEngine: reporting);
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    expect(reporting.runs, 1);
    expect(find.textContaining('远端仍有数据'), findsOneWidget);
    expect(find.textContaining('同步完成：'), findsNothing);
  });

  testWidgets('manual conflict deferral is reported as paused', (tester) async {
    final reporting = _ReportEngine(api, outbox, const SyncRunReport(
      pushed: 0, pulled: 0, skipped: false, deferred: 1,
    ));
    await mount(tester, configuredEngine: reporting);
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    expect(reporting.runs, 1);
    expect(find.textContaining('同步暂停：'), findsOneWidget);
    expect(find.textContaining('同步完成：'), findsNothing);
  });

  testWidgets('manual request retains engine backoff feedback', (tester) async {
    final reporting = _ReportEngine(api, outbox, const SyncRunReport(
      pushed: 0, pulled: 0, skipped: true, reason: 'retry backoff is active',
    ));
    await mount(tester, configuredEngine: reporting);
    await tester.tap(find.text('立即同步'));
    await tester.pumpAndSettle();
    expect(reporting.runs, 1);
    expect(find.text('本次未同步：retry backoff is active'), findsOneWidget);
    expect(find.textContaining('同步完成：'), findsNothing);
  });

  for (final action in ['keep_remote', 'keep_local']) {
    testWidgets('$action calls runOnce only after atomic settlement', (tester) async {
      api.receipt = _resolved(action);
      await mount(tester);
      await tester.tap(find.text(action == 'keep_local' ? '保留本地' : '保留远端').first);
      await tester.pumpAndSettle();
      expect(engine.runs, 1);
      expect(api.requests.single.action, action);
      expect((await outbox.getConflict(conflictId))!.resolution, 'remote_$action');
      expect(await outbox.getConflictResolutionRefreshToken('family-a'), isNotNull);
      expect(find.textContaining('等待获取 NAS 最新快照'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('NAS rejection, transport error and wrong receipt preserve open conflict', (tester) async {
    api.receipt = _resolved('keep_remote', accepted: false);
    await mount(tester);
    final button = find.text('保留远端').first;
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.open);
    api.receipt = _resolved('keep_remote', id: 'wrong-conflict');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.open);
    api.error = StateError('network failed');
    await tester.tap(button);
    await tester.pumpAndSettle();
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.open);
    expect(await outbox.hasSnapshotBlockingChanges(scopeId: 'family-a'), isTrue);
    expect(await outbox.getConflictResolutionRefreshToken('family-a'), isNull);
    expect(engine.runs, 0);
  });

  testWidgets('failed follow-up sync retains settlement and durable refresh intent', (tester) async {
    api.receipt = _resolved('keep_remote');
    engine.error = StateError('NAS offline');
    await mount(tester);
    await tester.tap(find.text('保留远端').first);
    await tester.pumpAndSettle();
    expect(engine.runs, 1);
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.rejected);
    expect(await outbox.getConflictResolutionRefreshToken('family-a'), isNotNull);
    expect(find.textContaining('最新快照同步尚未完成'), findsOneWidget);
  });

  testWidgets('UI reports snapshot complete only after engine consumes refresh token', (tester) async {
    api.receipt = _resolved('keep_remote');
    engine.consumeRefresh = true;
    await mount(tester);
    await tester.tap(find.text('保留远端').first);
    await tester.pumpAndSettle();
    expect(engine.runs, 1);
    expect(await outbox.getConflictResolutionRefreshToken('family-a'), isNull);
    expect(find.textContaining('最新快照同步已完成'), findsOneWidget);
  });

  for (final action in ['keep_remote', 'keep_local']) {
    testWidgets('$action legacy half-settlement recovers using GET without remote mutation', (tester) async {
      await outbox.resolveConflict(
        id: conflictId,
        status: action == 'keep_local' ? SyncConflictStatus.resolved : SyncConflictStatus.rejected,
        resolution: 'remote_$action',
      );
      expect(await outbox.listOpenConflicts(scopeId: 'family-a'), isEmpty);
      api.openConflicts = [];
      api.detail = _resolved(action).conflict;
      api.resolvedPages[0] = NasSyncConflictListResponse(conflicts: [api.detail!], hasMore: false);
      await mount(tester);
      expect(find.text('保留本地'), findsNothing);
      expect(find.text('保留远端'), findsNothing);
      await tester.tap(find.text('按原动作恢复本地结算').first);
      await tester.pumpAndSettle();
      expect(api.requests, isEmpty);
      expect(api.detailReads, 1);
      expect(engine.runs, 1);
      expect(await outbox.listUnsettledLinkedConflicts(scopeId: 'family-a'), isEmpty);
      expect(await outbox.getConflictResolutionRefreshToken('family-a'), isNotNull);
      // Settled legacy audit must not be displayed again after reloading.
      showScreen.value = false;
      await tester.pumpAndSettle();
      showScreen.value = true;
      await tester.pumpAndSettle();
      expect(find.text('按原动作恢复本地结算'), findsNothing);
    });
  }

  testWidgets('accepted but local write failed retains receipt for no-mutation retry', (tester) async {
    api.receipt = _resolved('keep_remote');
    await database.customStatement("""
      CREATE TRIGGER fail_refresh BEFORE INSERT ON app_settings
      WHEN NEW.key LIKE 'sync_resolution_refresh:%'
      BEGIN SELECT RAISE(ABORT, 'disk failure'); END
    """);
    await mount(tester);
    await tester.tap(find.text('保留远端').first);
    await tester.pumpAndSettle();
    expect(api.requests.length, 1);
    expect(engine.runs, 0);
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.open);
    expect(find.text('按原动作恢复本地结算'), findsWidgets);
    await database.customStatement('DROP TRIGGER fail_refresh');
    await tester.tap(find.text('按原动作恢复本地结算').first);
    await tester.pumpAndSettle();
    expect(api.requests.length, 1);
    expect(api.detailReads, 1);
    expect(engine.runs, 1);
    expect(await outbox.hasSnapshotBlockingChanges(scopeId: 'family-a'), isFalse);
  });

  for (final code in ['CONFLICT_ALREADY_RESOLVED', 'NETWORK_ERROR']) {
    testWidgets('$code reads GET receipt and settles without retry mutation', (tester) async {
      api.error = NasApiError(
        kind: code == 'NETWORK_ERROR' ? NasApiErrorKind.network : NasApiErrorKind.conflict,
        message: 'receipt lost', code: code,
      );
      api.detail = _resolved('keep_remote').conflict;
      await mount(tester);
      await tester.tap(find.text('保留远端').first);
      await tester.pumpAndSettle();
      expect(api.requests.length, 1);
      expect(api.detailReads, 1);
      expect(engine.runs, 1);
      expect(await outbox.hasSnapshotBlockingChanges(scopeId: 'family-a'), isFalse);
    });
  }

  testWidgets('different original action requires recovery button, never repeats mutation', (tester) async {
    api.error = NasApiError(kind: NasApiErrorKind.conflict, message: 'already resolved', code: 'CONFLICT_ALREADY_RESOLVED');
    api.detail = _resolved('keep_local').conflict;
    await mount(tester);
    await tester.tap(find.text('保留远端').first);
    await tester.pumpAndSettle();
    expect(engine.runs, 0);
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.open);
    await tester.tap(find.text('按原动作恢复本地结算').first);
    await tester.pumpAndSettle();
    expect(api.requests.length, 1);
    expect(engine.runs, 1);
    expect((await outbox.getConflict(conflictId))!.resolution, 'remote_keep_local');
  });

  testWidgets('GET receipt mismatch leaves recovery conflict protected', (tester) async {
    api.openConflicts = [];
    api.resolvedPages[0] = NasSyncConflictListResponse(conflicts: [_resolved('keep_remote').conflict], hasMore: false);
    api.detail = _resolved('keep_local').conflict;
    await mount(tester);
    await tester.tap(find.text('按原动作恢复本地结算').first);
    await tester.pumpAndSettle();
    expect(api.requests, isEmpty);
    expect(engine.runs, 0);
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.open);
    expect(await outbox.hasSnapshotBlockingChanges(scopeId: 'family-a'), isTrue);
  });

  testWidgets('leaving page during request still persists valid resolution', (tester) async {
    await mount(tester);
    await tester.tap(find.text('保留远端').first);
    await tester.pump();
    // Remove the screen without replacing/disposal of provider overrides.
    showScreen.value = false;
    await tester.pump();
    api.response.complete(_resolved('keep_remote'));
    await tester.pumpAndSettle();
    expect((await outbox.getConflict(conflictId))!.status, SyncConflictStatus.rejected);
    expect(await outbox.getConflictResolutionRefreshToken('family-a'), isNotNull);
    expect(engine.runs, 0);
    expect(tester.takeException(), isNull);
  });
}
