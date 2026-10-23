import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// Call sites choose an event code; messages and application data are never
/// accepted as log fields.
enum DiagnosticEvent {
  frameworkError,
  unhandledAsyncError,
  notificationInitializationFailed,
  notificationTimeZoneFailed,
  systemUiSetupFailed,
  diagnosticsExportFailed,
}

class DiagnosticLogService {
  DiagnosticLogService({
    Future<Directory> Function()? directoryProvider,
    DateTime Function()? now,
    this.maxFileBytes = 64 * 1024,
    this.retainedFiles = 3,
  }) : assert(maxFileBytes >= 512),
       assert(retainedFiles >= 1 && retainedFiles <= 5),
       _directoryProvider = directoryProvider ?? _defaultDirectory,
       _now = now ?? DateTime.now;

  static final shared = DiagnosticLogService();

  final Future<Directory> Function() _directoryProvider;
  final DateTime Function() _now;
  final int maxFileBytes;
  final int retainedFiles;
  Future<void> _pending = Future<void>.value();
  bool _handlersInstalled = false;
  int _queuedWrites = 0;

  // Static source labels deliberately omit filesystem/package paths and
  // arbitrary function names. Unrecognized frames are excluded.
  static const _sources = <String, String>{
    'package:momo_box/main.dart': 'main',
    'package:momo_box/app/momo_box_app.dart': 'app',
    'package:momo_box/application/inventory_service.dart': 'inventory-service',
    'package:momo_box/application/shopping_service.dart': 'shopping-service',
    'package:momo_box/application/initial_import_service.dart':
        'initial-import',
    'package:momo_box/application/sync_business_adapter.dart': 'sync-adapter',
    'package:momo_box/application/sync_engine.dart': 'sync-engine',
    'package:momo_box/application/sync_scheduler.dart': 'sync-scheduler',
    'package:momo_box/application/nas_auth_service.dart': 'authentication',
    'package:momo_box/application/ai_assistant_service.dart': 'ai-assistant',
    'package:momo_box/application/ai_conversation_store.dart':
        'ai-conversation',
    'package:momo_box/application/ai_inventory_action_service.dart':
        'ai-actions',
    'package:momo_box/application/media_service.dart': 'media',
    'package:momo_box/application/backup_service.dart': 'backup-service',
    'package:momo_box/data/repositories/inventory_repository.dart':
        'inventory-repository',
    'package:momo_box/data/repositories/shopping_repository.dart':
        'shopping-repository',
    'package:momo_box/data/repositories/backup_repository.dart':
        'backup-repository',
    'package:momo_box/data/repositories/sync_outbox_repository.dart':
        'sync-outbox',
    'package:momo_box/data/nas/nas_api_client.dart': 'nas-client',
    'package:momo_box/presentation/controllers/providers.dart': 'providers',
    'package:momo_box/presentation/screens/settings_screen.dart': 'settings',
    'package:momo_box/presentation/widgets/intake_sheet.dart': 'intake',
    'package:momo_box/services/local_notification_service.dart':
        'notifications',
    'package:momo_box/services/calendar_sync_service.dart': 'calendar',
  };
  static const _errorTypes = <String>{
    'Error',
    'Exception',
    'StateError',
    'ArgumentError',
    'RangeError',
    'FormatException',
    'TypeError',
    '_TypeError',
    'NoSuchMethodError',
    'UnsupportedError',
    'UnimplementedError',
    'AssertionError',
    '_AssertionError',
    'SocketException',
    'HttpException',
    'HandshakeException',
    'TimeoutException',
    'FileSystemException',
    'PathNotFoundException',
    'PathAccessException',
    'PlatformException',
    'MissingPluginException',
    'SqliteException',
    'SqliteExceptionImpl',
    'DriftWrappedException',
    'NasApiError',
    'BackupImportException',
    'SyncRemoteChangeDeferred',
    'OtherError',
  };

  static Future<Directory> _defaultDirectory() async {
    final parent = await getApplicationSupportDirectory();
    return Directory('${parent.path}${Platform.pathSeparator}diagnostics');
  }

  /// Preserve framework presentation and the previous asynchronous handler's
  /// return value. With no prior dispatcher handler, false leaves the error
  /// unhandled by Dart's normal propagation path.
  void installErrorHandlers() {
    if (_handlersInstalled) return;
    _handlersInstalled = true;
    final frameworkHandler = FlutterError.onError;
    FlutterError.onError = (details) {
      unawaited(
        record(
          DiagnosticEvent.frameworkError,
          details.exception,
          stackTrace: details.stack,
        ),
      );
      if (frameworkHandler != null) {
        frameworkHandler(details);
      } else {
        FlutterError.presentError(details);
      }
    };
    final asynchronousHandler = PlatformDispatcher.instance.onError;
    PlatformDispatcher.instance.onError = (error, stack) {
      unawaited(
        record(DiagnosticEvent.unhandledAsyncError, error, stackTrace: stack),
      );
      return asynchronousHandler?.call(error, stack) ?? false;
    };
  }

  Future<T> _serialized<T>(Future<T> Function() action) {
    final operation = _pending.then((_) => action());
    _pending = operation.then<void>(
      (_) {},
      onError: (Object _, StackTrace __) {},
    );
    return operation;
  }

