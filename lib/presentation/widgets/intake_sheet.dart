import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:uuid/uuid.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/recognition_models.dart';
import '../controllers/providers.dart';

class IntakeSheet extends ConsumerStatefulWidget {
  const IntakeSheet({this.initialName, this.initialCategory, this.initialQuantity = 1, super.key});

  final String? initialName;
  final String? initialCategory;
  final int initialQuantity;

  @override
  ConsumerState<IntakeSheet> createState() => _IntakeSheetState();
}

class _IntakeSheetState extends ConsumerState<IntakeSheet> {
  static const _categories = ['药品保健', '食品生鲜', '美妆个护', '母婴用品', '其他物品'];

  final _formKey = GlobalKey<FormState>();
  final _name = TextEditingController();
  final _brand = TextEditingController();
  final _specification = TextEditingController();
  final _quantity = TextEditingController(text: '1');
  final _location = TextEditingController();
  final _barcode = TextEditingController();
  final _batchNo = TextEditingController();
  final _threshold = TextEditingController(text: '1');
  final _shelfLife = TextEditingController();
  final _picker = ImagePicker();
  final _mediaDraftId = const Uuid().v4();
  String _category = '药品保健';
  ShelfLifeUnit _shelfLifeUnit = ShelfLifeUnit.days;
  String _dateSource = 'manual';
  String _datePrecision = 'day';
  DateTime? _productionDate;
  DateTime? _expiryDate;
  bool _saving = false;
  bool _recognizing = false;
  bool _parsingAi = false;

