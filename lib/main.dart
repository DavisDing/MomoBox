import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/momo_box_app.dart';
import 'presentation/controllers/providers.dart';
import 'services/local_notification_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final notifications = LocalNotificationService();
  try {
    await notifications.initialize();
  } catch (_) {
    // 本地通知不可用时仍允许单机库存核心正常启动。
  }
  runApp(
    ProviderScope(
      overrides: [localNotificationServiceProvider.overrideWithValue(notifications)],
      child: const MomoBoxApp(),
    ),
  );
}
