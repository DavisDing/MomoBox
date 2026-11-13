import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:url_launcher/url_launcher.dart';
import '../../domain/models/home_environment.dart';
import '../../domain/models/nas_homeassistant_models.dart';
import '../../application/home_environment_service.dart';
import '../controllers/providers.dart';
import '../widgets/momo_components.dart';
import '../widgets/momo_mobile_layout.dart';
import 'home_assistant_settings_screen.dart';

class EnvironmentSettingsScreen extends ConsumerStatefulWidget {
  const EnvironmentSettingsScreen({super.key});
  @override
  ConsumerState<EnvironmentSettingsScreen> createState() => _EnvironmentSettingsScreenState();
}

class _EnvironmentSettingsScreenState extends ConsumerState<EnvironmentSettingsScreen> {
  HomeEnvironmentConfig? _draft;
  final _city = TextEditingController();
  List<WeatherPlace> _places = [];
  bool _searching = false, _saving = false;
  String? _error;
  @override
  void initState() {
    super.initState();
    Future.microtask(() { if (mounted) _refreshSensors(); });
  }
  String _sourceDetails() {
    final async = ref.read(homeEnvironmentProvider);
    final data = async.valueOrNull;
    if (data == null) return '尚未读取环境数据。';
    String line(String name, EnvironmentReading? reading) => reading == null ? '$name：未接入' :
      '$name：${reading.value.toStringAsFixed(1)} · ${reading.source}\n${reading.source.startsWith('Open-Meteo') ? '气象数据时间' : '读取时间'}：${reading.observedAt.toLocal()}${reading.isStale(DateTime.now()) ? ' · 上次数据' : ''}';
    return [line('室内温度',data.indoorTemperature),line('室内湿度',data.indoorHumidity),
      line('室外温度',data.outdoorTemperature),line('室外体感',data.apparentTemperature)].join('\n\n');
  }
  @override
  void dispose() { _city.dispose(); super.dispose(); }
  void _update({String? temperature, String? humidity, String? outdoor, String? weather,
    WeatherPlace? place, bool removePlace = false}) {
    final old = _draft ?? const HomeEnvironmentConfig();
    setState(() => _draft = HomeEnvironmentConfig(
      temperatureEntity:temperature ?? old.temperatureEntity,
      humidityEntity:humidity ?? old.humidityEntity,
      outdoorEntity:outdoor ?? old.outdoorEntity,weatherEntity:weather ?? old.weatherEntity,
      place:removePlace ? null : place ?? old.place));
  }
  Future<void> _search() async {
    if (_searching || _city.text.trim().length < 2) return;
    setState(() {_searching=true;_error=null;_places=[];});
    try {
      final result = await ref.read(publicWeatherServiceProvider).search(_city.text);
      if (mounted) setState(() {_places=result; if(result.isEmpty) _error='未找到城市，请补充城市名或省份';});
    } catch (_) { if(mounted) setState(() => _error='城市查询失败，请检查网络后重试'); }
    finally { if(mounted) setState(() => _searching=false); }
  }
  Future<void> _save() async {
    if (_saving || _draft == null) return;
    setState(() {_saving=true;_error=null;});
    try {
      await ref.read(settingsRepositoryProvider).setValue(HomeEnvironmentConfig.settingsKey,_draft!.encode());
      ref.invalidate(homeEnvironmentProvider);
      if(mounted) Navigator.pop(context);
    } catch (_) { if(mounted) setState(() => _error='保存失败，请重试'); }
    finally { if(mounted) setState(() => _saving=false); }
  }
  Future<void> _refreshSensors() async {
    await ref.read(smartHomeControllerProvider.notifier).refresh();
  }
  @override
  Widget build(BuildContext context) {
    ref.watch(homeEnvironmentProvider);
    final stored = ref.watch(homeEnvironmentConfigProvider);
    if (_draft == null && stored.hasValue) _draft = stored.value!;
    final config = _draft ?? const HomeEnvironmentConfig();
    final home = ref.watch(smartHomeControllerProvider);
    final entities = home.entities.where((e)=> e.isVisible && (e.domain=='sensor'||e.domain=='weather')).toList();
    Widget selector(String title,String? value,Iterable<NasHaEntity> choices,ValueChanged<String> changed) {
      final rows=choices.toList();
      final exists=rows.any((e)=>'${e.integrationId}::${e.entityId}'==value);
      return Padding(padding:const EdgeInsets.only(bottom:16),child:DropdownButtonFormField<String>(
        key:ValueKey('$title:$value:${rows.length}'),initialValue:exists ? value : '',isExpanded:true,
        decoration:InputDecoration(labelText:title,helperText:value?.isNotEmpty==true&&!exists?'原实体当前不可用，请重新选择':null),
        items:[const DropdownMenuItem(value:'',child:Text('未选择')),
          ...rows.map((e)=>DropdownMenuItem(value:'${e.integrationId}::${e.entityId}',
            child:Text('${e.name}${e.areaName==null?'':' · ${e.areaName}'}')))],
        onChanged:_saving?null:(value)=>changed(value??''),
      ));
    }
    final sensors=entities.where((e)=>e.domain=='sensor');
    Iterable<NasHaEntity> sensorClass(String deviceClass) => sensors.where((entity) {
      final remote = home.entityStates['${entity.integrationId}::${entity.entityId}'];
      return isEnvironmentSensor(entity, remote, deviceClass);
    });
    return Scaffold(appBar:MomoAppBar.adaptive(context,title:const Text('环境数据来源')),
      body: stored.isLoading && _draft==null ? const Center(child:CircularProgressIndicator()) :
      ListView(padding:MomoMobileLayout.pageInsets(context).add(EdgeInsets.only(top:16,bottom:24+MediaQuery.viewPaddingOf(context).bottom)),children:[
        ExpansionTile(tilePadding:EdgeInsets.zero,title:const Text('当前来源与读取时间'),
          children:[Padding(padding:const EdgeInsets.only(bottom:16),child:Text(_sourceDetails()))]),
        const Text('室内温湿度来自你选择的已授权传感器。没有传感器时留空，不以空调设定值或室外天气代替。温度统一显示为摄氏度。'),
        Wrap(spacing:8,children:[
          TextButton.icon(onPressed:home.isLoading?null:_refreshSensors,
            icon:const Icon(Icons.refresh),label:Text(home.isLoading?'正在读取传感器…':'刷新传感器')),
          TextButton(onPressed:()=>Navigator.of(context).push(MaterialPageRoute<void>(
            builder:(_)=>const HomeAssistantSettingsScreen())),child:const Text('HA 连接与实体授权')),
        ]),
        if(sensors.isEmpty) const Text('暂无已授权传感器。HA 连接成功后，还需在“实体权限与状态”中为当前家庭角色开启查看权限，再刷新此页。')
        else if(sensorClass('temperature').isEmpty && sensorClass('humidity').isEmpty)
          const Text('暂未读到可识别的温湿度。请刷新并检查传感器的状态、单位和设备类型；未知或无权限的状态不会用作测量值。'),
        const SizedBox(height:20),
        selector('室内温度传感器',config.temperatureEntity,sensorClass('temperature'),(v)=>_update(temperature:v)),
        selector('室内湿度传感器',config.humidityEntity,sensorClass('humidity'),(v)=>_update(humidity:v)),
        selector('室外温度传感器（可选）',config.outdoorEntity,sensorClass('temperature'),(v)=>_update(outdoor:v)),
        selector('家庭天气实体',config.weatherEntity,entities.where((e)=>e.domain=='weather'),(v)=>_update(weather:v)),
        const Divider(height:30),
        Text('公共天气回退',style:Theme.of(context).textTheme.titleMedium),
        const SizedBox(height:8),
        const Text('仅补充缺失或过期的室外温度与体感。搜索时将城市名发送至 Open-Meteo；选中并保存后，发送该城市坐标获取天气。不读取手机定位。'),
        const SizedBox(height:12),
        TextField(controller:_city,decoration:const InputDecoration(labelText:'城市',hintText:'输入城市名，至少两个字符'),
          onSubmitted:(_)=>_search()),
        const SizedBox(height:8),
        OutlinedButton.icon(onPressed:_searching?null:_search,icon:const Icon(Icons.search),label:Text(_searching?'查询中…':'查询城市')),
        for(final place in _places) ListTile(title:Text(place.name),
          subtitle:Text('${place.description ?? '地点'} · ${place.coordinates}'),
          leading:const Icon(Icons.location_city_outlined),onTap:_saving?null:()=>_update(place:place)),
        if(config.place!=null) ListTile(contentPadding:EdgeInsets.zero,title:Text('已选：${config.place!.name}'),
          subtitle:Text('${config.place!.description ?? '地点'} · ${config.place!.coordinates}\n保存后启用公共天气回退'),trailing:IconButton(tooltip:'停用公共天气',
            onPressed:_saving?null:()=>_update(removePlace:true),icon:const Icon(Icons.close))),
        const SizedBox(height:12),
        const Text('天气数据：Open-Meteo / CC BY 4.0。显示气象数据本身的时间，成功请求不代表数据时间立即变化；页面可见时每分钟检查，缓存满 10 分钟重新获取，也可在家居页下拉刷新。城市天气不代表室内实测。'),
        Wrap(spacing:8,children:[
          TextButton(onPressed:()=>launchUrl(Uri.parse('https://open-meteo.com/'),
            mode:LaunchMode.externalApplication),child:const Text('Open-Meteo')),
          TextButton(onPressed:()=>launchUrl(Uri.parse('https://creativecommons.org/licenses/by/4.0/'),
            mode:LaunchMode.externalApplication),child:const Text('CC BY 4.0 许可')),
        ]),
        if(_error!=null || stored.hasError) Padding(padding:const EdgeInsets.symmetric(vertical:12),
          child:Text(_error??'设置读取失败，请返回后重试',style:TextStyle(color:Theme.of(context).colorScheme.error))),
        const SizedBox(height:16),
        FilledButton(onPressed:_saving||_draft==null?null:_save,child:Text(_saving?'保存中…':'保存来源')),
      ]));
  }
}
