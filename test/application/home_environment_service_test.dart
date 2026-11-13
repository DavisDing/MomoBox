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
  test('template temperature sensors are selectable by Celsius/Fahrenheit units without guessing names', () {
    final sensor = entity('sensor.template','sensor');
    final remote = state('sensor.template','21.5',{'unit_of_measurement':'°C'});
    expect(isEnvironmentSensor(sensor,remote,'temperature'),isTrue);
    expect(environmentFromHa(const HomeEnvironmentConfig(temperatureEntity:'ha::sensor.template'),
      [sensor],{'ha::sensor.template':remote},now:now).indoorTemperature!.value,21.5);
    expect(isEnvironmentSensor(sensor,state('sensor.template','50',{'unit_of_measurement':'%'}),'humidity'),isFalse);
    expect(isEnvironmentSensor(sensor,state('sensor.template','50',{'device_class':'battery','unit_of_measurement':'%'}),'humidity'),isFalse);
    expect(isEnvironmentSensor(sensor,state('sensor.template','22',{'device_class':'voltage','unit_of_measurement':'°C'}),'temperature'),isFalse);
    expect(isEnvironmentSensor(sensor,null,'temperature'),isFalse);
  });
  test('city search preserves distinct places, includes administrative context and removes exact duplicates', () async {
    final chengdu = {'id':1815286,'name':'成都','latitude':30.66667,'longitude':104.06667,
      'feature_code':'PPLA','admin1':'四川','admin2':'成都市','country':'中国'};
    final service = PublicWeatherService(client:MockClient((_) async => http.Response.bytes(
      utf8.encode(jsonEncode({'results':[chengdu,chengdu,
        {...chengdu,'id':9614220,'latitude':26.983,'longitude':114.207,'feature_code':'PPL','admin1':'江西','admin2':'吉安市'},
        {...chengdu,'id':10154883,'latitude':31.11537,'longitude':107.44296,'feature_code':'PPL','admin2':'达州市'},
        {...chengdu,'id':10198468,'latitude':30.7673,'longitude':102.121,'feature_code':'PPL','admin2':'阿坝藏族羌族自治州'},
        {...chengdu,'latitude':999}]})),200)));
    addTearDown(service.close);
    final places = await service.search('成都');
    expect(places.length,4);
    expect(places.map((p)=>p.name).toSet().length,4);
    expect(places.first.name,'成都 · 成都市 · 四川 · 中国');
    expect(places.first.description,'省级行政中心');
    expect(places[1].name,contains('吉安市 · 江西'));
    expect(places[1].description,'居民点');
    expect(WeatherPlace.fromJson(places.first.toJson())!.description,'省级行政中心');
  });
  test('weather cache expires on real clock progression without inventing a newer observation time', () async {
    var instant = now;
    var calls = 0;
    final service = PublicWeatherService(clock:()=>instant,client:MockClient((_) async {
      calls++;
      await Future<void>.delayed(Duration.zero);
      return http.Response.bytes(utf8.encode(jsonEncode({'current':{'time':instant.subtract(const Duration(minutes:11)).millisecondsSinceEpoch~/1000,
        'temperature_2m':18,'apparent_temperature':17},'current_units':{'temperature_2m':'°C','apparent_temperature':'°C'}})),200);
    }));
    addTearDown(service.close);
    const place = WeatherPlace('成都',30.66667,104.06667);
    final first = await Future.wait([service.current(place),service.current(place)]);
    expect(calls,1);
    expect(first.first.outdoorTemperature!.observedAt,now.subtract(const Duration(minutes:11)));
    instant = now.add(const Duration(minutes:9));
    await service.current(place);
    expect(calls,1);
    instant = now.add(const Duration(minutes:10));
    final updated = await service.current(place);
    expect(calls,2);
    expect(updated.outdoorTemperature!.observedAt,instant.subtract(const Duration(minutes:11)));
  });
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
      return http.Response.bytes(utf8.encode(jsonEncode({'current':{'time':DateTime.now().toUtc().millisecondsSinceEpoch~/1000,
        'temperature_2m':18,'apparent_temperature':17},'current_units':{'temperature_2m':'°C','apparent_temperature':'°C'}})),200,
        headers:{'content-type':'application/json; charset=utf-8'});
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
      http.Response.bytes(utf8.encode(jsonEncode({'current':{'time':DateTime.now().toUtc().millisecondsSinceEpoch~/1000,
        'temperature_2m':18,'apparent_temperature':null},'current_units':{'temperature_2m':'°C','apparent_temperature':'°C'}})),200,
        headers:{'content-type':'application/json; charset=utf-8'})));
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
