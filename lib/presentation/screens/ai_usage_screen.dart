import '../../app/momo_typography.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/ai_usage_models.dart';
import '../controllers/providers.dart';
import '../widgets/momo_glass_components.dart';
import '../widgets/momo_floating_dock.dart';

class AiUsageScreen extends ConsumerStatefulWidget {
  const AiUsageScreen({super.key});

  @override
  ConsumerState<AiUsageScreen> createState() => _AiUsageScreenState();
}

class _AiUsageScreenState extends ConsumerState<AiUsageScreen> {
  int _page = 0;
  int _pageSize = 20;
  int _selectedFilterIndex = 0; // 0: 当日, 1: 近7天, 2: 近30天, 3: 全部

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final usageLogs = ref.watch(aiUsageLogsProvider).valueOrNull ?? const <AiUsageRecord>[];
    final filteredLogs = _filterLogs(usageLogs, _selectedFilterIndex);
    final pageCount = (filteredLogs.length / _pageSize).ceil().clamp(1, 1000000);
    final page = _page.clamp(0, pageCount - 1);
    final pageLogs = filteredLogs.skip(page * _pageSize).take(_pageSize);
    final summary = AiUsageSummary.aggregate(filteredLogs);

    return Scaffold(
      appBar: MomoGlassAppBar(
        title: const Text('AI 用量统计与日志'),
        actions: [
          if (usageLogs.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_sweep_outlined),
              tooltip: '清空日志',
              onPressed: () async {
                final confirm = await showDialog<bool>(
                  context: context,
                  builder: (ctx) => AlertDialog(
                    title: const Text('确认清空所有 AI 用量日志？'),
                    actions: [
                      TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
                      TextButton(
                        onPressed: () => Navigator.pop(ctx, true),
                        child: Text('清空', style: TextStyle(color: scheme.error)),
                      ),
                    ],
                  ),
                );
                if (confirm == true) {
                  await ref.read(aiUsageServiceProvider).clearLogs();
                }
              },
            ),
        ],
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(16, 16, 16, 16 + MomoDockInsets.bottomOf(context)),
        children: [
          // 时间段切换 Tab
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<int>(
              showSelectedIcon: false,
              segments: const [
                ButtonSegment(value: 0, label: Text('当日')),
                ButtonSegment(value: 1, label: Text('近7天')),
                ButtonSegment(value: 2, label: Text('近30天')),
                ButtonSegment(value: 3, label: Text('全部')),
              ],
              selected: {_selectedFilterIndex},
              onSelectionChanged: (set) {
                setState(() {
                  _selectedFilterIndex = set.first;
                  _page = 0;
                });
              },
            ),
          ),
          const SizedBox(height: 16),

          // 核心汇总数据卡片
          MomoGlassCard(
            frosted: false,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Wrap(
                  spacing: 16,
                  runSpacing: 8,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    const Text('Token 消耗概览', style: TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.title)),
                    Text('${summary.requestCount} 次调用', style: TextStyle(color: scheme.primary, fontWeight: FontWeight.bold)),
                  ],
                ),
                const SizedBox(height: 16),
                Row(
                  children: [
                    _buildStatMetric('总 Token', summary.totalTokens.toString(), scheme.primary),
                    _buildStatMetric('输入 Token', summary.promptTokens.toString(), scheme.onSurface),
                    _buildStatMetric('输出 Token', summary.completionTokens.toString(), scheme.onSurface),
                  ],
                ),
                const Divider(height: 24),
                Row(
                  children: [
                    _buildStatMetric('缓存读取', summary.cachedReadTokens.toString(), scheme.onSurface),
                    _buildStatMetric('缓存写入', summary.cachedWriteTokens.toString(), scheme.onSurface),
                    _buildStatMetric('缓存占比', '${(summary.cacheRatio * 100).toStringAsFixed(1)}%', scheme.onSurface),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 20),

          // 明细列表标题
          const Text('调用明细记录', style: TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.title)),
          const SizedBox(height: 8),

