import '../data/repositories/backup_repository.dart';

class BackupService {
  BackupService(this._repository, {this.synchronizeAfterRestore});

  final BackupRepository _repository;
  final Future<void> Function()? synchronizeAfterRestore;

  Future<void> synchronizeRestoredData() async =>
      synchronizeAfterRestore?.call();

  Future<String> exportJson() => _repository.exportJson();

  Future<ImportReport> importJson(String content) =>
      _repository.importJson(content);
}
