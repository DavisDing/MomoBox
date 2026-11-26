import 'dart:async';

import 'package:drift/drift.dart' show BooleanExpressionOperators;
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../core/database/app_database.dart';
import '../../application/sync_engine.dart';
import '../../application/initial_import_service.dart';
import '../../application/nas_connection_service.dart';
import '../../data/nas/nas_api_error.dart';
import '../../data/repositories/sync_workspace_repository.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../../domain/models/sync_models.dart';
import '../../domain/models/initial_import_models.dart';
import 'nas_account_controller.dart';

enum NasSetupStatus {
  connectionRequired,
  preparing,
  inviteRequired,
  workspaceMismatch,
  ready,
  failed,
}

class NasSetupState {
  const NasSetupState(this.status, {this.message, this.resetTarget});
  final NasSetupStatus status;
  final String? message;
  final SyncWorkspaceIdentity? resetTarget;
}

/// The normal connection path owns binding, device registration, bootstrap and
/// interrupted import recovery. Only unresolved data conflicts need review.
class NasSetupController extends StateNotifier<NasSetupState> {
  NasSetupController({
    required this.database,
    required this.accountReader,
    required this.refreshAccess,
    required this.workspaceReady,
    required this.engineReader,
    required this.importReader,
    required this.cleanLocalMedia,
    this.runLocalReset,
    this.onResetStarted,
    this.onReady,
  }) : super(const NasSetupState(NasSetupStatus.connectionRequired));
  final AppDatabase database;
  final NasAccountController Function() accountReader;
  final Future<void> Function() refreshAccess;
  final Future<void> Function() workspaceReady;
  final SyncEngine? Function() engineReader;
  final InitialImportService? Function() importReader;
  final Future<void> Function() cleanLocalMedia;
  final Future<void> Function(Future<void> Function())? runLocalReset;
  final void Function()? onResetStarted;
  final void Function()? onReady;
  Future<void>? _running;
  int _revision = 0;
  String? _attempted;
  String? _runningIdentity;
  String? _runningFamily;
  bool _pendingChange = false;

  void changed() {
    final account = accountReader();
    final key = '${account.serverIdentity}:${account.snapshot.auth.user?.id}';
    if (!account.snapshot.isAuthenticated) {
      _revision++;
      _attempted = null;
      if (_running != null) _pendingChange = true;
      state = const NasSetupState(NasSetupStatus.connectionRequired);
      return;
    }
    if (_running != null) {
      if (_runningIdentity != key ||
          (_runningFamily != null &&
              _runningFamily != account.snapshot.family.familyId)) {
        _revision++;
        _pendingChange = true;
      }
      return;
    }
    if (account.snapshot.isLoading) return;
    final context = '$key:${account.snapshot.family.familyId}';
    if (_attempted == context) return;
    _attempted = context;
    unawaited(prepare());
  }

  Future<void> prepare() => _run(_prepare);

  Future<void> resetLocalWorkspace(NasSetupState confirmation) async {
    final target = confirmation.resetTarget;
    if (confirmation.status != NasSetupStatus.workspaceMismatch ||
        target == null ||
        !identical(confirmation, state)) {
      return;
    }
    await _run((revision) => _resetLocalWorkspace(target, revision));
  }

  Future<void> _run(Future<void> Function(int) operation) {
    final running = _running;
    if (running != null) return running;
    final account = accountReader();
    _runningIdentity =
        '${account.serverIdentity}:${account.snapshot.auth.user?.id}';
    _runningFamily = account.snapshot.family.familyId;
    final next = operation(++_revision);
    _running = next;
    return next.whenComplete(() {
      if (identical(_running, next)) _running = null;
      if (_pendingChange && mounted) {
        _pendingChange = false;
        changed();
      }
    });
  }

