import '../../app/momo_typography.dart';
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:mobile_scanner/mobile_scanner.dart';
import 'package:uuid/uuid.dart';
import 'app_feedback.dart';
import 'momo_glass_components.dart';

import '../../domain/inventory/expiry_rules.dart';
import '../../domain/inventory/product_categories.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/recognition_models.dart';
import '../controllers/providers.dart';

class _IntakeDraftMemory {
  String? mediaDraftId;
  String? name;
  String? brand;
  String? specification;
  String quantity = '1';
  String? location;
  String? barcode;
  String? batchNo;
  String threshold = '1';
  String? shelfLife;
  String category = ProductCategories.fallback;
  bool categoryManuallySelected = false;
  bool useLocalCategoryHints = true;
  ShelfLifeUnit shelfLifeUnit = ShelfLifeUnit.days;
  DateTime? productionDate;
  DateTime? expiryDate;
  String dateSource = 'manual';
  String datePrecision = 'day';

  bool get hasContent =>
      mediaDraftId != null ||
      (name != null && name!.trim().isNotEmpty) ||
      (brand != null && brand!.trim().isNotEmpty) ||
      (barcode != null && barcode!.trim().isNotEmpty) ||
      productionDate != null ||
      expiryDate != null;

  void clear() {
    mediaDraftId = null;
    name = null;
    brand = null;
    specification = null;
    quantity = '1';
    location = null;
    barcode = null;
    batchNo = null;
    threshold = '1';
    shelfLife = null;
    category = ProductCategories.fallback;
    categoryManuallySelected = false;
    useLocalCategoryHints = true;
    shelfLifeUnit = ShelfLifeUnit.days;
    productionDate = null;
    expiryDate = null;
    dateSource = 'manual';
    datePrecision = 'day';
  }
}

final _intakeDraft = _IntakeDraftMemory();

class IntakeSheet extends ConsumerStatefulWidget {
  const IntakeSheet({
    this.initialDraft,
    this.initialCategoryFromAi = false,
    this.initialName,
    this.initialCategory,
    this.initialQuantity = 1,
    this.beforeIntake,
    this.onIntake,
    this.onIntakeSuccess,
    super.key,
  });

  final IntakeDraft? initialDraft;
  /// AI categories are validated, not reclassified by local name hints.
  /// Explicit/manual categories (including legacy values) remain untouched.
  final bool initialCategoryFromAi;
  final String? initialName;
  final String? initialCategory;
  final int initialQuantity;
  final Future<void> Function()? beforeIntake;
  final Future<String> Function(IntakeDraft draft, String? mergeProductId)? onIntake;
  final FutureOr<void> Function(String productId)? onIntakeSuccess;

  @override
  ConsumerState<IntakeSheet> createState() => _IntakeSheetState();
}

class _IntakeSheetState extends ConsumerState<IntakeSheet> {
  // Keep existing values stable: saved products and backups store category as text.
  static const _categories = ProductCategories.values;

  final _formKey = GlobalKey<FormState>();
  final _categoryFieldKey = GlobalKey<FormFieldState<String>>();
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
  late final String _mediaDraftId;
  String _category = ProductCategories.fallback;
  bool _categoryManuallySelected = false;
  bool _useLocalCategoryHints = true;
  ShelfLifeUnit _shelfLifeUnit = ShelfLifeUnit.days;
  String _dateSource = 'manual';
  String _datePrecision = 'day';
  DateTime? _productionDate;
  DateTime? _expiryDate;
  bool _saving = false;
  bool _recognizing = false;
  bool _parsingAi = false;
  bool _intakeCompleted = false;

