import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

import '../app/momo_theme.dart';

class AppRelease {
  const AppRelease({
    required this.tagName,
    required this.name,
    required this.htmlUrl,
    required this.publishedAt,
    required this.body,
    required this.apkUrl,
    this.apkSha256,
  });

  final String tagName;
  final String name;
  final String htmlUrl;
  final DateTime? publishedAt;
  final String body;
  final String? apkUrl;
  final String? apkSha256;

  String get version => tagName.replaceFirst(RegExp(r'^[vV]'), '');
}

class UpdateCheckResult {
  const UpdateCheckResult({required this.currentVersion, this.release});

  final String currentVersion;
  final AppRelease? release;

  bool get hasUpdate => release != null && UpdateService.compareVersions(release!.version, currentVersion) > 0;
}

class UpdateService {
  UpdateService({http.Client? client}) : _client = client ?? http.Client();

  static const latestReleaseApi = 'https://api.github.com/repos/DavisDing/MomoBox/releases/latest';
  static const _channel = MethodChannel('com.example.momo_box/update');
  final http.Client _client;

  Future<UpdateCheckResult> checkForUpdates() async {
    final response = await _client.get(
      Uri.parse(latestReleaseApi),
      headers: const {
        'Accept': 'application/vnd.github+json',
        'User-Agent': 'MomoBox-updater',
      },
    ).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200) {
      throw Exception('GitHub Releases 返回 HTTP ${response.statusCode}');
    }
    final json = jsonDecode(response.body);
    if (json is! Map<String, dynamic>) throw const FormatException('Release 数据格式无效');
    final assets = (json['assets'] as List<dynamic>? ?? const [])
        .whereType<Map<String, dynamic>>()
        .toList();
    final apk = assets.firstWhere(
      (asset) => (asset['name']?.toString() ?? '').toLowerCase().endsWith('.apk'),
      orElse: () => <String, dynamic>{},
    );
    final checksumAsset = assets.firstWhere(
      (asset) => (asset['name']?.toString() ?? '').toLowerCase() == 'sha256sums.txt',
      orElse: () => <String, dynamic>{},
    );
    String? checksum;
    final checksumUrl = checksumAsset['browser_download_url']?.toString();
    if (checksumUrl != null && checksumUrl.isNotEmpty) {
      final checksumResponse = await _client.get(Uri.parse(checksumUrl)).timeout(const Duration(seconds: 10));
      if (checksumResponse.statusCode == 200) {
        checksum = _parseChecksum(checksumResponse.body, apk['name']?.toString());
      }
    }

    return UpdateCheckResult(
      currentVersion: MomoAppInfo.appVersion,
      release: AppRelease(
        tagName: json['tag_name']?.toString() ?? '',
        name: json['name']?.toString() ?? json['tag_name']?.toString() ?? '新版本',
        htmlUrl: json['html_url']?.toString() ?? 'https://github.com/DavisDing/MomoBox/releases',
        publishedAt: DateTime.tryParse(json['published_at']?.toString() ?? ''),
        body: json['body']?.toString() ?? '',
        apkUrl: apk['browser_download_url']?.toString(),
        apkSha256: checksum,
      ),
    );
  }

  Future<File> downloadApk(AppRelease release, {void Function(int received, int total)? onProgress}) async {
    final url = release.apkUrl;
    if (url == null || url.isEmpty) throw const FormatException('此 Release 没有 APK 产物');
    final response = await _client.send(http.Request('GET', Uri.parse(url))).timeout(const Duration(seconds: 30));
    if (response.statusCode != 200) throw Exception('APK 下载失败：HTTP ${response.statusCode}');

    final directory = await getApplicationDocumentsDirectory();
    final safeVersion = release.version.replaceAll(RegExp(r'[^A-Za-z0-9._-]+'), '_');
    final file = File('${directory.path}/MomoBox-${safeVersion.isEmpty ? 'latest' : safeVersion}.apk');
    final sink = file.openWrite();
    var received = 0;
    final total = response.contentLength ?? -1;
    await for (final chunk in response.stream) {
      sink.add(chunk);
      received += chunk.length;
      onProgress?.call(received, total);
    }
    await sink.close();

    if (release.apkSha256 != null && release.apkSha256!.isNotEmpty) {
      final digest = await sha256.bind(file.openRead()).first;
      if (digest.toString().toLowerCase() != release.apkSha256!.toLowerCase()) {
        await file.delete();
        throw const FormatException('APK SHA-256 校验失败，已删除下载文件');
      }
    }
    return file;
  }

  Future<void> installApk(File file) async {
    await _channel.invokeMethod<void>('installApk', {'path': file.path});
  }

  Future<void> openReleasePage(String url) async {
    await _channel.invokeMethod<void>('openUrl', {'url': url});
  }

  void close() => _client.close();

  static String? _parseChecksum(String body, String? fileName) {
    if (fileName == null || fileName.isEmpty) return null;
    for (final line in const LineSplitter().convert(body)) {
      final parts = line.trim().split(RegExp(r'\s+'));
      if (parts.length >= 2 &&
          (parts.last == fileName || parts.last.replaceAll('\\', '/').endsWith('/$fileName')) &&
          RegExp(r'^[a-fA-F0-9]{64}$').hasMatch(parts.first)) {
        return parts.first;
      }
    }
    return null;
  }

  static int compareVersions(String left, String right) {
    final a = _versionParts(left);
    final b = _versionParts(right);
    for (var i = 0; i < 3; i++) {
      if (a[i] != b[i]) return a[i].compareTo(b[i]);
    }
    return 0;
  }

  static List<int> _versionParts(String value) {
    final normalized = value.trim().replaceFirst(RegExp(r'^[vV]'), '').split('+').first.split('-').first;
    final numbers = normalized.split('.').map((part) => int.tryParse(part) ?? 0).take(3).toList();
    while (numbers.length < 3) {
      numbers.add(0);
    }
    return numbers;
  }
}