  Future<void> _resetLocalWorkspace(
    SyncWorkspaceIdentity target,
    int revision,
  ) async {
    final account = accountReader();
    bool isCurrent() =>
        mounted &&
        revision == _revision &&
        identical(accountReader(), account) &&
        account.snapshot.isAuthenticated &&
        account.serverIdentity == target.endpoint &&
        account.snapshot.auth.user?.id == target.userId &&
        account.snapshot.family.hasFamily &&
        account.snapshot.family.familyId == target.familyId &&
        account.snapshot.devices.status == NasDeviceStatus.ready;

    if (!isCurrent()) return;
    state = const NasSetupState(
      NasSetupStatus.preparing,
      message: '正在清除本机数据并连接当前家庭…',
    );
    try {
      onResetStarted?.call();
      Future<void> resetDatabase() =>
          SyncWorkspaceRepository(database).resetFor(
            target,
            retainedSettings: const {
              nasServerUrlKey,
              nasFamilyCodeKey,
              nasLastCheckedAtKey,
              nasDeviceIdKey,
              syncLocalWorkspaceIdKey,
              'theme',
              'font_scale',
            },
            isCurrent: isCurrent,
          );
      await (runLocalReset?.call(resetDatabase) ?? resetDatabase());
    } catch (_) {
      if (isCurrent()) {
        state = NasSetupState(
          NasSetupStatus.workspaceMismatch,
          message: '无法清除旧家庭数据，本机记录仍保留。请重试。',
          resetTarget: target,
        );
      }
      return;
    }
    if (isCurrent()) await _prepare(revision);
  }

