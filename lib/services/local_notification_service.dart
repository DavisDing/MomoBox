import 'dart:io';

import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter_timezone/flutter_timezone.dart';
import 'package:timezone/data/latest_all.dart' as tz;
import 'package:timezone/timezone.dart' as tz;

import '../domain/inventory/reminder_rules.dart';
import '../domain/models/inventory_models.dart';

class LocalNotificationService {
  LocalNotificationService({FlutterLocalNotificationsPlugin? plugin}) : _plugin = plugin ?? FlutterLocalNotificationsPlugin();

  static const _channelId = 'momobox_reminders';
  static const _channelName = '库存提醒';
  static const _channelDescription = '效期、过期和低库存提醒';

  final FlutterLocalNotificationsPlugin _plugin;
  bool _initialized = false;

  Future<void> initialize() async {
    if (_initialized) return;
    tz.initializeTimeZones();
    try {
      final dynamic timezone = await FlutterTimezone.getLocalTimezone();
      final timezoneName = timezone is String ? timezone : timezone.name as String;
      tz.setLocalLocation(tz.getLocation(timezoneName));
    } catch (_) {
      // 在不支持读取系统时区的平台上，timezone 包的默认位置仍可用于 CI 构建。
    }

    const android = AndroidInitializationSettings('@mipmap/ic_launcher');
    final darwin = DarwinInitializationSettings(
      requestAlertPermission: false,
      requestBadgePermission: false,
      requestSoundPermission: false,
    );
    await _plugin.initialize(
      InitializationSettings(android: android, iOS: darwin),
    );
    _initialized = true;
    await requestPermission();
  }

  Future<void> requestPermission() async {
    if (!_initialized) return;
    if (Platform.isAndroid) {
      await _plugin
          .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
          ?.requestNotificationsPermission();
    } else if (Platform.isIOS) {
      await _plugin
          .resolvePlatformSpecificImplementation<IOSFlutterLocalNotificationsPlugin>()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    }
  }

  Future<void> sync(List<InventoryItem> items, {DateTime? now}) async {
    if (!_initialized) return;
    await _plugin.cancelAll();
    final reference = now ?? DateTime.now();
    final candidates = ReminderRules.candidates(items, today: reference);
    for (final candidate in candidates) {
      final scheduled = _nextNineAm(candidate.date, reference);
      await _plugin.zonedSchedule(
        _stableId(candidate.key),
        _title(candidate.type),
        _body(candidate),
        scheduled,
        const NotificationDetails(
          android: AndroidNotificationDetails(
            _channelId,
            _channelName,
            channelDescription: _channelDescription,
            importance: Importance.high,
            priority: Priority.high,
          ),
          iOS: DarwinNotificationDetails(threadIdentifier: _channelId),
        ),
        androidScheduleMode: AndroidScheduleMode.inexactAllowWhileIdle,
        payload: candidate.item.id,
      );
    }
  }

  tz.TZDateTime _nextNineAm(DateTime date, DateTime now) {
    var scheduled = tz.TZDateTime(tz.local, date.year, date.month, date.day, 9);
    final current = tz.TZDateTime.from(now, tz.local);
    if (!scheduled.isAfter(current)) {
      final next = date.add(const Duration(days: 1));
      scheduled = tz.TZDateTime(tz.local, next.year, next.month, next.day, 9);
    }
    return scheduled;
  }

  int _stableId(String value) {
    var hash = 0x811c9dc5;
    for (final codeUnit in value.codeUnits) {
      hash ^= codeUnit;
      hash = (hash * 0x01000193) & 0x7fffffff;
    }
    return hash;
  }

  String _title(ReminderType type) => switch (type) {
        ReminderType.expiring => '物品即将到期',
        ReminderType.expired => '物品已过期',
        ReminderType.lowStock => '库存偏低',
      };

  String _body(ReminderCandidate candidate) => switch (candidate.type) {
        ReminderType.expiring => '${candidate.item.name} 将在 30 天内到期，请及时处理。',
        ReminderType.expired => '${candidate.item.name} 有批次已过期，请检查并报废。',
        ReminderType.lowStock => '${candidate.item.name} 剩余 ${candidate.item.totalStock} ${candidate.item.unit}，低于阈值 ${candidate.item.lowStockThreshold}。',
      };
}
