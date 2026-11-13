import 'dart:io';
import 'dart:typed_data';
import 'package:cross_file/cross_file.dart';
import 'package:crypto/crypto.dart';
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

  Future<StoredImageFile> storeUploadSource(XFile source) async {
    final bytes = await source.readAsBytes();
    if (bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw StateError('请选择不超过 8 MiB 的 JPEG 或 PNG 图片。');
    }
    return _storeBytes('${_uuid.v4()}.jpg', bytes);
  }

  Future<StoredImageFile> storeBackendImage(String id, List<int> bytes) async {
    if (!RegExp(r'^[0-9a-fA-F-]{36}$').hasMatch(id) || bytes.isEmpty || bytes.length > 8 * 1024 * 1024) {
      throw const FormatException('后端图片无效。');
    }
    return _storeBytes('$id.jpg', bytes);
  }

  Future<StoredImageFile> _storeBytes(String name, List<int> bytes) async {
    final directory = await _mediaDirectory();
    final file = File(p.join(directory.path, name));
    await file.writeAsBytes(Uint8List.fromList(bytes), flush: true);
    final mimeType = bytes.length >= 4 && bytes[0] == 0x89 && bytes[1] == 0x50 && bytes[2] == 0x4e && bytes[3] == 0x47
        ? 'image/png' : 'image/jpeg';
    return StoredImageFile(path: file.path, mimeType: mimeType,
      sizeBytes: bytes.length, sha256: sha256.convert(bytes).toString());
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

  Future<int> totalBytes() async {
    var total = 0;
    for (final path in await existingPaths()) {
      final file = File(path);
      if (await file.exists()) total += await file.length();
    }
    return total;
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
