import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/domain/models/nas_models.dart';
import 'package:momo_box/presentation/controllers/nas_account_controller.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/screens/home_assistant_settings_screen.dart';
import 'package:momo_box/presentation/screens/nas_settings_screen.dart';
import 'package:momo_box/services/nas_credentials_service.dart';
import 'package:momo_box/services/local_network_permission_service.dart';

import '../support/memory_settings_repository.dart';

http.Response _json(Map<String, Object?> body, [int status = 200]) =>
    http.Response(
      jsonEncode(body),
      status,
      headers: {'content-type': 'application/json; charset=utf-8'},
    );

http.Response _auth(String token) => _json({
  'user': {'id': 'user', 'email': 'user@example.com', 'nickname': '家人'},
  'access_token': token,
  'refresh_token': 'refresh-$token',
  'expires_in': 900,
});

http.Response _family([String role = 'owner']) => _json({
  'family': {
    'id': 'family',
    'name': '家庭',
    'created_at': '2026-11-11T00:00:00Z',
  },
  'membership': {'family_id': 'family', 'role': role},
});

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  testWidgets('Android17主动连接申请权限时禁用重复点击，拒绝后公网NAS仍可连接', (tester) async {
    final response = Completer<String>();
    final methods = <String>[];
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(LocalNetworkPermissionService.channel, (
      call,
    ) async {
      methods.add(call.method);
      return call.method == 'request' ? response.future : 'denied';
    });
    addTearDown(
      () => messenger.setMockMethodCallHandler(
        LocalNetworkPermissionService.channel,
        null,
      ),
    );
    var healthRequests = 0;
    final fixture = _Fixture(
      (_) async => _json({}, 404),
      health: (_) async {
        healthRequests++;
        return _json({'status': 'ok', 'database': 'ok'});
      },
    );
    await tester.binding.setSurfaceSize(const Size(430, 1000));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          settingsRepositoryProvider.overrideWithValue(
            fixture.settingsRepository,
          ),
          nasConnectionServiceProvider.overrideWithValue(fixture.connection),
          nasAccountProvider.overrideWith((ref) => fixture.account),
        ],
        child: const MaterialApp(home: NasSettingsScreen()),
      ),
    );
    await tester.pumpAndSettle();
    final initialRequests = healthRequests;
    expect(methods, isEmpty, reason: '被动恢复连接不能弹系统授权框');
    final connect = find.text('测试并保存 NAS 连接');
    await tester.ensureVisible(connect);
    await tester.pumpAndSettle();
    await tester.tap(connect);
    await tester.pump();
    await tester.pump();
    expect(methods, ['request']);
    expect(healthRequests, initialRequests);
    final busy = find.widgetWithText(FilledButton, '检测中…');
    expect(tester.widget<FilledButton>(busy).onPressed, isNull);
    await tester.tap(busy);
    response.complete('denied');
    await tester.pumpAndSettle();
    expect(methods, ['request']);
    expect(healthRequests, initialRequests + 1);
    final container = ProviderScope.containerOf(
      tester.element(find.byType(NasSettingsScreen)),
    );
    expect(container.read(nasConnectionProvider).isConnected, isTrue);
    expect(find.text('测试并保存 NAS 连接'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await fixture.close(disposeAccount: false);
  });

  for (final join in [false, true]) {
    for (final refreshFails in [false, true]) {
      test(
        '${join ? 'join' : 'create'} refreshes family scope before members, devices and HA; refresh failure=$refreshFails remains blocked',
        () async {
          var familyCreated = false;
          var refreshCalls = 0;
          var haCalls = 0;
          var familyCalls = 0;
          final refreshEntered = Completer<void>();
          final refreshResult = Completer<http.Response>();
          final fixture = _Fixture((request) async {
            final path = request.url.path;
            if (path.endsWith('/auth/login')) return _auth('without-family');
            if (path.endsWith('/families/current')) {
              return familyCreated ? _family() : _json({}, 404);
            }
            if (path.endsWith('/families') || path.endsWith('/families/join')) {
              familyCalls++;
              familyCreated = true;
              return _family();
            }
            if (path.endsWith('/auth/refresh')) {
              refreshCalls++;
              refreshEntered.complete();
              return refreshResult.future;
            }
            expect(request.headers['Authorization'], 'Bearer with-family');
            if (path.endsWith('/families/members')) {
              return _json({'members': []});
            }
            if (path.endsWith('/devices')) return _json({'devices': []});
            if (path.endsWith('/home-assistant/integrations')) {
              haCalls++;
              return _json({'integrations': []});
            }
            return _json({}, 404);
          });
          addTearDown(fixture.close);
          await fixture.login();
          final missing = fixture.account.createHomeAssistantRepository();
          addTearDown(missing.close);
          expect(await missing.restoreCredentials(), isFalse);
          final operation =
              join
                  ? fixture.account.joinFamily('invite')
                  : fixture.account.createFamily('家庭');
          await refreshEntered.future;
          expect(fixture.account.state.family.hasFamily, isFalse);
          final pending = fixture.account.createHomeAssistantRepository();
          addTearDown(pending.close);
          expect(await pending.restoreCredentials(), isFalse);
          // Exercise both a successful refresh and an unavailable NAS after the
          // family was actually saved; no protected request uses the old scope.
          refreshResult.complete(
            refreshFails ? _json({}, 503) : _auth('with-family'),
          );
          await operation;
          expect(refreshCalls, 1);
          expect(familyCalls, 1);
          final repository = fixture.account.createHomeAssistantRepository();
          addTearDown(repository.close);
          expect(await repository.restoreCredentials(), !refreshFails);
          if (!refreshFails) {
            expect(await repository.listIntegrations(), isEmpty);
          }
          expect(haCalls, refreshFails ? 0 : 1);
          expect(fixture.account.state.family.hasFamily, !refreshFails);
          if (refreshFails) {
            expect(fixture.account.state.errorMessage, isNotNull);
          }
        },
      );
    }
  }

  for (final role in [null, 'member', 'owner']) {
    testWidgets(
      'HA setup guides family prerequisites and restricts management: $role',
      (tester) async {
        var haCalls = 0;
        final fixture = _Fixture((request) async {
          final path = request.url.path;
          if (path.endsWith('/auth/login')) return _auth('access');
          if (path.endsWith('/families/current')) {
            return role == null ? _json({}, 404) : _family(role);
          }
          if (path.endsWith('/families/members')) return _json({'members': []});
          if (path.endsWith('/devices')) return _json({'devices': []});
          if (path.endsWith('/home-assistant/integrations')) {
            haCalls++;
            return _json({'integrations': []});
          }
          return _json({}, 404);
        });
        await fixture.login();
        await tester.binding.setSurfaceSize(const Size(390, 844));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(
                fixture.settingsRepository,
              ),
              nasConnectionServiceProvider.overrideWithValue(
                fixture.connection,
              ),
              nasAccountProvider.overrideWith((ref) => fixture.account),
            ],
            child: const MaterialApp(home: HomeAssistantSettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        final save = tester.widget<FilledButton>(
          find.widgetWithText(FilledButton, '保存配置'),
        );
        expect(save.onPressed != null, role == 'owner');
        if (role == null) {
          expect(haCalls, 0);
          expect(find.textContaining('创建或加入家庭'), findsWidgets);
          await tester.ensureVisible(find.text('前往 NAS 与家庭设置'));
          await tester.tap(find.text('前往 NAS 与家庭设置'));
          await tester.pumpAndSettle();
          expect(find.byType(NasSettingsScreen), findsOneWidget);
        } else if (role == 'member') {
          expect(find.textContaining('仅家庭创建者或管理员'), findsOneWidget);
        } else {
          // The health provider may rebuild the HA controller once.
          expect(haCalls, greaterThanOrEqualTo(1));
          expect(find.text('前往 NAS 与家庭设置'), findsNothing);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await fixture.close(disposeAccount: false);
      },
    );
  }
  testWidgets('owner can grant a newly discovered entity without borrowing another role permission', (tester) async {
    final grants = <String, Map<String, dynamic>>{};
    final writes = <Map<String, dynamic>>[];
    final entity = {'id': 'row', 'integration_id': 'ha', 'entity_id': 'light.kitchen',
      'domain': 'light', 'name': '厨房灯', 'is_visible': true, 'is_controllable': true,
      'capabilities': ['on_off']};
    final fixture = _Fixture((request) async {
      final path = request.url.path;
      if (path.endsWith('/auth/login')) return _auth('owner-session');
      if (path.endsWith('/families/current')) return _family();
      if (path.endsWith('/families/members')) return _json({'members': []});
      if (path.endsWith('/devices')) return _json({'devices': []});
      if (path.endsWith('/integrations')) {
        return _json({'integrations': [{
          'id': 'ha', 'name': 'HA', 'base_url': 'http://ha.local:8123',
          'status': 'healthy', 'created_at': '2026-11-12T00:00:00Z',
        }]});
      }
      if (path.endsWith('/test')) return _json({'connected': true, 'checked_at': DateTime.now().toUtc().toIso8601String()});
      if (path.endsWith('/catalog')) return _json({'entities': [entity]});
      if (path.endsWith('/entities')) return _json({'entities': grants['owner']?['can_view'] == true ? [entity] : []});
      if (path.endsWith('/permissions')) {
        if (request.method == 'PUT') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          writes.add(body);
          grants[body['role'] as String] = body;
          return _json(body);
        }
        return _json({'permissions': grants.values.toList()});
      }
      if (path.endsWith('/state')) return _json({'entity_id': 'light.kitchen', 'state': 'off', 'attributes': {}, 'fetched_at': DateTime.now().toUtc().toIso8601String()});
      for (final name in ['groups', 'recipes', 'rules', 'suggestions']) {
        if (path.endsWith('-$name')) return _json({name: []});
      }
      return _json({}, 404);
    });
    await fixture.login();
    await tester.binding.setSurfaceSize(const Size(390, 844));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(overrides: [
      settingsRepositoryProvider.overrideWithValue(fixture.settingsRepository),
      nasConnectionServiceProvider.overrideWithValue(fixture.connection),
      nasAccountProvider.overrideWith((ref) => fixture.account),
    ], child: const MaterialApp(home: HomeAssistantSettingsScreen())));
    await tester.pumpAndSettle();
    expect(writes, isEmpty);
    await tester.ensureVisible(find.text('厨房灯'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('厨房灯'));
    await tester.pumpAndSettle();
    final view = find.widgetWithText(SwitchListTile, '允许查看状态');
    final control = find.widgetWithText(SwitchListTile, '允许控制实体');
    expect(tester.widget<SwitchListTile>(view).value, isFalse);
    expect(tester.widget<SwitchListTile>(control).onChanged, isNull);
    await tester.ensureVisible(view);
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许查看状态'));
    await tester.pumpAndSettle();
    expect(writes.single['role'], 'owner');
    expect(writes.single['can_view'], isTrue);
    await tester.ensureVisible(control);
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许控制实体'));
    await tester.pumpAndSettle();
    expect(writes.last['allowed_commands'], ['turn_on', 'turn_off', 'toggle']);
    await tester.ensureVisible(view);
    await tester.pumpAndSettle();
    await tester.tap(find.text('允许查看状态'));
    await tester.pumpAndSettle();
    expect(writes.last['can_view'], isFalse);
    expect(writes.last['can_control'], isFalse);
    expect(writes.last['allowed_commands'], isEmpty);
    final roles = find.byType(DropdownButtonFormField<String>);
    await tester.ensureVisible(roles);
    await tester.pumpAndSettle();
    await tester.tap(roles);
    await tester.pumpAndSettle();
    await tester.tap(find.text('普通成员').last);
    await tester.pumpAndSettle();
    expect(tester.widget<SwitchListTile>(view).value, isFalse);
    expect(writes, hasLength(3));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    await fixture.close(disposeAccount: false);
  });
  for (final (fails, scrollDuringSave) in [
    (false, false),
    (true, false),
    (false, true),
  ]) {
    testWidgets(
      'permission update preserves expanded entities and the current viewport; fails=$fails, scroll=$scrollDuringSave',
      (tester) async {
        final grants = <String, Map<String, dynamic>>{};
        final entities = List.generate(
          18,
          (index) => <String, dynamic>{
            'id': 'row-$index',
            'integration_id': 'ha',
            'entity_id': 'light.room_$index',
            'domain': 'light',
            'name': '房间灯 $index',
            'is_visible': true,
            'is_controllable': true,
            'capabilities': ['on_off'],
          },
        );
        var writes = 0;
        final permissionGate = Completer<void>();
        addTearDown(() {
          if (!permissionGate.isCompleted) permissionGate.complete();
        });
        final fixture = _Fixture((request) async {
          final path = request.url.path;
          if (path.endsWith('/auth/login')) return _auth('owner-session');
          if (path.endsWith('/families/current')) return _family();
          if (path.endsWith('/families/members')) return _json({'members': []});
          if (path.endsWith('/devices')) return _json({'devices': []});
          if (path.endsWith('/integrations')) {
            return _json({
              'integrations': [
                {
                  'id': 'ha',
                  'name': 'HA',
                  'base_url': 'http://ha.local:8123',
                  'status': 'healthy',
                  'created_at': '2026-11-12T00:00:00Z',
                },
              ],
            });
          }
          if (path.endsWith('/test')) {
            return _json({
              'connected': true,
              'checked_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
          if (path.endsWith('/catalog')) return _json({'entities': entities});
          if (path.endsWith('/entities')) {
            return _json({
              'entities': entities
                  .where(
                    (entity) =>
                        grants[entity['entity_id']]?['can_view'] == true,
                  )
                  .map((entity) => {...entity, 'is_controllable': false})
                  .toList(),
            });
          }
          if (path.endsWith('/permissions')) {
            if (request.method == 'PUT') {
              writes++;
              if (scrollDuringSave) await permissionGate.future;
              if (fails) {
                return _json({
                  'error': {
                    'code': 'UNAVAILABLE',
                    'message': 'permission save failed',
                  },
                }, 503);
              }
              final body = jsonDecode(request.body) as Map<String, dynamic>;
              grants[body['entity_id'] as String] = body;
              return _json(body);
            }
            return _json({'permissions': grants.values.toList()});
          }
          if (path.endsWith('/state')) {
            return _json({
              'entity_id':
                  request.url.pathSegments[request.url.pathSegments.length - 2],
              'state': 'off',
              'attributes': {},
              'fetched_at': DateTime.now().toUtc().toIso8601String(),
            });
          }
          for (final name in ['groups', 'recipes', 'rules', 'suggestions']) {
            if (path.endsWith('-$name')) return _json({name: []});
          }
          return _json({}, 404);
        });
        await fixture.login();
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        addTearDown(tester.view.reset);
        await tester.pumpWidget(
          ProviderScope(
            overrides: [
              settingsRepositoryProvider.overrideWithValue(
                fixture.settingsRepository,
              ),
              nasConnectionServiceProvider.overrideWithValue(
                fixture.connection,
              ),
              nasAccountProvider.overrideWith((ref) => fixture.account),
            ],
            child: const MaterialApp(home: HomeAssistantSettingsScreen()),
          ),
        );
        await tester.pumpAndSettle();
        for (var index = 0; index < 6; index++) {
          await tester.ensureVisible(find.text('房间灯 $index'));
          await tester.pumpAndSettle();
          await tester.tap(find.text('房间灯 $index'));
          await tester.pumpAndSettle();
        }
        final entity = find.ancestor(
          of: find.text('房间灯 4'),
          matching: find.byType(ExpansionTile),
        );
        final view = find.descendant(
          of: entity,
          matching: find.widgetWithText(SwitchListTile, '允许查看状态'),
        );
        await Scrollable.ensureVisible(tester.element(view), alignment: .3);
        await tester.pumpAndSettle();
        final tileState = tester.state(entity);
        final beforeTop = tester.getTopLeft(view).dy;
        final beforeExpanded = find
            .widgetWithText(SwitchListTile, '允许查看状态')
            .evaluate()
            .length;
        await tester.tap(view);
        if (scrollDuringSave) {
          await tester.pump(const Duration(milliseconds: 50));
          final scroll = find
              .descendant(
                of: find.byType(HomeAssistantSettingsScreen),
                matching: find.byType(Scrollable),
              )
              .first;
          await tester.drag(scroll, const Offset(0, -350));
          await tester.pump(const Duration(milliseconds: 100));
          permissionGate.complete();
        }
        await tester.pumpAndSettle();
        expect(writes, 1);
        expect(tester.state(entity), same(tileState));
        expect(
          find.widgetWithText(SwitchListTile, '允许查看状态'),
          findsNWidgets(beforeExpanded),
        );
        expect(tester.widget<SwitchListTile>(view).value, !fails);
        if (scrollDuringSave) {
          expect(
            (tester.getTopLeft(view).dy - beforeTop).abs(),
            greaterThan(50),
            reason: 'Do not undo scrolling while a request is in flight.',
          );
        } else {
          expect(tester.getTopLeft(view).dy, closeTo(beforeTop, 1));
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump();
        await fixture.close(disposeAccount: false);
      },
    );
  }
}

class _Fixture {
  _Fixture(Future<http.Response> Function(http.Request) handler, {
    Future<http.Response> Function(http.Request)? health,
  }) {
    settingsRepository.values[nasServerUrlKey] = 'https://nas.example';
    final settings = SettingsService(settingsRepository);
    connection = NasConnectionService(
      settings,
      client: MockClient(health ?? (_) async => _json({'status': 'ok'})),
    );
    account = NasAccountController(
      settings: settings,
      connection: connection,
      credentials: NasCredentialsService(),
      apiClientFactory: (url) => NasApiClient(url, client: MockClient(handler)),
    );
  }
  final settingsRepository = MemorySettingsRepository();
  late final NasConnectionService connection;
  late final NasAccountController account;

  Future<void> login() => account.login(
    const NasLoginRequest(
      email: 'user@example.com',
      password: 'valid-password',
    ),
  );
  Future<void> close({bool disposeAccount = true}) async {
    if (disposeAccount) account.dispose();
    connection.close();
    await settingsRepository.close();
  }
}