  @override
  void initState() {
    super.initState();
    final restoreDraft = widget.initialDraft == null && widget.initialName == null &&
        widget.initialCategory == null && _intakeDraft.hasContent;
    _mediaDraftId = restoreDraft
        ? (_intakeDraft.mediaDraftId ?? const Uuid().v4())
        : const Uuid().v4();
    final aiDraft = widget.initialDraft;
    if (aiDraft != null) {
      _name.text = aiDraft.name;
      _quantity.text = '${aiDraft.quantity}';
      _category = widget.initialCategoryFromAi
          ? ProductCategories.validateAiCategory(aiDraft.category) ?? ProductCategories.fallback
          : aiDraft.category;
      _categoryManuallySelected = !widget.initialCategoryFromAi;
      _useLocalCategoryHints = !widget.initialCategoryFromAi;
      _brand.text = aiDraft.brand ?? '';
      _specification.text = aiDraft.specification ?? '';
      _barcode.text = aiDraft.barcode ?? '';
      _location.text = aiDraft.location ?? '';
      _batchNo.text = aiDraft.batchNo ?? '';
      _threshold.text = '${aiDraft.lowStockThreshold}';
      _shelfLife.text = aiDraft.shelfLifeAmount?.toString() ?? '';
      _shelfLifeUnit = aiDraft.shelfLifeUnit;
      _productionDate = aiDraft.productionDate;
      _expiryDate = aiDraft.expiryDate;
      _dateSource = aiDraft.dateSource;
      _datePrecision = aiDraft.datePrecision;
    } else if (widget.initialName != null || widget.initialCategory != null) {
      _name.text = widget.initialName ?? '';
      _quantity.text = widget.initialQuantity.toString();
      if (widget.initialCategory != null && widget.initialCategory!.isNotEmpty) {
        _category = widget.initialCategory!;
        _categoryManuallySelected = true;
      } else {
        _category = ProductCategories.forManualEntry(name: _name.text);
      }
    } else if (_intakeDraft.hasContent) {
      _name.text = _intakeDraft.name ?? '';
      _brand.text = _intakeDraft.brand ?? '';
      _specification.text = _intakeDraft.specification ?? '';
      _quantity.text = _intakeDraft.quantity;
      _location.text = _intakeDraft.location ?? '';
      _barcode.text = _intakeDraft.barcode ?? '';
      _batchNo.text = _intakeDraft.batchNo ?? '';
      _threshold.text = _intakeDraft.threshold;
      _shelfLife.text = _intakeDraft.shelfLife ?? '';
      _category = _intakeDraft.category;
      _categoryManuallySelected = _intakeDraft.categoryManuallySelected;
      _useLocalCategoryHints = _intakeDraft.useLocalCategoryHints;
      _shelfLifeUnit = _intakeDraft.shelfLifeUnit;
      _productionDate = _intakeDraft.productionDate;
      _expiryDate = _intakeDraft.expiryDate;
      _dateSource = _intakeDraft.dateSource;
      _datePrecision = _intakeDraft.datePrecision;
    } else {
      _name.text = '';
      _quantity.text = widget.initialQuantity.toString();
    }
  }

  void _saveDraft() {
    // Assistant drafts remain in their proposal; do not overwrite a separate
    // manual draft when opening, cancelling or completing one from chat.
    if (_intakeCompleted || widget.initialDraft != null) return;
    // Keep the media identity even when the draft contains only photos/OCR.
    _intakeDraft.mediaDraftId = _mediaDraftId;
    _intakeDraft.name = _name.text;
    _intakeDraft.brand = _brand.text;
    _intakeDraft.specification = _specification.text;
    _intakeDraft.quantity = _quantity.text;
    _intakeDraft.location = _location.text;
    _intakeDraft.barcode = _barcode.text;
    _intakeDraft.batchNo = _batchNo.text;
    _intakeDraft.threshold = _threshold.text;
    _intakeDraft.shelfLife = _shelfLife.text;
    _intakeDraft.category = _category;
    _intakeDraft.categoryManuallySelected = _categoryManuallySelected;
    _intakeDraft.useLocalCategoryHints = _useLocalCategoryHints;
    _intakeDraft.shelfLifeUnit = _shelfLifeUnit;
    _intakeDraft.productionDate = _productionDate;
    _intakeDraft.expiryDate = _expiryDate;
    _intakeDraft.dateSource = _dateSource;
    _intakeDraft.datePrecision = _datePrecision;
  }

