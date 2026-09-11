import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../data/repositories/mock_smart_home_repository.dart';
import '../../domain/models/smart_home_models.dart';

final mockSmartHomeRepositoryProvider = Provider<MockSmartHomeRepository>((ref) {
  return MockSmartHomeRepository();
});

class SmartHomeState {
  const SmartHomeState({
    required this.devices,
    required this.scenes,
    required this.logs,
    required this.haStatus,
    required this.haAddress,
    required this.nasAddress,
    required this.nasOnline,
    this.isLoading = false,
  });

  final List<SmartDevice> devices;
  final List<SmartScene> scenes;
  final List<ConsumableLinkageLog> logs;
  final HaConnectionStatus haStatus;
  final String haAddress;
  final String nasAddress;
  final bool nasOnline;
  final bool isLoading;

  SmartHomeState copyWith({
    List<SmartDevice>? devices,
    List<SmartScene>? scenes,
    List<ConsumableLinkageLog>? logs,
    HaConnectionStatus? haStatus,
    String? haAddress,
    String? nasAddress,
    bool? nasOnline,
    bool? isLoading,
  }) {
    return SmartHomeState(
      devices: devices ?? this.devices,
      scenes: scenes ?? this.scenes,
      logs: logs ?? this.logs,
      haStatus: haStatus ?? this.haStatus,
      haAddress: haAddress ?? this.haAddress,
      nasAddress: nasAddress ?? this.nasAddress,
      nasOnline: nasOnline ?? this.nasOnline,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class SmartHomeController extends StateNotifier<SmartHomeState> {
  SmartHomeController(this._repository)
      : super(
          SmartHomeState(
            devices: _repository.devices,
            scenes: _repository.scenes,
            logs: _repository.logs,
            haStatus: _repository.haStatus,
            haAddress: _repository.haAddress,
            nasAddress: _repository.nasAddress,
            nasOnline: _repository.nasOnline,
          ),
        );

  final MockSmartHomeRepository _repository;

  void toggleDevice(String id) {
    _repository.toggleDevice(id);
    state = state.copyWith(devices: _repository.devices);
  }

  void updateClimateTemperature(String id, double delta) {
    _repository.updateClimateTemperature(id, delta);
    state = state.copyWith(devices: _repository.devices);
  }

  void updateLightBrightness(String id, int brightness) {
    _repository.updateLightBrightness(id, brightness);
    state = state.copyWith(devices: _repository.devices);
  }

  void confirmConsumableLog(String id) {
    _repository.confirmConsumableLog(id);
    state = state.copyWith(logs: _repository.logs);
  }

  void ignoreConsumableLog(String id) {
    _repository.ignoreConsumableLog(id);
    state = state.copyWith(logs: _repository.logs);
  }

  void setHaConnectionStatus(HaConnectionStatus status) {
    _repository.setHaConnectionStatus(status);
    state = state.copyWith(haStatus: _repository.haStatus);
  }

  Future<void> refresh() async {
    state = state.copyWith(isLoading: true);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    state = state.copyWith(
      isLoading: false,
      devices: _repository.devices,
      scenes: _repository.scenes,
      logs: _repository.logs,
      haStatus: _repository.haStatus,
    );
  }
}

final smartHomeControllerProvider =
    StateNotifierProvider<SmartHomeController, SmartHomeState>((ref) {
  final repo = ref.watch(mockSmartHomeRepositoryProvider);
  return SmartHomeController(repo);
});