  Future<void> _prepare(int revision) async {
    final account = accountReader();
    final user = account.snapshot.auth.user?.id;
    final endpoint = account.serverIdentity;
    bool current() =>
        mounted &&
        revision == _revision &&
        identical(accountReader(), account) &&
        account.snapshot.isAuthenticated &&
        account.snapshot.auth.user?.id == user &&
        account.serverIdentity == endpoint;
    if (!current() ||
        user == null ||
        endpoint == null ||
        account.snapshot.isLoading) {
      return;
    }
    state = const NasSetupState(
      NasSetupStatus.preparing,
      message: '正在连接家庭并同步数据…',
    );
    try {
      final status = account.snapshot.family.status;
      if (status == NasFamilyStatus.error || status == NasFamilyStatus.idle) {
        await account.refreshFamilyAndDevices();
      }
      if (!current()) return;
      if (account.snapshot.family.status == NasFamilyStatus.missing) {
        await account.initializeFamily();
      }
      if (!current()) return;
      if (!account.snapshot.family.hasFamily) {
        final inviteRequired =
            account.snapshot.family.status == NasFamilyStatus.inviteRequired;
        state = NasSetupState(
          inviteRequired
              ? NasSetupStatus.inviteRequired
              : NasSetupStatus.failed,
          message:
              account.snapshot.family.errorMessage ??
              (inviteRequired
                  ? '此 NAS 已有家庭，请输入创建者提供的邀请码加入。'
                  : '未能连接 NAS 家庭，请重试。'),
        );
        return;
      }
      final identity = SyncWorkspaceIdentity(
        endpoint: endpoint,
        userId: user,
        familyId: account.snapshot.family.familyId!,
      );
      bool sameFamily() =>
          current() && identity.familyId == account.snapshot.family.familyId;
      await account.prepareCurrentDevice();
      if (!sameFamily()) return;
      if (account.snapshot.devices.status != NasDeviceStatus.ready) {
        throw StateError(
          account.snapshot.devices.errorMessage ?? '设备登记未完成，请重试连接。',
        );
      }
      final workspace = SyncWorkspaceRepository(database);
      final access = await workspace.inspect(identity);
      if (!sameFamily()) return;
      if (access.status == SyncWorkspaceStatus.mismatch) {
        _attempted = '$endpoint:$user:${identity.familyId}';
        state = NasSetupState(
          NasSetupStatus.workspaceMismatch,
          message: '本机仍保留原家庭的数据。可以返回原家庭，或清除本机数据后连接当前家庭。',
          resetTarget: identity,
        );
        return;
      }
      if (!access.canSync) {
        if (!access.canBind) {
          throw StateError(access.message ?? '已有数据属于另一家庭，请返回原账号。');
        }
        await workspace.bind(identity, isCurrent: sameFamily);
      }
      final resetOwner = identity.encode();
      final needsMediaCleanup =
          await (database.select(database.appSettings)..where(
                (row) =>
                    row.key.equals(syncWorkspaceMediaCleanupKey) &
                    row.value.equals(resetOwner),
              ))
              .getSingleOrNull();
      if (!sameFamily()) return;
      if (needsMediaCleanup != null) {
        try {
          await cleanLocalMedia();
        } catch (_) {
          throw StateError('本机库存已清除，但图片缓存清理未完成。请重试。');
        }
        if (!sameFamily()) return;
        await (database.delete(database.appSettings)..where(
              (row) =>
                  row.key.equals(syncWorkspaceMediaCleanupKey) &
                  row.value.equals(resetOwner),
            ))
            .go();
      }
      await refreshAccess();
      await workspaceReady();
      if (!sameFamily()) return;
      final engine = engineReader();
      if (engine == null) throw StateError('连接准备未完成，请重试。');
      final outbox = SyncOutboxRepository(database);
      final saved = await outbox.getState(identity.familyId);
      final mode = await outbox.getConfirmedBootstrapMode(identity.familyId);
      if (mode != 'join_and_merge' ||
          saved == null ||
          saved.bootstrapStatus == SyncBootstrapStatus.unconfigured ||
          saved.bootstrapStatus == SyncBootstrapStatus.keepLocalOnly) {
        final bootstrap = await engine.bootstrap();
        if (!sameFamily()) return;
        if (!bootstrap.availableModes.contains('join_and_merge')) {
          throw StateError('NAS 不支持自动连接，请更新后端。');
        }
        final receipt = await engine.confirmBootstrap(mode: 'join_and_merge');
        if (!receipt.accepted) throw StateError('NAS 未接受初始化，请重试。');
      }
      // Upgrade old local stock through the existing idempotent, bounded
      // preflight/import contract. It rejects overlaps instead of adding stock.
      final local =
          await database.customSelect(
            '''SELECT
        (SELECT count(*) FROM products WHERE deleted_at IS NULL AND server_version=0) +
        (SELECT count(*) FROM shopping_entries WHERE deleted_at IS NULL AND server_version=0) +
        (SELECT count(*) FROM product_batches WHERE deleted_at IS NULL AND server_version=0) AS n''',
          ).getSingle();
      final importer = importReader();
      if (importer != null) {
        final progress = await importer.watchProgress().first;
        if (progress?.isActive == true) {
          final resumed = await importer.resume();
          if (resumed.status != InitialImportStatus.completed) {
            throw StateError(resumed.message ?? '原有数据接入尚未完成，请核对同步状态。');
          }
        } else if (local.read<int>('n') > 0 &&
            !await outbox.hasSnapshotBlockingChanges(
              scopeId: identity.familyId,
            )) {
          final preview = await importer.preview();
          if (!preview.canPrepare) {
            throw StateError('原有数据需核对：${preview.blockers.join('；')}');
          }
          final prepared = await importer.prepare(preview);
          if (prepared.status == InitialImportStatus.blocked) {
            throw StateError('原有数据与 NAS 存在重叠，请核对；数据已保留。');
          }
          final imported = await importer.execute();
          if (imported.status != InitialImportStatus.completed) {
            throw StateError(imported.message ?? '原有数据接入尚未完成，请核对同步状态。');
          }
        }
      } else if (local.read<int>('n') > 0) {
        throw StateError('原有数据接入服务未就绪，请重试连接。');
      }
      if (!sameFamily()) return;
      var report = await engine.runOnce();
      for (
        var round = 1;
        round < 8 && (report.hasMorePending || report.hasMoreRemote);
        round++
      ) {
        if (!sameFamily()) return;
        report = await engine.runOnce();
      }
      if (!sameFamily()) return;
      if (report.skipped ||
          report.deferred > 0 ||
          report.hasMorePending ||
          report.hasMoreRemote) {
        throw StateError(report.reason ?? '同步尚未完成，请查看连接与同步状态中的待处理项目。');
      }
      await database.transaction(() async {
        if (!sameFamily()) throw StateError('NAS 会话已切换，未记录初始化完成。');
        await database
            .into(database.appSettings)
            .insertOnConflictUpdate(
              AppSettingsCompanion.insert(
                key: 'nas_setup_complete',
                value: identity.encode(),
                updatedAt: DateTime.now(),
              ),
            );
        if (!sameFamily()) throw StateError('NAS 会话已切换，未记录初始化完成。');
      });
      if (!sameFamily()) return;
      _attempted = '$endpoint:$user:${identity.familyId}';
      state = const NasSetupState(NasSetupStatus.ready);
      onReady?.call();
    } catch (error) {
      if (current()) {
        state = NasSetupState(
          NasSetupStatus.failed,
          message: switch (error) {
            NasApiError(:final message) => message,
            StateError(message: final String message) => message,
            _ => '首次同步未完成。请重试或查看连接与同步状态。',
          },
        );
      }
    }
  }

  @override
  void dispose() {
    _revision++;
    super.dispose();
  }
}
