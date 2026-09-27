import 'dart:async';

import 'package:flutter/widgets.dart';

import '../data/nas/nas_api_error.dart';
import 'network_status_source.dart';
import 'sync_engine.dart';

/// Coordinates best-effort sync while the app is in the foreground.
///
/// The scheduler deliberately remains outside [SyncEngine]. It only decides
/// when to ask the engine to run; durable state, protocol cursors and server
/// error handling remain owned by the engine/repositories.
class SyncScheduler with WidgetsBindingObserver {
  SyncScheduler({
    required SyncEngine? Function() engineReader,
    NetworkStatusSource? networkStatusSource,
    this.recoveryDebounce = const Duration(milliseconds: 750),
    this.initialRetryDelay = const Duration(seconds: 15),
    this.maxRetryDelay = const Duration(minutes: 5),
  })  : _engineReader = engineReader,
        _networkStatusSource =
            networkStatusSource ?? ConnectivityPlusNetworkStatusSource(),
        _ownsNetworkStatusSource = networkStatusSource == null;

  final SyncEngine? Function() _engineReader;
  final NetworkStatusSource _networkStatusSource;
  final bool _ownsNetworkStatusSource;
  final Duration recoveryDebounce;
  final Duration initialRetryDelay;
  final Duration maxRetryDelay;

  StreamSubscription<NetworkAvailability>? _networkSubscription;
  Timer? _recoveryDebounceTimer;
  Timer? _retryTimer;
  Future<void>? _runInFlight;
  bool _runRequestedWhileBusy = false;
  bool _started = false;
  bool _disposed = false;
  bool _isForeground = true;
  NetworkAvailability _networkAvailability = NetworkAvailability.unknown;
  int _retryAttempt = 0;

  bool get isForeground => _isForeground;
  NetworkAvailability get networkAvailability => _networkAvailability;

  /// Starts lifecycle and connectivity observation.
  void start() {
    if (_started || _disposed) return;
    _started = true;
    _isForeground = _isLifecycleForeground(WidgetsBinding.instance.lifecycleState);
    WidgetsBinding.instance.addObserver(this);
    _networkSubscription = _networkStatusSource.changes.listen(
      _handleNetworkAvailability,
      onError: (_, __) {
        // A platform connectivity stream failure must not stop lifecycle
        // observation. The next foreground event or manual request can retry.
      },
    );
    unawaited(_initializeNetworkStatus());
    requestRun();
  }

  /// Requests one foreground synchronization attempt.
  ///
  /// Requests while an attempt is running are coalesced into one follow-up
  /// attempt. Requests while offline/backgrounded are ignored rather than
  /// creating timers that could outlive the active app session.
  void requestRun() {
    if (!_canScheduleRun) return;
    if (_runInFlight != null) {
      _runRequestedWhileBusy = true;
      return;
    }

    _runInFlight = _runSafely();
  }

  /// Compatibility hook for callers that already have a connectivity adapter.
  void onNetworkAvailable() {
    _handleNetworkAvailability(NetworkAvailability.online);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _isForeground = state == AppLifecycleState.resumed;

    if (!_isForeground) {
      _recoveryDebounceTimer?.cancel();
      _recoveryDebounceTimer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _runRequestedWhileBusy = false;
      return;
    }

    // A resumed callback is a foreground edge. It is safe to coalesce this
    // with an in-flight run and let the retry/backoff logic decide the next one.
    requestRun();
  }

  Future<void> _initializeNetworkStatus() async {
    try {
      _handleNetworkAvailability(await _networkStatusSource.current);
    } catch (_) {
      // Keep the initial state unknown. A first run is still allowed, and a
      // later stream/lifecycle event can establish the actual state.
    }
  }

  void _handleNetworkAvailability(NetworkAvailability next) {
    if (_disposed || !_started || next == _networkAvailability) return;

    final previous = _networkAvailability;
    _networkAvailability = next;

    if (next == NetworkAvailability.offline) {
      _recoveryDebounceTimer?.cancel();
      _recoveryDebounceTimer = null;
      _retryTimer?.cancel();
      _retryTimer = null;
      _runRequestedWhileBusy = false;
      return;
    }

    if (next != NetworkAvailability.online || !_isForeground) return;

    // A transition to online is debounced. Repeated identical connectivity
    // events were removed above and therefore cannot reset this timer.
    if (previous != NetworkAvailability.online) {
      _recoveryDebounceTimer?.cancel();
      _recoveryDebounceTimer = Timer(recoveryDebounce, () {
        _recoveryDebounceTimer = null;
        requestRun();
      });
    }
  }

  bool get _canScheduleRun =>
      _started &&
      !_disposed &&
      _isForeground &&
      _networkAvailability != NetworkAvailability.offline;

  Future<void> _runSafely() async {
    try {
      final engine = _engineReader();
      if (engine == null) return;

      final report = await engine.runOnce();
      _retryAttempt = 0;
      _retryTimer?.cancel();
      _retryTimer = null;

      if (report.skipped && report.reason == 'retry backoff is active') {
        _scheduleRetry();
      }
    } catch (error) {
      if (_isRetryable(error)) _scheduleRetry();
    } finally {
      _runInFlight = null;
      if (_runRequestedWhileBusy && _canScheduleRun) {
        _runRequestedWhileBusy = false;
        Future<void>.microtask(requestRun);
      } else {
        _runRequestedWhileBusy = false;
      }
    }
  }

  bool _isRetryable(Object error) {
    return error is NasApiError && error.isRetryable;
  }

  void _scheduleRetry() {
    if (!_canScheduleRun || _retryTimer != null) return;

    final delay = _retryDelayForAttempt(_retryAttempt);
    _retryAttempt++;
    _retryTimer = Timer(delay, () {
      _retryTimer = null;
      requestRun();
    });
  }

  Duration _retryDelayForAttempt(int attempt) {
    final seconds = initialRetryDelay.inSeconds * (1 << attempt.clamp(0, 10));
    final candidate = Duration(seconds: seconds);
    return candidate <= maxRetryDelay ? candidate : maxRetryDelay;
  }

  bool _isLifecycleForeground(AppLifecycleState? state) {
    // During the first widget initialization Flutter may not have published a
    // lifecycle state yet. Treat that short startup window as active; explicit
    // inactive/hidden/paused/detached states always disable scheduling.
    return state == null || state == AppLifecycleState.resumed;
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _runRequestedWhileBusy = false;
    _recoveryDebounceTimer?.cancel();
    _recoveryDebounceTimer = null;
    _retryTimer?.cancel();
    _retryTimer = null;
    _networkSubscription?.cancel();
    _networkSubscription = null;
    if (_started) {
      WidgetsBinding.instance.removeObserver(this);
    }
    if (_ownsNetworkStatusSource) _networkStatusSource.dispose();
  }
}
