import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../application/initial_import_service.dart';
import '../../domain/models/initial_import_models.dart';
import '../controllers/providers.dart';
import 'initial_import_history_dialog.dart';
import 'initial_import_review_dialog.dart';

/// Explicit first-import controls. Building the card never uploads a manifest.
class InitialImportCard extends ConsumerStatefulWidget {
  const InitialImportCard({super.key, this.disabled = false, required this.onBusyChanged});

  final bool disabled;
  final ValueChanged<bool> onBusyChanged;

  @override
  ConsumerState<InitialImportCard> createState() => _InitialImportCardState();
}

class _InitialImportCardState extends ConsumerState<InitialImportCard> {
  bool _busy = false;
  bool _pausing = false;
  String? _notice;

  bool _isCurrent(InitialImportService service) =>
      mounted && identical(ref.read(initialImportServiceProvider), service);

  @override
  Widget build(BuildContext context) {
    final service = ref.watch(initialImportServiceProvider);
    final progress = ref.watch(initialImportProgressProvider);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('导入既有库存与历史', style: Theme.of(context).textTheme.titleMedium),
            const SizedBox(height: 8),
            const Text('保留当前库存量，旧历史独立归档。先审阅分类和覆盖范围，再明确确认导入；登录和绑定不会自动上传。'),
            if (service == null) ...[
              const SizedBox(height: 8),
              const Text('请先完成登录、家庭、设备和本机数据归属确认。'),
            ],
            const SizedBox(height: 8),
            progress.when(
              loading: () => const LinearProgressIndicator(),
              error: (error, _) => Text('读取导入计划失败：$error'),
              data: (value) => _buildProgress(context, service, value),
            ),
            if (_notice != null) ...[
              const SizedBox(height: 8),
              Text(_notice!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildProgress(
    BuildContext context,
    InitialImportService? service,
    InitialImportProgress? progress,
  ) {
    final active = progress?.isActive == true;
    final enabled = !widget.disabled && !_busy;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (progress != null) ...[
          Text('状态：${_statusLabel(progress.status)}'),
          Text('家庭时区：${progress.familyTimeZone}'),
          Text('NAS 已接收 ${progress.acceptedCount} / ${progress.totalCount} 条'),
          if (progress.message != null) Text(progress.message!),
          if (progress.status == InitialImportStatus.awaitingSnapshot)
            const Text('NAS 已接收计划，仍需完成本机快照和历史恢复。'),
          if (progress.status == InitialImportStatus.completed)
            const Text('本次库存与历史归档已同步；覆盖限制和沿用远端的内容见下方说明。'),
          for (final exclusion in progress.exclusions) Text('覆盖说明：$exclusion'),
          const SizedBox(height: 8),
        ],
        if (!active)
          OutlinedButton.icon(
            onPressed: enabled && service != null ? () => _preview(service) : null,
            icon: const Icon(Icons.fact_check_outlined),
            label: const Text('预检既有数据'),
          ),
        if (progress != null && active) Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            if (progress.canResume || progress.status == InitialImportStatus.sending)
              FilledButton.icon(
                onPressed: enabled && service != null ? () => _resume(service) : null,
                icon: const Icon(Icons.play_arrow),
                label: Text(progress.status == InitialImportStatus.sending ? '核对原回执并继续' : '审阅并继续原计划'),
              ),
            if (_busy || progress.status == InitialImportStatus.sending)
              OutlinedButton(
                onPressed: service == null || widget.disabled || _pausing
                    ? null : () => _pause(service),
                child: const Text('暂停后续步骤'),
              ),
            if (progress.canAbandon)
              TextButton(
                onPressed: enabled && service != null ? () => _abandonPrepared(service) : null,
                child: const Text('结束未提交计划'),
              ),
          ],
        ),
        if (_busy) const Padding(
          padding: EdgeInsets.only(top: 8),
          child: LinearProgressIndicator(),
        ),
        TextButton.icon(
          onPressed: enabled && service != null ? () => _showHistory(service) : null,
          icon: const Icon(Icons.history),
          label: const Text('查看 NAS 独立历史归档'),
        ),
      ],
    );
  }

  Future<void> _withBusy(InitialImportService service, Future<void> Function() operation) async {
    if (_busy || widget.disabled || !_isCurrent(service)) return;
    setState(() {
      _busy = true;
      _notice = null;
    });
    widget.onBusyChanged(true);
    try {
      await operation();
    } catch (error) {
      if (_isCurrent(service)) setState(() => _notice = '导入未完成：$error');
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        widget.onBusyChanged(false);
      }
    }
  }

  Future<void> _preview(InitialImportService service) => _withBusy(service, () async {
    final preview = await service.preview();
    if (!_isCurrent(service)) return;
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => InitialImportReviewDialog(preview: preview, confirmImport: false),
    );
    if (accepted != true || !_isCurrent(service)) return;
    final result = await service.prepare(preview);
    if (_isCurrent(service)) {
      setState(() => _notice = result.status == InitialImportStatus.prepared
          ? 'NAS 预检已通过，计划已保存。请审阅并确认导入。'
          : 'NAS 预检状态：${_statusLabel(result.status)}。请查看计划说明。');
    }
  });

  Future<void> _resume(InitialImportService service) => _withBusy(service, () async {
    final preview = await service.readPreparedPreview();
    if (!_isCurrent(service)) return;
    if (preview == null) throw StateError('未找到原冻结计划，请重新读取导入状态。');
    final accepted = await showDialog<bool>(
      context: context,
      builder: (_) => InitialImportReviewDialog(preview: preview, confirmImport: true),
    );
    if (accepted != true || !_isCurrent(service)) return;
    await service.resume();
  });

  Future<void> _pause(InitialImportService service) async {
    if (_pausing || !_isCurrent(service)) return;
    setState(() => _pausing = true);
    try {
      await service.pause();
      if (_isCurrent(service)) {
        setState(() => _notice = '已请求暂停后续步骤；正在发送的请求仍可能被 NAS 接收。继续时将核对原回执。');
      }
    } catch (error) {
      if (_isCurrent(service)) setState(() => _notice = '暂停未完成：$error');
    } finally {
      if (mounted) setState(() => _pausing = false);
    }
  }

  Future<void> _abandonPrepared(InitialImportService service) => _withBusy(service, () async {
    final accepted = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('结束未提交计划'),
        content: const Text('仅在尚未发送正式导入时结束本机冻结，保留原计划记录。未知发送结果或已接收的计划不能撤销，必须继续核对原回执。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('结束未提交计划')),
        ],
      ),
    );
    if (accepted != true || !_isCurrent(service)) return;
    await service.abandonPrepared();
    if (_isCurrent(service)) setState(() => _notice = '未提交计划已结束，原记录已保留，可以重新预检。');
  });

  Future<void> _showHistory(InitialImportService service) => _withBusy(service, () async {
    final identity = ref.read(syncWorkspaceIdentityProvider);
    if (identity == null || !_isCurrent(service)) return;
    await showDialog<void>(
      context: context,
      builder: (_) => InitialImportHistoryDialog(
        familyId: identity.familyId,
        isSessionCurrent: () => _isCurrent(service) && service.isCurrent,
        loadPage: (after, until) => service.history(after: after, until: until),
      ),
    );
  });

  String _statusLabel(InitialImportStatus status) => switch (status) {
    InitialImportStatus.prepared => '待确认导入',
    InitialImportStatus.sending => '发送中或回执待核对',
    InitialImportStatus.awaitingSnapshot => '等待本机数据收敛',
    InitialImportStatus.completed => '库存与历史归档已完成',
    InitialImportStatus.paused => '已暂停',
    InitialImportStatus.blocked => '需要处理阻塞项',
    InitialImportStatus.abandoned => '未提交计划已结束',
  };
}
