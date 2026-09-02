import '../data/repositories/reminder_repository.dart';
import '../domain/models/inventory_models.dart';

class ReminderService {
  ReminderService(this._repository);

  final ReminderRepository _repository;

  Stream<List<ReminderAcknowledgement>> watchAcknowledgements() =>
      _repository.watchAcknowledgements();

  Future<void> acknowledge({required String reminderKey, required String fingerprint}) =>
      _repository.acknowledge(reminderKey: reminderKey, fingerprint: fingerprint);

  Future<void> reconcile(List<InventoryItem> items) =>
      _repository.clearRecoveredLowStockAcknowledgements(items);

  Future<void> acknowledgeAll(
    Iterable<({String reminderKey, String fingerprint})> reminders,
  ) =>
      _repository.acknowledgeAll(reminders);
}
