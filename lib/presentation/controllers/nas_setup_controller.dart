import 'dart:async';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../core/database/app_database.dart';
import '../../application/sync_engine.dart';
import '../../application/initial_import_service.dart';
import '../../data/repositories/sync_workspace_repository.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../../domain/models/sync_models.dart';
import '../../domain/models/initial_import_models.dart';
import 'nas_account_controller.dart';

enum NasSetupStatus {
  connectionRequired,
  preparing,
  inviteRequired,
  ready,
  failed,
}

class NasSetupState {
  const NasSetupState(this.status, {this.message});
  final NasSetupStatus status;
  final String? message;
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
    this.onReady,
  }) : super(const NasSetupState(NasSetupStatus.connectionRequired));
  final AppDatabase database;
  final NasAccountController Function() accountReader;
  final Future<void> Function() refreshAccess;
  final Future<void> Function() workspaceReady;
  final SyncEngine? Function() engineReader;
  final InitialImportService? Function() importReader;
  final void Function()? onReady;
  Future<void>? _running;
  int _revision = 0;
  String? _attempted;
  String? _runningIdentity;
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
      if (_runningIdentity != key) {
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

  Future<void> prepare() {
    final running = _running;
    if (running != null) return running;
    final account = accountReader();
    _runningIdentity =
        '${account.serverIdentity}:${account.snapshot.auth.user?.id}';
    final next = _prepare(++_revision);
    _running = next;
    return next.whenComplete(() {
      if (identical(_running, next)) _running = null;
      if (_pendingChange && mounted) {
        _pendingChange = false;
        changed();
      }
    });
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
    if (!current() || user == null || endpoint == null) return;
    state = const NasSetupState(
      NasSetupStatus.preparing,
      message: '正在连接家庭并同步数据…',
    );
    try {
      if (!account.snapshot.family.hasFamily) await account.initializeFamily();
      if (!current()) return;
      if (!account.snapshot.family.hasFamily) {
        state = NasSetupState(
          NasSetupStatus.inviteRequired,
          message:
              account.snapshot.family.errorMessage ??
              '此 NAS 已有家庭，请输入创建者提供的邀请码加入。',
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
      if (!access.canSync) {
        if (!access.canBind) {
          throw StateError(access.message ?? '已有数据属于另一家庭，请返回原账号。');
        }
        await workspace.bind(identity, isCurrent: sameFamily);
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
          message: '连接初始化未完成，原数据已保留。$error',
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
