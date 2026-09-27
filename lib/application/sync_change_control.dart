/// Control-flow exceptions used by the sync application boundary.
///
/// A deferred remote change must stop the pull before its cursor. The
/// server change stays retriable until an explicit resolution is committed. It is intentionally distinct from a
/// malformed or failed change, which must still fail the sync run and retry.
class SyncRemoteChangeDeferred implements Exception {
  const SyncRemoteChangeDeferred(this.reason);

  final String reason;

  @override
  String toString() => 'SyncRemoteChangeDeferred: $reason';
}
