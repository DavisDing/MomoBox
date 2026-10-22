import 'package:flutter/material.dart';

import '../../domain/models/initial_import_models.dart';

/// Reviews the frozen inventory baseline, independently from ordinary sync.
class InitialImportReviewDialog extends StatefulWidget {
  const InitialImportReviewDialog({
    super.key,
    required this.preview,
    required this.confirmImport,
  });

  final InitialImportPreview preview;
  final bool confirmImport;

  @override
  State<InitialImportReviewDialog> createState() => _InitialImportReviewDialogState();
}

class _InitialImportReviewDialogState extends State<InitialImportReviewDialog> {
  bool _reviewed = false;

  @override
  Widget build(BuildContext context) {
    final preview = widget.preview;
    return AlertDialog(
      title: Text(widget.confirmImport ? '确认导入既有数据' : '审阅既有数据预检'),
      scrollable: true,
      content: SizedBox(
        width: 440,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('NAS：${preview.target.endpoint}'),
            Text('账号：${preview.target.userId}'),
            Text('家庭：${preview.target.familyId}'),
            Text('家庭时区：${preview.familyTimeZone}'),
            const SizedBox(height: 12),
            const Text('直接保留累计入库量和当前余量。旧历史单独归档，不再次扣减库存。生产日和到期日保留原年月日。'),
            const SizedBox(height: 8),
            Text('本次共 ${preview.totalCount} 条'),
            for (final entry in preview.counts.entries)
              Text('${initialImportCountLabel(entry.key)}：${entry.value}'),
            if (_datedBatches(preview).isNotEmpty) ...[
              const SizedBox(height: 12),
              Text('批次日期核对', style: Theme.of(context).textTheme.titleSmall),
              const Text('下列是当前保存的年月日。旧数据未记录原时区时，请对照原始资料核对；系统无法证明已丢失的日期来源。'),
              for (final batch in _datedBatches(preview))
                Padding(
                  padding: const EdgeInsets.only(top: 6),
                  child: Text('批次：${batch['batch_no'] ?? batch['id']}\n'
                    '生产日：${batch['produced_date'] ?? '未记录'} · 到期日：${batch['expiry_date'] ?? '无效期'}'),
                ),
            ],
            const SizedBox(height: 12),
            Text('分类映射', style: Theme.of(context).textTheme.titleSmall),
            if (preview.categories.isEmpty) const Text('没有需要导入的分类。'),
            for (final category in preview.categories)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                  '${category.sourceName} → ${_categoryActionLabel(category.action)}\n'
                  '${category.categoryId}'
                  '${category.reason == null ? '' : '\n${category.reason}'}',
                ),
              ),
            const SizedBox(height: 12),
            if (preview.exclusions.isNotEmpty) ...[
              Text('覆盖说明与排除项', style: Theme.of(context).textTheme.titleSmall),
              for (final exclusion in preview.exclusions) Text('• $exclusion'),
              const SizedBox(height: 8),
            ],
            if (preview.blockers.isNotEmpty) ...[
              Text('需要先处理', style: Theme.of(context).textTheme.titleSmall),
              for (final blocker in preview.blockers)
                Text('• $blocker', style: TextStyle(color: Theme.of(context).colorScheme.error)),
            ] else ...[
              Text(widget.confirmImport
                  ? '确认后会将这份已冻结的计划提交到 NAS。未知回执将按原计划恢复；暂停不能撤销 NAS 已接收的数据。'
                  : '下一步会把这份计划发送到 NAS 预检并保存待确认计划，正式导入还需要再次确认。'),
              CheckboxListTile(
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: _reviewed,
                onChanged: (value) => setState(() => _reviewed = value ?? false),
                title: const Text('我已核对目标家庭、分类、日期和覆盖范围'),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
        FilledButton(
          onPressed: preview.canPrepare && _reviewed ? () => Navigator.pop(context, true) : null,
          child: Text(widget.confirmImport ? '确认导入' : '提交预检并准备'),
        ),
      ],
    );
  }

  List<Map> _datedBatches(InitialImportPreview preview) {
    final raw = preview.manifest['product_batches'];
    if (raw is! List) return const [];
    return raw.whereType<Map>().where((batch) =>
      batch['produced_date'] != null || batch['expiry_date'] != null).toList(growable: false);
  }

  String _categoryActionLabel(InitialImportCategoryAction action) => switch (action) {
    InitialImportCategoryAction.create => '新建分类',
    InitialImportCategoryAction.reuse => '复用已有分类，保留颜色和排序',
    InitialImportCategoryAction.blocked => '映射待处理',
  };
}

String initialImportCountLabel(String key) => switch (key) {
  'categories' => '分类',
  'products' => '商品',
  'product_batches' => '批次',
  'shopping_items' => '采购',
  'reminder_settings' => '提醒策略',
  'history' => '历史归档',
  _ => key,
};
