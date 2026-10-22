import '../../data/repositories/sync_workspace_repository.dart';

enum InitialImportStatus {
  prepared,
  sending,
  awaitingSnapshot,
  completed,
  paused,
  blocked,
  abandoned,
}

enum InitialImportCategoryAction { create, reuse, blocked }

class InitialImportCategory {
  const InitialImportCategory({
    required this.sourceName,
    required this.categoryId,
    required this.action,
    this.reason,
  });

  final String sourceName;
  final String categoryId;
  final InitialImportCategoryAction action;
  final String? reason;
}

/// A read-only preview. It is never permission to upload business data.
class InitialImportPreview {
  const InitialImportPreview({
    required this.importId,
    required this.target,
    required this.localWorkspaceId,
    required this.counts,
    required this.blockers,
    required this.exclusions,
    required this.categories,
    required this.fingerprint,
    required this.familyTimeZone,
    required this.manifest,
  });

  final String importId;
  final SyncWorkspaceIdentity target;
  final String localWorkspaceId;
  final Map<String, int> counts;
  final List<String> blockers;
  final List<String> exclusions;
  final List<InitialImportCategory> categories;
  final String fingerprint;
  final String familyTimeZone;
  final Map<String, dynamic> manifest;

  int get totalCount => counts.values.fold(0, (sum, value) => sum + value);
  bool get canPrepare => blockers.isEmpty;
}

class InitialImportProgress {
  const InitialImportProgress({
    required this.importId,
    required this.status,
    required this.counts,
    required this.acceptedCount,
    required this.totalCount,
    required this.exclusions,
    required this.familyTimeZone,
    this.message,
    this.canAbandon = false,
  });

  final String importId;
  final InitialImportStatus status;
  final Map<String, int> counts;
  final int acceptedCount;
  final int totalCount;
  final List<String> exclusions;
  final String familyTimeZone;
  final String? message;
  final bool canAbandon;

  /// Retain the durable plan even when paused, blocked or the account changes.
  bool get isActive => status != InitialImportStatus.completed &&
      status != InitialImportStatus.abandoned;
  bool get isBusy => status == InitialImportStatus.sending;
  bool get canResume => status == InitialImportStatus.prepared ||
      status == InitialImportStatus.paused ||
      status == InitialImportStatus.awaitingSnapshot ||
      status == InitialImportStatus.blocked;
}
