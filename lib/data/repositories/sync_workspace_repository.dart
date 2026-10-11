import 'dart:convert';

import '../../core/database/app_database.dart';

const syncWorkspaceBindingKey = 'sync_workspace_binding';

/// An endpoint identity is not a server-instance or restore-epoch identity.
class SyncWorkspaceIdentity {
  const SyncWorkspaceIdentity({
    required this.endpoint,
    required this.userId,
    required this.familyId,
  });

  final String endpoint;
  final String userId;
  final String familyId;

  bool matches(SyncWorkspaceIdentity other) =>
      endpoint == other.endpoint && userId == other.userId && familyId == other.familyId;

  String encode() => jsonEncode({
        'version': 1,
        'endpoint': endpoint,
        'user_id': userId,
        'family_id': familyId,
      });

  static SyncWorkspaceIdentity decode(String value) {
    final json = jsonDecode(value);
    if (json is! Map || json['version'] != 1 ||
        ![json['endpoint'], json['user_id'], json['family_id']]
            .every((item) => item is String && item.isNotEmpty && item.trim() == item)) {
      throw const FormatException('本机工作区绑定损坏或版本不支持；已暂停同步，未修改业务数据。');
    }
    return SyncWorkspaceIdentity(
      endpoint: json['endpoint'] as String,
      userId: json['user_id'] as String,
      familyId: json['family_id'] as String,
    );
  }
}

enum SyncWorkspaceStatus { unavailable, unbound, legacyReview, matched, mismatch, blocked }

class SyncWorkspaceAccess {
  const SyncWorkspaceAccess(this.status, {this.owner, this.message});
  final SyncWorkspaceStatus status;
  final SyncWorkspaceIdentity? owner;
  final String? message;
  bool get canSync => status == SyncWorkspaceStatus.matched;
  bool get canBind => status == SyncWorkspaceStatus.unbound || status == SyncWorkspaceStatus.legacyReview;
}

/// One immutable business owner per local database. Binding never rewrites
/// business rows, outbox keys, cursors, conflicts, credentials or remote data.
class SyncWorkspaceRepository {
  SyncWorkspaceRepository(this._database);
  final AppDatabase _database;

  Stream<String?> watchBinding() => (_database.select(_database.appSettings)
        ..where((row) => row.key.equals(syncWorkspaceBindingKey)))
      .watchSingleOrNull().map((row) => row?.value);

  Future<SyncWorkspaceIdentity?> readOwner() async {
    final row = await (_database.select(_database.appSettings)
          ..where((row) => row.key.equals(syncWorkspaceBindingKey))).getSingleOrNull();
    return row == null ? null : SyncWorkspaceIdentity.decode(row.value);
  }

  Future<Set<String>> _legacyScopes() async {
    final rows = await _database.customSelect('''
SELECT scope_id FROM sync_states
UNION SELECT scope_id FROM sync_outbox
UNION SELECT scope_id FROM sync_conflicts
UNION SELECT scope_id FROM sync_applied_changes
''').get();
    final scopes = rows.map((row) => row.read<String>('scope_id')).toSet();
    // Include imported old auxiliary bindings even when the state row is absent.
    final settings = await _database.select(_database.appSettings).get();
    for (final row in settings) {
      if (row.key.startsWith('sync_aux:') || row.key.startsWith('sync_category_binding:') ||
          row.key.startsWith('reminder_sync_policy:')) {
        final parts = row.key.split(':');
        if (parts.length > 2) scopes.add(parts[1]);
      }
    }
    return scopes;
  }

  Future<SyncWorkspaceAccess> inspect(SyncWorkspaceIdentity? current) async {
    try {
      final owner = await readOwner();
      if (owner != null) {
        return SyncWorkspaceAccess(
          current == null ? SyncWorkspaceStatus.unavailable :
              owner.matches(current) ? SyncWorkspaceStatus.matched : SyncWorkspaceStatus.mismatch,
          owner: owner,
          message: current != null && !owner.matches(current)
              ? '当前 NAS、账号或家庭与本机数据归属不一致，已暂停同步。请返回原身份；不会自动迁移或覆盖库存。'
              : null,
        );
      }
      if (current == null) return const SyncWorkspaceAccess(SyncWorkspaceStatus.unavailable);
      final scopes = await _legacyScopes();
      if (scopes.any((scope) => scope != current.familyId)) {
        return const SyncWorkspaceAccess(SyncWorkspaceStatus.blocked,
            message: '本机存在其他家庭的同步现场，不能绑定当前身份。请保留数据，先核对原家庭和迁移方案。');
      }
      return SyncWorkspaceAccess(scopes.isEmpty ? SyncWorkspaceStatus.unbound : SyncWorkspaceStatus.legacyReview,
          message: scopes.isEmpty ? '本机尚未确认数据归属，同步已暂停。' :
              '旧版同步现场缺少 NAS 和账号归属。家庭 ID 相同也不能证明来源，请确认原身份后再绑定。');
    } on FormatException {
      return const SyncWorkspaceAccess(SyncWorkspaceStatus.blocked,
          message: '本机工作区绑定损坏或版本不支持，已暂停同步；请保留现场，不要清库或重新绑定。');
    }
  }

  Future<void> bind(SyncWorkspaceIdentity identity, {required bool Function() isCurrent}) =>
      _database.transaction(() async {
        SyncWorkspaceIdentity.decode(identity.encode());
        final access = await inspect(identity);
        if (!isCurrent()) throw StateError('身份已改变，请重新核对本机数据归属。');
        if (access.canSync) return; // Repeat same confirmation is idempotent.
        if (!access.canBind) throw StateError(access.message ?? '工作区已有归属，不能重新绑定。');
        await _database.into(_database.appSettings).insert(
              AppSettingsCompanion.insert(key: syncWorkspaceBindingKey, value: identity.encode(), updatedAt: DateTime.now()),
            );
        if (!isCurrent()) throw StateError('身份已改变，数据归属确认已撤销。');
      });

  /// Local edits belong to the durable owner even while signed out or logged
  /// into a different server. Resolve inside the business transaction, not from
  /// a cached account/provider, so held repositories cannot target a new family.
  Future<String?> localMutationScope() async {
    final owner = await readOwner();
    if (owner != null) return owner.familyId;
    final scopes = await _legacyScopes();
    if (scopes.length == 1) return scopes.single;
    if (scopes.isNotEmpty) {
      throw StateError('本机存在多个家庭的同步现场，暂不能确定新增操作归属；请保留数据后核对迁移方案。');
    }
    return null;
  }
}
