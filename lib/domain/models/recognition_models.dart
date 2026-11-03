import '../inventory/expiry_rules.dart';

class BarcodeLookupResult {
  const BarcodeLookupResult({
    required this.barcode,
    required this.source,
    this.name,
    this.brand,
    this.specification,
    this.category,
  });

  final String barcode;
  final String source;
  final String? name;
  final String? brand;
  final String? specification;
  final String? category;

  bool get hasProductData => [name, brand, specification, category].any(
        (value) => value != null && value.trim().isNotEmpty,
      );

  Map<String, Object?> toJson() => {
        'name': name,
        'brand': brand,
        'specification': specification,
        'category': category,
      };

  factory BarcodeLookupResult.fromJson({
    required String barcode,
    required String source,
    required Map<String, dynamic> json,
  }) =>
      BarcodeLookupResult(
        barcode: barcode,
        source: source,
        name: _stringOrNull(json['name']),
        brand: _stringOrNull(json['brand']),
        specification: _stringOrNull(json['specification']),
        category: _stringOrNull(json['category']),
      );
}

enum MediaAssetType {
  productImage('product_image', '商品图片'),
  instructionImage('instruction_image', '说明书图片');

  const MediaAssetType(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static MediaAssetType fromStorageValue(String value) =>
      MediaAssetType.values.firstWhere(
        (type) => type.storageValue == value,
        orElse: () => MediaAssetType.productImage,
      );
}

class MediaAsset {
  const MediaAsset({
    required this.id,
    required this.entityType,
    required this.entityId,
    required this.type,
    required this.localPath,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
    required this.createdAt,
    this.width,
    this.height,
    this.ocrText,
    this.ocrUpdatedAt,
    this.backendState,
    this.backendError,
  });

  final String? backendState;
  final String? backendError;
  String? get backendStatusLabel => switch (backendState) {
    'uploading' => '上传中', 'failed' => '上传待重试',
    'download_failed' => '图片恢复待重试',
    'synced' => '已上传后端', 'ocr_processing' => '后端 OCR 中',
    'ocr_failed' => '后端 OCR 待重试', 'ocr_complete' => '后端 OCR 完成',
    'deleting' => '删除待同步', _ => null,
  };

  final String id;
  final String entityType;
  final String entityId;
  final MediaAssetType type;
  final String localPath;
  final String mimeType;
  final int sizeBytes;
  final int? width;
  final int? height;
  final String sha256;
  final String? ocrText;
  final DateTime? ocrUpdatedAt;
  final DateTime createdAt;

  bool get hasOcrText => ocrText != null && ocrText!.trim().isNotEmpty;
}

class MediaCleanupReport {
  const MediaCleanupReport({
    required this.deletedFiles,
    required this.deletedMetadata,
  });

  final int deletedFiles;
  final int deletedMetadata;
}

class IntakeDraftSuggestion {
  const IntakeDraftSuggestion({
    this.name,
    this.brand,
    this.specification,
    this.category,
    this.batchNo,
    this.productionDate,
    this.expiryDate,
    this.shelfLifeAmount,
    this.shelfLifeUnit,
    this.datePrecision,
    this.notes,
  });

  final String? name;
  final String? brand;
  final String? specification;
  final String? category;
  final String? batchNo;
  final DateTime? productionDate;
  final DateTime? expiryDate;
  final int? shelfLifeAmount;
  final ShelfLifeUnit? shelfLifeUnit;
  final String? datePrecision;
  final String? notes;

  bool get isEmpty =>
      [name, brand, specification, category, batchNo, notes].every((value) => value == null) &&
      productionDate == null &&
      expiryDate == null &&
      shelfLifeAmount == null;
}

String? stringOrNull(Object? value) => _stringOrNull(value);

String? _stringOrNull(Object? value) {
  if (value is! String) return null;
  final trimmed = value.trim();
  return trimmed.isEmpty ? null : trimmed;
}
