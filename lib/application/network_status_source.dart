import 'package:connectivity_plus/connectivity_plus.dart';

enum NetworkAvailability {
  unknown,
  offline,
  online,
}

/// Small platform boundary for observing whether the device has a usable
/// network interface. This intentionally does not promise internet reachability
/// or NAS reachability; the sync engine remains the source of truth for those.
abstract interface class NetworkStatusSource {
  Stream<NetworkAvailability> get changes;

  Future<NetworkAvailability> get current;

  void dispose();
}

/// Open-source connectivity_plus adapter used by the foreground sync scheduler.
class ConnectivityPlusNetworkStatusSource implements NetworkStatusSource {
  ConnectivityPlusNetworkStatusSource({Connectivity? connectivity})
      : _connectivity = connectivity ?? Connectivity();

  final Connectivity _connectivity;

  @override
  Stream<NetworkAvailability> get changes =>
      _connectivity.onConnectivityChanged.map(_fromResults);

  @override
  Future<NetworkAvailability> get current async =>
      _fromResults(await _connectivity.checkConnectivity());

  @override
  void dispose() {
    // connectivity_plus does not expose a disposable stream subscription or
    // native resource here. The scheduler owns and cancels its subscription.
  }
}

NetworkAvailability _fromResults(List<ConnectivityResult> results) {
  if (results.isEmpty ||
      results.every((result) => result == ConnectivityResult.none)) {
    return NetworkAvailability.offline;
  }
  return NetworkAvailability.online;
}