  @override
  void dispose() {
    _saveDraft();
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
    if (_saving || _recognizing || _parsingAi) return;
    final barcode = await Navigator.of(context).push<String>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => const _BarcodeScannerScreen(),
      ),
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
    final category = ProductCategories.canonical(result.category);
    setState(() {
      if (result.name != null) _name.text = result.name!;
      if (result.brand != null) _brand.text = result.brand!;
      if (result.specification != null) _specification.text = result.specification!;
      if (category != null) {
        if (!_categoryManuallySelected) _updateCategory(category);
        // The user accepted this external category; name edits must not
        // override it, including after restoring this draft.
        _useLocalCategoryHints = false;
      } else {
        _applyLocalCategoryHint();
      }
    });
  }

  Future<void> _attachImage() async {
    final choice = await showModalBottomSheet<({ImageSource source, MediaAssetType type})>(
      context: context,
      builder: (context) => SafeArea(
        child: Wrap(
          children: [
            ListTile(
              leading: const Icon(Icons.camera_alt_outlined),
              title: const Text('拍照'),
              onTap: () => Navigator.pop(context, (
                source: ImageSource.camera, type: MediaAssetType.productImage,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.photo_library_outlined),
              title: const Text('从相册选择'),
              onTap: () => Navigator.pop(context, (
                source: ImageSource.gallery, type: MediaAssetType.productImage,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.description_outlined),
              title: const Text('拍摄说明书'),
              onTap: () => Navigator.pop(context, (
                source: ImageSource.camera, type: MediaAssetType.instructionImage,
              )),
            ),
            ListTile(
              leading: const Icon(Icons.collections_outlined),
              title: const Text('选择说明书图片'),
              onTap: () => Navigator.pop(context, (
                source: ImageSource.gallery, type: MediaAssetType.instructionImage,
              )),
            ),
          ],
        ),
      ),
    );
    if (choice == null || !mounted) return;
    try {
      final image = await _picker.pickImage(source: choice.source, imageQuality: 100);
      if (image == null || !mounted) return;
      await ref.read(mediaServiceProvider).attachImage(
            source: image,
            entityType: 'intake_draft',
            entityId: _mediaDraftId,
            type: choice.type,
          );
      if (mounted) _message('${choice.type.label}已保存到本机。');
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
      var failedCount = 0;
      final mediaService = ref.read(mediaServiceProvider);
      for (final asset in images) {
        try {
          final text = await mediaService.runOcr(asset);
          if (text.isNotEmpty) textCount++;
        } catch (_) {
          failedCount++;
        }
      }
      if (mounted) {
        final summary = '本地 OCR 完成：$textCount/${images.length} 张图片识别到文字。';
        _message(failedCount == 0 ? summary : '$summary 另有 $failedCount 张未能识别，可手动填写。');
      }
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
            '将仅发送本地 OCR 文本（约 $textLength 字），不上传原图。会发送到你配置的主 AI 服务；主服务失败时，也可能发送到你配置的副服务或兜底服务。只生成可编辑草稿，不会自动入库。',
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
    final category = ProductCategories.validateAiCategory(suggestion.category) ?? ProductCategories.fallback;
    setState(() {
      if (suggestion.name != null) _name.text = suggestion.name!;
      if (suggestion.brand != null) _brand.text = suggestion.brand!;
      if (suggestion.specification != null) _specification.text = suggestion.specification!;
      if (suggestion.batchNo != null) _batchNo.text = suggestion.batchNo!;
      if (suggestion.shelfLifeAmount != null) _shelfLife.text = suggestion.shelfLifeAmount.toString();
      if (suggestion.shelfLifeUnit != null) _shelfLifeUnit = suggestion.shelfLifeUnit!;
      if (suggestion.productionDate != null) _productionDate = suggestion.productionDate;
      if (suggestion.expiryDate != null) _expiryDate = suggestion.expiryDate;
      if (!_categoryManuallySelected) {
        _updateCategory(category);
      }
      // Even when the model is uncertain, do not silently replace its result
      // with a name-based guess now or on subsequent edits/draft restoration.
      _useLocalCategoryHints = false;
      if (suggestion.productionDate != null ||
          suggestion.expiryDate != null ||
          suggestion.shelfLifeAmount != null) {
        _dateSource = 'ai';
        _datePrecision = suggestion.datePrecision ?? 'unknown';
      }
    });
  }

  void _updateCategory(String category) {
    if (_category == category) return;
    _category = category;
    // Synchronize programmatic suggestions without replacing the field state
    // (and losing focus) every time its selected value changes.
    _categoryFieldKey.currentState?.didChange(category);
  }

  void _applyLocalCategoryHint() {
    if (_categoryManuallySelected || !_useLocalCategoryHints) return;
    final category = ProductCategories.suggestForName(_name.text);
    if (category != null) _updateCategory(category);
  }

  String? get _categoryHint {
    if (_categoryManuallySelected || !_useLocalCategoryHints) return null;
    final candidates = ProductCategories.candidatesForManualEntry(_name.text);
    if (candidates.length < 2) return null;
    return '可能属于${candidates.join('、')}，请手动选择分类；当前分类保持不变。';
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
    if (_saving || _intakeCompleted || _recognizing || _parsingAi) return;
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
      if (!mounted) return;
      await widget.beforeIntake?.call();
      final productId = widget.onIntake == null
          ? await service.intake(draft, mergeProductId: mergeProductId)
          : await widget.onIntake!(draft, mergeProductId);
      _intakeCompleted = true;
      if (widget.initialDraft == null) _intakeDraft.clear();
      // Record committed intake even if the sheet was closed while SQLite ran.
      String? receiptWarning;
      try {
        await widget.onIntakeSuccess?.call(productId);
      } catch (_) {
        receiptWarning = '库存已入库，但后续记录保存失败，请核实结果后再操作。';
      }
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
      final warnings = [if (receiptWarning != null) receiptWarning,
        if (mediaWarning != null) mediaWarning].join('\n');
      Navigator.of(context).pop();
      showAppSnackBar(context,
        SnackBar(content: Text(warnings.isEmpty ? '已入库。' : warnings)),
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
                    RadioGroup<int>(
                      groupValue: selectedIndex,
                      onChanged: (value) {
                        if (value != null) setDialogState(() => selectedIndex = value);
                      },
                      child: Column(
                        children: [
                          for (var index = 0; index < matches.length; index++)
                            RadioListTile<int>(
                              value: index,
                              contentPadding: EdgeInsets.zero,
                              title: Text(matches[index].name),
                              subtitle: Text(_matchDescription(matches[index])),
                            ),
                        ],
                      ),
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
          shape: Theme.of(context).bottomSheetTheme.shape,
          color: Theme.of(context).bottomSheetTheme.backgroundColor,
          clipBehavior: Clip.antiAlias,
          child: SafeArea(
            top: false,
            child: Form(
              key: _formKey,
              child: ListView(
                controller: controller,
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                children: [
                  Center(
                    child: GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      child: Container(
                        padding: const EdgeInsets.symmetric(vertical: 8),
                        child: Container(
                          width: 36,
                          height: 5,
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.outlineVariant,
                            borderRadius: BorderRadius.circular(8),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Row(
                    children: [
                      Expanded(child: Text('入库', style: Theme.of(context).textTheme.titleLarge)),
                      IconButton(
                        tooltip: '扫描条码',
                        onPressed: _saving || _recognizing || _parsingAi ? null : _scanBarcode,
                        icon: const Icon(Icons.qr_code_scanner_outlined),
                      ),
                      IconButton(
                        tooltip: '关闭入库草稿',
                        onPressed: _saving ? null : () => Navigator.of(context).pop(),
                        icon: const Icon(Icons.close),
                      ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _MediaDraftSection(
                    assets: assets,
                    loading: attachments.isLoading,
                    recognizing: _recognizing,
                    parsingAi: _parsingAi,
                    enabled: !_saving && !_intakeCompleted,
                    onAddImage: _attachImage,
                    onOcr: () => _runLocalOcr(assets),
                    onAi: () => _parseAiDraft(assets),
                    onDelete: _deleteAsset,
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _name,
                    decoration: const InputDecoration(labelText: '物品名称 *'),
                    textInputAction: TextInputAction.next,
                    onChanged: (_) => setState(() => _applyLocalCategoryHint()),
                    validator: (value) => value == null || value.trim().isEmpty ? '请填写物品名称' : null,
                  ),
                  const SizedBox(height: 8),
                  DropdownButtonFormField<String>(
                    key: _categoryFieldKey,
                    isExpanded: true,
                    initialValue: _category,
                    isDense: true,
                    menuMaxHeight: 280,
                    borderRadius: BorderRadius.circular(16),
                    decoration: InputDecoration(labelText: '分类 *', helperText: _categoryHint, helperMaxLines: 4),
                    items: [if (!_categories.contains(_category)) _category, ..._categories]
                        .map((category) => DropdownMenuItem(value: category, child: Text(category))).toList(),
                    onChanged: (value) => setState(() {
                      _category = value ?? _category;
                      _categoryManuallySelected = true;
                    }),
                  ),
                  const SizedBox(height: 8),
                  _AdaptiveIntakeRow(
                    children: [
                      TextFormField(controller: _brand, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: '品牌（可选）')),
                      TextFormField(controller: _specification, textInputAction: TextInputAction.next, decoration: const InputDecoration(labelText: '规格（可选）')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _AdaptiveIntakeRow(
                    children: [
                      TextFormField(controller: _quantity, decoration: const InputDecoration(labelText: '入库数量 *'), keyboardType: TextInputType.number, validator: _positiveIntegerValidator),
                      TextFormField(controller: _threshold, decoration: const InputDecoration(labelText: '低库存阈值 *'), keyboardType: TextInputType.number, validator: _positiveIntegerValidator),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _AdaptiveIntakeRow(
                    children: [
                      TextFormField(controller: _location, decoration: const InputDecoration(labelText: '存放位置')),
                      TextFormField(controller: _batchNo, decoration: const InputDecoration(labelText: '批次号')),
                    ],
                  ),
                  const SizedBox(height: 8),
                  TextFormField(
                    controller: _barcode,
                    decoration: InputDecoration(
                      labelText: '条码',
                      suffixIcon: IconButton(icon: const Icon(Icons.qr_code_scanner), tooltip: '扫描条码', onPressed: _saving || _recognizing || _parsingAi ? null : _scanBarcode),
                    ),
                    keyboardType: TextInputType.number,
                  ),
                  const SizedBox(height: 8),
                  _AdaptiveIntakeRow(
                    children: [
                      _DateField(label: '生产日期', value: _productionDate, onTap: () => _pickDate(false), onClear: () => setState(() => _productionDate = null)),
                      _DateField(label: '到期日期（可不填）', value: _expiryDate, onTap: () => _pickDate(true), onClear: () => setState(() => _expiryDate = null)),
                    ],
                  ),
                  const SizedBox(height: 8),
                  _AdaptiveIntakeRow(
                    children: [
                      TextFormField(controller: _shelfLife, decoration: const InputDecoration(labelText: '保质期（可选）'), keyboardType: TextInputType.number, validator: (value) { if (value == null || value.trim().isEmpty) return null; final parsed = int.tryParse(value); return parsed == null || parsed < 1 ? '请输入大于 0 的整数' : null; }),
                      DropdownButtonFormField<ShelfLifeUnit>(
                        key: ValueKey(_shelfLifeUnit),
                        initialValue: _shelfLifeUnit,
                        decoration: const InputDecoration(labelText: '保质期单位'),
                        isExpanded: true,
                        isDense: true,
                        menuMaxHeight: 200,
                        borderRadius: BorderRadius.circular(12),
                        onChanged: (value) => setState(() => _shelfLifeUnit = value ?? _shelfLifeUnit),
                        items: const [
                          DropdownMenuItem(value: ShelfLifeUnit.days, child: Text('天', overflow: TextOverflow.ellipsis)),
                          DropdownMenuItem(value: ShelfLifeUnit.months, child: Text('个月', overflow: TextOverflow.ellipsis)),
                        ],
                      ),
                    ],
                  ),
                  const SizedBox(height: 16),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton.icon(
                      onPressed: _saving || _intakeCompleted || _recognizing || _parsingAi ? null : _submit,
                      icon: _saving ? const SizedBox.square(dimension: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.inventory_2),
                      label: Text(_intakeCompleted ? '已入库' : _saving ? '正在保存…' : '确认入库'),
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

/// Compact at normal text sizes; reflows rather than shrinking accessible text.
class _AdaptiveIntakeRow extends StatelessWidget {
  const _AdaptiveIntakeRow({required this.children, this.minChildWidth = 132});

  final List<Widget> children;
  final double minChildWidth;

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(MomoTextSize.body) /
          MomoTextSize.body;
      final requiredWidth = children.length * minChildWidth *
          (textScale < 1 ? 1 : textScale) + (children.length - 1) * 8;
      final inline = constraints.maxWidth >= requiredWidth;
      return Flex(
        direction: inline ? Axis.horizontal : Axis.vertical,
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var index = 0; index < children.length; index++) ...[
            if (index > 0) SizedBox(width: inline ? 8 : 0, height: inline ? 0 : 8),
            if (inline)
              Expanded(child: children[index])
            else
              SizedBox(width: double.infinity, child: children[index]),
          ],
        ],
      );
    },
  );
}

class _IntakeToolButton extends StatelessWidget {
  const _IntakeToolButton({
    required this.label, required this.tooltip, required this.icon,
    required this.onPressed, this.loading = false,
  });

  final String label;
  final String tooltip;
  final IconData icon;
  final VoidCallback? onPressed;
  final bool loading;

  @override
  Widget build(BuildContext context) => Tooltip(
    message: tooltip,
    child: Semantics(
      liveRegion: loading,
      child: OutlinedButton(
        onPressed: loading ? null : onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(48, 48),
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 10),
          textStyle: Theme.of(context).textTheme.bodyMedium,
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            if (loading)
              const SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2))
            else Icon(icon, size: 18),
            const SizedBox(width: 4),
            Flexible(child: Text(loading ? '$label中…' : label, textAlign: TextAlign.center)),
          ],
        ),
      ),
    ),
  );
}

class _MediaDraftSection extends StatelessWidget {
  const _MediaDraftSection({
    required this.assets,
    required this.loading,
    required this.recognizing,
    required this.parsingAi,
    required this.enabled,
    required this.onAddImage,
    required this.onOcr,
    required this.onAi,
    required this.onDelete,
  });

  final List<MediaAsset> assets;
  final bool loading;
  final bool recognizing;
  final bool parsingAi;
  final bool enabled;
  final VoidCallback onAddImage;
  final VoidCallback onOcr;
  final VoidCallback onAi;
  final ValueChanged<MediaAsset> onDelete;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final captionSize = MediaQuery.textScalerOf(context).scale(MomoTextSize.caption);
    final previewWidth = (captionSize * 6 + 16).clamp(128.0, double.infinity);
    // Paragraph layout rounds line metrics; fontSize * height can be smaller
    // even for a single line (and ignores wrapping/custom font metrics).
    var captionHeight = 0.0;
    // Labels depend only on the two asset types, not on attachment count.
    // Measure each possible label once per build so text scaling/theme changes
    // stay accurate without laying out the same caption for every attachment.
    if (assets.isNotEmpty) {
      for (final type in MediaAssetType.values) {
        final painter = TextPainter(
          text: TextSpan(text: type.label, style: theme.textTheme.bodySmall),
          textDirection: Directionality.of(context),
          textScaler: MediaQuery.textScalerOf(context),
          locale: Localizations.maybeLocaleOf(context),
        )..layout(maxWidth: previewWidth.toDouble());
        if (painter.height > captionHeight) captionHeight = painter.height;
        painter.dispose();
      }
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _AdaptiveIntakeRow(
          minChildWidth: 84,
          children: [
            _IntakeToolButton(
              label: '图片',
              tooltip: '添加商品、包装或说明书图片',
              icon: Icons.add_a_photo_outlined,
              onPressed: enabled && !recognizing && !parsingAi ? onAddImage : null,
            ),
            _IntakeToolButton(
              label: 'OCR',
              tooltip: '本地识别图片文字',
              icon: Icons.document_scanner_outlined,
              loading: recognizing,
              onPressed: enabled && !parsingAi ? onOcr : null,
            ),
            _IntakeToolButton(
              label: 'AI解析',
              tooltip: '确认后发送 OCR 文本，生成可编辑草稿',
              icon: Icons.auto_awesome_outlined,
              loading: parsingAi,
              onPressed: enabled && !recognizing ? onAi : null,
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text('图片留本机 · OCR 本地识别 · AI 发送前需确认', style: theme.textTheme.bodySmall),
        if (loading)
          const Padding(padding: EdgeInsets.only(top: 8), child: LinearProgressIndicator()),
        if (assets.isNotEmpty) ...[
          const SizedBox(height: 8),
          SizedBox(
            height: 104 + 8 + captionHeight.ceilToDouble(),
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: assets.length,
              separatorBuilder: (_, __) => const SizedBox(width: 8),
              itemBuilder: (context, index) {
                final asset = assets[index];
                return SizedBox(
                  width: previewWidth.toDouble(),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      SizedBox(
                        height: 104,
                        child: Stack(
                          children: [
                            Positioned.fill(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(10),
                                child: Image.file(
                                  File(asset.localPath),
                                  fit: BoxFit.cover,
                                  semanticLabel: asset.type.label,
                                  errorBuilder: (_, __, ___) => ColoredBox(
                                    color: theme.colorScheme.surfaceContainerHighest,
                                    child: const Center(child: Icon(Icons.broken_image_outlined)),
                                  ),
                                ),
                              ),
                            ),
                            Positioned(
                              right: 0, top: 0,
                              child: IconButton(
                                tooltip: '删除${asset.type.label}',
                                style: IconButton.styleFrom(backgroundColor: Colors.black54, foregroundColor: Colors.white),
                                iconSize: 16,
                                onPressed: enabled && !recognizing && !parsingAi ? () => onDelete(asset) : null,
                                icon: const Icon(Icons.close),
                              ),
                            ),
                            if (asset.hasOcrText)
                              const Positioned(
                                left: 4, top: 4,
                                child: Tooltip(
                                  message: '已保存本地 OCR 文字',
                                  child: DecoratedBox(
                                    decoration: BoxDecoration(color: Colors.black54, shape: BoxShape.circle),
                                    child: Padding(
                                      padding: EdgeInsets.all(4),
                                      child: Icon(Icons.text_snippet_outlined, size: 18, color: Colors.white),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(asset.type.label, style: theme.textTheme.bodySmall),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ],
    );
  }
}

class _BarcodeScannerScreen extends StatefulWidget {
  const _BarcodeScannerScreen();

  @override
  State<_BarcodeScannerScreen> createState() => _BarcodeScannerScreenState();
}

class _BarcodeScannerScreenState extends State<_BarcodeScannerScreen>
    with WidgetsBindingObserver {
  final _picker = ImagePicker();
  late final MobileScannerController _controller;
  StreamSubscription<BarcodeCapture>? _barcodeSubscription;
  Future<void>? _cameraOperation;
  bool _completed = false;
  bool _torchOn = false;
  bool _isAnalyzing = false;
  bool _isPickingImage = false;

  bool get _isBusy => _isAnalyzing || _isPickingImage;

  @override
  void initState() {
    super.initState();
    _controller = MobileScannerController(
      autoStart: false,
      detectionSpeed: DetectionSpeed.normal,
      facing: CameraFacing.back,
    );
    WidgetsBinding.instance.addObserver(this);
    _barcodeSubscription = _controller.barcodes.listen(
      _onDetect,
      onError: _onBarcodeError,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_startCamera());
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The permission dialog itself may trigger lifecycle changes before the
    // controller has finished initializing. Do not race that initial start.
    if (_completed || _isPickingImage || !_controller.value.hasCameraPermission) {
      return;
    }

    switch (state) {
      case AppLifecycleState.resumed:
        unawaited(_startCamera());
        return;
      case AppLifecycleState.inactive:
      case AppLifecycleState.hidden:
      case AppLifecycleState.paused:
        unawaited(_stopCamera());
        return;
      case AppLifecycleState.detached:
        return;
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_barcodeSubscription?.cancel());
    unawaited(_controller.dispose());
    super.dispose();
  }

  void _onDetect(BarcodeCapture capture) {
    if (_completed) return;
    for (final barcode in capture.barcodes) {
      final value = barcode.rawValue?.trim();
      if (value != null && RegExp(r'^\d{8,14}$').hasMatch(value)) {
        _completed = true;
        unawaited(_stopCamera());
        Navigator.of(context).pop(value);
        return;
      }
    }
  }

  void _onBarcodeError(Object error, StackTrace stackTrace) {
    debugPrint('Barcode scan frame failed: $error');
    debugPrintStack(stackTrace: stackTrace);
  }

  Future<void> _queueCameraOperation(Future<void> Function() operation) {
    final previous = _cameraOperation;
    final next = () async {
      try {
        if (previous != null) await previous;
        await operation();
      } catch (error, stackTrace) {
        debugPrint('Barcode camera operation failed: $error');
        debugPrintStack(stackTrace: stackTrace);
      }
    }();
    _cameraOperation = next;
    unawaited(
      next.whenComplete(() {
        if (identical(_cameraOperation, next)) _cameraOperation = null;
      }),
    );
    return next;
  }

  void _logCameraError(String operation, MobileScannerException error) {
    final details = error.errorDetails;
    debugPrint('Barcode camera $operation failed: $error');
    debugPrint('Barcode camera platform code: ${details?.code}');
    debugPrint('Barcode camera platform details: ${details?.details}');
  }

  Future<void> _startCamera() => _queueCameraOperation(() async {
        if (!mounted || _completed) return;
        await _controller.start();
        final error = _controller.value.error;
        if (error != null) _logCameraError('start', error);
      });

  Future<void> _stopCamera() => _queueCameraOperation(() async {
        if (_controller.value.isRunning) await _controller.stop();
      });

  Future<void> _retryCamera() => _queueCameraOperation(() async {
        if (!mounted || _completed) return;
        await _controller.stop();
        await _controller.start();
        final error = _controller.value.error;
        if (error != null) _logCameraError('restart', error);
      });

  Future<void> _toggleTorch() async {
    try {
      await _controller.toggleTorch();
      if (mounted) setState(() => _torchOn = !_torchOn);
    } catch (error, stackTrace) {
      debugPrint('Barcode torch operation failed: $error');
      debugPrintStack(stackTrace: stackTrace);
    }
  }

  Future<void> _scanFromImage(ImageSource source) async {
    if (_isBusy) return;
    setState(() => _isPickingImage = true);
    try {
      // image_picker may open another camera activity. Release the CameraX
      // preview first so the two camera clients never contend for the lens.
      await _stopCamera();
      final file = await _picker.pickImage(source: source, imageQuality: 100);
      if (file == null || !mounted) return;
      setState(() => _isAnalyzing = true);

      final capture = await _controller.analyzeImage(file.path);
      if (capture != null && capture.barcodes.isNotEmpty) {
        for (final barcode in capture.barcodes) {
          final value = barcode.rawValue?.trim();
          if (value != null && RegExp(r'^\d{8,14}$').hasMatch(value)) {
            _completed = true;
            if (mounted) Navigator.of(context).pop(value);
            return;
          }
        }
      }
      if (mounted) {
        showAppSnackBar(context,
          const SnackBar(content: Text('图片中未识别到有效商品条码，请调整拍摄角度或光线后重试。')),
        );
      }
    } catch (error, stackTrace) {
      debugPrint('Barcode image analysis failed: $error');
      debugPrintStack(stackTrace: stackTrace);
      if (mounted) {
        showAppSnackBar(context,
          const SnackBar(content: Text('识别图片条码失败，请稍后重试。')),
        );
      }
    } finally {
      if (mounted) {
        setState(() {
          _isPickingImage = false;
          _isAnalyzing = false;
        });
        if (!_completed) unawaited(_startCamera());
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Scaffold(
      appBar: MomoGlassAppBar(
        title: const Text('扫描商品条码'),
        leading: IconButton(
          icon: const Icon(Icons.close),
          tooltip: '关闭',
          onPressed: () => Navigator.of(context).pop(),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.photo_library_outlined),
            tooltip: '从相册选择识别',
            onPressed: _isBusy ? null : () => _scanFromImage(ImageSource.gallery),
          ),
          IconButton(
            icon: const Icon(Icons.camera_alt_outlined),
            tooltip: '拍照识别条码',
            onPressed: _isBusy ? null : () => _scanFromImage(ImageSource.camera),
          ),
          IconButton(
            icon: Icon(_torchOn ? Icons.flash_on : Icons.flash_off),
            tooltip: '开关手电筒',
            onPressed: _isBusy ? null : _toggleTorch,
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(24),
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    const ColoredBox(color: Colors.black),
                    MobileScanner(
                      controller: _controller,
                      onDetect: null,
                      errorBuilder: (context, error) {
                        final errorName = error.errorCode.name;
                        final errorDetails = error.errorDetails?.message?.trim();
                        final statusText = errorDetails == null || errorDetails.isEmpty
                            ? '状态：$errorName\n实时预览未能启动。请点击下方“重试启动”；如仍失败，可使用“拍照识别”继续完成入库。'
                            : '状态：$errorName\n$errorDetails\n可点击下方“重试启动”；如仍失败，可使用“拍照识别”继续完成入库。';
                        return ColoredBox(
                          color: theme.colorScheme.surface,
                          child: Center(
                            child: SingleChildScrollView(
                              padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 20),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(Icons.videocam_off_outlined, color: theme.colorScheme.onSurfaceVariant, size: 48),
                                  const SizedBox(height: 14),
                                  Text(
                                    '无法访问实时摄像头',
                                    style: TextStyle(color: theme.colorScheme.onSurface, fontSize: MomoTextSize.section, fontWeight: FontWeight.bold),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    statusText,
                                    style: TextStyle(color: theme.colorScheme.onSurfaceVariant, fontSize: MomoTextSize.body, height: 1.4),
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 20),
                                  Wrap(
                                    spacing: 10,
                                    runSpacing: 10,
                                    alignment: WrapAlignment.center,
                                    children: [
                                      FilledButton.icon(
                                        onPressed: _isBusy ? null : _retryCamera,
                                        icon: const Icon(Icons.refresh, size: 18),
                                        label: const Text('重试开启'),
                                      ),
                                      FilledButton.tonalIcon(
                                        onPressed: _isBusy ? null : () => _scanFromImage(ImageSource.camera),
                                        icon: const Icon(Icons.camera_alt, size: 18),
                                        label: const Text('拍照识别'),
                                      ),
                                      FilledButton.tonalIcon(
                                        onPressed: _isBusy ? null : () => _scanFromImage(ImageSource.gallery),
                                        icon: const Icon(Icons.photo_library, size: 18),
                                        label: const Text('相册识别'),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  TextButton.icon(
                                    onPressed: () => Navigator.of(context).pop(),
                                    icon: const Icon(Icons.edit_note, size: 18),
                                    label: const Text('返回手动填写'),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    // The guide is decorative only. Without IgnorePointer it
                    // intercepts taps on the error-state action buttons beneath it.
                    IgnorePointer(
                      child: Center(
                        child: Container(
                          width: 260,
                          height: 170,
                          decoration: BoxDecoration(
                            border: Border.all(color: theme.colorScheme.primary.withValues(alpha: 0.9), width: 2.5),
                            borderRadius: BorderRadius.circular(20),
                            boxShadow: [
                              BoxShadow(
                                color: theme.colorScheme.primary.withValues(alpha: 0.25),
                                blurRadius: 16,
                                spreadRadius: 2,
                              ),
                            ],
                          ),
                        ),
                      ),
                    ),
                    if (_isAnalyzing)
                      Container(
                        color: Colors.black54,
                        child: const Center(
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              CircularProgressIndicator(color: Colors.white),
                              SizedBox(height: 14),
                              Text('正在解析条码…', style: TextStyle(color: Colors.white, fontSize: MomoTextSize.body)),
                            ],
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: [
                  MomoGlassCard(
                    margin: EdgeInsets.zero,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.center_focus_strong, color: theme.colorScheme.onSurfaceVariant, size: 16),
                        const SizedBox(width: 6),
                        const Flexible(
                          child: Text('对准条码自动识别', style: TextStyle(fontSize: MomoTextSize.caption)),
                        ),
                      ],
                    ),
                  ),
                  OutlinedButton.icon(
                    onPressed: _isBusy ? null : () => _scanFromImage(ImageSource.camera),
                    icon: const Icon(Icons.camera_alt, size: 16),
                    label: const Text('拍照识别'),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
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
    return Semantics(
      button: true,
      child: InkWell(
        borderRadius: BorderRadius.circular(12),
        onTap: onTap,
        child: InputDecorator(
          decoration: InputDecoration(
            labelText: label,
            floatingLabelBehavior: FloatingLabelBehavior.always,
            suffixIcon: value == null
                ? const Icon(Icons.event_outlined, size: 20)
                : IconButton(tooltip: '清除$label', onPressed: onClear, icon: const Icon(Icons.clear, size: 20)),
          ),
          child: Text(selected, style: Theme.of(context).textTheme.bodyMedium),
        ),
      ),
    );
  }
}

String? _dateText(DateTime? value) => value == null ? null : '${value.year}-${value.month.toString().padLeft(2, '0')}-${value.day.toString().padLeft(2, '0')}';
