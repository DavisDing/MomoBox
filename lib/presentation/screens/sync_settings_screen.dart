import '../../app/momo_typography.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/sync_engine.dart';
import '../../data/nas/nas_sync_api.dart';
import '../../data/nas/nas_api_error.dart';
import '../../data/repositories/sync_outbox_repository.dart';
import '../../domain/models/nas_sync_models.dart';
import '../../domain/models/sync_models.dart';
import '../controllers/providers.dart';
import '../widgets/momo_components.dart';
import '../widgets/momo_floating_dock.dart';
import '../widgets/initial_import_history_dialog.dart';

/// Setup is automatic. Actual conflicts still require a user decision and a
/// matching NAS receipt before changing the local review record.
class SyncSettingsScreen extends ConsumerStatefulWidget {
  const SyncSettingsScreen({super.key});

  @override
  ConsumerState<SyncSettingsScreen> createState() => _SyncSettingsScreenState();
}

class _SyncSettingsScreenState extends ConsumerState<SyncSettingsScreen> {
  bool _working = false;
  String? _message;
  String? _resolvingRemoteConflictId;
  Future<NasSyncConflictListResponse>? _remoteConflictsFuture;
  NasSyncApi? _remoteConflictsApi;
  String? _remoteConflictsDeviceId;
  List<NasSyncConflictDetail> _remoteConflicts = const <NasSyncConflictDetail>[];
  List<SyncConflictEntry> _recoveryLocals = const <SyncConflictEntry>[];
  String? _recoveryScopeId;

