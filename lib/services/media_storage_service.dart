import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter_image_compress/flutter_image_compress.dart';
import 'package:image_picker/image_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:uuid/uuid.dart';

class StoredImageFile {
  const StoredImageFile({
    required this.path,
    required this.mimeType,
    required this.sizeBytes,
    required this.sha256,
  });

  final String path;
  final String mimeType;
  final int sizeBytes;
  final String sha256;
}

class MediaStorageService {
  MediaStorageService({Uuid? uuid}) : _uuid = uuid ?? const Uuid();

  final Uuid _uuid;

  Future<StoredImageFile> storeImage(XFile source) async {
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty) throw StateError('选择的图片为空。');
    final directory = await _mediaDirectory();
    final outputPath = p.join(directory.path, '${_uuid.v4()}.jpg');
    final compressed = await FlutterImageCompress.compressWithList(
      bytes,
      minWidth: 1920,
      minHeight: 1920,
      quality: 82,
      format: CompressFormat.jpeg,
      keepExif: false,
    );
    if (compressed.isEmpty) {
      throw StateError('图片压缩失败，请更换图片后重试。');
    }
    final output = compressed;
    await File(outputPath).writeAsBytes(output, flush: true);
    return StoredImageFile(
      path: outputPath,
      mimeType: 'image/jpeg',
      sizeBytes: output.length,
      sha256: sha256.convert(output).toString(),
    );
  }

  Future<bool> deleteIfExists(String path) async {
    final file = File(path);
    if (!await file.exists()) return false;
    await file.delete();
    return true;
  }

  Future<Set<String>> existingPaths() async {
    final directory = await _mediaDirectory();
    final paths = <String>{};
    await for (final entity in directory.list(followLinks: false)) {
      if (entity is File) paths.add(entity.path);
    }
    return paths;
  }

  Future<int> deleteUnreferenced(Set<String> referencedPaths) async {
    final paths = await existingPaths();
    var deleted = 0;
    for (final path in paths.difference(referencedPaths)) {
      if (await deleteIfExists(path)) deleted++;
    }
    return deleted;
  }

  Future<Directory> _mediaDirectory() async {
    final directory = await getApplicationDocumentsDirectory();
    final media = Directory(p.join(directory.path, 'media'));
    if (!await media.exists()) await media.create(recursive: true);
    return media;
  }
}
