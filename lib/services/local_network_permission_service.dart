import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

enum LocalNetworkPermissionStatus { notRequired, granted, denied, unavailable }

/// Android 17 local-network access is separate from public Internet access.
/// Only an explicit connection action requests permission; passive probes do not.
class LocalNetworkPermissionService {
  static const channel = MethodChannel('com.example.momo_box/local_network');
  Future<LocalNetworkPermissionStatus>? _requestInFlight;

  Future<LocalNetworkPermissionStatus> status() => _invoke('status');

  Future<LocalNetworkPermissionStatus> request() {
    final current = _requestInFlight;
    if (current != null) return current;
    final next = _invoke('request');
    _requestInFlight = next;
    return next.whenComplete(() {
      if (identical(_requestInFlight, next)) _requestInFlight = null;
    });
  }

  Future<LocalNetworkPermissionStatus> _invoke(String method) async {
    if (kIsWeb || defaultTargetPlatform != TargetPlatform.android) {
      return LocalNetworkPermissionStatus.notRequired;
    }
    try {
      return switch (await channel.invokeMethod<String>(method)) {
        'not_required' => LocalNetworkPermissionStatus.notRequired,
        'granted' => LocalNetworkPermissionStatus.granted,
        'denied' => LocalNetworkPermissionStatus.denied,
        _ => LocalNetworkPermissionStatus.unavailable,
      };
    } on MissingPluginException {
      return LocalNetworkPermissionStatus.unavailable;
    } on PlatformException {
      return LocalNetworkPermissionStatus.unavailable;
    }
  }
}
