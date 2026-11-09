import 'dart:convert';

class EnvironmentReading {
  const EnvironmentReading(this.value, this.source, this.observedAt, {this.stale = false});
  final double value;
  final String source;
  final DateTime observedAt;
  final bool stale;
  bool isStale(DateTime now) => stale || now.toUtc().difference(observedAt.toUtc()) > const Duration(minutes: 30);
}

class HomeEnvironment {
  const HomeEnvironment({this.indoorTemperature, this.indoorHumidity,
    this.outdoorTemperature, this.apparentTemperature, this.message});
  final EnvironmentReading? indoorTemperature;
  final EnvironmentReading? indoorHumidity;
  final EnvironmentReading? outdoorTemperature;
  final EnvironmentReading? apparentTemperature;
  final String? message;
}

class WeatherPlace {
  const WeatherPlace(this.name, this.latitude, this.longitude);
  final String name;
  final double latitude;
  final double longitude;
  Map<String, Object> toJson() => {'name': name, 'latitude': latitude, 'longitude': longitude};
  static WeatherPlace? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final lat = raw['latitude'], lon = raw['longitude'], name = raw['name'];
    if (name is! String || name.trim().isEmpty || lat is! num || lon is! num ||
        !lat.isFinite || !lon.isFinite || lat < -90 || lat > 90 || lon < -180 || lon > 180) return null;
    return WeatherPlace(name, lat.toDouble(), lon.toDouble());
  }
}

class HomeEnvironmentConfig {
  const HomeEnvironmentConfig({this.temperatureEntity, this.humidityEntity,
    this.outdoorEntity, this.weatherEntity, this.place});
  static const settingsKey = 'ha_environment_v1';
  final String? temperatureEntity;
  final String? humidityEntity;
  final String? outdoorEntity;
  final String? weatherEntity;
  final WeatherPlace? place;
  String encode() => jsonEncode({'temperature': temperatureEntity, 'humidity': humidityEntity,
    'outdoor': outdoorEntity, 'weather': weatherEntity, 'place': place?.toJson()});
  static HomeEnvironmentConfig decode(String? raw) {
    try {
      final data = jsonDecode(raw ?? '{}');
      if (data is! Map) return const HomeEnvironmentConfig();
      String? id(String name) => data[name] is String ? data[name] as String : null;
      return HomeEnvironmentConfig(temperatureEntity:id('temperature'), humidityEntity:id('humidity'),
        outdoorEntity:id('outdoor'), weatherEntity:id('weather'), place:WeatherPlace.fromJson(data['place']));
    } catch (_) { return const HomeEnvironmentConfig(); }
  }
}

double? environmentNumber(Object? raw, {required double min, required double max}) {
  final value = raw is num ? raw.toDouble() : raw is String ? double.tryParse(raw) : null;
  return value != null && value.isFinite && value >= min && value <= max ? value : null;
}

double? environmentCelsius(Object? raw, Object? unit) {
  final value = environmentNumber(raw, min: -200, max: 300);
  if (value == null) return null;
  final result = switch (unit) {
    '°C' || 'C' => value,
    '°F' || 'F' => (value - 32) * 5 / 9,
    _ => null,
  };
  return environmentNumber(result, min: -100, max: 100);
}
