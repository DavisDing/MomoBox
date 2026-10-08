import 'dart:async';

/// Serializes sync run/bootstrap operations for one local database and scope,
/// including engines rebuilt by providers while an old attempt is in flight.
/// This is an isolate-local coordinator, not a cross-process database lock.
class SyncExecutionCoordinator {
  static final _databases = Expando<Map<String, _ScopeQueue>>();

  static Future<T> run<T>(Object databaseIdentity, String scopeId,
      Future<T> Function() operation) {
    final scopes = _databases[databaseIdentity] ??= <String, _ScopeQueue>{};
    final queue = scopes.putIfAbsent(scopeId, _ScopeQueue.new);
    queue.waiters++;
    final previous = queue.tail;
    final released = Completer<void>();
    queue.tail = released.future;
    return previous.then((_) async {
      try {
        return await operation();
      } finally {
        queue.waiters--;
        if (queue.waiters == 0) scopes.remove(scopeId);
        released.complete();
      }
    });
  }
}

class _ScopeQueue {
  Future<void> tail = Future<void>.value();
  int waiters = 0;
}
