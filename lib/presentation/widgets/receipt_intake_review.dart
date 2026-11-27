import 'package:flutter/material.dart';

import '../../domain/inventory/product_categories.dart';
import '../../domain/models/ai_action.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/recognition/ai_draft_parser.dart';
import '../../domain/recognition/ai_intake_limits.dart';

class ReceiptIntakeReview extends StatefulWidget {
  const ReceiptIntakeReview(this.items, {super.key});
  final List<ReceiptLine> items;

  @override
  State<ReceiptIntakeReview> createState() => _ReceiptIntakeReviewState();
}

class _ReceiptIntakeReviewState extends State<ReceiptIntakeReview> {
  final _form = GlobalKey<FormState>();
  late final _rows = widget.items.map(_ReceiptRow.new).toList();

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('核对小票商品'),
    scrollable: true,
    content: Form(
      key: _form,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in _rows) ...[
            CheckboxListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(row.name),
              value: row.selected,
              onChanged:
                  (selected) =>
                      setState(() => row.selected = selected ?? false),
            ),
            TextFormField(
              initialValue: row.name,
              enabled: row.selected,
              onChanged: (value) => row.name = value,
              decoration: const InputDecoration(labelText: '物品名称'),
              validator:
                  (value) =>
                      row.selected &&
                              (value == null ||
                                  value.trim().isEmpty ||
                                  value.runes.length > 255)
                          ? '请输入有效名称'
                          : null,
            ),
            TextFormField(
              initialValue: row.quantity,
              enabled: row.selected,
              onChanged: (value) => row.quantity = value,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: '数量（件）'),
              validator: (value) {
                if (!row.selected) return null;
                final quantity = int.tryParse(value?.trim() ?? '') ?? 0;
                return quantity < 1 || quantity > AiIntakeLimits.maxQuantity
                    ? '请输入 1–${AiIntakeLimits.maxQuantity} 的整数'
                    : null;
              },
            ),
            DropdownButtonFormField<String>(
              isExpanded: true,
              initialValue: row.category,
              decoration: const InputDecoration(labelText: '分类'),
              items: [
                for (final category in ProductCategories.values)
                  DropdownMenuItem(value: category, child: Text(category)),
              ],
              onChanged:
                  row.selected
                      ? (category) => row.category = category ?? row.category
                      : null,
            ),
            TextFormField(
              initialValue: row.expiryDate,
              enabled: row.selected,
              onChanged: (text) => row.expiryDate = text,
              decoration: const InputDecoration(
                labelText: '到期日（可选，YYYY-MM-DD）',
              ),
              validator: (value) {
                if (!row.selected || value == null || value.trim().isEmpty) {
                  return null;
                }
                try {
                  AiInventoryAction.date(value.trim());
                  return null;
                } on FormatException {
                  return '请输入有效日期';
                }
              },
            ),
            const SizedBox(height: 16),
          ],
        ],
      ),
    ),
    actions: [
      TextButton(
        onPressed: () => Navigator.pop(context),
        child: const Text('取消'),
      ),
      FilledButton(
        onPressed:
            _rows.any((row) => row.selected)
                ? () {
                  if (!_form.currentState!.validate()) return;
                  Navigator.pop(context, [
                    for (final row in _rows)
                      if (row.selected)
                        IntakeDraft(
                          name: row.name.trim(),
                          category: row.category,
                          quantity: int.parse(row.quantity.trim()),
                          expiryDate:
                              row.expiryDate.trim().isEmpty
                                  ? null
                                  : AiInventoryAction.date(
                                    row.expiryDate.trim(),
                                  ),
                        ),
                  ]);
                }
                : null,
        child: const Text('下一步'),
      ),
    ],
  );
}

class _ReceiptRow {
  _ReceiptRow(ReceiptLine item)
    : name = item.name,
      quantity = item.quantity?.toString() ?? '',
      category = item.category;

  String name;
  String quantity;
  String category;
  String expiryDate = '';
  bool selected = true;
}
