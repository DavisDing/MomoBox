import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/nas/nas_api_error.dart';
import 'network_status_source.dart';
import 'sync_engine.dart';

/// Foreground policy only. Durable queues, backoff and database/scope execution
/// coordination remain owned by the engine; this class never requeues failures.
class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler({
    required SyncEngine? Function() engineReader,
    NetworkStatusSource? networkStatusSource,
    this.recoveryDebounce = const Duration(milliseconds: 750),
    this.outboxDebounce = const Duration(milliseconds: 300),
    this.continuationDelay = const Duration(milliseconds: 250),
    this.maxContinuationRuns = 8,
    this.foregroundPullInterval = const Duration(minutes: 1),
    this.initialRetryDelay = const Duration(seconds: 15),
    this.maxRetryDelay = const Duration(minutes: 5),
  })  : assert(recoveryDebounce > Duration.zero),
        assert(outboxDebounce > Duration.zero),
        assert(continuationDelay > Duration.zero),
        assert(maxContinuationRuns >= 0),
        assert(foregroundPullInterval == null ||
            foregroundPullInterval >= Duration.zero),
        assert(initialRetryDelay > Duration.zero),
        assert(maxRetryDelay >= initialRetryDelay),
        _engineReader = engineReader,
        _networkStatusSource =
            networkStatusSource ?? ConnectivityPlusNetworkStatusSource(),
        _ownsNetworkStatusSource = networkStatusSource == null;

  final SyncEngine? Function() _engineReader;
  final NetworkStatusSource _networkStatusSource;
  final bool _ownsNetworkStatusSource;
  final Duration recoveryDebounce;
  final Duration outboxDebounce;
  final Duration continuationDelay;
  final int maxContinuationRuns;

  /// Null or Duration.zero disables periodic pulls (isolated policy tests).
  final Duration? foregroundPullInterval;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;

  StreamSubscription<NetworkAvailability>? _networkSubscription;
  StreamSubscription<Object?>? _pendingSubscription;
  Stream<Object?>? _pendingChanges;
  Timer? _recoveryDebounceTimer;
  Timer? _outboxTimer;
  Timer? _continuationTimer;
  Timer? _periodicTimer;
  Timer? _retryTimer;
  Future<SyncRunReport?>? _runInFlight;
  SyncEngine? _runningEngine;
  int? _runningEngineRevision;
  bool _manualRequestedForFlight = false;
  bool _runRequestedWhileBusy = false;
  bool _started = false;
  bool _disposed = false;
  bool _isForeground = true;
  NetworkAvailability _networkAvailability = NetworkAvailability.unknown;
  int _retryAttempt = 0;
  int _continuationRuns = 0;
  int _networkEventRevision = 0;
  int _contextRevision = 0;
  // Engine/session invalidation is stronger than a background/offline hint.
  int _engineRevision = 0;

  bool get isForeground => _isForeground;
  NetworkAvailability get networkAvailability => _networkAvailability;

  /// Rebind on authenticated scope/repository changes. This does not mutate
  /// outbox data; pending membership/status changes must be filtered upstream.
  void bindPendingChanges(Stream<Object?>? changes) {
    if (_disposed) return;
    _pendingSubscription?.cancel();
    _pendingSubscription = null;
    _pendingChanges = changes;
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _observePendingChanges();
  }

  void _observePendingChanges() {
    if (!_started || _disposed || _pendingChanges == null) return;
    final changes = _pendingChanges;
    _pendingSubscription = changes!.listen((_) {
      if (identical(changes, _pendingChanges)) notifyOutboxCommitted();
    }, onError: (Object _, StackTrace __) {
      // A failed local watch must not break local operations/manual sync.
      // Lifecycle/periodic attempts remain available; never restart in a loop.
    });
  }

  /// Debounce only local request-content commits, not local view refreshes.
  void notifyOutboxCommitted() {
    if (!_canScheduleRun) return;
    _outboxTimer?.cancel();
    _outboxTimer = Timer(outboxDebounce, () {
      _outboxTimer = null;
      requestRun();
    });
  }

  /// Invalidate stale results/timers without rebuilding this shared scheduler.
  void onEngineChanged() {
    _engineRevision++;
    _contextRevision++;
    _retryAttempt = 0;
    _continuationRuns = 0;
    _cancelTimers();
    _runRequestedWhileBusy = false;
    requestRun();
    _ensurePeriodicPull();
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    _contextRevision++;
    _isForeground = _isLifecycleForeground(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _networkSubscription = _networkStatusSource.changes.listen(
      _handleNetworkAvailability,
      onError: (Object _, StackTrace __) {},
    );
    _observePendingChanges();
    unawaited(_initializeNetworkStatus());
    requestRun();
    _ensurePeriodicPull();
  }

  /// App unmount stops observation; provider teardown owns final disposal.
  /// Keeping stop separate permits remounting under the same ProviderScope.
  void stop() {
    if (!_started) return;
    _started = false;
    _contextRevision++;
    _networkEventRevision++;
    _runRequestedWhileBusy = false;
    _cancelTimers();
    _networkSubscription?.cancel();
    _networkSubscription = null;
    _pendingSubscription?.cancel();
    _pendingSubscription = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  /// Explicit UI request: may bypass foreground/connectivity *hints*, but does
  /// not bypass engine backoff. Errors are deliberately returned to the UI.
  /// Concurrent manual and automatic requests for this engine share a future.
  Future<SyncRunReport?> runNow() {
    if (_disposed) return Future.value(null);
    final engine = _engineReader();
    if (engine == null) return Future.value(null);
    final flight = _runInFlight;
    if (flight != null) {
      if (identical(engine, _runningEngine) &&
          _runningEngineRevision == _engineRevision) {
        _manualRequestedForFlight = true;
        return flight;
      }
      // A provider replacement must target the new engine, not return an old
      // session's report. Wait locally; the engine also coordinates by scope.
      return _runAfterCurrent(flight);
    }
    _continuationRuns = 0;
    return _beginRun(engine);
  }

  Future<SyncRunReport?> _runAfterCurrent(Future<SyncRunReport?> flight) async {
    try {
      await flight;
    } catch (_) {
      // An old session's error must not stand in for the current session.
    }
    return runNow();
  }

  /// An external foreground edge/commit starts a new bounded drain budget.
  void requestRun() => _requestRun(resetContinuation: true);

  void _requestRun({required bool resetContinuation}) {
    if (!_canScheduleRun) return;
    if (resetContinuation) _continuationRuns = 0;
    if (_runInFlight != null) {
      _runRequestedWhileBusy = true;
      return;
    }
    final engine = _engineReader();
    if (engine == null) {
      _ensurePeriodicPull();
      return;
    }
    // Automatic failures are best effort; runNow callers still see the original
    // future/error. Queued work checks lifecycle again before touching engine.
    unawaited(_beginRun(engine, automatic: true).catchError((Object _) => null));
  }

  Future<SyncRunReport?> _beginRun(SyncEngine engine, {bool automatic = false}) {
    _cancelTimers();
    _runRequestedWhileBusy = false;
    final revision = _contextRevision;
    final engineRevision = _engineRevision;
    _runningEngine = engine;
    _runningEngineRevision = engineRevision;
    _manualRequestedForFlight = !automatic;
    final flight = Future<SyncRunReport?>.microtask(
      () => _execute(engine, revision, engineRevision, automatic: automatic),
    );
    _runInFlight = flight;
    return flight;
  }

  Future<SyncRunReport?> _execute(
    SyncEngine engine,
    int revision,
    int engineRevision, {
    required bool automatic,
  }) async {
    try {
      if (_disposed ||
          (automatic && !_manualRequestedForFlight && !_canScheduleRun)) {
        return null;
      }
      // Neither explicit nor automatic queued work may enter an old session.
      // A manual caller can promote an automatic request past lifecycle/network
      // hints, but cannot promote it past an engine/account replacement.
      if (engineRevision != _engineRevision ||
          !identical(engine, _engineReader())) {
        return null;
      }
      if (automatic && !_manualRequestedForFlight &&
          revision != _contextRevision) {
        return null;
      }
      final report = await engine.runOnce();
      // A manual page must not display success from a replaced/logged-out
      // session. Lifecycle/network hint changes alone do not invalidate a
      // completed report for the same engine; they only suppress scheduling.
      if (_disposed || engineRevision != _engineRevision ||
          !identical(engine, _engineReader())) {
        return null;
      }
      if (revision != _contextRevision) return report;
      if (report.skipped && report.reason == 'retry backoff is active') {
        _scheduleRetry();
      } else {
        _retryAttempt = 0;
        // deferred alone includes conflicts/blocked work and is NEVER a drain
        // signal. The engine owns the eligibility of hasMorePending.
        if (!report.skipped && (report.hasMorePending ||
            (report.deferred == 0 && report.hasMoreRemote))) {
          _scheduleContinuation();
        }
      }
      return report;
    } catch (error) {
      // Likewise, an old session's failure is not the new session's error.
      if (_disposed || engineRevision != _engineRevision ||
          !identical(engine, _engineReader())) {
        return null;
      }
      if (revision == _contextRevision && error is NasApiError && error.isRetryable) {
        _scheduleRetry();
      }
      rethrow;
    } finally {
      _runInFlight = null;
      _runningEngine = null;
      _runningEngineRevision = null;
      _manualRequestedForFlight = false;
      if (_runRequestedWhileBusy && _canScheduleRun) {
        _runRequestedWhileBusy = false;
        // At most one follow-up for genuine external commits/edges while busy;
        // not an immediate self-triggered microtask feedback loop.
        _outboxTimer?.cancel();
        _outboxTimer = Timer(outboxDebounce, () {
          _outboxTimer = null;
          requestRun();
        });
      } else {
        _runRequestedWhileBusy = false;
      }
      _ensurePeriodicPull();
    }
  }

  void _scheduleContinuation() {
    if (!_canScheduleRun || _continuationRuns >= maxContinuationRuns) return;
    _continuationRuns++;
    _continuationTimer = Timer(continuationDelay, () {
      _continuationTimer = null;
      _requestRun(resetContinuation: false);
    });
  }

  void _ensurePeriodicPull() {
    final interval = foregroundPullInterval;
    if (!_canScheduleRun || interval == null || interval == Duration.zero ||
        _periodicTimer != null) {
      return;
    }
    _periodicTimer = Timer(interval, () {
      _periodicTimer = null;
      // Do not let a periodic read defeat an active retry/commit/drain delay,
      // or queue additional runs behind a slow request.
      if (_runInFlight == null && _retryTimer == null &&
          _continuationTimer == null && _outboxTimer == null &&
          _recoveryDebounceTimer == null) {
        requestRun();
      }
      _ensurePeriodicPull();
    });
  }

  void onNetworkAvailable() => _handleNetworkAvailability(NetworkAvailability.online);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || !_started) return;
    final wasForeground = _isForeground;
    _isForeground = state == AppLifecycleState.resumed;
    if (!_isForeground) {
      _contextRevision++;
      _cancelTimers();
      _runRequestedWhileBusy = false;
    } else if (!wasForeground) {
      requestRun();
      _ensurePeriodicPull();
    }
  }

  Future<void> _initializeNetworkStatus() async {
    final revision = _networkEventRevision;
    try {
      final initial = await _networkStatusSource.current;
      if (revision != _networkEventRevision) return;
      _handleNetworkAvailability(initial);
    } catch (_) {
      // Unknown keeps the original best-effort policy, not a false offline.
    }
  }

  void _handleNetworkAvailability(NetworkAvailability next) {
    if (_disposed || !_started) return;
    _networkEventRevision++;
    if (next == _networkAvailability) return;
    _networkAvailability = next;
    if (next == NetworkAvailability.offline) {
      _contextRevision++;
      _cancelTimers();
      _runRequestedWhileBusy = false;
      return;
    }
    if (!_isForeground) return;
    _ensurePeriodicPull();
    _recoveryDebounceTimer?.cancel();
    _recoveryDebounceTimer = Timer(recoveryDebounce, () {
      _recoveryDebounceTimer = null;
      requestRun();
    });
  }

  bool get _canScheduleRun => _started && !_disposed && _isForeground &&
      _networkAvailability != NetworkAvailability.offline;

  void _scheduleRetry() {
    if (!_canScheduleRun || _retryTimer != null) return;
    final delay = _retryDelayForAttempt(_retryAttempt++);
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      _requestRun(resetContinuation: false);
    });
  }

  Duration _retryDelayForAttempt(int attempt) {
    final microseconds = initialRetryDelay.inMicroseconds * (1 << attempt.clamp(0, 10));
    final candidate = Duration(microseconds: microseconds);
    return candidate <= maxRetryDelay ? candidate : maxRetryDelay;
  }

  void _cancelTimers() {
    _recoveryDebounceTimer?.cancel();
    _recoveryDebounceTimer = null;
    _outboxTimer?.cancel();
    _outboxTimer = null;
    _continuationTimer?.cancel();
    _continuationTimer = null;
    _periodicTimer?.cancel();
    _periodicTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
  }

  bool _isLifecycleForeground(AppLifecycleState? state) =>
      state == null || state == AppLifecycleState.resumed;

  void dispose() {
    if (_disposed) return;
    stop();
    _disposed = true;
    _cancelTimers();
    _pendingChanges = null;
    if (_ownsNetworkStatusSource) _networkStatusSource.dispose();
  }
}
