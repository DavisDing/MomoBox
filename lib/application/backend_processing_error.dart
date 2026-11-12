/// A local, safe-to-display setup failure. Never wrap upstream response text.
class BackendProcessingSetupException implements Exception {
  const BackendProcessingSetupException(this.message);
  final String message;

  @override
  String toString() => message;
}
