import '../../domain/models/smart_home_models.dart';

/// Mock Smart Home 仓库
/// 标注：所有数据均为前端标准 Mock 数据，等待 Full-stack Agent 接入后端 NAS 与 Home Assistant 真实服务。
class MockSmartHomeRepository {
  List<SmartDevice> _devices = [
    // 客厅
    const SmartDevice(
      id: 'media_player.living_room_tv',
      name: '客厅电视',
      room: '客厅',
      type: DeviceType.tv,
      isOn: false,
      statusText: '待机',
    ),
    const SmartDevice(
      id: 'light.living_room_main',
      name: '客厅主灯',
      room: '客厅',
      type: DeviceType.light,
      isOn: true,
      brightness: 85,
      statusText: '亮度 85%',
    ),
    const SmartDevice(
      id: 'climate.living_room_ac',
      name: '客厅空调',
      room: '客厅',
      type: DeviceType.climate,
      isOn: true,
      temperature: 25.0,
      mode: '制冷',
      statusText: '制冷 25°C',
    ),

    // 厨房
    const SmartDevice(
      id: 'switch.kitchen_ice_maker',
      name: '智能制冰机',
      room: '厨房',
      type: DeviceType.iceMaker,
      isOn: true,
      statusText: '正在快速制冰 (80%)',
    ),
    const SmartDevice(
      id: 'light.kitchen_ceiling',
      name: '厨房顶灯',
      room: '厨房',
      type: DeviceType.light,
      isOn: false,
      brightness: 70,
      statusText: '已关闭',
    ),

    // 阳台
    const SmartDevice(
      id: 'washer.balcony_smart_washer',
      name: '洗烘一体机',
      room: '阳台',
      type: DeviceType.washer,
      isOn: true,
      washerState: WasherState.completed,
      statusText: '标准洗已完成（待取衣）',
    ),
  ];

  final List<SmartScene> _scenes = const [
    SmartScene(
      id: 'scene.movie_night',
      name: '观影模式',
      icon: '🎬',
      description: '调暗客厅主灯，打开电视并切换音响',
    ),
    SmartScene(
      id: 'scene.back_home',
      name: '温馨回家',
      icon: '🏡',
      description: '开启玄关灯与客厅空调舒适温度',
    ),
    SmartScene(
      id: 'scene.leave_home',
      name: '全屋离家',
      icon: '🚪',
      description: '关闭全部照明与非必要插座',
    ),
    SmartScene(
      id: 'scene.night_sleep',
      name: '夜间整理',
      icon: '🌙',
      description: '关闭主灯，开启柔光小夜灯',
    ),
    SmartScene(
      id: 'scene.shopping_out',
      name: '出门采买',
      icon: '🛍️',
      description: '空调转节能，推送待买耗材提醒',
    ),
  ];

  List<ConsumableLinkageLog> _logs = [
    ConsumableLinkageLog(
      id: 'log-101',
      deviceName: '阳台洗烘一体机',
      eventSummary: '标准洗涤程序顺利结束',
      consumableName: '浓缩洗衣液',
      quantity: 1,
      unit: '份',
      status: ConsumableActionStatus.pending,
      timestamp: DateTime.now().subtract(const Duration(minutes: 18)),
      ruleDescription: '阳台洗衣机完成洗涤 -> 耗材建议扣减洗衣液 1 份',
    ),
    ConsumableLinkageLog(
      id: 'log-100',
      deviceName: '厨房智能制冰机',
      eventSummary: '满冰仓自动停机',
      consumableName: '纯净过滤水',
      quantity: 1,
      unit: '升',
      status: ConsumableActionStatus.deducted,
      timestamp: DateTime.now().subtract(const Duration(hours: 3)),
      ruleDescription: '制冰机满水制冰 -> 自动扣减耗材记录',
    ),
  ];

  HaConnectionStatus _connectionStatus = HaConnectionStatus.online;
  final String _haAddress = 'http://homeassistant.local:8123';
  final String _nasAddress = 'http://nas.local:8080';
  final bool _nasOnline = true;

  // Getters
  List<SmartDevice> get devices => List.unmodifiable(_devices);
  List<SmartScene> get scenes => List.unmodifiable(_scenes);
  List<ConsumableLinkageLog> get logs => List.unmodifiable(_logs);
  HaConnectionStatus get haStatus => _connectionStatus;
  String get haAddress => _haAddress;
  String get nasAddress => _nasAddress;
  bool get nasOnline => _nasOnline;

  // Actions
  void toggleDevice(String id) {
    _devices = _devices.map((d) {
      if (d.id == id) {
        final nextState = !d.isOn;
        return d.copyWith(
          isOn: nextState,
          statusText: nextState ? (d.type == DeviceType.climate ? '${d.mode} ${d.temperature.toStringAsFixed(0)}°C' : '开启') : '已关闭',
        );
      }
      return d;
    }).toList();
  }

  void updateClimateTemperature(String id, double delta) {
    _devices = _devices.map((d) {
      if (d.id == id && d.type == DeviceType.climate) {
        final newTemp = (d.temperature + delta).clamp(16.0, 30.0);
        return d.copyWith(
          temperature: newTemp,
          statusText: '${d.mode} ${newTemp.toStringAsFixed(0)}°C',
        );
      }
      return d;
    }).toList();
  }

  void updateLightBrightness(String id, int brightness) {
    _devices = _devices.map((d) {
      if (d.id == id && d.type == DeviceType.light) {
        return d.copyWith(
          brightness: brightness,
          statusText: '亮度 $brightness%',
        );
      }
      return d;
    }).toList();
  }

  void confirmConsumableLog(String id) {
    _logs = _logs.map((l) {
      if (l.id == id) {
        return l.copyWith(status: ConsumableActionStatus.deducted);
      }
      return l;
    }).toList();
  }

  void ignoreConsumableLog(String id) {
    _logs = _logs.map((l) {
      if (l.id == id) {
        return l.copyWith(status: ConsumableActionStatus.ignored);
      }
      return l;
    }).toList();
  }

  void setHaConnectionStatus(HaConnectionStatus status) {
    _connectionStatus = status;
  }
}
