import 'dart:async';
import 'dart:convert';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/home_environment_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/domain/models/home_environment.dart';
import 'package:momo_box/domain/models/nas_homeassistant_models.dart';
import 'package:momo_box/domain/models/smart_home_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/controllers/smart_home_controller.dart';
import 'package:momo_box/presentation/screens/environment_settings_screen.dart';

class _Home extends SmartHomeController {
  _Home() : super(NasSmartHomeRepository(null), nasAddress:'',role:'member');
  int refreshes = 0;
  @override
  Future<void> refresh() async { refreshes++; }
  void show(SmartHomeState next) { state = next; }
}

Future<void> _settle() async {
  for (var i = 0; i < 4; i++) {
    await Future<void>.delayed(const Duration(milliseconds:10));
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.resumed));
  test('minute refresh retains same-city values; city and HA permission changes remove old readings', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    final home = _Home();
    final clock = StreamController<DateTime>.broadcast();
    var now = DateTime.utc(2026,11,12,10);
    var calls = 0;
    Completer<http.Response>? pending;
    http.Response weather() => http.Response.bytes(utf8.encode(jsonEncode({'current':{
      'time':now.millisecondsSinceEpoch~/1000,'temperature_2m':18,'apparent_temperature':17},
      'current_units':{'temperature_2m':'°C','apparent_temperature':'°C'}})),200);
    final service = PublicWeatherService(clock:()=>now,client:MockClient((_) async {
      calls++;
      return pending == null ? weather() : pending.future;
    }));
    final container = ProviderContainer(overrides:[
      databaseProvider.overrideWithValue(db),
      smartHomeControllerProvider.overrideWith((ref)=>home),
      environmentClockProvider.overrideWith((ref) async* { yield now; yield* clock.stream; }),
      publicWeatherServiceProvider.overrideWithValue(service),
    ]);
    final subscription = container.listen(homeEnvironmentProvider,(_,__){});
    try {
      final settings = container.read(settingsRepositoryProvider);
      await settings.setValue(HomeEnvironmentConfig.settingsKey,
        const HomeEnvironmentConfig(place:WeatherPlace('成都',30.6,104)).encode());
      await _settle();
      expect(container.read(homeEnvironmentProvider).valueOrNull!.outdoorTemperature!.value,18);
      expect(calls,1);
      final config = container.read(homeEnvironmentConfigProvider).value;
      for (final key in ['ai_usage_logs','sync_processing_warning:family-a','theme_name']) {
        await settings.setValue(key,'updated');
        await _settle();
        expect(identical(container.read(homeEnvironmentConfigProvider).value,config),isTrue);
        expect(calls,1);
      }
      pending = Completer<http.Response>();
      now = now.add(const Duration(minutes:10));
      clock.add(now);
      await _settle();
      expect(calls,2);
      expect(container.read(homeEnvironmentProvider).isLoading,isTrue);
      expect(container.read(homeEnvironmentProvider).valueOrNull!.outdoorTemperature!.value,18);
      pending.complete(weather());
      await _settle();
      expect(container.read(homeEnvironmentProvider).valueOrNull!.outdoorTemperature!.observedAt,now);

      pending = Completer<http.Response>();
      await settings.setValue(HomeEnvironmentConfig.settingsKey,
        const HomeEnvironmentConfig(place:WeatherPlace('上海',31.2,121.5)).encode());
      await _settle();
      expect(calls,3);
      expect(container.read(homeEnvironmentProvider).valueOrNull!.outdoorTemperature,isNull);
      pending.complete(weather());
      await _settle();

      final visible = home.state.copyWith(nasOnline:true,haStatus:HaConnectionStatus.online,
        entities:const [NasHaEntity(id:'temp',integrationId:'ha',entityId:'sensor.temp',
          domain:'sensor',name:'客厅',isVisible:true,isControllable:false)],
        entityStates:{'ha::sensor.temp':NasHaEntityState(entityId:'sensor.temp',state:'24',
          attributes:const {'unit_of_measurement':'°C'},fetchedAt:now)});
      home.show(visible);
      await settings.setValue(HomeEnvironmentConfig.settingsKey,
        const HomeEnvironmentConfig(temperatureEntity:'ha::sensor.temp').encode());
      await _settle();
      expect(container.read(homeEnvironmentProvider).valueOrNull!.indoorTemperature!.value,24);
      home.show(visible.copyWith(entities:[],entityStates:{}));
      expect(container.read(homeEnvironmentProvider).valueOrNull!.indoorTemperature,isNull);
      final refreshes = home.refreshes;
      clock.add(now.add(const Duration(minutes:1)));
      await _settle();
      expect(home.refreshes,refreshes+1);
      WidgetsBinding.instance.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      clock.add(now.add(const Duration(minutes:2)));
      await _settle();
      expect(home.refreshes,refreshes+1);
    } finally {
      subscription.close();
      container.dispose();
      service.close();
      await clock.close();
      await db.close();
    }
  });

  testWidgets('environment settings refreshes HA and offers authorized template temperature sensors', (tester) async {
    final home = _Home();
    home.show(home.state.copyWith(entities:const [
      NasHaEntity(id:'temp',integrationId:'ha',entityId:'sensor.temp',domain:'sensor',
        name:'模板温度',isVisible:true,isControllable:false),
      NasHaEntity(id:'hidden',integrationId:'ha',entityId:'sensor.hidden',domain:'sensor',
        name:'未授权温度',isVisible:false,isControllable:false),
    ],entityStates:{
      'ha::sensor.temp':NasHaEntityState(entityId:'sensor.temp',state:'21',
        attributes:const {'unit_of_measurement':'°C'},fetchedAt:DateTime.now()),
    }));
    await tester.pumpWidget(ProviderScope(overrides:[
      smartHomeControllerProvider.overrideWith((ref)=>home),
      homeEnvironmentProvider.overrideWithValue(const AsyncData(HomeEnvironment())),
      homeEnvironmentConfigProvider.overrideWith((ref)=>Stream.value(const HomeEnvironmentConfig())),
    ],child:const MaterialApp(home:EnvironmentSettingsScreen())));
    await tester.pumpAndSettle();
    expect(home.refreshes,greaterThanOrEqualTo(1));
    await tester.tap(find.byType(DropdownButtonFormField<String>).first);
    await tester.pumpAndSettle();
    expect(find.text('模板温度'),findsOneWidget);
    expect(find.text('未授权温度'),findsNothing);
    await tester.tap(find.text('模板温度'));
    await tester.pumpAndSettle();
    expect(find.text('模板温度'),findsOneWidget);
    await tester.pumpWidget(const SizedBox.shrink());
  });
}
