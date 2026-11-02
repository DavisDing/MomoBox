import 'dart:async';

import 'package:flutter/widgets.dart';

import '../domain/inventory/calendar_date.dart';

/// Refresh date-derived views without writing inventory or requiring NAS.
/// App mount owns start/stop; provider disposal owns final teardown.
class CalendarRefreshScheduler with WidgetsBindingObserver {
  CalendarRefreshScheduler({
    required VoidCallback onRefresh,
    DateTime Function()? clock,
  })  : _onRefresh = onRefresh,
        _clock = clock ?? DateTime.now;

  final VoidCallback _onRefresh;
  final DateTime Function() _clock;
  String? _timeZone;
  String? _calendarKey;
  Timer? _timer;
  bool _started = false;
  bool _disposed = false;
  bool _foreground = false;

  /// Inventory has already refreshed when its family timezone arrives.
  /// Rebase the timer without causing an inventory -> refresh feedback loop.
  void updateTimeZone(String? timeZone) {
    if (_disposed || _timeZone == timeZone) return;
    if (timeZone != null) CalendarDate.validateTimeZone(timeZone);
    _timeZone = timeZone;
    _calendarKey = _key(_clock());
    _schedule();
  }

  void start() {
    if (_started || _disposed) return;
    _started = true;
    final state = WidgetsBinding.instance.lifecycleState;
    _foreground = state == null || state == AppLifecycleState.resumed;
    WidgetsBinding.instance.addObserver(this);
    final key = _key(_clock());
    final changedWhileStopped = _calendarKey != null && _calendarKey != key;
    _calendarKey = key;
    if (_foreground && changedWhileStopped) _onRefresh();
    _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_started || _disposed) return;
    final wasForeground = _foreground;
    _foreground = state == AppLifecycleState.resumed;
    if (_foreground && !wasForeground) {
      final key = _key(_clock());
      if (key != _calendarKey) {
        _calendarKey = key;
        _onRefresh();
      }
    }
    _schedule();
  }

  String _key(DateTime now) {
    final date = CalendarDate.encode(
      CalendarDate.today(timeZone: _timeZone, instant: now),
    );
    // Travel/system timezone changes can alter notification times even when
    // the local calendar day has not changed. Family time is independent.
    return _timeZone == null
        ? '$date:${now.toLocal().timeZoneOffset.inMinutes}'
        : '$_timeZone:$date';
  }

  void _schedule() {
    _timer?.cancel();
    _timer = null;
    if (!_started || _disposed || !_foreground) return;
    final untilMidnight = CalendarDate.untilNextDay(
      timeZone: _timeZone, instant: _clock(),
    );
    // Wake at midnight, and check at most once a minute for wall-clock/zone
    // changes. Ordinary ticks do not query the DB or reschedule notifications.
    const maximumDelay = Duration(minutes: 1);
    final delay = untilMidnight > Duration.zero && untilMidnight < maximumDelay
        ? untilMidnight
        : maximumDelay;
    _timer = Timer(delay, () {
      final key = _key(_clock());
      if (key != _calendarKey) {
        _calendarKey = key;
        _onRefresh();
      }
      _schedule();
    });
  }

  void stop() {
    if (!_started) return;
    _started = false;
    _timer?.cancel();
    _timer = null;
    WidgetsBinding.instance.removeObserver(this);
  }

  void dispose() {
    stop();
    _disposed = true;
  }
}
