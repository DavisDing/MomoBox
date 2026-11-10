import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../domain/models/recognition_models.dart';
import '../controllers/providers.dart';

/// Product photography always comes from the saved product, never demo art.
class MomoProductImage extends ConsumerWidget {
  const MomoProductImage({required this.productId, super.key});

  final String productId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final assets = ref.watch(
      mediaAssetsProvider((entityType: 'product', entityId: productId)),
    );
    final photos = assets.valueOrNull?.where(
      (asset) => asset.type == MediaAssetType.productImage,
    );
    final path =
        photos != null && photos.isNotEmpty ? photos.first.localPath : null;
    Widget placeholder() => Center(
      child: Icon(
        Icons.inventory_2_outlined,
        size: 32,
        color: Theme.of(context).colorScheme.primary.withValues(alpha: .6),
      ),
    );
    return ColoredBox(
      color: Theme.of(context).colorScheme.primaryContainer,
      child:
          path == null
              ? placeholder()
              : Image.file(
                File(path),
                fit: BoxFit.cover,
                errorBuilder: (_, __, ___) => placeholder(),
              ),
    );
  }
}
