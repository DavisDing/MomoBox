import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:uuid/uuid.dart';

import '../../application/ai_draft_service.dart';
import '../../application/ai_fallback_executor.dart';
import '../../application/inventory_service.dart';
import '../../application/media_service.dart';
import '../../domain/models/inventory_models.dart';
import '../../domain/models/recognition_models.dart';
import '../../domain/recognition/ai_draft_parser.dart';
import 'product_match_confirmation.dart';
import 'receipt_intake_review.dart';

const receiptCleanupWarning = '小票临时图片暂未清理，可稍后在存储管理中清理。';

class ReceiptRecognitionException implements Exception {
  const ReceiptRecognitionException(this.message);

  final String message;
}

Future<XFile?> pickReceiptImage(BuildContext context) async {
  final source = await showModalBottomSheet<ImageSource>(
    context: context,
    builder:
        (context) => SafeArea(
          child: Wrap(
            children: [
              ListTile(
                leading: const Icon(Icons.camera_alt_outlined),
                title: const Text('拍摄购物小票'),
                onTap: () => Navigator.pop(context, ImageSource.camera),
              ),
              ListTile(
                leading: const Icon(Icons.photo_library_outlined),
                title: const Text('从相册选择小票'),
                onTap: () => Navigator.pop(context, ImageSource.gallery),
              ),
            ],
          ),
        ),
  );
  if (source == null || !context.mounted) return null;
  try {
    return await ImagePicker().pickImage(source: source, imageQuality: 100);
  } on PlatformException {
    throw const ReceiptRecognitionException('无法取得小票图片，请检查相机或相册权限。');
  }
}

Future<bool?> confirmReceiptImage(BuildContext context, XFile image) =>
    showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('发送小票图片'),
            scrollable: true,
            content: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Image.file(
                  File(image.path),
                  height: 220,
                  cacheHeight: 660,
                  fit: BoxFit.contain,
                  semanticLabel: '小票预览',
                  errorBuilder:
                      (_, _, _) => const Icon(Icons.receipt_long_outlined),
                ),
                const SizedBox(height: 12),
                const Text('图片将上传到家庭 NAS 识别。'),
              ],
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('发送图片'),
              ),
            ],
          ),
    );

Future<List<ReceiptLine>?> recognizeReceipt(
  BuildContext context, {
  required XFile image,
  required MediaService media,
  required AiDraftService ai,
  required bool Function() canContinue,
  required VoidCallback onCleanupFailure,
  VoidCallback? onParsing,
}) async {
  const entityType = 'intake_draft';
  final entityId = const Uuid().v4();
  MediaAsset? receipt;
  try {
    final String text;
    try {
      receipt = await media.attachImage(
        source: image,
        entityType: entityType,
        entityId: entityId,
        type: MediaAssetType.productImage,
      );
      if (!canContinue()) return null;
      text = (await media.runOcr(receipt)).trim();
    } catch (_) {
      throw const ReceiptRecognitionException('小票图片上传或文字识别失败，请检查图片和 NAS 连接。');
    }
    if (!context.mounted || !canContinue()) return null;
    if (text.isEmpty) {
      throw const ReceiptRecognitionException('小票上未识别到文字，请重新拍摄。');
    }

    final allowed = await showDialog<bool>(
      context: context,
      builder:
          (context) => AlertDialog(
            title: const Text('确认发送 OCR 文本？'),
            scrollable: true,
            content: Text(
              'NAS 将把小票识别出的文字（约 ${text.length} 字）发送给配置的 AI。'
              '文字可能包含商家或付款信息。原图留在 NAS 的 OCR 流程中。',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () => Navigator.pop(context, true),
                child: const Text('确认发送'),
              ),
            ],
          ),
    );
    if (allowed != true || !canContinue()) return null;
    onParsing?.call();
    try {
      final items = await ai.parseReceiptText(text);
      return canContinue() ? items : null;
    } catch (error) {
      throw ReceiptRecognitionException('小票商品提取失败。${aiFailureMessage(error)}');
    }
  } finally {
    try {
      // Upload can fail after the local asset has been staged.
      final assets =
          receipt != null
              ? [receipt]
              : await media.loadForEntity(
                entityType: entityType,
                entityId: entityId,
              );
      for (final asset in assets) {
        await media.delete(asset);
      }
    } catch (_) {
      onCleanupFailure();
    }
  }
}

/// Runs the same review and atomic inventory write from either entry point.
Future<int?> reviewReceiptIntake(
  BuildContext context, {
  required List<ReceiptLine> items,
  required InventoryService inventory,
  required bool Function() canContinue,
  Future<void> Function()? beforeWrite,
}) async {
  if (!canContinue()) return null;
  final drafts = await showDialog<List<IntakeDraft>>(
    context: context,
    builder: (_) => ReceiptIntakeReview(items),
  );
  if (drafts == null || !canContinue()) return null;
  final plans = <({IntakeDraft draft, String? mergeProductId})>[];
  for (final draft in drafts) {
    final matches = await inventory.findMatchingProducts(draft);
    if (!context.mounted || !canContinue()) return null;
    String? mergeProductId;
    if (matches.isNotEmpty) {
      final decision = await showProductMatchConfirmation(
        context,
        matches,
        draftName: draft.name,
      );
      if (!canContinue() || decision.choice == MatchChoice.cancel) return null;
      mergeProductId = decision.candidate?.id;
    }
    plans.add((draft: draft, mergeProductId: mergeProductId));
  }
  if (!context.mounted || !canContinue()) return null;
  final confirmed = await showDialog<bool>(
    context: context,
    builder:
        (context) => AlertDialog(
          title: const Text('确认批量入库'),
          content: Text('将 ${plans.length} 项已核对的商品分别记为新批次。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('确认入库'),
            ),
          ],
        ),
  );
  if (confirmed != true || !canContinue()) return null;
  await beforeWrite?.call();
  if (!canContinue()) return null;
  await inventory.intakeBatch(plans);
  return plans.length;
}
