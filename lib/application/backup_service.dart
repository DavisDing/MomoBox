import '../data/repositories/backup_repository.dart';

class BackupService {
  BackupService(this._repository);

  final BackupRepository _repository;

  Future<String> exportJson() => _repository.exportJson();

  Future<ImportReport> importJson(String content) => _repository.importJson(content);
}
