import 'package:flutter/material.dart';

import '../../domain/models/nas_import_models.dart';

/// A separate read-only archive; paging never invokes inventory commands.
class InitialImportHistoryDialog extends StatefulWidget {
  const InitialImportHistoryDialog({super.key, required this.loadPage,
    required this.isSessionCurrent, required this.familyId});

  final Future<NasImportHistoryPage> Function(int after, int until) loadPage;
  final bool Function() isSessionCurrent;
  final String familyId;

  @override
  State<InitialImportHistoryDialog> createState() => _InitialImportHistoryDialogState();
}

class _InitialImportHistoryDialogState extends State<InitialImportHistoryDialog> {
  NasImportHistoryPage? _page;
  bool _loading = true;
  bool _sessionChanged = false;
  String? _error;
  int _pageNumber = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final previous = _page;
    final after = previous?.nextCursor ?? 0;
    final until = previous?.until ?? 0;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      if (!widget.isSessionCurrent()) throw StateError('NAS 会话已改变，请返回原身份重新打开归档。');
      final page = await widget.loadPage(after, until);
      if (!mounted) return;
      if (!widget.isSessionCurrent()) {
        setState(() {
          _page = null;
          _sessionChanged = true;
        });
        throw StateError('NAS 会话已改变，请返回原身份重新打开归档。');
      }
      if ((previous != null && page.until != until) || page.nextCursor < after ||
          page.nextCursor > page.until || (page.hasMore && page.nextCursor <= after)) {
        throw const FormatException('历史分页高水位改变或游标未正确推进。');
      }
      var cursor = after;
      for (final record in page.records) {
        final value = record['cursor'];
        if (value is! int || value <= cursor || value > page.until) {
          throw const FormatException('历史页包含重复、乱序或越界条目。');
        }
        cursor = value;
      }
      if ((page.hasMore && cursor != page.nextCursor) ||
          (!page.hasMore && page.nextCursor != page.until)) {
        throw const FormatException('历史分页结束标记与游标不一致。');
      }
      setState(() {
        _page = page;
        _pageNumber++;
      });
    } catch (error) {
      if (mounted) {
        setState(() {
          if (!widget.isSessionCurrent()) {
            _page = null;
            _sessionChanged = true;
          }
          _error = '读取历史归档失败：$error';
        });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final page = _page;
    return AlertDialog(
      title: const Text('NAS 独立历史归档'),
      content: SizedBox(
        width: 480,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('家庭：${widget.familyId}'),
            const Text('这是旧记录的独立归档，查看不会再次扣减库存。来源操作人和时区未记录时不作推断。'),
            const SizedBox(height: 8),
            if (_loading) const LinearProgressIndicator(),
            if (_error != null) Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
            if (page != null) ...[
              Text('第 $_pageNumber 页 · 截止游标 ${page.until}'),
              Expanded(
                child: page.records.isEmpty
                    ? const Center(child: Text('当前没有已归档的旧历史。'))
                    : ListView.separated(
                        itemCount: page.records.length,
                        separatorBuilder: (_, _) => const Divider(),
                        itemBuilder: (_, index) => _record(page.records[index]),
                      ),
              ),
            ],
          ],
        ),
      ),
      actions: [
        if (!_sessionChanged && !_loading && (_error != null || page?.hasMore == true))
          TextButton(onPressed: _load, child: Text(_error != null ? '重试原页' : '下一页')),
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('关闭')),
      ],
    );
  }

  Widget _record(Map<String, dynamic> record) {
    final type = switch (record['type']) {
      'intake' => '入库', 'restock' => '补充', 'consume' => '消费',
      'discard' => '报废', 'adjust' => '调整', _ => '${record['type']}',
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text('$type · ${record['quantity']} 件'),
        Text('商品来源 ID：${record['product_id']}'),
        if (record['batch_id'] != null) Text('批次来源 ID：${record['batch_id']}'),
        Text('发生时间：${record['occurred_at']}'),
        Text('来源时区：${record['source_time_zone'] ?? '未记录'}'),
        if (record['note'] != null) Text('备注：${record['note']}'),
      ],
    );
  }
}
