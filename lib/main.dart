import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/momo_box_app.dart';
import 'presentation/controllers/providers.dart';
import 'services/local_notification_service.dart';
import 'services/diagnostic_log_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final diagnostics = DiagnosticLogService.shared;
  diagnostics.installErrorHandlers();
  if (Platform.isAndroid) {
    try {
      // Android 16 enforces edge-to-edge for modern target SDKs. Configure it
      // explicitly so the app and its system-bar styling behave consistently
      // on both Android 16 and Android 17.
      await SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    } catch (error, stack) {
      unawaited(diagnostics.record(DiagnosticEvent.systemUiSetupFailed, error, stackTrace: stack));
      // System UI configuration is an enhancement and must not block offline use.
    }
  }
  final notifications = LocalNotificationService();
  try {
    await notifications.initialize();
  } catch (error, stack) {
    unawaited(diagnostics.record(DiagnosticEvent.notificationInitializationFailed, error, stackTrace: stack));
    // 本地通知不可用时仍允许单机库存核心正常启动。
  }
  runApp(
    ProviderScope(
      overrides: [localNotificationServiceProvider.overrideWithValue(notifications)],
      child: const MomoBoxApp(),
    ),
  );
}
