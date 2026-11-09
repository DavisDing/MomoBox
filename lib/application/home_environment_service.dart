import 'dart:convert';
import 'package:http/http.dart' as http;
import '../domain/models/home_environment.dart';
import '../domain/models/nas_homeassistant_models.dart';

/// No location permission or IP lookup: only a city explicitly chosen by the user.
class PublicWeatherService {
  PublicWeatherService({http.Client? client}) : _client = client ?? http.Client();
  final http.Client _client;
  final Map<String, (DateTime, HomeEnvironment)> _cache = {};
  void expireCache() {
    for (final key in _cache.keys.toList()) {
      _cache[key] = (DateTime.fromMillisecondsSinceEpoch(0),_cache[key]!.$2);
    }
  }
  void close() => _client.close();
  Future<Map<String, dynamic>> _get(Uri uri) async {
    final response = await _client.get(uri).timeout(const Duration(seconds: 10));
    if (response.statusCode != 200 || response.bodyBytes.length > 512000) throw StateError('天气服务暂不可用');
    final data = jsonDecode(utf8.decode(response.bodyBytes));
    if (data is! Map<String, dynamic>) throw const FormatException('Invalid weather response');
    return data;
  }
  Future<List<WeatherPlace>> search(String city) async {
    final query = city.trim();
    if (query.length < 2 || query.length > 80) return [];
    final json = await _get(Uri.https('geocoding-api.open-meteo.com', '/v1/search',
      {'name':query, 'count':'8', 'language':'zh', 'format':'json'}));
    final results = json['results'];
    if (results is! List) return [];
    return results.whereType<Map>().map((row) => WeatherPlace.fromJson({
      ...row, 'name': [row['name'], row['admin1'], row['country']].whereType<String>().toSet().join(' · '),
    })).whereType<WeatherPlace>().toList();
  }
  Future<HomeEnvironment> current(WeatherPlace place) async {
    final key = '${place.latitude},${place.longitude}:${place.name}';
    final cached = _cache[key];
    if (cached != null && DateTime.now().difference(cached.$1) < const Duration(minutes: 10)) return cached.$2;
    try {
      final json = await _get(Uri.https('api.open-meteo.com','/v1/forecast',{
        'latitude':'${place.latitude}', 'longitude':'${place.longitude}',
        'current':'temperature_2m,apparent_temperature', 'temperature_unit':'celsius',
        'timeformat':'unixtime', 'timezone':'GMT',
      }));
      final current = json['current'], units = json['current_units'];
      if (current is! Map || units is! Map || current['time'] is! num) throw const FormatException('Missing weather time');
      final time = environmentNumber(current['time'], min:0, max:4102444800);
      if (time == null) throw const FormatException('Invalid weather time');
      final at = DateTime.fromMillisecondsSinceEpoch((time * 1000).round(), isUtc:true);
      if (at.isAfter(DateTime.now().toUtc().add(const Duration(minutes: 5)))) throw const FormatException('Future weather time');
      EnvironmentReading? reading(String name) {
        final value = environmentCelsius(current[name], units[name]);
        return value == null ? null : EnvironmentReading(value, 'Open-Meteo · ${place.name}', at);
      }
      final result = HomeEnvironment(outdoorTemperature:reading('temperature_2m'),
        apparentTemperature:reading('apparent_temperature'));
      _cache[key] = (DateTime.now(), result);
      return result;
    } catch (_) {
      EnvironmentReading? previous(EnvironmentReading? value) => value == null ? null :
        EnvironmentReading(value.value,value.source,value.observedAt,stale:true);
      if (cached != null) {
        return HomeEnvironment(outdoorTemperature:previous(cached.$2.outdoorTemperature),
          apparentTemperature:previous(cached.$2.apparentTemperature), message:'天气刷新失败，显示上次数据');
      }
      rethrow;
    }
  }
}

/// A selected authorized entity is required. No name guessing or climate target fallback.
HomeEnvironment environmentFromHa(HomeEnvironmentConfig config,
  List<NasHaEntity> entities, Map<String, NasHaEntityState> states,
  {DateTime? now, bool forceStale = false, Set<String> staleEntityKeys = const {}}) {
  final instant = (now ?? DateTime.now()).toUtc();
  EnvironmentReading? read(String? key, String kind) {
    if (key == null) return null;
    final matches = entities.where((e) => '${e.integrationId}::${e.entityId}' == key && e.isVisible);
    if (matches.length != 1) return null;
    final entity = matches.single, remote = states[key];
    if (remote == null || remote.entityId != entity.entityId ||
        {'unknown','unavailable'}.contains(remote.state) ||
        remote.fetchedAt.toUtc().isAfter(instant.add(const Duration(minutes: 5)))) {
      return null;
    }
    final attrs = remote.attributes;
    double? value;
    if (entity.domain == 'weather' && {'outdoor','feels'}.contains(kind)) {
      value = environmentCelsius(attrs[kind == 'feels' ? 'apparent_temperature' : 'temperature'], attrs['temperature_unit']);
    } else if (entity.domain == 'sensor') {
      if (kind == 'humidity') {
        if (attrs['device_class'] != 'humidity' || attrs['unit_of_measurement'] != '%') return null;
        value = environmentNumber(remote.state,min:0,max:100);
      } else {
        if (attrs['device_class'] != 'temperature') return null;
        value = environmentCelsius(remote.state, attrs['unit_of_measurement']);
      }
    }
    return value == null ? null : EnvironmentReading(value, entity.name, remote.fetchedAt,
      stale:forceStale || staleEntityKeys.contains(key));
  }
  return HomeEnvironment(indoorTemperature:read(config.temperatureEntity,'temperature'),
    indoorHumidity:read(config.humidityEntity,'humidity'),
    outdoorTemperature:_freshOutdoor(read(config.outdoorEntity,'outdoor'),read(config.weatherEntity,'outdoor'),instant),
    apparentTemperature:read(config.weatherEntity,'feels'));
}

EnvironmentReading? _freshOutdoor(EnvironmentReading? sensor,EnvironmentReading? weather,DateTime now) =>
  sensor != null && !sensor.isStale(now) ? sensor :
  weather != null && !weather.isStale(now) ? weather : sensor ?? weather;

HomeEnvironment mergeHomeEnvironment(HomeEnvironment ha, HomeEnvironment weather, DateTime now) {
  EnvironmentReading? choose(EnvironmentReading? primary, EnvironmentReading? fallback) =>
    primary != null && !primary.isStale(now) ? primary :
    fallback != null && !fallback.isStale(now) ? fallback : primary ?? fallback;
  return HomeEnvironment(indoorTemperature:ha.indoorTemperature,indoorHumidity:ha.indoorHumidity,
    outdoorTemperature:choose(ha.outdoorTemperature,weather.outdoorTemperature),
    apparentTemperature:choose(ha.apparentTemperature,weather.apparentTemperature),message:weather.message);
}
