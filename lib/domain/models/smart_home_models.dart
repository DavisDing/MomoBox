/// Smart Home & Home Assistant 领域与展示模型 (Mock / Contract)
/// 等待 Full-stack Agent 接入真实 NAS HA WebSocket / REST API。

library;

enum HaConnectionStatus {
  online,
  offline,
  syncing,
  unconfigured,
}

enum DeviceType {
  light,
  tv,
  climate,
  iceMaker,
  washer,
  switchDevice,
}

enum WasherState {
  idle,
  running,
  completed,
}

class SmartDevice {
  const SmartDevice({
    required this.id,
    required this.name,
    required this.room,
    required this.type,
    this.isOn = false,
    this.brightness = 80,
    this.temperature = 25.0,
    this.mode = '制冷',
    this.statusText = '已就绪',
    this.washerState = WasherState.idle,
    this.isReachable = true,
  });

  final String id;
  final String name;
  final String room;
  final DeviceType type;
  final bool isOn;
  final int brightness; // 0 - 100
  final double temperature; // 16.0 - 30.0
  final String mode; // 制冷 / 制热 / 送风
  final String statusText;
  final WasherState washerState;
  final bool isReachable;

  SmartDevice copyWith({
    String? id,
    String? name,
    String? room,
    DeviceType? type,
    bool? isOn,
    int? brightness,
    double? temperature,
    String? mode,
    String? statusText,
    WasherState? washerState,
    bool? isReachable,
  }) {
    return SmartDevice(
      id: id ?? this.id,
      name: name ?? this.name,
      room: room ?? this.room,
      type: type ?? this.type,
      isOn: isOn ?? this.isOn,
      brightness: brightness ?? this.brightness,
      temperature: temperature ?? this.temperature,
      mode: mode ?? this.mode,
      statusText: statusText ?? this.statusText,
      washerState: washerState ?? this.washerState,
      isReachable: isReachable ?? this.isReachable,
    );
  }
}

class SmartScene {
  const SmartScene({
    required this.id,
    required this.name,
    required this.icon,
    required this.description,
  });

  final String id;
  final String name;
  final String icon;
  final String description;
}

enum ConsumableActionStatus {
  pending, // 待确认
  deducted, // 已自动扣减
  ignored, // 已忽略
}

class ConsumableLinkageLog {
  const ConsumableLinkageLog({
    required this.id,
    required this.deviceName,
    required this.eventSummary,
    required this.consumableName,
    required this.quantity,
    required this.unit,
    required this.status,
    required this.timestamp,
    this.ruleDescription = '洗涤程序完成触发耗材建议',
  });

  final String id;
  final String deviceName;
  final String eventSummary;
  final String consumableName;
  final int quantity;
  final String unit;
  final ConsumableActionStatus status;
  final DateTime timestamp;
  final String ruleDescription;

  ConsumableLinkageLog copyWith({
    ConsumableActionStatus? status,
  }) {
    return ConsumableLinkageLog(
      id: id,
      deviceName: deviceName,
      eventSummary: eventSummary,
      consumableName: consumableName,
      quantity: quantity,
      unit: unit,
      status: status ?? this.status,
      timestamp: timestamp,
      ruleDescription: ruleDescription,
    );
  }
}