  @override
  Widget build(BuildContext context) {
    final account = ref.watch(nasAccountProvider);
    final engine = ref.watch(syncEngineProvider);
    final syncApi = ref.watch(nasSyncApiProvider);
    final deviceId = account.devices.currentDeviceId;
    final scopeId = account.family.familyId;
    final importProgress = scopeId == null ? null : ref.watch(initialImportProgressProvider).valueOrNull;
    final importer = ref.watch(initialImportServiceProvider);
    final state = scopeId == null ? null : ref.watch(syncStateProvider(scopeId)).valueOrNull;
    final conflicts = scopeId == null
        ? const AsyncValue<List<SyncConflictEntry>>.data(<SyncConflictEntry>[])
        : ref.watch(syncConflictsProvider(scopeId)).whenData((items) => [
            ...items,
            if (_recoveryScopeId == scopeId)
              ..._recoveryLocals.where((local) => !items.any((item) => item.id == local.id)),
          ]);

    return Scaffold(
      appBar: MomoAppBar.adaptive(context, title: const Text('连接与同步状态')),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 12, 16, 32 + MomoDockInsets.bottomOf(context)),
        children: [
          MomoCard(child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
            const Text('NAS 自动同步'),
            const Text('设备登记、家庭数据接入与同步初始化由 App 自动完成。'),
            if (state?.lastSuccessAt != null) Text('最近成功：${_formatDate(state!.lastSuccessAt!)}'),
            if (state?.lastErrorMessage != null) Text(state!.lastErrorMessage!),
            if (importProgress?.message != null) Text(importProgress!.message!),
            if (_message != null) Text(_message!),
            TextButton(onPressed:_working?null:()=>ref.read(nasSetupProvider.notifier).prepare(),child:const Text('重试连接')),
            if (importer != null && scopeId != null) TextButton(onPressed:()=>showDialog<void>(
              context:context,builder:(_)=>InitialImportHistoryDialog(familyId:scopeId,
                isSessionCurrent:()=>mounted && identical(ref.read(initialImportServiceProvider),importer) && importer.isCurrent,
                loadPage:(after,until)=>importer.history(after:after,until:until))),child:const Text('查看旧记录归档')),
          ])),
          const SizedBox(height:12),
          _buildConflictCard(context, scopeId, conflicts, syncApi, deviceId),
          if (scopeId != null) _buildRejectedCard(scopeId, engine, syncApi, deviceId),
          const SizedBox(height: 12),

        ],
      ),
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

  Widget _buildRejectedCard(String scopeId, SyncEngine? engine, NasSyncApi? api, String? deviceId) {
    final repository = SyncOutboxRepository(ref.read(databaseProvider));
    return FutureBuilder<List<SyncOutboxEntry>>(
      future: repository.listUnsettledRejected(scopeId: scopeId),
      builder: (context, snapshot) {
        if (snapshot.hasError) {
          return const Card(child: Padding(
            padding: EdgeInsets.all(16), child: Text('读取被拒绝变更失败；原同步记录仍保留。')));
        }
        final entries = snapshot.data ?? const <SyncOutboxEntry>[];
        if (entries.isEmpty) return const SizedBox.shrink();
        return Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('被拒绝的变更', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('这些变更仍阻止权威快照覆盖本机。可确认放弃有明确拒绝回执的意图。HA 通信或审计失败时，必须先核实设备实际状态。'),
            for (final entry in entries) FutureBuilder<bool>(
              future: repository.canAbandonRejected(entry),
              builder: (context, permission) => ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text('${entry.entity ?? entry.operation.wireValue} · ${entry.entityId ?? entry.changeId}'),
                subtitle: Text('${entry.lastErrorCode ?? 'rejected'}：${entry.lastErrorMessage ?? '没有错误详情'}'
                    '${permission.data == false ? '\n缺少明确拒绝回执；请保留记录核对，不能假定未执行。' : ''}'),
                trailing: TextButton(
                  onPressed: permission.data != true || engine == null || api == null || deviceId == null ||
                      _working || _resolvingRemoteConflictId != null
                      ? null : () => _abandonRejected(entry, engine, api, deviceId),
                  child: const Text('放弃此变更'),
                ),
              ),
            ),
          ],
        )));
      },
    );
  }

  Future<void> _abandonRejected(SyncOutboxEntry entry, SyncEngine engine, NasSyncApi api, String deviceId) async {
    final outcomeWarning = const {'HA_UNAVAILABLE', 'HA_AUDIT_FAILURE'}.contains(entry.lastErrorCode) ||
        (entry.lastErrorCode == 'INVALID_LOCAL_CHANGE' && entry.attemptCount > 1)
        ? '原请求结果可能未知，请先核实 NAS 或设备的实际状态。继续仅撤回这条请求，不会撤销设备动作。'
        : '已收到拒绝或本地无法发送的证据。';
    final accepted = await showDialog<bool>(context: context, builder: (context) => AlertDialog(
      title: const Text('放弃被拒绝的变更？'),
      content: Text('$outcomeWarning继续将放弃这条本地意图，并获取 NAS 最新权威快照撤销相应本地变更。'
          '其他尚未解决的操作仍会阻止覆盖；原请求和拒绝回执会保留，库存及 Home Assistant 操作不会重新执行。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认放弃并恢复')),
      ],
    ));
    if (accepted != true || !mounted) return;
    if (!_isCurrentEngine(engine) || !identical(ref.read(nasSyncApiProvider), api) ||
        ref.read(nasAccountProvider).family.familyId != entry.scopeId ||
        ref.read(nasAccountProvider).devices.currentDeviceId != deviceId) {
      return;
    }
    final repository = SyncOutboxRepository(ref.read(databaseProvider));
    setState(() { _working = true; _message = null; });
    try {
      api.assertCurrentSession();
      await repository.abandonRejected(scopeId: entry.scopeId, changeId: entry.changeId);
      if (!_isCurrentEngine(engine)) return;
      ref.invalidate(syncConflictsProvider(entry.scopeId));
      setState(() => _message = '放弃确认已保存；正在恢复 NAS 最新状态。');
      await engine.runOnce();
      if (_isCurrentEngine(engine)) {
        final refresh = await repository.getConflictResolutionRefreshToken(entry.scopeId);
        setState(() => _message = refresh == null ? '已按 NAS 最新快照恢复；原拒绝记录保留供核对。'
            : '放弃确认已保存；仍需解决其他变更或恢复网络后获取最新快照。');
      }
    } catch (error) {
      if (_isCurrentEngine(engine)) setState(() => _message = '恢复尚未完成，现场已保留：$error');
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  Widget _buildRemoteConflictSection(
    BuildContext context,
    Future<NasSyncConflictListResponse>? remoteFuture,
    NasSyncApi? syncApi,
    String? deviceId,
    AsyncValue<List<SyncConflictEntry>> localConflicts,
  ) {
    final title = Text('远端冲突与待恢复回执', style: Theme.of(context).textTheme.titleSmall);
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
              final error = snapshot.error;
              return Text('读取远端冲突失败：${error is NasApiError ? error.message : '请稍后重试。'}');
            }
            final response = snapshot.data;
            if (response == null || response.conflicts.isEmpty) {
              return const Text('当前没有开放的远端冲突或待恢复回执。');
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
                      child: Text('远端记录超过单次显示上限，开放冲突与已解决回执各读取最近 200 条；更早回执尚未匹配，本地未结算记录仍保留。'),
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
              if (conflict.status == 'resolved')
                _buildSettlementRecoveryAction(
                  conflict, deviceId,
                  localConflicts.valueOrNull ?? const <SyncConflictEntry>[],
                )
              else ...[
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
              if (canResolveRemotely && remote.status == 'resolved')
                _buildSettlementRecoveryAction(remote, deviceId, [conflict])
              else ...[
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
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildSettlementRecoveryAction(
    NasSyncConflictDetail remote,
    String deviceId,
    List<SyncConflictEntry> locals,
  ) {
    final action = remote.resolution?['action'];
    final supported = action == 'keep_local' || action == 'keep_remote';
    final working = _resolvingRemoteConflictId != null;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(supported
            ? 'NAS 已按“${action == 'keep_local' ? '保留本地' : '保留远端'}”解决；仅恢复本地结算，不再执行远端变更。'
            : 'NAS 已解决，但原动作不支持恢复；本地冲突继续保留。'),
        FilledButton.tonal(
          onPressed: !supported || working ? null : () => _resolveRemoteConflict(
            conflict: remote, deviceId: deviceId, localConflicts: locals,
            action: action as String,
          ),
          child: const Text('按原动作恢复本地结算'),
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
        child: Text('$label：$compact', style: const TextStyle(fontSize: MomoTextSize.caption)),
      ),
    );
  }

  bool _isCurrentEngine(SyncEngine engine) =>
      mounted && identical(ref.read(syncEngineProvider), engine);

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
    final scopeId = ref.read(nasAccountProvider).family.familyId;
    final repository = SyncOutboxRepository(ref.read(databaseProvider));
    final response = await api.listConflicts(
      deviceId: deviceId, status: 'open', limit: 200,
    );
    final recovery = <NasSyncConflictDetail>[];
    final locals = scopeId == null ? const <SyncConflictEntry>[] :
        await repository.listUnsettledLinkedConflicts(scopeId: scopeId);
    var recoveryHasMore = false;
    if (scopeId != null && locals.isNotEmpty) {
      final changeIds = <String>{
        for (final local in locals) ...[local.changeId, if (local.outboxChangeId != null) local.outboxChangeId!],
      };
      // Keep the existing bounded list behavior; do not expand full history.
      final resolved = await api.listConflicts(deviceId: deviceId, status: 'resolved', limit: 200);
      recoveryHasMore = resolved.hasMore;
      for (final remote in resolved.conflicts) {
        if (remote.status == 'resolved' && changeIds.contains(remote.changeId) &&
            locals.any((local) => local.entity == remote.entity && local.entityId == remote.entityId &&
                (local.changeId == remote.changeId || local.outboxChangeId == remote.changeId))) {
          recovery.add(remote);
        }
      }
    }
    final combined = NasSyncConflictListResponse(
      conflicts: [...response.conflicts, ...recovery], hasMore: response.hasMore || recoveryHasMore,
    );
    if (mounted && identical(_remoteConflictsApi, api) &&
        _remoteConflictsDeviceId == deviceId &&
        ref.read(nasAccountProvider).family.familyId == scopeId) {
      setState(() {
        _remoteConflicts = combined.conflicts;
        _recoveryLocals = locals;
        _recoveryScopeId = scopeId;
      });
    }
    return combined;
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
      if (remote.entity == local.entity && remote.entityId == local.entityId &&
          (remote.changeId == local.changeId ||
              (remote.changeId != null && remote.changeId == local.outboxChangeId))) {
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
      if (remote.entity == local.entity && remote.entityId == local.entityId &&
          (remote.changeId == local.changeId ||
              (remote.changeId != null && remote.changeId == local.outboxChangeId))) {
        return local;
      }
    }
    return null;
  }

  bool _matchesResolvedReceipt(
    NasSyncConflictDetail requested,
    NasSyncConflictDetail receipt,
  ) => receipt.status == 'resolved' &&
      receipt.conflictId == requested.conflictId && receipt.changeId == requested.changeId &&
      receipt.entity == requested.entity && receipt.entityId == requested.entityId &&
      (requested.operation == null || receipt.operation == requested.operation) &&
      (receipt.resolution?['action'] == 'keep_local' || receipt.resolution?['action'] == 'keep_remote');

  void _retainResolvedReceipt(NasSyncConflictDetail receipt) {
    if (!mounted) return;
    setState(() {
      _remoteConflicts = [
        for (final remote in _remoteConflicts)
          if (remote.conflictId != receipt.conflictId) remote,
        receipt,
      ];
      _remoteConflictsFuture = Future.value(NasSyncConflictListResponse(
        conflicts: _remoteConflicts, hasMore: false,
      ));
    });
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
    final account = ref.read(nasAccountProvider);
    final scopeId = account.family.familyId;
    final changeId = conflict.changeId;
    if (api == null || scopeId == null ||
        account.devices.currentDeviceId != deviceId) {
      setState(() => _message = 'NAS 会话已失效，无法解决远端冲突。');
      return;
    }
    if (changeId == null || changeId.trim().isEmpty ||
        conflict.conflictId.trim().isEmpty ||
        (action != 'keep_local' && action != 'keep_remote')) {
      setState(() => _message = '冲突标识或解决动作无效，本地冲突仍保留。');
      return;
    }
    // Capture the persistence boundary before network I/O. A disposed page
    // must not lose a valid receipt; a switched family must not receive it.
    final repository = SyncOutboxRepository(ref.read(databaseProvider));
    setState(() {
      _resolvingRemoteConflictId = conflict.conflictId;
      _message = null;
    });
    NasSyncConflictResolveResponse response;
    try {
      if (conflict.status == 'resolved') {
        // Re-read via the existing GET endpoint; cached/list evidence must not
        // permit switching the original action or executing another mutation.
        final receipt = await api.getConflict(deviceId: deviceId, conflictId: conflict.conflictId);
        if (!_matchesResolvedReceipt(conflict, receipt) || receipt.resolution?['action'] != action) {
          throw StateError('NAS 已解决回执或原动作不匹配，本地冲突仍保留。');
        }
        response = NasSyncConflictResolveResponse(conflict: receipt, accepted: true);
      } else {
        response = await api.resolveConflict(
          NasSyncConflictResolveRequest(
            deviceId: deviceId, conflictId: conflict.conflictId,
            action: action, expectedVersion: conflict.serverVersion ?? 0,
          ),
        );
      }
    } catch (error) {
      if (error is NasApiError &&
          (error.code == 'CONFLICT_ALREADY_RESOLVED' || error.isRetryable)) {
        try {
          final receipt = await api.getConflict(deviceId: deviceId, conflictId: conflict.conflictId);
          if (!_matchesResolvedReceipt(conflict, receipt)) {
            throw StateError('NAS 已解决回执不匹配，本地冲突仍保留。');
          }
          if (mounted && ref.read(nasAccountProvider).family.familyId == scopeId &&
              ref.read(nasAccountProvider).devices.currentDeviceId == deviceId &&
              identical(ref.read(nasSyncApiProvider), api)) {
            _retainResolvedReceipt(receipt);
          }
          if (receipt.resolution?['action'] != action) {
            throw StateError('NAS 原解决动作不同，请按回执原动作恢复本地结算。');
          }
          response = NasSyncConflictResolveResponse(conflict: receipt, accepted: true);
        } catch (readError) {
          if (mounted) {
            setState(() {
              _message = '读取已解决回执失败，本地冲突仍保留：$readError';
              _resolvingRemoteConflictId = null;
            });
          }
          return;
        }
      } else {
        if (mounted) {
          setState(() {
            _message = '远端冲突解决失败，本地冲突仍保留：$error';
            _resolvingRemoteConflictId = null;
          });
        }
        return;
      }
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

    try {
      if (response.conflict.conflictId != conflict.conflictId ||
          response.conflict.changeId != changeId ||
          response.conflict.entity != conflict.entity ||
          response.conflict.entityId != conflict.entityId ||
          response.conflict.status != 'resolved' ||
          response.conflict.resolution?['action'] != action ||
          (conflict.operation != null && response.conflict.operation != conflict.operation)) {
        throw StateError('NAS 冲突解决回执与请求不匹配。');
      }
      if (mounted && (ref.read(nasAccountProvider).family.familyId != scopeId ||
          ref.read(nasAccountProvider).devices.currentDeviceId != deviceId ||
          !identical(ref.read(nasSyncApiProvider), api))) {
        throw StateError('NAS 会话或家庭已切换，请在原家庭重新确认结算。');
      }
      await repository.transaction(() async {
        final local = await repository.getConflictByChangeId(scopeId: scopeId, changeId: changeId) ??
            _matchingLocalConflict(localConflicts, conflict);
        // Remote-only conflicts still need a durable receipt and fresh snapshot.
        // This is an audit of a real NAS resolution, not a fake business apply.
        final id = local?.id ?? await repository.recordConflict(SyncConflictDraft(
          scopeId: scopeId,
          changeId: changeId,
          entity: conflict.entity,
          entityId: conflict.entityId,
          reason: conflict.reason,
          serverVersion: conflict.serverVersion,
          serverPayloadJson: conflict.serverPayload == null ? null : jsonEncode(conflict.serverPayload),
          clientPayloadJson: conflict.clientPayload == null ? null : jsonEncode(conflict.clientPayload),
        ));
        await repository.settleOutboxConflict(
          conflictId: id,
          scopeId: scopeId,
          changeId: changeId,
          remoteConflictId: conflict.conflictId,
          action: action,
          response: response,
        );
      });
    } catch (error) {
      if (mounted && ref.read(nasAccountProvider).family.familyId == scopeId &&
          ref.read(nasAccountProvider).devices.currentDeviceId == deviceId &&
          identical(ref.read(nasSyncApiProvider), api) &&
          _matchesResolvedReceipt(conflict, response.conflict)) {
        _retainResolvedReceipt(response.conflict);
      }
      if (mounted) {
        setState(() {
          _message = '远端已解决，但本地结算未完成，本地冲突仍保留待处理：$error';
          _resolvingRemoteConflictId = null;
        });
      }
      return;
    }

    if (!mounted) return; // The durable refresh token survives leaving the page.
    ref.invalidate(syncConflictsProvider(scopeId));
    setState(() {
      _remoteConflicts = _remoteConflicts
          .where((item) => item.conflictId != conflict.conflictId)
          .toList(growable: false);
      _remoteConflictsFuture = null;
      _recoveryLocals = _recoveryLocals.where((local) =>
          local.changeId != changeId && local.outboxChangeId != changeId).toList(growable: false);
      _message = '远端已解决，本地结算已保存；等待获取 NAS 最新快照。';
    });
    try {
      // Do not bootstrap here: that would change the user's confirmed mode.
      // Engine consumes the resolution refresh token even on an empty pull.
      final current = ref.read(nasAccountProvider);
      final engine = ref.read(syncEngineProvider);
      if (engine != null && current.family.familyId == scopeId &&
          current.devices.currentDeviceId == deviceId &&
          identical(ref.read(nasSyncApiProvider), api)) {
        await ref.read(syncSchedulerProvider).runNow();
        final pendingRefresh = await repository.getConflictResolutionRefreshToken(scopeId);
        if (mounted && pendingRefresh == null) {
          setState(() => _message = '远端已解决，本地结算及最新快照同步已完成。');
        }
      }
    } catch (error) {
      if (mounted) {
        setState(() => _message = '本地结算已保存，最新快照同步尚未完成，稍后可重试：$error');
      }
    } finally {
      if (mounted) setState(() => _resolvingRemoteConflictId = null);
    }
  }

  String _formatDate(DateTime value) {
    final local = value.toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${two(local.month)}-${two(local.day)} ${two(local.hour)}:${two(local.minute)}';
  }
}