  @override
  void initState() {
    super.initState();
    _name.text = widget.initialName ?? '';
    _quantity.text = widget.initialQuantity.toString();
    if (widget.initialCategory != null && _categories.contains(widget.initialCategory)) {
      _category = widget.initialCategory!;
    }
  }

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
    _shelfLife.dispose();
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
        _dateSource = 'manual';
        _datePrecision = 'day';
        if (isExpiry) {
          _expiryDate = selected;
        } else {
          _productionDate = selected;
        }
      });
    }
  }

  Future<void> _scanBarcode() async {
    final barcode = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      useSafeArea: true,
      builder: (_) => const _BarcodeScannerSheet(),
    );
    if (barcode == null || !mounted) return;
    setState(() => _barcode.text = barcode);
    try {
      final result = await ref.read(barcodeLookupServiceProvider).lookup(barcode);
      if (!mounted) return;
      if (result == null) {
        _message('已识别条码；未命中本地缓存或未配置可用的条码 API，请继续手动填写。');
        return;
      }
      final apply = await _showBarcodeResult(result);
      if (apply == true && mounted) _applyBarcodeResult(result);
    } catch (error) {
      if (mounted) _message('条码已填写；信息查询失败：$error');
    }
  }

  Future<bool?> _showBarcodeResult(BarcodeLookupResult result) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('条码信息候选'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('来源：${result.source == 'external_api' ? '外部条码 API（已缓存）' : result.source}'),
              const SizedBox(height: 8),
              _CandidateLine('名称', result.name),
              _CandidateLine('品牌', result.brand),
              _CandidateLine('规格', result.specification),
              _CandidateLine('分类', result.category),
              const SizedBox(height: 8),
              const Text('确认后仅填入表单草稿，仍需点击“确认入库”才会写入库存。'),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('暂不使用')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('填入草稿')),
          ],
        ),
      );

  void _applyBarcodeResult(BarcodeLookupResult result) {
    setState(() {
      if (result.name != null) _name.text = result.name!;
      if (result.brand != null) _brand.text = result.brand!;
      if (result.specification != null) _specification.text = result.specification!;
      if (result.category != null) {
        _category = _categories.contains(result.category) ? result.category! : '其他物品';
      }
    });
  }

  Future<void> _attachImage(MediaAssetType type) async {
    final source = await showModalBottomSheet<ImageSource>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, ImageSource.camera),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, ImageSource.gallery),
            ),
          ],
        ),
      ),
    );
    if (source == null) return;
    try {
      final image = await _picker.pickImage(source: source, imageQuality: 100);
      if (image == null) return;
      await ref.read(mediaServiceProvider).attachImage(
            source: image,
            entityType: 'intake_draft',
            entityId: _mediaDraftId,
            type: type,
          );
      if (mounted) _message('${type.label}已保存到本机。');
    } catch (error) {
      if (mounted) _message('保存图片失败：$error');
    }
  }

  Future<void> _runLocalOcr(List<MediaAsset> assets) async {
    final images = assets.where((asset) => asset.type == MediaAssetType.productImage || asset.type == MediaAssetType.instructionImage).toList();
    if (images.isEmpty) {
      _message('请先添加商品、包装或说明书图片。');
      return;
    }
    setState(() => _recognizing = true);
    try {
      var textCount = 0;
      for (final asset in images) {
        final text = await ref.read(mediaServiceProvider).runOcr(asset);
        if (text.isNotEmpty) textCount++;
      }
      if (mounted) _message('本地 OCR 完成：$textCount/${images.length} 张图片识别到文字。');
    } catch (error) {
      if (mounted) _message('本地 OCR 失败：$error');
    } finally {
      if (mounted) setState(() => _recognizing = false);
    }
  }

  Future<void> _parseAiDraft(List<MediaAsset> assets) async {
    final text = assets
        .where((asset) => asset.hasOcrText)
        .map((asset) => asset.ocrText!.trim())
        .join('\n\n');
    if (text.isEmpty) {
      _message('请先对说明书或包装图片执行本地 OCR。');
      return;
    }
    final confirmed = await _confirmAiUpload(text.length);
    if (confirmed != true || !mounted) return;
    setState(() => _parsingAi = true);
    try {
      final suggestion = await ref.read(aiDraftServiceProvider).parseOcrText(text);
      if (!mounted) return;
      final apply = await _showAiSuggestion(suggestion);
      if (apply == true && mounted) _applyAiSuggestion(suggestion);
    } catch (error) {
      if (mounted) _message('AI 解析未写入草稿：$error');
    } finally {
      if (mounted) setState(() => _parsingAi = false);
    }
  }

  Future<bool?> _confirmAiUpload(int textLength) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认发送 OCR 文本？'),
          content: Text(
            '将仅发送本地 OCR 文本（约 $textLength 字），不上传原图。发送到你在设置中配置的 AI 服务后，只生成可编辑草稿，不会自动入库。',
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('取消')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('确认发送')),
          ],
        ),
      );

  Future<bool?> _showAiSuggestion(IntakeDraftSuggestion suggestion) => showDialog<bool>(
        context: context,
        builder: (context) => AlertDialog(
          title: const Text('确认 AI 草稿'),
          content: SizedBox(
            width: 440,
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('AI 结果仅供辅助，请核对包装后再应用；不会自动入库。'),
                  const SizedBox(height: 10),
                  _CandidateLine('名称', suggestion.name),
                  _CandidateLine('品牌', suggestion.brand),
                  _CandidateLine('规格', suggestion.specification),
                  _CandidateLine('分类', suggestion.category),
                  _CandidateLine('批次号', suggestion.batchNo),
                  _CandidateLine('生产日期', _dateText(suggestion.productionDate)),
                  _CandidateLine('到期日期', _dateText(suggestion.expiryDate)),
                  _CandidateLine('保质期', suggestion.shelfLifeAmount?.toString()),
                  _CandidateLine('保质期单位', suggestion.shelfLifeUnit == null ? null : suggestion.shelfLifeUnit == ShelfLifeUnit.days ? '天' : '个月'),
                  _CandidateLine('日期精度', suggestion.datePrecision),
                  _CandidateLine('备注', suggestion.notes),
                ],
              ),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('放弃')),
            FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('应用到可编辑草稿')),
          ],
        ),
      );

  void _applyAiSuggestion(IntakeDraftSuggestion suggestion) {
    setState(() {
      if (suggestion.name != null) _name.text = suggestion.name!;
      if (suggestion.brand != null) _brand.text = suggestion.brand!;
      if (suggestion.specification != null) _specification.text = suggestion.specification!;
      if (suggestion.batchNo != null) _batchNo.text = suggestion.batchNo!;
      if (suggestion.shelfLifeAmount != null) _shelfLife.text = suggestion.shelfLifeAmount.toString();
      if (suggestion.shelfLifeUnit != null) _shelfLifeUnit = suggestion.shelfLifeUnit!;
      if (suggestion.productionDate != null) _productionDate = suggestion.productionDate;
      if (suggestion.expiryDate != null) _expiryDate = suggestion.expiryDate;
      if (suggestion.category != null) {
        _category = _categories.contains(suggestion.category) ? suggestion.category! : '其他物品';
      }
      if (suggestion.productionDate != null ||
          suggestion.expiryDate != null ||
          suggestion.shelfLifeAmount != null) {
        _dateSource = 'ai';
        _datePrecision = suggestion.datePrecision ?? 'unknown';
      }
    });
  }

  Future<void> _deleteAsset(MediaAsset asset) async {
    try {
      await ref.read(mediaServiceProvider).delete(asset);
      if (mounted) _message('图片已删除。');
    } catch (error) {
      if (mounted) _message('删除图片失败：$error');
    }
  }

  Future<void> _submit() async {
    if (!(_formKey.currentState?.validate() ?? false)) return;
    setState(() => _saving = true);
    try {
      final draft = IntakeDraft(
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
        shelfLifeAmount: int.tryParse(_shelfLife.text),
        shelfLifeUnit: _shelfLifeUnit,
        dateSource: _dateSource,
        datePrecision: _datePrecision,
      );
      final service = ref.read(inventoryServiceProvider);
      final matches = await service.findMatchingProducts(draft);
      String? mergeProductId;
      if (matches.isNotEmpty) {
        final decision = await _showMatchConfirmation(matches);
        if (!mounted || decision.choice == _MatchChoice.cancel) return;
        if (decision.choice == _MatchChoice.merge) mergeProductId = decision.candidate!.id;
      }
      final productId = await service.intake(draft, mergeProductId: mergeProductId);
      String? mediaWarning;
      try {
        await ref.read(mediaServiceProvider).reassignIntakeAssets(
              intakeDraftId: _mediaDraftId,
              productId: productId,
            );
      } catch (error) {
        mediaWarning = '库存已入库，但图片关联失败：$error。可稍后在设置中清理媒体缓存。';
      }
      if (!mounted) return;
      Navigator.of(context).pop();
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text(mediaWarning ?? '已入库。')),
      );
    } catch (error) {
      if (!mounted) return;
      _message('$error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<_MatchDecision> _showMatchConfirmation(List<ProductMatchCandidate> matches) async {
    var selectedIndex = 0;
    final decision = await showDialog<_MatchDecision>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setDialogState) {
          final selected = matches[selectedIndex];
          return AlertDialog(
            title: const Text('发现相似商品'),
            content: SizedBox(
              width: 420,
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    const Text('请选择如何处理本次入库：'),
                    const SizedBox(height: 10),
                    for (var index = 0; index < matches.length; index++)
                      RadioListTile<int>(
                        value: index,
                        groupValue: selectedIndex,
                        contentPadding: EdgeInsets.zero,
                        title: Text(matches[index].name),
                        subtitle: Text(_matchDescription(matches[index])),
                        onChanged: (value) => setDialogState(() => selectedIndex = value!),
                      ),
                    const SizedBox(height: 6),
                    Text('当前选择：${selected.name}', style: Theme.of(context).textTheme.bodySmall),
                    const SizedBox(height: 12),
                    const Text('合并只会为已有商品新增一个独立批次；不会静默修改原商品信息。'),
                  ],
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, const _MatchDecision(_MatchChoice.cancel)),
                child: const Text('取消'),
              ),
              TextButton(
                onPressed: () => Navigator.pop(dialogContext, const _MatchDecision(_MatchChoice.create)),
                child: const Text('新建独立商品'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(
                  dialogContext,
                  _MatchDecision(_MatchChoice.merge, candidate: selected),
                ),
                child: const Text('合并到已有商品'),
              ),
            ],
          );
        },
      ),
    );
    return decision ?? const _MatchDecision(_MatchChoice.cancel);
  }

  String _matchDescription(ProductMatchCandidate candidate) => [
        candidate.category,
        candidate.brand,
        candidate.specification,
        candidate.barcode,
      ].whereType<String>().where((value) => value.trim().isNotEmpty).join(' · ');

  void _message(String message) {
    ScaffoldMessenger.of(context)
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  Widget build(BuildContext context) {
    final attachments = ref.watch(mediaAssetsProvider((entityType: 'intake_draft', entityId: _mediaDraftId)));
    final assets = attachments.valueOrNull ?? const <MediaAsset>[];
    return Padding(
      padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
      child: DraggableScrollableSheet(
        expand: false,
        initialChildSize: 0.9,
        minChildSize: 0.55,
        maxChildSize: 0.96,
        builder: (context, controller) => Material(
          borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
          child: SafeArea(
            top: false,
            child: Form(
              key: _formKey,
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 28),
                children: [
                  Center(
                    child: Container(
                      width: 42,
                      height: 4,
                      decoration: BoxDecoration(
                        color: Theme.of(context).colorScheme.outlineVariant,
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text('入库', style: Theme.of(context).textTheme.headlineSmall),
                  const SizedBox(height: 16),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : _scanBarcode,
                          icon: const Icon(Icons.qr_code_scanner_outlined),
                          label: const Text('扫描条码'),
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: OutlinedButton.icon(
                          onPressed: _saving ? null : () => _attachImage(MediaAssetType.productImage),
                          icon: const Icon(Icons.add_a_photo_outlined),
                          label: const Text('添加图片'),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 12),
                  TextFormField(controller: _name, decoration: const InputDecoration(labelText: '物品名称 *'), validator: (value) => value == null || value.trim().isEmpty ? '请填写物品名称' : null),
                  const SizedBox(height: 10),
                  DropdownButtonFormField<String>(
                    value: _category,
                    decoration: const InputDecoration(labelText: '分类 *'),
                    items: _categories.map((category) => DropdownMenuItem(value: category, child: Text(category))).toList(),
                    onChanged: (value) => setState(() => _category = value ?? _category),
                  ),
                  const SizedBox(height: 10),
                  TextFormField(controller: _brand, decoration: const InputDecoration(labelText: '品牌（可选）')),
                  const SizedBox(height: 10),
                  TextFormField(controller: _specification, decoration: const InputDecoration(labelText: '规格（可选）')),
                  const SizedBox(height: 10),
                  Row(
                    children: [
                      Expanded(child: TextFormField(controller: _quantity, decoration: const InputDecoration(labelText: '入库数量 *'), keyboardType: TextInputType.number, validator: _positiveIntegerValidator)),
                      const SizedBox(width: 10),
                      Expanded(child: TextFormField(controller: _threshold, decoration: const InputDecoration(labelText: '低库存阈值 *'), keyboardType: TextInputType.number, validator: _positiveIntegerValidator)),
                    ],
                  ),
                  const SizedBox(height: 10),
                  TextFormField(controller: _location, decoration: const InputDecoration(labelText: '存放位置')),
                  const SizedBox(height: 10),
                  TextFormField(
                    controller: _barcode,
                    decoration: InputDecoration(
                      labelText: '条码',
                      suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), tooltip: '扫描条码', onPressed: _saving ? null : _scanBarcode),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 10),
                  TextFormField(controller: _batchNo, decoration: const InputDecoration(labelText: '批次号')),
                  const SizedBox(height: 8),
                  _DateField(label: '生产日期', value: _productionDate, onTap: () => _pickDate(false), onClear: () => setState(() => _productionDate = null)),
                  const SizedBox(height: 4),
                  _DateField(label: '到期日期（可不填）', value: _expiryDate, onTap: () => _pickDate(true), onClear: () => setState(() => _expiryDate = null)),
                  const SizedBox(height: 8),
                  Row(
                    children: [
                      Expanded(child: TextFormField(controller: _shelfLife, decoration: const InputDecoration(labelText: '保质期（可选）', hintText: '填写后可自动算到期日'), keyboardType: TextInputType.number, validator: (value) { if (value == null || value.trim().isEmpty) return null; final parsed = int.tryParse(value); return parsed == null || parsed < 1 ? '请输入大于 0 的整数' : null; })),
                      const SizedBox(width: 10),
                      DropdownButton<ShelfLifeUnit>(value: _shelfLifeUnit, onChanged: (value) => setState(() => _shelfLifeUnit = value ?? _shelfLifeUnit), items: const [DropdownMenuItem(value: ShelfLifeUnit.days, child: Text('天')), DropdownMenuItem(value: ShelfLifeUnit.months, child: Text('个月'))]),
                    ],
                  ),
                  const SizedBox(height: 20),
                  _MediaDraftSection(
                    assets: assets,
                    loading: attachments.isLoading,
                    recognizing: _recognizing,
                    parsingAi: _parsingAi,
                    onAddInstruction: () => _attachImage(MediaAssetType.instructionImage),
                    onOcr: () => _runLocalOcr(assets),
                    onAi: () => _parseAiDraft(assets),
                    onDelete: _deleteAsset,
                  ),
                  const SizedBox(height: 18),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving ? null : _submit,
                      icon: _saving ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.inventory_2),
                      label: Text(_saving ? '正在保存…' : '确认入库'),
                    ),
                  ),
                ],
              ),
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

class _MediaDraftSection extends StatelessWidget {
  const _MediaDraftSection({
    required this.assets,
    required this.loading,
    required this.recognizing,
    required this.parsingAi,
    required this.onAddInstruction,
    required this.onOcr,
    required this.onAi,
    required this.onDelete,
  });

  final List<MediaAsset> assets;
  final bool loading;
  final bool recognizing;
  final bool parsingAi;
  final VoidCallback onAddInstruction;
  final VoidCallback onOcr;
  final VoidCallback onAi;
  final ValueChanged<MediaAsset> onDelete;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('图片与本地识别', style: Theme.of(context).textTheme.titleSmall),
              const SizedBox(height: 4),
              const Text('图片压缩后仅保存到本机。OCR 默认在设备本地执行；AI 只读取你确认上传的 OCR 文本。'),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  OutlinedButton.icon(onPressed: onAddInstruction, icon: const Icon(Icons.description_outlined), label: const Text('添加说明书图片')),
                  FilledButton.tonalIcon(onPressed: recognizing ? null : onOcr, icon: recognizing ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.document_scanner_outlined), label: Text(recognizing ? '识别中…' : '本地 OCR')),
                  FilledButton.tonalIcon(onPressed: parsingAi ? null : onAi, icon: parsingAi ? const SizedBox.square(dimension: 14, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.auto_awesome_outlined), label: Text(parsingAi ? '解析中…' : 'AI 解析草稿')),
                ],
              ),
              if (loading) const Padding(padding: EdgeInsets.only(top: 10), child: LinearProgressIndicator()),
              if (assets.isNotEmpty) ...[
                const SizedBox(height: 10),
                SizedBox(
                  height: 104,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: assets.length,
                    separatorBuilder: (_, __) => const SizedBox(width: 8),
                    itemBuilder: (context, index) {
                      final asset = assets[index];
                      return SizedBox(
                        width: 128,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.file(File(asset.localPath), fit: BoxFit.cover, errorBuilder: (_, __, ___) => const ColoredBox(color: Color(0xFFE0E0E0), child: Icon(Icons.broken_image_outlined))),
                              ),
                            ),
                            Positioned(left: 4, bottom: 4, child: DecoratedBox(decoration: BoxDecoration(color: Colors.black54, borderRadius: BorderRadius.circular(6)), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2), child: Text(asset.type.label, style: const TextStyle(color: Colors.white, fontSize: 10))))),
                            Positioned(right: 0, top: 0, child: IconButton(style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white), iconSize: 16, onPressed: () => onDelete(asset), icon: const Icon(Icons.close))),
                            if (asset.hasOcrText) const Positioned(left: 5, top: 5, child: Icon(Icons.text_snippet, size: 18, color: Colors.white)),
                          ],
                        ),
                      );
                    },
                  ),
                ),
              ],
            ],
          ),
        ),
      );
}

