import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/network_status_source.dart';
import 'package:momo_box/application/sync_engine.dart';
import 'package:momo_box/application/sync_scheduler.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';

const _success = SyncRunReport(pushed: 0, pulled: 0, skipped: false);

class _Engine implements SyncEngine {
  int calls = 0;
  int active = 0;
  int maxActive = 0;
  Future<SyncRunReport> Function()? run;

  @override
  Future<SyncRunReport> runOnce({int maxPush = 100, int pullLimit = 100}) async {
    calls++;
    active++;
    if (active > maxActive) maxActive = active;
    try {
      return await (run?.call() ?? Future.value(_success));
    } finally {
      active--;
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Network implements NetworkStatusSource {
  final _events = StreamController<NetworkAvailability>.broadcast(sync: true);
  NetworkAvailability availability = NetworkAvailability.unknown;
  Completer<NetworkAvailability>? initialStatus;

  @override
  Stream<NetworkAvailability> get changes => _events.stream;

  @override
  Future<NetworkAvailability> get current =>
      initialStatus?.future ?? Future.value(availability);

  void emit(NetworkAvailability value) {
    availability = value;
    _events.add(value);
  }

  @override
  void dispose() => unawaited(_events.close());
}

void main() {
  testWidgets('startup without an engine does not block a later configured engine', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    SyncEngine? configured;
    final scheduler = SyncScheduler(engineReader: () => configured, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);

    scheduler.start();
    await tester.pump();
    expect(engine.calls, 0);
    configured = engine;
    scheduler.requestRun();
    await tester.pump();
    expect(engine.calls, 1);
    scheduler.requestRun();
    await tester.pump();
    expect(engine.calls, 2);
  });

  testWidgets('concurrent requests are coalesced into one follow-up run', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final first = Completer<SyncRunReport>();
    engine.run = () => engine.calls == 1 ? first.future : Future.value(_success);
    final scheduler = SyncScheduler(engineReader: () => engine, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);

    scheduler.start();
    await tester.pump();
    for (var i = 0; i < 10; i++) {
      scheduler.requestRun();
    }
    expect(engine.calls, 1);
    first.complete(_success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.calls, 2);
    expect(engine.maxActive, 1);
  });

  testWidgets('offline blocks runs; repeated recovery events have one debounce', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      foregroundPullInterval: Duration.zero, networkStatusSource: network,
      recoveryDebounce: const Duration(milliseconds: 100),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    final initialCalls = engine.calls;
    network.emit(NetworkAvailability.offline);
    scheduler.requestRun();
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, initialCalls);
    network.emit(NetworkAvailability.online);
    await tester.pump(const Duration(milliseconds: 60));
    network.emit(NetworkAvailability.online);
    await tester.pump(const Duration(milliseconds: 39));
    expect(engine.calls, initialCalls);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.calls, initialCalls + 1);
  });

  testWidgets('a stale initial online result cannot override a newer offline event', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final initialStatus = Completer<NetworkAvailability>();
    final network = _Network()..initialStatus = initialStatus;
    final engine = _Engine();
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      foregroundPullInterval: Duration.zero, networkStatusSource: network,
      recoveryDebounce: const Duration(milliseconds: 100),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    final initialCalls = engine.calls;

    network.emit(NetworkAvailability.offline);
    initialStatus.complete(NetworkAvailability.online);
    await tester.pump();
    expect(scheduler.networkAvailability, NetworkAvailability.offline);
    scheduler.requestRun();
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, initialCalls);
  });

  testWidgets('a stale initial offline result cannot cancel a newer online recovery', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final initialStatus = Completer<NetworkAvailability>();
    final network = _Network()..initialStatus = initialStatus;
    final engine = _Engine();
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      foregroundPullInterval: Duration.zero, networkStatusSource: network,
      recoveryDebounce: const Duration(milliseconds: 100),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    final initialCalls = engine.calls;

    network.emit(NetworkAvailability.online);
    initialStatus.complete(NetworkAvailability.offline);
    await tester.pump();
    expect(scheduler.networkAvailability, NetworkAvailability.online);
    await tester.pump(const Duration(milliseconds: 100));
    expect(engine.calls, initialCalls + 1);
  });

  testWidgets('offline before the startup microtask prevents queued execution', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final scheduler = SyncScheduler(engineReader: () => engine, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    network.emit(NetworkAvailability.offline);
    await tester.pump();
    expect(engine.calls, 0);
    expect(scheduler.networkAvailability, NetworkAvailability.offline);
  });

  testWidgets('background before the startup microtask prevents queued execution', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final scheduler = SyncScheduler(engineReader: () => engine, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump();
    expect(engine.calls, 0);
    scheduler.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.calls, 1);
  });

  testWidgets('retryable errors use sub-second backoff and success stops retries', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    engine.run = () async {
      if (engine.calls <= 2) throw NasApiError.network(StateError('offline'));
      return _success;
    };
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      foregroundPullInterval: Duration.zero, networkStatusSource: network,
      initialRetryDelay: const Duration(milliseconds: 100),
      maxRetryDelay: const Duration(milliseconds: 200),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    expect(engine.calls, 1);
    await tester.pump(const Duration(milliseconds: 99));
    expect(engine.calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.calls, 2);
    await tester.pump(const Duration(milliseconds: 199));
    expect(engine.calls, 2);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.calls, 3);
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, 3);
  });

  testWidgets('authorization errors do not create automatic retries', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    engine.run = () async => throw NasApiError(
      kind: NasApiErrorKind.unauthorized,
      message: 'login required',
    );
    final scheduler = SyncScheduler(engineReader: () => engine, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
  });

  testWidgets('background cancels retry; resume starts one foreground run', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    engine.run = () async => throw NasApiError.timeout(TimeoutException('NAS'));
    final scheduler = SyncScheduler(engineReader: () => engine, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
    engine.run = () async => _success;
    scheduler.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.calls, 2);
  });

  testWidgets('disposal cancels recovery timers and queued startup execution', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final scheduler = SyncScheduler(engineReader: () => engine, foregroundPullInterval: Duration.zero, networkStatusSource: network);
    addTearDown(network.dispose);
    scheduler.start();
    scheduler.dispose();
    await tester.pump();
    expect(engine.calls, 0);
    network.emit(NetworkAvailability.online);
    scheduler.requestRun();
    await tester.pump(const Duration(minutes: 1));
    expect(engine.calls, 0);
  });

  testWidgets('engine backoff report schedules another bounded foreground attempt', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    engine.run = () async => engine.calls == 1
        ? const SyncRunReport(pushed: 0, pulled: 0, skipped: true, reason: 'retry backoff is active')
        : _success;
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      foregroundPullInterval: Duration.zero, networkStatusSource: network,
      initialRetryDelay: const Duration(seconds: 1),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, 2);
    await tester.pump(const Duration(minutes: 1));
    expect(engine.calls, 2);
  });

  testWidgets('outbox content commits debounce without resetting on reads', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final commits = StreamController<Object?>.broadcast(sync: true);
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
      outboxDebounce: const Duration(milliseconds: 100),
    );
    addTearDown(network.dispose);
    addTearDown(commits.close);
    scheduler.bindPendingChanges(commits.stream);
    scheduler.start();
    await tester.pump();
    commits.add('first committed request');
    await tester.pump(const Duration(milliseconds: 60));
    commits.add('second committed request');
    await tester.pump(const Duration(milliseconds: 99));
    expect(engine.calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.calls, 2);
    scheduler.dispose();
  });

  testWidgets('hasMorePending drains maxPush batches with a finite delay/budget', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine()..run = () async => const SyncRunReport(
      pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
    );
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
      continuationDelay: const Duration(milliseconds: 100),
      maxContinuationRuns: 2,
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    expect(engine.calls, 1);
    await tester.pump(const Duration(milliseconds: 99));
    expect(engine.calls, 1);
    await tester.pump(const Duration(milliseconds: 1));
    expect(engine.calls, 2);
    await tester.pump(const Duration(milliseconds: 100));
    expect(engine.calls, 3);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 3);
    scheduler.requestRun(); // A genuine external edge gets a fresh budget.
    await tester.pump();
    expect(engine.calls, 4);
    scheduler.dispose();
  });

  for (final report in <SyncRunReport>[
    const SyncRunReport(pushed: 0, pulled: 0, skipped: false, deferred: 10),
    const SyncRunReport(pushed: 0, pulled: 0, skipped: true,
      reason: 'bootstrap is not ready', hasMorePending: true),
    const SyncRunReport(pushed: 0, pulled: 0, skipped: true,
      reason: 'scope contains blocked/rejected/conflict work', deferred: 2),
  ]) {
    testWidgets('no busy drain for deferred/skipped: ${report.reason}', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final network = _Network();
      final engine = _Engine()..run = () async => report;
      final scheduler = SyncScheduler(
        engineReader: () => engine, networkStatusSource: network,
        foregroundPullInterval: Duration.zero,
      );
      addTearDown(network.dispose);
      scheduler.start();
      await tester.pump();
      await tester.pump(const Duration(minutes: 10));
      expect(engine.calls, 1);
      scheduler.dispose();
    });
  }

  testWidgets('last successful batch clears the continuation signal', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    engine.run = () async => engine.calls == 1
        ? const SyncRunReport(pushed: 100, pulled: 0, skipped: false, hasMorePending: true)
        : _success;
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 2);
    scheduler.dispose();
  });

  testWidgets('remote page remainder uses the same finite continuation budget', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine()..run = () async => const SyncRunReport(
      pushed: 0, pulled: 100, skipped: false, hasMoreRemote: true,
    );
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero, maxContinuationRuns: 2,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(milliseconds: 250));
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 3);
  });

  testWidgets('remote hasMore signal cannot bypass a deferred conflict', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine()..run = () async => const SyncRunReport(
      pushed: 0, pulled: 0, skipped: false, deferred: 1, hasMoreRemote: true,
    );
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
  });

  testWidgets('periodic pull works in unknown network and skips an active run', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final engine = _Engine();
    engine.run = () => engine.calls == 1 ? first.future : Future.value(_success);
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: const Duration(seconds: 1),
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 3));
    expect(engine.calls, 1);
    first.complete(_success);
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, 2);
    expect(engine.maxActive, 1);
    scheduler.dispose();
  });

  testWidgets('periodic pull does not defeat a longer engine retry delay', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine()..run = () async => throw NasApiError.network(StateError('NAS'));
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: const Duration(seconds: 1),
      initialRetryDelay: const Duration(seconds: 5),
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(seconds: 4));
    expect(engine.calls, 1);
    await tester.pump(const Duration(seconds: 1));
    expect(engine.calls, 2);
    scheduler.dispose();
  });

  for (final cancellation in ['background', 'offline', 'stop', 'dispose']) {
    testWidgets('$cancellation cancels pending drain/commit/periodic timers', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final network = _Network();
      final engine = _Engine()..run = () async => const SyncRunReport(
        pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
      );
      final scheduler = SyncScheduler(
        engineReader: () => engine, networkStatusSource: network,
      );
      addTearDown(network.dispose);
      scheduler.start();
      await tester.pump();
      scheduler.notifyOutboxCommitted();
      switch (cancellation) {
        case 'background':
          scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
        case 'offline':
          network.emit(NetworkAvailability.offline);
        case 'stop':
          scheduler.stop();
        case 'dispose':
          scheduler.dispose();
      }
      await tester.pump(const Duration(minutes: 10));
      expect(engine.calls, 1);
      scheduler.dispose();
    });
  }

  testWidgets('late completion after background cannot recreate continuation', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => first.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    first.complete(const SyncRunReport(
      pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
    ));
    await tester.pump();
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
    scheduler.dispose();
  });

  testWidgets('manual run bypasses hints, shares active work and preserves errors', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => first.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(network.dispose);
    scheduler.start();
    network.emit(NetworkAvailability.offline);
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    // Even a not-yet-executed automatic request can be explicitly promoted.
    final manual = scheduler.runNow();
    final concurrent = scheduler.runNow();
    expect(identical(manual, concurrent), isTrue);
    final error = NasApiError.network(StateError('manual failure'));
    final assertion = expectLater(manual, throwsA(same(error)));
    await tester.pump();
    expect(engine.calls, 1);
    first.completeError(error);
    await tester.pump();
    await assertion;
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
    expect(engine.maxActive, 1);
    scheduler.dispose();
  });

  testWidgets('manual success uses the same bounded continuation policy', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    engine.run = () async => engine.calls == 2
        ? const SyncRunReport(pushed: 100, pulled: 0, skipped: false, hasMorePending: true)
        : _success;
    final manual = scheduler.runNow();
    await tester.pump();
    expect((await manual)!.hasMorePending, isTrue);
    await tester.pump(const Duration(milliseconds: 250));
    expect(engine.calls, 3);
    scheduler.dispose();
  });

  testWidgets('engine replacement drops old report and manual targets current engine', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final oldEngine = _Engine()..run = () => first.future;
    final newEngine = _Engine();
    SyncEngine current = oldEngine;
    final scheduler = SyncScheduler(
      engineReader: () => current, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    current = newEngine;
    scheduler.onEngineChanged();
    final manual = scheduler.runNow();
    first.complete(const SyncRunReport(
      pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
    ));
    await tester.pump();
    expect(await manual, same(_success));
    expect(newEngine.calls, 1);
    await tester.pump(const Duration(seconds: 1));
    // The pending external edge was satisfied by the explicit current-engine
    // run; old hasMorePending must not schedule a third request.
    expect(newEngine.calls, 1);
    scheduler.dispose();
  });

  testWidgets('manual request before microtask cannot enter a replaced engine', (tester) async {
    final network = _Network();
    final oldEngine = _Engine();
    final newEngine = _Engine();
    SyncEngine? current = oldEngine;
    final scheduler = SyncScheduler(
      engineReader: () => current,
      networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    final stale = scheduler.runNow();
    current = newEngine;
    scheduler.onEngineChanged();
    final currentRequest = scheduler.runNow();
    await tester.pump();
    expect(await stale, isNull);
    expect(await currentRequest, same(_success));
    expect(oldEngine.calls, 0);
    expect(newEngine.calls, 1);
    current = null;
    expect(await scheduler.runNow(), isNull);
  });

  testWidgets('background and resume before microtask discard obsolete queued work', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final engine = _Engine();
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
      outboxDebounce: const Duration(milliseconds: 100),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    scheduler.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await tester.pump();
    expect(engine.calls, 0);
    await tester.pump(const Duration(milliseconds: 100));
    expect(engine.calls, 1);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
  });

  testWidgets('commits while busy cause one follow-up, shared with manual callers', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => first.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    final manual = scheduler.runNow();
    for (var i = 0; i < 5; i++) {
      scheduler.notifyOutboxCommitted();
    }
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.calls, 1);
    engine.run = () async => _success;
    first.complete(_success);
    await tester.pump();
    expect(await manual, same(_success));
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.calls, 2);
    expect(engine.maxActive, 1);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 2);
  });

  testWidgets('periodic ticks do not queue extra work behind a slow pull', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => first.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      networkStatusSource: network,
      foregroundPullInterval: const Duration(minutes: 1),
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    await tester.pump(const Duration(minutes: 5));
    expect(engine.calls, 1);
    engine.run = () async => _success;
    first.complete(_success);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    expect(engine.calls, 1);
    await tester.pump(const Duration(minutes: 1));
    expect(engine.calls, 2);
    expect(engine.maxActive, 1);
    // TearDown runs after Widget binding invariants; stop the periodic policy
    // before this test body returns, then prove no timer restarts it.
    scheduler.dispose();
    await tester.pump(const Duration(minutes: 2));
    expect(engine.calls, 2);
  });

  testWidgets('late completion after dispose never restores retry or drain timers', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final first = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => first.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine,
      networkStatusSource: network,
    );
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    final manual = scheduler.runNow();
    scheduler.dispose();
    first.complete(const SyncRunReport(
      pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
    ));
    await tester.pump();
    expect(await manual, isNull);
    expect(await scheduler.runNow(), isNull);
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
  });

  for (final fails in [false, true]) {
    testWidgets('manual old-session ${fails ? "error" : "report"} becomes null after engine replacement', (tester) async {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      final network = _Network();
      final oldResult = Completer<SyncRunReport>();
      final oldEngine = _Engine()..run = () => oldResult.future;
      final newEngine = _Engine();
      SyncEngine? current = oldEngine;
      final scheduler = SyncScheduler(
        engineReader: () => current,
        networkStatusSource: network,
        foregroundPullInterval: Duration.zero,
      );
      addTearDown(scheduler.dispose);
      addTearDown(network.dispose);
      // Deliberately not started: legacy conflict/manual pages must remain
      // passive unless the App has explicitly mounted/started observation.
      final oldManual = scheduler.runNow();
      await tester.pump();
      expect(oldEngine.calls, 1);
      current = newEngine;
      scheduler.onEngineChanged();
      final newManual = scheduler.runNow();
      if (fails) {
        oldResult.completeError(NasApiError.network(StateError('old server')));
      } else {
        oldResult.complete(const SyncRunReport(
          pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
        ));
      }
      await tester.pump();
      expect(await oldManual, isNull);
      expect(await newManual, same(_success));
      expect(newEngine.calls, 1);
      await tester.pump(const Duration(minutes: 10));
      expect(newEngine.calls, 1);
    });
  }

  testWidgets('logout while manual sync is in flight discards the old report', (tester) async {
    final network = _Network();
    final result = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => result.future;
    SyncEngine? current = engine;
    final scheduler = SyncScheduler(
      engineReader: () => current, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    final manual = scheduler.runNow();
    await tester.pump();
    current = null;
    scheduler.onEngineChanged();
    result.complete(_success);
    await tester.pump();
    expect(await manual, isNull);
    expect(await scheduler.runNow(), isNull);
  });

  testWidgets('same-engine manual report survives background revision without scheduling', (tester) async {
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    final network = _Network();
    final result = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => result.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    scheduler.start();
    await tester.pump();
    final manual = scheduler.runNow();
    scheduler.didChangeAppLifecycleState(AppLifecycleState.paused);
    const report = SyncRunReport(
      pushed: 100, pulled: 0, skipped: false, hasMorePending: true,
    );
    result.complete(report);
    await tester.pump();
    expect(await manual, same(report));
    await tester.pump(const Duration(minutes: 10));
    expect(engine.calls, 1);
  });

  testWidgets('engine revision discards an old report even if identity is reused', (tester) async {
    final network = _Network();
    final oldResult = Completer<SyncRunReport>();
    final engine = _Engine()..run = () => oldResult.future;
    final scheduler = SyncScheduler(
      engineReader: () => engine, networkStatusSource: network,
      foregroundPullInterval: Duration.zero,
    );
    addTearDown(scheduler.dispose);
    addTearDown(network.dispose);
    final oldManual = scheduler.runNow();
    await tester.pump();
    scheduler.onEngineChanged();
    engine.run = () async => _success;
    final newManual = scheduler.runNow();
    oldResult.complete(_success);
    await tester.pump();
    expect(await oldManual, isNull);
    expect(await newManual, same(_success));
    expect(engine.calls, 2);
    expect(engine.maxActive, 1);
  });

}