  /// Logging is best effort and must never replace the original failure or
  /// prevent offline startup. In particular, error.toString() is never read.
  Future<void> record(
    DiagnosticEvent event,
    Object error, {
    StackTrace? stackTrace,
  }) async {
    if (_queuedWrites >= 128) return;
    _queuedWrites++;
    try {
      final type = error.runtimeType.toString();
      final record = <String, dynamic>{
        'time': _now().toUtc().toIso8601String(),
        'event': event.name,
        'error_type': _errorTypes.contains(type) ? type : 'OtherError',
        'frames': _frames(stackTrace),
      };
      await _serialized(() => _append(record));
    } catch (_) {
      // A full disk, unavailable plugin or malformed stack cannot poison the
      // serial queue or change the application's existing error behavior.
    } finally {
      _queuedWrites--;
    }
  }

  Future<void> flush() => _pending;

  List<Map<String, dynamic>> _frames(StackTrace? stack) {
    if (stack == null) return [];
    final result = <Map<String, dynamic>>[];
    final text = stack.toString();
    final bounded = text.length > 16384 ? text.substring(0, 16384) : text;
    for (final frame in bounded.split('\n').take(64)) {
      for (final source in _sources.entries) {
        final match = RegExp(
          '${RegExp.escape(source.key)}:(\\d{1,7}):(\\d{1,7})(?:\\)|\\s|\$)',
        ).firstMatch(frame);
        if (match == null) continue;
        result.add({
          'source': source.value,
          'line': int.parse(match.group(1)!),
          'column': int.parse(match.group(2)!),
        });
        break;
      }
      if (result.length == 8) break;
    }
    return result;
  }

  File _file(Directory directory, int index) =>
      File('${directory.path}${Platform.pathSeparator}events-$index.jsonl');

  Future<Directory> _directory() async {
    final directory = await _directoryProvider();
    await directory.create(recursive: true);
    return directory;
  }

  Future<void> _append(Map<String, dynamic> record) async {
    List<int> bytes = utf8.encode('${jsonEncode(record)}\n');
    final frames = record['frames'] as List<Map<String, dynamic>>;
    while (bytes.length > maxFileBytes && frames.isNotEmpty) {
      frames.removeLast();
      bytes = utf8.encode('${jsonEncode(record)}\n');
    }
    if (bytes.length > maxFileBytes) return;
    final directory = await _directory();
    final current = _file(directory, 0);
    final length = await current.exists() ? await current.length() : 0;
    var needsNewline = false;
    if (length > 0) {
      final input = await current.open();
      try {
        await input.setPosition(length - 1);
        needsNewline = await input.readByte() != 10;
      } finally {
        await input.close();
      }
    }
    if (length + bytes.length + (needsNewline ? 1 : 0) > maxFileBytes) {
      needsNewline = false;
      if (retainedFiles == 1) {
        await current.delete();
      } else {
        for (var index = retainedFiles - 1; index >= 1; index--) {
          final destination = _file(directory, index);
          if (await destination.exists()) await destination.delete();
          final source = _file(directory, index - 1);
          if (await source.exists()) await source.rename(destination.path);
        }
      }
    }
    if (needsNewline) bytes = [10, ...bytes];
    await current.writeAsBytes(bytes, mode: FileMode.append, flush: true);
  }

  /// Rebuild exports from known schema fields, even when an existing log was
  /// damaged or modified. Bounded reads prevent oversized files from causing
  /// unbounded memory use during export.
  Future<String> exportJson() => _serialized(() async {
    final directory = await _directory();
    final events = <Map<String, dynamic>>[];
    for (var index = retainedFiles - 1; index >= 0; index--) {
      final file = _file(directory, index);
      if (!await file.exists()) continue;
      final input = await file.open();
      try {
        final length = await input.length();
        final offset = length > maxFileBytes ? length - maxFileBytes : 0;
        await input.setPosition(offset);
        var content = utf8.decode(
          await input.read(maxFileBytes),
          allowMalformed: true,
        );
        if (offset > 0) {
          final newline = content.indexOf('\n');
          content = newline < 0 ? '' : content.substring(newline + 1);
        }
        for (final line in content.split('\n')) {
          final event = _safeStoredEvent(line);
          if (event != null) events.add(event);
        }
      } finally {
        await input.close();
      }
    }
    return const JsonEncoder.withIndent('  ').convert({
      'format': 'momobox-diagnostics',
      'version': 1,
      'exported_at': _now().toUtc().toIso8601String(),
      'coverage': 'dart-framework-and-async-errors',
      'events': events,
    });
  });

  Map<String, dynamic>? _safeStoredEvent(String line) {
    try {
      final raw = jsonDecode(line);
      if (raw is! Map ||
          raw['time'] is! String ||
          !DiagnosticEvent.values.any((event) => event.name == raw['event']) ||
          !_errorTypes.contains(raw['error_type']) ||
          raw['frames'] is! List) {
        return null;
      }
      final time = DateTime.tryParse(raw['time'] as String);
      if (time == null) return null;
      final frames = <Map<String, dynamic>>[];
      for (final frame in (raw['frames'] as List).take(8)) {
        if (frame is! Map ||
            !_sources.values.contains(frame['source']) ||
            frame['line'] is! int ||
            frame['column'] is! int) {
          continue;
        }
        final line = frame['line'] as int;
        final column = frame['column'] as int;
        if (line < 1 || line > 9999999 || column < 1 || column > 9999999) {
          continue;
        }
        frames.add({'source': frame['source'], 'line': line, 'column': column});
      }
      return {
        'time': time.toUtc().toIso8601String(),
        'event': raw['event'],
        'error_type': raw['error_type'],
        'frames': frames,
      };
    } catch (_) {
      return null;
    }
  }
}