class _BarcodeScannerSheet extends StatefulWidget {
  const _BarcodeScannerSheet();

  @override
  State<_BarcodeScannerSheet> createState() => _BarcodeScannerSheetState();
}

class _BarcodeScannerSheetState extends State<_BarcodeScannerSheet> {
  final _controller = MobileScannerController();
  bool _completed = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && RegExp(r'^\d{8,14}$').hasMatch(value)) {
        _completed = true;
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        appBar: AppBar(title: const Text('扫描商品条码')),
        body: Column(
          children: [
            Expanded(child: MobileScanner(controller: _controller, onDetect: _onDetect)),
            Padding(
              padding: const EdgeInsets.all(16),
              child: Text('将 EAN/UPC 等商品条码置于取景框内。相机不可用时可返回手动输入。', textAlign: TextAlign.center, style: Theme.of(context).textTheme.bodySmall),
            ),
          ],
        ),
      );
}

class _CandidateLine extends StatelessWidget {
  const _CandidateLine(this.label, this.value);
  final String label;
  final String? value;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Text('$label：${value == null || value!.trim().isEmpty ? '未识别' : value}'),
      );
}

enum _MatchChoice { merge, create, cancel }

class _MatchDecision {
  const _MatchDecision(this.choice, {this.candidate});
  final _MatchChoice choice;
  final ProductMatchCandidate? candidate;
}

class _DateField extends StatelessWidget {
  const _DateField({required this.label, required this.value, required this.onTap, required this.onClear});
  final String label;
  final DateTime? value;
  final VoidCallback onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final selected = _dateText(value) ?? '未设置';
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

String? _dateText(DateTime? value) => value == null ? null : '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
