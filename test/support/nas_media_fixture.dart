import 'package:momo_box/application/backend_processing_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/media_repository.dart';
import 'package:momo_box/services/media_storage_service.dart';

BackendProcessingService unavailableMediaBackend(
  AppDatabase db,
  MediaRepository repo,
  MediaStorageService storage,
) => BackendProcessingService(
  db,
  repo,
  storage,
  resolveApi: () async => throw StateError('NAS offline'),
  scopeId: () => 'family',
);
