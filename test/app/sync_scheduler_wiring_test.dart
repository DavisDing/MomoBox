import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/application/nas_auth_service.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/network_status_source.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/sync_outbox_repository.dart';
import 'package:momo_box/domain/models/nas_family_device_models.dart';
import 'package:momo_box/domain/models/sync_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/services/nas_credentials_service.dart';

import '../support/memory_settings_repository.dart';

const _success = SyncRunReport(pushed: 0, pulled: 0, skipped: false);
final _selectedEngine = StateProvider<SyncEngine?>((ref) => null);

class _Engine implements SyncEngine {
  int calls = 0;
  Future<SyncRunReport> Function()? run;

  @override
  Future<SyncRunReport> runOnce({int maxPush = 100, int pullLimit = 100}) async {
    calls++;
    return run == null ? _success : await run!();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Network implements NetworkStatusSource {
  final events = StreamController<NetworkAvailability>.broadcast(sync: true);
  int currentReads = 0;

  @override
  Stream<NetworkAvailability> get changes => events.stream;

  @override
  Future<NetworkAvailability> get current async {
    currentReads++;
    return NetworkAvailability.unknown;
  }

  @override
  void dispose() => unawaited(events.close());
}

class _Account extends NasAccountController {
  _Account(SettingsService settings, NasConnectionService connection)
      : super(settings: settings, connection: connection, credentials: NasCredentialsService()) {
    selectScope('family-a');
  }

  void selectScope(String? scope) {
    if (scope == null) {
      state = const NasAccountState.initial();
      return;
    }
    state = NasAccountState(
      status: NasAccountStatus.authenticated,
      auth: const NasAuthSnapshot(status: NasAuthStatus.authenticated),
      family: NasFamilyState(
        status: NasFamilyStatus.available,
        current: NasFamilyResponseDto(
          family: NasFamilyDto(id: scope, name: '家庭', createdAt: DateTime.utc(2026)),
          membership: NasFamilyMembershipDto(familyId: scope, role: 'owner'),
        ),
      ),
      devices: const NasDeviceState(currentDeviceId: 'device'),
    );
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late AppDatabase database;
  late MemorySettingsRepository settings;
  late NasConnectionService connection;
  late _Account account;
  late _Network network;
  late _Engine engine;
  late ProviderContainer container;
  late GoRouter router;

  setUp(() {
    database = AppDatabase.forTesting(NativeDatabase.memory());
    settings = MemorySettingsRepository();
    connection = NasConnectionService(SettingsService(settings));
    account = _Account(SettingsService(settings), connection);
    network = _Network();
    engine = _Engine();
    router = GoRouter(routes: [
      GoRoute(path: '/', builder: (_, __) => const SizedBox.shrink()),
    ]);
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(database),
      nasAccountProvider.overrideWith((ref) => account),
      syncNetworkStatusSourceProvider.overrideWithValue(network),
      syncForegroundPullIntervalProvider.overrideWithValue(const Duration(minutes: 1)),
      _selectedEngine.overrideWith((ref) => engine),
      syncEngineProvider.overrideWith((ref) {
        if (!ref.watch(nasAccountProvider).isAuthenticated) return null;
        return ref.watch(_selectedEngine);
      }),
      // No platform permissions or actual inventory UI in this wiring test.
      appRouterProvider.overrideWithValue(router),
      inventoryProvider.overrideWith((ref) => const Stream.empty()),
      reminderAcknowledgementsProvider.overrideWith((ref) => const Stream.empty()),
      themeNameProvider.overrideWith((ref) => Stream.value('default')),
      fontScaleProvider.overrideWith((ref) => Stream.value(1.0)),
    ]);
  });

  tearDown(() async {
    container.dispose();
    router.dispose();
    network.dispose();
    connection.close();
    await settings.close();
    await database.close();
  });

  Future<void> mount(WidgetTester tester) => tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: const MomoBoxApp(enableMediaReconciliation: false),
    ),
  );

  Future<void> unmount(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    // Stopping the App cancels Drift subscriptions and schedules query cleanup.
    await tester.pump(Duration.zero);
  }

  Future<void> flushDatabaseWatch(WidgetTester tester, Future<void> Function() write) async {
    // Keep writes and Drift watch continuations in the same fake zone. A
    // real-zone transaction can otherwise wait for a fake-zone watch query
    // that holds the executor while runAsync prevents the fake clock advancing.
    var completed = false;
    Object? failure;
    StackTrace? failureStack;
    final pending = write().then<void>((_) {
      completed = true;
    }, onError: (Object error, StackTrace stack) {
      failure = error;
      failureStack = stack;
      completed = true;
    });
    for (var attempt = 0; attempt < 100; attempt++) {
      await tester.runAsync(() async {
        for (var i = 0; i < 8; i++) {
          await Future<void>.delayed(Duration.zero);
        }
      });
      await tester.pump(Duration.zero);
      if (completed) break;
    }
    expect(completed, isTrue, reason: 'Database write did not complete after bounded IO/clock turns');
    await pending;
    if (failure != null) Error.throwWithStackTrace(failure!, failureStack!);
  }

  Future<void> enqueue(String id, String scope) => SyncOutboxRepository(database)
      .enqueue(SyncOutboxDraft(
        changeId: id, scopeId: scope, operation: SyncOperation.entityUpsert,
        entity: 'products', entityId: id, idempotencyKey: '$id-stable-idempotency-key',
        requestJson: '{"entity":"products","entity_id":"$id","payload":{"name":"$id"}}',
      )).then((_) {});

  testWidgets('provider reads are passive and manual callers join the mounted App flight', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final first = Completer<SyncRunReport>();
    engine.run = () => first.future;
    final scheduler = container.read(syncSchedulerProvider);
    await tester.pump();
    expect(engine.calls, 0);
    expect(network.currentReads, 0);
    await mount(tester);
    await flushDatabaseWatch(tester, () async {});
    expect(engine.calls, 1);
    expect(container.read(syncSchedulerProvider), same(scheduler));
    final manual = scheduler.runNow();
    final concurrent = container.read(syncSchedulerProvider).runNow();
    expect(identical(manual, concurrent), isTrue);
    first.complete(_success);
    await tester.pump();
    expect(await manual, same(_success));
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.calls, 1);
    await unmount(tester);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
    engine.run = null;
    await mount(tester);
    expect(container.read(syncSchedulerProvider), same(scheduler));
    expect(engine.calls, 2);
    await unmount(tester);
  });

  testWidgets('scoped committed intents debounce; status and remote apply do not feed back', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await mount(tester);
    await flushDatabaseWatch(tester, () async {});
    expect(engine.calls, 1);
    await flushDatabaseWatch(tester, () async {
      await enqueue('one', 'family-a');
      await enqueue('two', 'family-a');
    });
    await tester.pump(const Duration(milliseconds: 299));
    expect(engine.calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.calls, 2);
    final repository = SyncOutboxRepository(database);
    await flushDatabaseWatch(tester, () async {
      await repository.claimNext(scopeId: 'family-a');
      await repository.releaseInFlight(changeId: 'one');
      await repository.applyRemoteAuxiliaryEntity(
        scopeId: 'family-a', entity: 'categories', entityId: 'remote',
        payload: {'name': 'remote'}, version: 1, updatedAt: DateTime.utc(2026),
      );
      await enqueue('foreign', 'family-b');
    });
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, 2);
    final scheduler = container.read(syncSchedulerProvider);
    final next = _Engine();
    account.selectScope('family-b');
    container.read(_selectedEngine.notifier).state = next;
    expect(container.read(syncSchedulerProvider), same(scheduler));
    await tester.pump();
    await flushDatabaseWatch(tester, () async {});
    await tester.pump(const Duration(milliseconds: 300));
    expect(next.calls, greaterThanOrEqualTo(1));
    final beforeOldCommit = next.calls;
    await flushDatabaseWatch(tester, () => enqueue('old-scope', 'family-a'));
    await tester.pump(const Duration(milliseconds: 300));
    expect(next.calls, beforeOldCommit);
    account.selectScope(null);
    await tester.pump();
    await flushDatabaseWatch(tester, () => enqueue('signed-out', 'family-b'));
    await tester.pump(const Duration(seconds: 1));
    expect(next.calls, beforeOldCommit);
    expect(await container.read(syncSchedulerProvider).runNow(), isNull);
    await unmount(tester);
  });

  testWidgets('provider invalidation reconnects mounted App to the manual policy owner', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await mount(tester);
    final original = container.read(syncSchedulerProvider);
    expect(engine.calls, 1);
    container.invalidate(syncSchedulerProvider);
    await tester.pump();
    final replacement = container.read(syncSchedulerProvider);
    expect(replacement, isNot(same(original)));
    expect(await original.runNow(), isNull);
    expect(engine.calls, 2);
    await tester.pump(const Duration(minutes: 1));
    expect(engine.calls, 3); // One owner, not an old and new periodic timer.
    await unmount(tester);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 3);
  });
}
