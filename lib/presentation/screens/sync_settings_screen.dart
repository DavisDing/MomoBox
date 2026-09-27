import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/sync_engine.dart';
import '../../data/nas/nas_sync_api.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../../domain/models/nas_sync_models.dart';
import '../../domain/models/sync_models.dart';
import '../controllers/nas_account_controller.dart';
import '../controllers/providers.dart';

/// Sync controls intentionally remain explicit: the user must choose a
/// bootstrap mode when the NAS reports that local and remote data need a
/// decision. Remote conflict resolution is acknowledged by the NAS before the
/// matching local review record is updated.
class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  bool _working = false;
  String? _message;
  List<String> _availableModes = const <String>[];
  String? _selectedMode;
  String? _resolvingRemoteConflictId;
  Future<NasSyncConflictListResponse>? _remoteConflictsFuture;
  NasSyncApi? _remoteConflictsApi;
  String? _remoteConflictsDeviceId;
  List<NasSyncConflictDetail> _remoteConflicts = const <NasSyncConflictDetail>[];

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(nasAccountProvider);
    final engine = ref.watch(syncEngineProvider);
    final syncApi = ref.watch(nasSyncApiProvider);
    final deviceId = account.devices.currentDeviceId;
    final scopeId = account.family.familyId;
    final state = scopeId == null ? null : ref.watch(syncStateProvider(scopeId)).valueOrNull;
    final conflicts = scopeId == null
        ? const AsyncValue<List<SyncConflictEntry>>.data(<SyncConflictEntry>[])
        : ref.watch(syncConflictsProvider(scopeId));

    return Scaffold(
      appBar: AppBar(title: const Text('同步设置')),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 32),
        children: [
          _buildOverviewCard(context, account, engine, state),
          const SizedBox(height: 12),
          _buildBootstrapCard(context, engine, state),
          const SizedBox(height: 12),
          _buildConflictCard(context, scopeId, conflicts, syncApi, deviceId),
        ],
      ),
    );
  }

  Widget _buildOverviewCard(
    BuildContext context,
    NasAccountState account,
    SyncEngine? engine,
    SyncStateModel? state,
  ) {
    final familyId = account.family.familyId;
    final workspace = ref.watch(localWorkspaceIdProvider).valueOrNull;
    final enabled = engine != null;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Icon(Icons.sync_outlined),
                const SizedBox(width: 10),
                Text('NAS 双向同步', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                Chip(
                  label: Text(enabled ? _statusLabel(state?.bootstrapStatus) : '未就绪'),
                  avatar: Icon(enabled ? Icons.cloud_done_outlined : Icons.cloud_off_outlined, size: 18),
                ),
              ],
            ),
            const SizedBox(height: 12),
            Text(
              enabled
                  ? '同步只在已登录、已加入家庭并注册当前设备后启用。'
                  : '请先在 NAS 协同管理中完成地址、登录、家庭和设备配置。',
            ),
            if (familyId != null) ...[
              const SizedBox(height: 8),
              Text('同步范围：$familyId', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (workspace != null) ...[
              const SizedBox(height: 4),
              Text('本地工作区：$workspace', style: Theme.of(context).textTheme.bodySmall),
            ],
            if (state?.lastSuccessAt != null) ...[
              const SizedBox(height: 8),
              Text('最近成功：${_formatDate(state!.lastSuccessAt!)}'),
            ],
            if (state?.lastErrorMessage != null) ...[
              const SizedBox(height: 8),
              Text(
                '最近错误：${state!.lastErrorMessage}',
                style: TextStyle(color: Theme.of(context).colorScheme.error),
              ),
            ],
            if (_message != null) ...[
              const SizedBox(height: 8),
              Text(_message!, style: TextStyle(color: Theme.of(context).colorScheme.primary)),
            ],
            const SizedBox(height: 12),
            FilledButton.icon(
              onPressed: !enabled || _working ? null : () => _runSync(engine),
              icon: _working
                  ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))
                  : const Icon(Icons.sync),
              label: const Text('立即同步'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBootstrapCard(BuildContext context, SyncEngine? engine, SyncStateModel? state) {
    final awaitingChoice = state?.bootstrapStatus == SyncBootstrapStatus.awaitingConfirmation;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('首次连接与数据归属', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text(
              '首次连接只读取服务端提供的可选模式；不会自动覆盖本地库存，也不会把“合并”显示为已完成。',
            ),
            const SizedBox(height: 12),
            if (awaitingChoice && _availableModes.isNotEmpty)
              RadioGroup<String>(
                groupValue: _selectedMode,
                onChanged: (value) => setState(() => _selectedMode = value),
                child: Column(children: _availableModes.map(_buildModeTile).toList()),
              ),
            if (awaitingChoice && _availableModes.isNotEmpty) const SizedBox(height: 8),
            OutlinedButton.icon(
              onPressed: engine == null || _working ? null : () => _bootstrap(engine),
              icon: const Icon(Icons.cloud_download_outlined),
              label: Text(awaitingChoice ? '重新读取可选模式' : '检查首次同步状态'),
            ),
            if (awaitingChoice) ...[
              const SizedBox(height: 8),
              FilledButton.icon(
                onPressed: engine == null || _working || _selectedMode == null
                    ? null
                    : () => _confirmBootstrap(engine, _selectedMode!),
                icon: const Icon(Icons.check),
                label: const Text('确认所选模式'),
              ),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildModeTile(String mode) {
    final title = switch (mode) {
      'join_and_merge' => '加入并合并',
      'create_new_family' => '创建新的家庭数据',
      'keep_local_only' => '仅保留本地数据',
      _ => mode,
    };
    final description = switch (mode) {
      'join_and_merge' => '接受服务端家庭范围，后续通过同步协议逐项处理变更和冲突。',
      'create_new_family' => '按服务端提供的创建流程建立新的家庭数据范围。',
      'keep_local_only' => '不继续远端同步，保留当前设备的离线数据。',
      _ => '服务端返回的同步模式。',
    };
    return RadioListTile<String>(
      value: mode,
      enabled: !_working,
      title: Text(title),
      subtitle: Text(description),
      contentPadding: EdgeInsets.zero,
    );
  }

  Widget _buildConflictCard(
    BuildContext context,
    String? scopeId,
    AsyncValue<List<SyncConflictEntry>> conflicts,
    NasSyncApi? syncApi,
    String? deviceId,
  ) {
    final remoteFuture = _remoteConflictsFutureFor(syncApi, deviceId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Text('待处理冲突', style: Theme.of(context).textTheme.titleMedium),
                const Spacer(),
                if (scopeId != null)
                  IconButton(
                    tooltip: '刷新本地与远端冲突',
                    onPressed: _working
                        ? null
                        : () {
                            ref.invalidate(syncConflictsProvider(scopeId));
                            _refreshRemoteConflicts();
                          },
                    icon: const Icon(Icons.refresh),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '保留远端或保留本地前会先调用 NAS 冲突接口；只有远端确认成功后，才会更新对应的本地冲突记录。',
            ),
            const SizedBox(height: 12),
            _buildRemoteConflictSection(context, remoteFuture, syncApi, deviceId, conflicts),
            const SizedBox(height: 16),
            Text('本地冲突记录', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            conflicts.when(
              loading: () => const LinearProgressIndicator(),
              error: (error, _) => Text('读取本地冲突失败：$error'),
              data: (items) => items.isEmpty
                  ? const Text('当前没有待处理的本地冲突记录。')
                  : Column(
                      children: items
                          .map((item) => _buildConflictTile(
                                context,
                                item,
                                syncApi,
                                deviceId,
                              ))
                          .toList(),
                    ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRemoteConflictSection(
    BuildContext context,
    Future<NasSyncConflictListResponse>? remoteFuture,
    NasSyncApi? syncApi,
    String? deviceId,
    AsyncValue<List<SyncConflictEntry>> localConflicts,
  ) {
    final title = Text('远端开放冲突', style: Theme.of(context).textTheme.titleSmall);
    if (syncApi == null || deviceId == null || deviceId.trim().isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 6),
          const Text('当前 NAS 会话或设备未就绪，暂时无法读取远端冲突。'),
        ],
      );
    }
    if (remoteFuture == null) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          title,
          const SizedBox(height: 6),
          const Text('正在准备读取远端冲突……'),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        title,
        const SizedBox(height: 6),
        FutureBuilder<NasSyncConflictListResponse>(
          future: remoteFuture,
          builder: (context, snapshot) {
            if (snapshot.connectionState == ConnectionState.waiting) {
              return const LinearProgressIndicator();
            }
            if (snapshot.hasError) {
              return Text('读取远端冲突失败：${snapshot.error}');
            }
            final response = snapshot.data;
            if (response == null || response.conflicts.isEmpty) {
              return const Text('当前没有开放的远端冲突。');
            }
            return Column(
              children: [
                ...response.conflicts.map(
                  (conflict) => _buildRemoteConflictTile(
                    context,
                    conflict,
                    deviceId,
                    localConflicts,
                  ),
                ),
                if (response.hasMore)
                  const Align(
                    alignment: Alignment.centerLeft,
                    child: Padding(
                      padding: EdgeInsets.only(top: 6),
                      child: Text('远端冲突超过单次显示上限，当前仅显示前 200 条。'),
                    ),
                  ),
              ],
            );
          },
        ),
      ],
    );
  }

  Widget _buildRemoteConflictTile(
    BuildContext context,
    NasSyncConflictDetail conflict,
    String deviceId,
    AsyncValue<List<SyncConflictEntry>> localConflicts,
  ) {
    final resolving = _resolvingRemoteConflictId == conflict.conflictId;
    final unsupportedLocal = _isInventoryOrHomeAssistantConflict(conflict);
    final local = localConflicts.valueOrNull == null
        ? null
        : _matchingLocalConflict(localConflicts.valueOrNull!, conflict);
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('${conflict.entity} · ${conflict.entityId ?? '未命名实体'}'),
      subtitle: Text(
        '${_remoteStatusLabel(conflict.status)} · ${conflict.reason} · 服务端版本 ${conflict.serverVersion ?? 0}',
      ),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        _payloadLine('冲突 ID', conflict.conflictId),
        if (conflict.operation != null) _payloadLine('操作', conflict.operation!),
        if (conflict.serverPayload != null)
          _payloadLine('服务端快照', _compactJson(conflict.serverPayload!)),
        if (conflict.clientPayload != null)
          _payloadLine('客户端变更', _compactJson(conflict.clientPayload!)),
        if (unsupportedLocal)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '库存或 Home Assistant 冲突不支持在此执行“保留本地/manual_merge”；请先保留远端，或在后端支持专用命令后再处理。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        if (local == null)
          const Align(
            alignment: Alignment.centerLeft,
            child: Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('未找到匹配的本地冲突记录；远端解决不会伪造本地已处理状态。'),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: resolving
                    ? null
                    : () => _resolveRemoteConflict(
                          conflict: conflict,
                          deviceId: deviceId,
                          localConflicts: localConflicts.valueOrNull ?? const <SyncConflictEntry>[],
                          action: 'keep_remote',
                        ),
                child: resolving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保留远端'),
              ),
              FilledButton.tonal(
                onPressed: resolving || unsupportedLocal
                    ? null
                    : () => _resolveRemoteConflict(
                          conflict: conflict,
                          deviceId: deviceId,
                          localConflicts: localConflicts.valueOrNull ?? const <SyncConflictEntry>[],
                          action: 'keep_local',
                        ),
                child: const Text('保留本地'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildConflictTile(
    BuildContext context,
    SyncConflictEntry conflict,
    NasSyncApi? syncApi,
    String? deviceId,
  ) {
    final remote = _matchingRemoteConflict(conflict);
    final resolving = _resolvingRemoteConflictId == remote?.conflictId;
    final unsupportedLocal = remote != null && _isInventoryOrHomeAssistantConflict(remote);
    final canResolveRemotely = syncApi != null && deviceId != null && remote != null;
    return ExpansionTile(
      tilePadding: EdgeInsets.zero,
      title: Text('${conflict.entity} · ${conflict.entityId ?? '未命名实体'}'),
      subtitle: Text('${conflict.reason} · ${_formatDate(conflict.createdAt)}'),
      childrenPadding: const EdgeInsets.only(bottom: 8),
      children: [
        if (conflict.serverVersion != null)
          _payloadLine('本地记录的服务端版本', '${conflict.serverVersion}'),
        if (conflict.serverPayloadJson != null)
          _payloadLine('服务端快照', conflict.serverPayloadJson!),
        if (conflict.clientPayloadJson != null)
          _payloadLine('本地变更', conflict.clientPayloadJson!),
        if (!canResolveRemotely)
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('正在等待匹配远端冲突；未匹配前不会只在本地标记为已处理。'),
          ),
        if (unsupportedLocal)
          Align(
            alignment: Alignment.centerLeft,
            child: Text(
              '库存或 Home Assistant 冲突不允许伪造“保留本地/manual_merge”。',
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
          ),
        Align(
          alignment: Alignment.centerRight,
          child: Wrap(
            spacing: 8,
            children: [
              TextButton(
                onPressed: !canResolveRemotely || resolving
                    ? null
                    : () => _resolveRemoteConflict(
                          conflict: remote,
                          deviceId: deviceId,
                          localConflicts: <SyncConflictEntry>[conflict],
                          action: 'keep_remote',
                        ),
                child: const Text('保留远端'),
              ),
              FilledButton.tonal(
                onPressed: !canResolveRemotely || resolving || unsupportedLocal
                    ? null
                    : () => _resolveRemoteConflict(
                          conflict: remote,
                          deviceId: deviceId,
                          localConflicts: <SyncConflictEntry>[conflict],
                          action: 'keep_local',
                        ),
                child: resolving
                    ? const SizedBox(
                        width: 18,
                        height: 18,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Text('保留本地'),
              ),
            ],
          ),
        ),
      ],
    );
  }

  String _remoteStatusLabel(String status) {
    return switch (status) {
      'open' => '开放',
      'resolved' => '已解决',
      'deferred' => '已延期',
      _ => status,
    };
  }

  String _compactJson(Map<String, dynamic> payload) {
    try {
      return jsonEncode(payload);
    } catch (_) {
      return payload.toString();
    }
  }

  Widget _payloadLine(String label, String value) {
    final compact = value.length > 500 ? '${value.substring(0, 500)}…' : value;
    return Align(
      alignment: Alignment.centerLeft,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: Text('$label：$compact', style: const TextStyle(fontSize: 12)),
      ),
    );
  }

  Future<void> _bootstrap(SyncEngine engine) async {
    setState(() {
      _working = true;
      _message = null;
      _selectedMode = null;
    });
    try {
      final response = await engine.bootstrap();
      if (!mounted) return;
      setState(() {
        _availableModes = response.availableModes;
        // Do not silently choose a destructive or data-merging bootstrap mode.
        // The user must explicitly select one before confirmation is enabled.
        _selectedMode = null;
        _message = response.mergeRequired ? '服务端要求选择首次同步模式。' : '服务端已准备好同步，可以立即同步。';
      });
    } catch (error) {
      if (mounted) setState(() => _message = '检查首次同步状态失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _confirmBootstrap(SyncEngine engine, String mode) async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final result = await engine.confirmBootstrap(mode: mode);
      if (!mounted) return;
      setState(() {
        _message = result.accepted
            ? '已接受模式“${_modeLabel(mode)}”。远端数据仍会通过后续同步逐步处理。'
            : '服务端拒绝了该同步模式。';
      });
      if (result.accepted && result.nextAction != 'keep_local_only') {
        await engine.runOnce();
      }
    } catch (error) {
      if (mounted) setState(() => _message = '确认同步模式失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<void> _runSync(SyncEngine engine) async {
    setState(() {
      _working = true;
      _message = null;
    });
    try {
      final report = await engine.runOnce();
      if (mounted) {
        setState(() => _message = report.skipped
            ? '本次未同步：${report.reason ?? '当前状态不允许同步'}'
            : '同步完成：推送 ${report.pushed} 条，拉取 ${report.pulled} 条，待处理 ${report.deferred} 条。');
      }
    } catch (error) {
      if (mounted) setState(() => _message = '同步失败：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Future<NasSyncConflictListResponse>? _remoteConflictsFutureFor(
    NasSyncApi? api,
    String? deviceId,
  ) {
    final normalizedDeviceId = deviceId?.trim();
    if (api == null || normalizedDeviceId == null || normalizedDeviceId.isEmpty) {
      _remoteConflictsFuture = null;
      _remoteConflictsApi = null;
      _remoteConflictsDeviceId = null;
      _remoteConflicts = const <NasSyncConflictDetail>[];
      return null;
    }
    if (!identical(_remoteConflictsApi, api) ||
        _remoteConflictsDeviceId != normalizedDeviceId ||
        _remoteConflictsFuture == null) {
      _remoteConflictsApi = api;
      _remoteConflictsDeviceId = normalizedDeviceId;
      _remoteConflicts = const <NasSyncConflictDetail>[];
      _remoteConflictsFuture = _loadRemoteConflicts(api, normalizedDeviceId);
    }
    return _remoteConflictsFuture;
  }

  Future<NasSyncConflictListResponse> _loadRemoteConflicts(
    NasSyncApi api,
    String deviceId,
  ) async {
    final response = await api.listConflicts(
      deviceId: deviceId,
      status: 'open',
      limit: 200,
    );
    if (mounted && identical(_remoteConflictsApi, api) && _remoteConflictsDeviceId == deviceId) {
      setState(() => _remoteConflicts = response.conflicts);
    }
    return response;
  }

  void _refreshRemoteConflicts() {
    if (!mounted) return;
    setState(() {
      _remoteConflictsFuture = null;
      _remoteConflicts = const <NasSyncConflictDetail>[];
    });
  }

  NasSyncConflictDetail? _matchingRemoteConflict(SyncConflictEntry local) {
    for (final remote in _remoteConflicts) {
      if (remote.changeId == local.changeId ||
          (remote.changeId != null && remote.changeId == local.outboxChangeId)) {
        return remote;
      }
    }
    return null;
  }

  SyncConflictEntry? _matchingLocalConflict(
    List<SyncConflictEntry> locals,
    NasSyncConflictDetail remote,
  ) {
    for (final local in locals) {
      if (remote.changeId == local.changeId ||
          (remote.changeId != null && remote.changeId == local.outboxChangeId)) {
        return local;
      }
    }
    return null;
  }

  bool _isInventoryOrHomeAssistantConflict(NasSyncConflictDetail conflict) {
    final value = '${conflict.entity} ${conflict.operation ?? ''}'.toLowerCase();
    return value.contains('inventory') ||
        value.contains('homeassistant') ||
        value.contains('home_assistant') ||
        value.contains('home-assistant') ||
        value.contains('ha_command');
  }

  Future<void> _resolveRemoteConflict({
    required NasSyncConflictDetail conflict,
    required String deviceId,
    required List<SyncConflictEntry> localConflicts,
    required String action,
  }) async {
    if (_resolvingRemoteConflictId != null) return;
    if (action == 'keep_local' && _isInventoryOrHomeAssistantConflict(conflict)) {
      setState(() => _message = '库存或 Home Assistant 冲突暂不支持保留本地。');
      return;
    }
    final api = ref.read(nasSyncApiProvider);
    if (api == null) {
      setState(() => _message = 'NAS 会话已失效，无法解决远端冲突。');
      return;
    }
    setState(() {
      _resolvingRemoteConflictId = conflict.conflictId;
      _message = null;
    });
    NasSyncConflictResolveResponse response;
    try {
      response = await api.resolveConflict(
        NasSyncConflictResolveRequest(
          deviceId: deviceId,
          conflictId: conflict.conflictId,
          action: action,
          expectedVersion: conflict.serverVersion ?? 0,
        ),
      );
    } catch (error) {
      if (mounted) {
        setState(() => _message = '远端冲突解决失败，本地冲突仍保留：$error');
      }
      if (mounted) setState(() => _resolvingRemoteConflictId = null);
      return;
    }

    if (!response.accepted) {
      if (mounted) {
        setState(() {
          _message = 'NAS 未接受“${action == 'keep_local' ? '保留本地' : '保留远端'}”，本地冲突仍保留。';
          _resolvingRemoteConflictId = null;
        });
      }
      return;
    }

    final local = _matchingLocalConflict(localConflicts, conflict);
    var localUpdated = false;
    if (local != null) {
      try {
        final repository = SyncOutboxRepository(ref.read(databaseProvider));
        await repository.resolveConflict(
          id: local.id,
          status: action == 'keep_local'
              ? SyncConflictStatus.resolved
              : SyncConflictStatus.rejected,
          resolution: action == 'keep_local' ? 'remote_keep_local' : 'remote_keep_remote',
        );
        localUpdated = true;
      } catch (error) {
        if (mounted) {
          setState(() {
            _message = '远端已解决，但本地冲突记录更新失败，仍保留待处理：$error';
            _resolvingRemoteConflictId = null;
          });
        }
      }
    }

    if (!mounted) return;
    final familyId = ref.read(nasAccountProvider).family.familyId;
    if (familyId != null) {
      ref.invalidate(syncConflictsProvider(familyId));
    }
    setState(() {
      _remoteConflicts = _remoteConflicts
          .where((item) => item.conflictId != conflict.conflictId)
          .toList(growable: false);
      _remoteConflictsFuture = null;
      _resolvingRemoteConflictId = null;
      _message ??= local == null || !localUpdated
            ? '远端已解决；未找到匹配的本地冲突记录。'
            : '远端已解决，并已更新本地冲突记录。';
    });
  }

  String _statusLabel(SyncBootstrapStatus? status) {
    return switch (status) {
      SyncBootstrapStatus.unconfigured => '未初始化',
      SyncBootstrapStatus.awaitingConfirmation => '等待选择',
      SyncBootstrapStatus.ready => '可同步',
      SyncBootstrapStatus.keepLocalOnly => '仅本地',
      SyncBootstrapStatus.blocked => '已阻塞',
      null => '未初始化',
    };
  }

  String _modeLabel(String mode) {
    return switch (mode) {
      'join_and_merge' => '加入并合并',
      'create_new_family' => '创建新的家庭数据',
      'keep_local_only' => '仅保留本地数据',
      _ => mode,
    };
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}
