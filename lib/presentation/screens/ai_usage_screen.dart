import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../../domain/models/ai_usage_models.dart';
import '../controllers/providers.dart';

class AiUsageScreen extends ConsumerStatefulWidget {
  const AiUsageScreen({super.key});

  @override
  ConsumerState<AiUsageScreen> createState() => _AiUsageScreenState();
}

class _AiUsageScreenState extends ConsumerState<AiUsageScreen> {
  int _selectedFilterIndex = 0; // 0: 当日, 1: 近7天, 2: 近30天, 3: 全部

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final usageLogs = ref.watch(aiUsageLogsProvider).valueOrNull ?? const <AiUsageRecord>[];
    final filteredLogs = _filterLogs(usageLogs, _selectedFilterIndex);
    final summary = AiUsageSummary.aggregate(filteredLogs);

    return Scaffold(
      appBar: AppBar(
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
                        child: const Text('清空', style: TextStyle(color: Colors.red)),
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
        padding: const EdgeInsets.all(16),
        children: [
          // 时间段切换 Tab
          SegmentedButton<int>(
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
              });
            },
          ),
          const SizedBox(height: 16),

          // 核心汇总数据卡片
          Card(
            color: palette.primary.withValues(alpha: 0.08),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(16),
              side: BorderSide(color: palette.primary.withValues(alpha: 0.2)),
            ),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      const Text('Token 消耗概览', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                      Text('${summary.requestCount} 次调用', style: TextStyle(color: palette.primary, fontWeight: FontWeight.bold)),
                    ],
                  ),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      _buildStatMetric('总 Token', summary.totalTokens.toString(), palette.primary),
                      _buildStatMetric('输入 Token', summary.promptTokens.toString(), Colors.blueGrey),
                      _buildStatMetric('输出 Token', summary.completionTokens.toString(), Colors.indigo),
                    ],
                  ),
                  const Divider(height: 24),
                  Row(
                    children: [
                      _buildStatMetric('缓存读取', summary.cachedReadTokens.toString(), Colors.teal),
                      _buildStatMetric('缓存写入', summary.cachedWriteTokens.toString(), Colors.amber.shade800),
                      _buildStatMetric('缓存占比', '${(summary.cacheRatio * 100).toStringAsFixed(1)}%', Colors.purple),
                    ],
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 20),

          // 明细列表标题
          const Text('调用明细记录', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
          const SizedBox(height: 8),

          if (filteredLogs.isEmpty)
            Card(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 40),
                child: Center(
                  child: Column(
                    children: [
                      Icon(Icons.query_builder, size: 48, color: Colors.grey.shade400),
                      const SizedBox(height: 8),
                      const Text('该时间段内暂无 AI 调用记录', style: TextStyle(color: Colors.grey)),
                    ],
                  ),
                ),
              ),
            )
          else
            ...filteredLogs.map((log) => _buildLogCard(log, palette)),
        ],
      ),
    );
  }

  Widget _buildStatMetric(String title, String value, Color color) {
    return Expanded(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 12, color: Colors.grey)),
          const SizedBox(height: 4),
          Text(
            value,
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: color),
          ),
        ],
      ),
    );
  }

  Widget _buildLogCard(AiUsageRecord log, MomoPalette palette) {
    final timeStr = '${log.timestamp.month.toString().padLeft(2, '0')}-${log.timestamp.day.toString().padLeft(2, '0')} ${log.timestamp.hour.toString().padLeft(2, '0')}:${log.timestamp.minute.toString().padLeft(2, '0')}:${log.timestamp.second.toString().padLeft(2, '0')}';
    final isQa = log.purpose == 'qa';

    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: (isQa ? Colors.purple : Colors.blue).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    isQa ? 'AI问答' : 'OCR草稿',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: isQa ? Colors.purple : Colors.blue.shade800,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    log.model,
                    style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                Text(timeStr, style: const TextStyle(fontSize: 11, color: Colors.grey)),
              ],
            ),
            const SizedBox(height: 8),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text('总消耗: ${log.effectiveTotal}', style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                Text('输入: ${log.promptTokens} / 输出: ${log.completionTokens}', style: const TextStyle(fontSize: 12, color: Colors.grey)),
                if (log.cachedReadTokens > 0)
                  Text('缓存读取: ${log.cachedReadTokens}', style: const TextStyle(fontSize: 11, color: Colors.teal)),
              ],
            ),
          ],
        ),
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
