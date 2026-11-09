import 'dart:convert';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/home_environment_service.dart';
import 'package:momo_box/domain/models/home_environment.dart';
import 'package:momo_box/domain/models/nas_homeassistant_models.dart';

void main() {
  final now = DateTime.utc(2026,11,9,8);
  NasHaEntity entity(String id,String domain,{bool visible=true}) => NasHaEntity(
    id:id,integrationId:'ha',entityId:id,domain:domain,name:id,isVisible:visible,isControllable:false);
  NasHaEntityState state(String id,String value,Map<String,dynamic> attrs,{DateTime? at}) => NasHaEntityState(
    entityId:id,state:value,attributes:attrs,fetchedAt:at??now);
  test('indoor readings require a selected visible temperature/humidity sensor with valid units',() {
    const config=HomeEnvironmentConfig(temperatureEntity:'ha::sensor.temp',humidityEntity:'ha::sensor.humidity');
    final entities=[entity('sensor.temp','sensor'),entity('sensor.humidity','sensor')];
    final states={
      'ha::sensor.temp':state('sensor.temp','75.2',{'device_class':'temperature','unit_of_measurement':'°F'}),
      'ha::sensor.humidity':state('sensor.humidity','48',{'device_class':'humidity','unit_of_measurement':'%'}),
    };
    final result=environmentFromHa(config,entities,states,now:now);
    expect(result.indoorTemperature!.value,closeTo(24,0.001));
    expect(result.indoorHumidity!.value,48);
    expect(result.outdoorTemperature,isNull);
    expect(environmentFromHa(const HomeEnvironmentConfig(),entities,states,now:now).indoorTemperature,isNull);
    expect(environmentFromHa(config,[entity('sensor.temp','sensor',visible:false)],states,now:now).indoorTemperature,isNull);
  });
  test('climate targets, unavailable states, mismatched entities and future times never become indoor measurements',() {
    const config=HomeEnvironmentConfig(temperatureEntity:'ha::climate.room');
    final entities=[entity('climate.room','climate')];
    expect(environmentFromHa(config,entities,{'ha::climate.room':state('climate.room','heat',
      {'temperature':24,'current_temperature':20})},now:now).indoorTemperature,isNull);
    const sensorConfig=HomeEnvironmentConfig(temperatureEntity:'ha::sensor.temp');
    for(final remote in [state('sensor.temp','unavailable',{'device_class':'temperature','unit_of_measurement':'°C'}),
      state('sensor.other','24',{'device_class':'temperature','unit_of_measurement':'°C'}),
      state('sensor.temp','24',{'device_class':'temperature','unit_of_measurement':'°C'},at:now.add(const Duration(hours:1)))]) {
      expect(environmentFromHa(sensorConfig,[entity('sensor.temp','sensor')],{'ha::sensor.temp':remote},now:now).indoorTemperature,isNull);
    }
  });
  test('weather can independently lack feels-like and stale readings retain their actual time',() {
    const config=HomeEnvironmentConfig(weatherEntity:'ha::weather.home');
    final at=now.subtract(const Duration(hours:2));
    final result=environmentFromHa(config,[entity('weather.home','weather')],{
      'ha::weather.home':state('weather.home','cloudy',{'temperature':18,'temperature_unit':'°C'},at:at),
    },now:now);
    expect(result.outdoorTemperature!.value,18);
    expect(result.outdoorTemperature!.observedAt,at);
    expect(result.outdoorTemperature!.isStale(now),isTrue);
    expect(result.apparentTemperature,isNull);
    expect(result.indoorTemperature,isNull);
  });
  test('public fallback fills each outdoor field independently and never supplies indoor values',() {
    final sensor=EnvironmentReading(18,'室外传感器',now);
    final public=EnvironmentReading(17,'公共天气',now);
    final result=mergeHomeEnvironment(HomeEnvironment(outdoorTemperature:sensor),
      HomeEnvironment(outdoorTemperature:public,apparentTemperature:public,
        indoorTemperature:public,indoorHumidity:public),now);
    expect(result.outdoorTemperature,same(sensor));
    expect(result.apparentTemperature,same(public));
    expect(result.indoorTemperature,isNull);
    expect(result.indoorHumidity,isNull);
    final expired=EnvironmentReading(20,'旧传感器',now.subtract(const Duration(hours:2)));
    expect(mergeHomeEnvironment(HomeEnvironment(outdoorTemperature:expired),
      HomeEnvironment(outdoorTemperature:public),now).outdoorTemperature,same(public));
  });
  test('public weather requests Celsius with UTC epoch time and caches per selected city',() async {
    var calls=0;
    final service=PublicWeatherService(client:MockClient((request) async {
      calls++;
      expect(request.url.host,'api.open-meteo.com');
      expect(request.url.queryParameters['timeformat'],'unixtime');
      return http.Response(jsonEncode({'current':{'time':DateTime.now().toUtc().millisecondsSinceEpoch~/1000,
        'temperature_2m':18,'apparent_temperature':17},'current_units':{'temperature_2m':'°C','apparent_temperature':'°C'}}),200);
    }));
    addTearDown(service.close);
    final weather=await service.current(const WeatherPlace('示例城市',31,121));
    expect(weather.outdoorTemperature!.value,18);
    expect(weather.apparentTemperature!.value,17);
    expect(weather.indoorHumidity,isNull);
    await service.current(const WeatherPlace('示例城市',31,121));
    expect(calls,1);
    await service.current(const WeatherPlace('另一城市',32,122));
    expect(calls,2);
  });
  test('configuration validation rejects invalid coordinates and preserves explicit empty sensor choices',() {
    expect(HomeEnvironmentConfig.decode('{"place":{"name":"bad","latitude":999,"longitude":0}}').place,isNull);
    expect(HomeEnvironmentConfig.decode('invalid').place,isNull);
    const value=HomeEnvironmentConfig(temperatureEntity:'',place:WeatherPlace('城市',31,121));
    final decoded=HomeEnvironmentConfig.decode(value.encode());
    expect(decoded.temperatureEntity,'');
    expect(decoded.place!.name,'城市');
    expect(environmentCelsius('NaN','°C'),isNull);
    expect(environmentNumber('101',min:0,max:100),isNull);
  });
  test('failed weather refresh preserves old data with an explicit stale status',() async {
    var fail=false;
    final service=PublicWeatherService(client:MockClient((_) async => fail ? http.Response('unavailable',503) :
      http.Response(jsonEncode({'current':{'time':DateTime.now().toUtc().millisecondsSinceEpoch~/1000,
        'temperature_2m':18,'apparent_temperature':null},'current_units':{'temperature_2m':'°C','apparent_temperature':'°C'}}),200)));
    addTearDown(service.close);
    const place=WeatherPlace('城市',31,121);
    final before=await service.current(place);
    fail=true;
    service.expireCache();
    final after=await service.current(place);
    expect(after.outdoorTemperature!.value,before.outdoorTemperature!.value);
    expect(after.outdoorTemperature!.observedAt,before.outdoorTemperature!.observedAt);
    expect(after.outdoorTemperature!.isStale(DateTime.now()),isTrue);
    expect(after.apparentTemperature,isNull);
    expect(after.message,contains('刷新失败'));
  });
}