          Wrap(
            spacing: 8, crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text('共 ${filteredLogs.length} 条'),
              const Text('每页'),
              DropdownButton<int>(
                value: _pageSize,
                items: [10, 20, 50, 100].map((size) => DropdownMenuItem(
                    value: size, child: Text('$size 条'))).toList(),
                onChanged: (size) { if (size != null) setState(() { _pageSize = size; _page = 0; }); },
              ),
              IconButton(tooltip: '上一页', icon: const Icon(Icons.chevron_left),
                onPressed: page > 0 ? () => setState(() => _page = page - 1) : null),
              Text('${page + 1} / $pageCount'),
              IconButton(tooltip: '下一页', icon: const Icon(Icons.chevron_right),
                onPressed: page + 1 < pageCount ? () => setState(() => _page = page + 1) : null),
            ],
          ),
          if (filteredLogs.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.query_builder, size: 48, color: scheme.onSurfaceVariant),
                      const SizedBox(height: 8),
                      Text('该时间段内暂无 AI 调用记录', style: TextStyle(color: scheme.onSurfaceVariant)),
                    ],
                  ),
                ),
              ),
            )
          else
            ...pageLogs.map((log) => _buildLogCard(log, scheme)),

        ],
      ),
    );
  }

  Widget _buildStatMetric(String title, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: TextStyle(fontSize: MomoTextSize.caption, color: Theme.of(context).colorScheme.onSurfaceVariant)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(fontSize: MomoTextSize.section, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard(AiUsageRecord log, ColorScheme scheme) {
    final timeStr = '${log.timestamp.month.toString().padLeft(2, '0')}-${log.timestamp.day.toString().padLeft(2, '0')} ${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}';
    final isQa = log.purpose == 'qa';

    return MomoGlassCard(
      key: ValueKey('ai-log-${log.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      frosted: false,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Wrap(
            spacing: 8,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: scheme.onSurface.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  isQa ? 'AI问答' : 'OCR草稿',
                  style: TextStyle(
                    fontSize: MomoTextSize.caption,
                    fontWeight: FontWeight.bold,
                    color: scheme.onSurface,
                  ),
                ),
              ),
              Text(
                  log.model,
                  style: const TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.body),
                  overflow: TextOverflow.ellipsis,
                ),
              Text(timeStr, style: TextStyle(fontSize: MomoTextSize.caption, color: scheme.onSurfaceVariant)),
            ],
          ),
          const SizedBox(height: 8),
          Text('${log.status == 'failure' ? '失败' : '成功'} · ${log.endpointType} · '
              '${log.providerLevel ?? 'primary'} · ${log.elapsedMs} ms'),
          if (log.status == 'failure')
            Text(log.failureReason ?? '请求失败', style: TextStyle(color: scheme.error)),
          Wrap(
            spacing: 12,
            runSpacing: 4,
            children: [
              Text('总消耗: ${log.effectiveTotal}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: MomoTextSize.body)),
              Text('输入: ${log.promptTokens} / 输出: ${log.completionTokens}', style: TextStyle(fontSize: MomoTextSize.caption, color: scheme.onSurfaceVariant)),
              if (log.cachedReadTokens > 0)
                Text('缓存读取: ${log.cachedReadTokens}', style: TextStyle(fontSize: MomoTextSize.caption, color: scheme.onSurfaceVariant)),
            ],
          ),
        ],
      ),
    );
  }

  List<AiUsageRecord> _filterLogs(List<AiUsageRecord> logs, int filterIndex) {
    if (filterIndex == 3) return logs;
    final now = DateTime.now();
    final todayStart = DateTime(now.year, now.month, now.day);
    if (filterIndex == 0) {
      return logs.where((l) => l.timestamp.isAfter(todayStart)).toList();
    }
    if (filterIndex == 1) {
      final sevenDaysAgo = todayStart.subtract(const Duration(days: 7));
      return logs.where((l) => l.timestamp.isAfter(sevenDaysAgo)).toList();
    }
    if (filterIndex == 2) {
      final thirtyDaysAgo = todayStart.subtract(const Duration(days: 30));
      return logs.where((l) => l.timestamp.isAfter(thirtyDaysAgo)).toList();
    }
    return logs;
  }
}
