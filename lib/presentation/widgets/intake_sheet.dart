import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/inventory_models.dart';
import '../controllers/providers.dart';

class IntakeSheet extends ConsumerStatefulWidget {
  const IntakeSheet({super.key});

  @override
  ConsumerState<IntakeSheet> createState() => _IntakeSheetState();
}

class _IntakeSheetState extends ConsumerState<IntakeSheet> {
  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _specification = TextEditingController();
  final _quantity = TextEditingController(text: '1');
  final _location = TextEditingController();
  final _barcode = TextEditingController();
  final _batchNo = TextEditingController();
  final _threshold = TextEditingController(text: '1');
  String _category = '药品保健';
  DateTime? _productionDate;
  DateTime? _expiryDate;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _brand.dispose();
    _specification.dispose();
    _quantity.dispose();
    _location.dispose();
    _barcode.dispose();
    _batchNo.dispose();
    _threshold.dispose();
    super.dispose();
  }

  Future<void> _pickDate(bool isExpiry) async {
    final initial = (isExpiry ? _expiryDate : _productionDate) ?? DateTime.now();
    final selected = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2000),
      lastDate: DateTime(2100),
      helpText: isExpiry ? '选择到期日期' : '选择生产日期',
    );
    if (selected != null && mounted) {
      setState(() {
        if (isExpiry) {
          _expiryDate = selected;
        } else {
          _productionDate = selected;
        }
      });
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      await ref.read(inventoryServiceProvider).intake(
            IntakeDraft(
              name: _name.text,
              category: _category,
              quantity: int.parse(_quantity.text),
              brand: _brand.text,
              specification: _specification.text,
              barcode: _barcode.text,
              location: _location.text,
              batchNo: _batchNo.text,
              lowStockThreshold: int.parse(_threshold.text),
              productionDate: _productionDate,
              expiryDate: _expiryDate,
            ),
          );
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('已入库。')));
    } catch (error) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$error')));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final bottom = MediaQuery.viewInsetsOf(context).bottom;
    return SafeArea(
      top: false,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 12, 20, bottom + 20),
        child: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Center(
                  child: Container(
                    width: 44,
                    height: 4,
                    decoration: BoxDecoration(
                      color: Theme.of(context).colorScheme.outlineVariant,
                      borderRadius: BorderRadius.circular(99),
                    ),
                  ),
                ),
                const SizedBox(height: 18),
                Text('手动入库', style: Theme.of(context).textTheme.headlineSmall),
                const SizedBox(height: 6),
                Text('无到期日期的批次可以正常管理，但不会产生效期提醒。',
                    style: Theme.of(context).textTheme.bodySmall),
                const SizedBox(height: 16),
                TextFormField(
                  controller: _name,
                  autofocus: true,
                  decoration: const InputDecoration(labelText: '物品名称 *'),
                  validator: (value) => value == null || value.trim().isEmpty ? '请填写物品名称' : null,
                ),
                const SizedBox(height: 10),
                DropdownButtonFormField<String>(
                  value: _category,
                  decoration: const InputDecoration(labelText: '分类'),
                  items: const ['药品保健', '食品生鲜', '美妆个护', '母婴用品', '其他物品']
                      .map((label) => DropdownMenuItem(value: label, child: Text(label)))
                      .toList(),
                  onChanged: (value) => setState(() => _category = value ?? _category),
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: TextFormField(controller: _brand, decoration: const InputDecoration(labelText: '品牌'))),
                    const SizedBox(width: 10),
                    Expanded(child: TextFormField(controller: _specification, decoration: const InputDecoration(labelText: '规格'))),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(
                      child: TextFormField(
                        controller: _quantity,
                        decoration: const InputDecoration(labelText: '入库数量 *'),
                        keyboardType: TextInputType.number,
                        validator: _positiveIntegerValidator,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: TextFormField(
                        controller: _threshold,
                        decoration: const InputDecoration(labelText: '低库存阈值 *'),
                        keyboardType: TextInputType.number,
                        validator: _positiveIntegerValidator,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                TextFormField(controller: _location, decoration: const InputDecoration(labelText: '存放位置')),
                const SizedBox(height: 10),
                TextFormField(controller: _barcode, decoration: const InputDecoration(labelText: '条码')),
                const SizedBox(height: 10),
                TextFormField(controller: _batchNo, decoration: const InputDecoration(labelText: '批次号')),
                const SizedBox(height: 8),
                _DateField(
                  label: '生产日期',
                  value: _productionDate,
                  onTap: () => _pickDate(false),
                  onClear: () => setState(() => _productionDate = null),
                ),
                const SizedBox(height: 4),
                _DateField(
                  label: '到期日期（可不填）',
                  value: _expiryDate,
                  onTap: () => _pickDate(true),
                  onClear: () => setState(() => _expiryDate = null),
                ),
                const SizedBox(height: 18),
                SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    onPressed: _saving ? null : _submit,
                    icon: _saving
                        ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2))
                        : const Icon(Icons.inventory_2),
                    label: Text(_saving ? '正在保存…' : '确认入库'),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String? _positiveIntegerValidator(String? value) {
    final parsed = int.tryParse(value ?? '');
    return parsed == null || parsed < 1 ? '请输入大于 0 的整数' : null;
  }
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap, required this.onClear});

  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final selected = value == null ? '未设置' : '${value!.year}-${value!.month.toString().padLeft(2, '0')}-${value!.day.toString().padLeft(2, '0')}';
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      tileColor: Theme.of(context).colorScheme.surface,
      title: Text(label),
      subtitle: Text(selected),
      leading: const Icon(Icons.event_outlined),
      onTap: onTap,
      trailing: value == null ? null : IconButton(onPressed: onClear, icon: const Icon(Icons.clear)),
    );
  }
}
