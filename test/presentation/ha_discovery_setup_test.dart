import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/domain/models/nas_homeassistant_models.dart';
import 'package:momo_box/presentation/controllers/smart_home_controller.dart';

http.Response _json(Object body, [int status = 200]) => http.Response(jsonEncode(body), status,
  headers: {'content-type': 'application/json; charset=utf-8'});

class _Fixture {
  bool saved = false;
  bool discoveryFails = false;
  int saves = 0;
  int discoveries = 0;
  final requests = <http.Request>[];
  final permissions = <Map<String, dynamic>>[];
  late final client = NasApiClient('https://nas.example', client: MockClient((request) async {
    requests.add(request);
    final path = request.url.path;
    if (path.endsWith('/integrations')) {
      if (request.method == 'POST') { saved = true; saves++; return _json(integration); }
      return _json({'integrations': saved ? [integration] : []});
    }
    if (path.endsWith('/integrations/ha')) { saves++; return _json(integration); }
    if (path.endsWith('/test')) return _json({'connected': true, 'checked_at': DateTime.now().toUtc().toIso8601String()});
    if (path.endsWith('/discover')) {
      discoveries++;
      if (discoveryFails) return _json({'error': {'code': 'HA_INTEGRATION_UNAVAILABLE', 'message': 'HA unavailable'}}, 503);
      return _json({'integration_id': 'ha', 'devices': 1, 'entities': 1});
    }
    if (path.endsWith('/catalog')) return _json({'entities': [entity]});
    if (path.endsWith('/entities')) {
      return _json({'entities': permissions.any((p) => p['role'] == 'owner' && p['can_view'] == true) ? [entity] : []});
    }
    if (path.endsWith('/permissions')) {
      if (request.method == 'PUT') {
        final permission = jsonDecode(request.body) as Map<String, dynamic>;
        permissions.removeWhere((p) => p['role'] == permission['role']);
        permissions.add(permission);
        return _json(permission);
      }
      return _json({'permissions': permissions});
    }
    if (path.endsWith('/state')) return _json({'entity_id': 'light.kitchen', 'state': 'off', 'attributes': {}, 'fetched_at': DateTime.now().toUtc().toIso8601String()});
    for (final name in ['groups', 'recipes', 'rules', 'suggestions']) {
      if (path.endsWith('-$name')) return _json({name: []});
    }
    return _json({}, 404);
  }))..setAccessToken('nas-session');
  late final repository = NasSmartHomeRepository.withSession(client, isSessionCurrent: () => true);
  late final controller = SmartHomeController(repository, nasAddress: 'https://nas.example', role: 'owner');
  final integration = {'id': 'ha', 'name': 'HA', 'base_url': 'http://ha.local:8123',
    'status': 'healthy', 'created_at': '2026-11-12T00:00:00Z'};
  final entity = {'id': 'row', 'integration_id': 'ha', 'entity_id': 'light.kitchen',
    'domain': 'light', 'name': '厨房灯', 'is_visible': true, 'is_controllable': true,
    'capabilities': ['on_off', 'brightness']};
  void close() { controller.dispose(); repository.close(); client.close(); }
}

void main() {
  for (final discoveryFails in [false, true]) {
    test('save triggers discovery; failure=$discoveryFails preserves integration and supports retry', () async {
      final fixture = _Fixture()..discoveryFails = discoveryFails;
      addTearDown(fixture.close);
      final controller = fixture.controller;
      await controller.refresh();
      await controller.configureIntegration(name: 'HA', baseUrl: Uri.parse('http://ha.local:8123'), accessToken: 'secret-ha-token-test');
      expect(fixture.saves, 1, reason: 'configure must persist the new integration');
      expect(fixture.discoveries, 1);
      expect(controller.state.integrations.single.id, 'ha');
      if (discoveryFails) {
        expect(controller.state.commandError, contains('实体发现失败'));
        fixture.discoveryFails = false;
        await controller.discoverEntities();
        expect(fixture.saves, 1);
        expect(fixture.discoveries, 2);
      }
      expect(controller.state.entityCatalog.single.name, '厨房灯');
      expect(controller.state.entities, isEmpty);
      expect(controller.state.devices, isEmpty);
      expect(controller.state.entityStates, isEmpty);
      expect(fixture.permissions, isEmpty);
      expect(fixture.requests.where((r) => r.url.path.endsWith('/state')), isEmpty);
      expect(controller.state.commandError, isNull);
      await controller.updatePermission(const NasHaEntityPermission(integrationId: 'ha', entityId: 'light.kitchen', role: 'owner', canView: true, canControl: false, allowedCommands: []));
      expect(controller.state.entities, hasLength(1));
      expect(controller.state.entityStates['ha::light.kitchen']!.state, 'off');
      expect(controller.powerUnavailableReason('ha::light.kitchen', turnOn: true), isNotNull);
    });
  }
}
