import 'dart:async';

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/nas_connection_service.dart';
import 'package:momo_box/application/settings_service.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/nas_homeassistant_models.dart';
import 'package:momo_box/domain/models/smart_home_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/controllers/smart_home_controller.dart';
import 'package:momo_box/presentation/screens/home_screen.dart';
import 'package:momo_box/presentation/screens/smart_home_screen.dart';

const _entityId = 'light.living_room';
const _deviceId = 'ha::$_entityId';

void main() {
  group('首页 HA 控制器边界（真实控制器 + 仅测试 fake repository）', () {
    test('member 读取授权设备闭环，不调用仅 owner/admin 可用的管理测试', () async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(repository.managementTests, 0);
      expect(repository.integrationReads, 1);
      expect(repository.entityReads, 1);
      expect(repository.permissionReads, 1);
      expect(repository.stateReads, 1);
      expect(controller.state.haStatus, HaConnectionStatus.online);
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, [NasHaCommand.turnOn]);
      expect(controller.state.devices.single.isOn, isTrue);
      expect(controller.state.commandError, isNull);
      // Explicitly prove the fake would reject the old refresh path.
      await expectLater(repository.testIntegration('ha'), throwsA(
        isA<NasApiError>().having((error) => error.statusCode, 'statusCode', 403),
      ));
    });

    for (final status in [
      NasHaIntegrationStatus.unknown,
      NasHaIntegrationStatus.unavailable,
      NasHaIntegrationStatus.invalidCredentials,
    ]) {
      test('member 不因历史 ${status.name} 管理状态阻断当前成功的实体读取', () async {
        final repository = _FakeHaRepository()..integrationStatus = status;
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        expect(repository.managementTests, 0);
        expect(repository.stateReads, 1);
        expect(controller.state.haStatus, HaConnectionStatus.online);
        await controller.setDevicePower(_deviceId, true);
        expect(repository.commands, [NasHaCommand.turnOn]);
        expect(controller.state.commandError, isNull);
      });
    }

    test('member 禁用集成不读取实体或发送控制', () async {
      final repository = _FakeHaRepository()
        ..integrationStatus = NasHaIntegrationStatus.disabled;
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(repository.managementTests, 0);
      expect(repository.entityReads, 0);
      expect(repository.permissionReads, 0);
      expect(repository.stateReads, 0);
      expect(controller.state.haStatus, HaConnectionStatus.offline);
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
    });

    test('member 实体读取失败仅保留过期缓存，不伪报在线或发送控制', () async {
      final repository = _FakeHaRepository()..connected = false;
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(repository.managementTests, 0);
      expect(repository.stateReads, 1);
      expect(controller.state.haStatus, HaConnectionStatus.stale);
      expect(controller.state.entityStates, isEmpty);
      expect(controller.state.devices.single.isReachable, isFalse);
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
    });

    for (final response in ['stale', 'wrong_entity']) {
      test('member 历史 unknown 状态下 $response 回执不能伪报在线或控制', () async {
        final repository = _FakeHaRepository()
          ..integrationStatus = NasHaIntegrationStatus.unknown
          ..remoteState = response == 'stale'
              ? _state(fetchedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 6)))
              : _state(entityId: 'light.other');
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        expect(repository.managementTests, 0);
        expect(repository.stateReads, 1);
        expect(controller.state.haStatus, HaConnectionStatus.stale);
        expect(controller.state.devices.single.isReachable, isFalse);
        await controller.setDevicePower(_deviceId, true);
        expect(repository.commands, isEmpty);
      });
    }

    test('member 实时状态端点 403 不借用管理权限或保留可控缓存', () async {
      final repository = _FakeHaRepository()
        ..fetchFailure = NasApiError(kind: NasApiErrorKind.forbidden,
          statusCode: 403, message: 'entity is not visible to this member');
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(repository.managementTests, 0);
      expect(controller.state.haStatus, HaConnectionStatus.stale);
      expect(controller.state.accessDeniedEntityIds, contains(_deviceId));
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
    });

    test('member 无可见实体时不以空状态集合伪报 HA 在线', () async {
      final repository = _FakeHaRepository()
        ..permissions = [_permission(role: 'owner')];
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(repository.managementTests, 0);
      expect(repository.permissionReads, 1);
      expect(repository.stateReads, 0);
      expect(controller.state.devices, isEmpty);
      expect(controller.state.haStatus, HaConnectionStatus.stale);
      expect(controller.state.message, contains('无法确认'));
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
    });

    for (final role in ['owner', 'admin']) {
      test('$role 使用管理连接测试并仅按自身白名单控制', () async {
        final repository = _FakeHaRepository()
          ..permissions = [_permission(role: role)];
        final controller = await _controller(repository, role: role);
        addTearDown(controller.dispose);
        expect(repository.managementTests, 1);
        expect(repository.entityReads, 1);
        expect(repository.permissionReads, 1);
        expect(repository.stateReads, 1);
        expect(controller.state.haStatus, HaConnectionStatus.online);
        await controller.setDevicePower(_deviceId, true);
        expect(repository.commands, [NasHaCommand.turnOn]);
        expect(controller.state.commandError, isNull);
      });

      test('$role 管理连接测试失败不继续读取或发送控制', () async {
        final repository = _FakeHaRepository()
          ..permissions = [_permission(role: role)]
          ..connected = false;
        final controller = await _controller(repository, role: role);
        addTearDown(controller.dispose);
        expect(repository.managementTests, 1);
        expect(repository.entityReads, 0);
        expect(repository.permissionReads, 0);
        expect(repository.stateReads, 0);
        expect(controller.state.haStatus, HaConnectionStatus.offline);
        await controller.setDevicePower(_deviceId, true);
        expect(repository.commands, isEmpty);
      });
    }

    test('admin 管理权限不等于设备控制权限，不能借用 owner 的设备 grant', () async {
      final repository = _FakeHaRepository()
        ..permissions = [_permission(role: 'owner'), _permission(role: 'admin', canControl: false)];
      final controller = await _controller(repository, role: 'admin');
      addTearDown(controller.dispose);
      expect(repository.managementTests, 1);
      expect(controller.state.devices, hasLength(1));
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
      expect(controller.state.commandError, contains('权限'));
    });

    test('typed toggle；等待 NAS 回执，不乐观翻转；同步拒绝重复提交', () async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      repository.pendingCommand = Completer<NasHaCommandResult>();
      final request = controller.toggleDevice(_deviceId);
      expect(controller.state.isCommandLoading, isTrue);
      expect(controller.state.devices.single.isOn, isFalse);
      await controller.toggleDevice(_deviceId);
      final refreshCalls = repository.integrationReads;
      await controller.refresh();
      expect(repository.integrationReads, refreshCalls);
      expect(repository.commands, [NasHaCommand.toggle]);
      expect(repository.commandTargets, ['ha::$_entityId']);
      expect(repository.requestIds.single, isNotEmpty);
      repository.pendingCommand!.complete(_result());
      await request;
      expect(controller.state.devices.single.isOn, isTrue);
      expect(controller.state.isCommandLoading, isFalse);
      expect(controller.state.commandError, isNull);
      expect(controller.state.entityStates[_deviceId]!.state, 'on');
    });

    for (final domain in ['climate', 'media_player']) {
      for (final initiallyOn in [false, true]) {
        test('$domain 无 toggle 能力时使用明确的 ${initiallyOn ? 'turn_off' : 'turn_on'}', () async {
          final entityId = '$domain.test';
          final repository = _FakeHaRepository()
            ..entities = [_entity(entityId: entityId, domain: domain, capabilities: ['turn_on', 'turn_off'])]
            ..permissions = [_permission(entityId: entityId, commands: ['turn_on', 'turn_off'])]
            ..remoteState = _state(entityId: entityId, value: initiallyOn ? (domain == 'climate' ? 'cool' : 'playing') : 'off')
            ..result = _result(entityId: entityId, stateEntityId: entityId,
              command: initiallyOn ? 'turn_off' : 'turn_on', value: initiallyOn ? 'off' : 'on');
          final controller = await _controller(repository);
          addTearDown(controller.dispose);
          final id = 'ha::$entityId';
          final target = !controller.state.devices.single.isOn;
          expect(target, !initiallyOn);
          expect(controller.powerUnavailableReason(id, turnOn: target), isNull);
          await controller.setDevicePower(id, target);
          expect(repository.commands, [initiallyOn ? NasHaCommand.turnOff : NasHaCommand.turnOn]);
          expect(controller.state.devices.single.isOn, !initiallyOn);
          expect(controller.state.commandError, isNull);
        });
      }
    }

    test('暂停的电视仍有电源，关闭操作为 turn_off 而非 turn_on', () async {
      const entityId = 'media_player.tv';
      final repository = _FakeHaRepository()
        ..entities = [_entity(entityId: entityId, domain: 'media_player', capabilities: ['turn_on', 'turn_off'])]
        ..permissions = [_permission(entityId: entityId, commands: ['turn_on', 'turn_off'])]
        ..remoteState = _state(entityId: entityId, value: 'paused');
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(controller.state.devices.single.isOn, isTrue);
      await controller.setDevicePower('ha::$entityId', !controller.state.devices.single.isOn);
      expect(repository.commands, [NasHaCommand.turnOff]);
    });

    test('power 预检检查目标权限，不因有 toggle 或反方向授权就允许', () async {
      final repository = _FakeHaRepository()
        ..permissions = [_permission(commands: ['turn_off', 'toggle'])];
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(controller.powerUnavailableReason(_deviceId, turnOn: true), contains('权限'));
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
      expect(controller.state.commandError, contains('turn_on'));
    });

    test('power 预检检查目标 capability，不因另一方向能力就允许', () async {
      final repository = _FakeHaRepository()
        ..entities = [_entity(capabilities: ['turn_off'])];
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      expect(controller.powerUnavailableReason(_deviceId, turnOn: true), contains('不支持'));
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, isEmpty);
    });

    test('明确的 power 操作进行中不会因再次点击而发送第二条命令', () async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      repository.pendingCommand = Completer<NasHaCommandResult>();
      final request = controller.setDevicePower(_deviceId, true);
      await controller.setDevicePower(_deviceId, true);
      await controller.setDevicePower(_deviceId, false);
      expect(repository.commands, [NasHaCommand.turnOn]);
      expect(controller.state.devices.single.isOn, isFalse);
      repository.pendingCommand!.complete(_result(command: 'turn_on'));
      await request;
      expect(controller.state.devices.single.isOn, isTrue);
    });

    test('accepted 不等于已翻转：以回执中的实际 off 状态为准', () async {
      final repository = _FakeHaRepository()..result = _result(value: 'off');
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      await controller.toggleDevice(_deviceId);
      expect(repository.commands, [NasHaCommand.toggle]);
      expect(controller.state.devices.single.isOn, isFalse);
      expect(controller.state.commandError, isNull);
    });

    test('回执无 state 时使用真实状态查询结果，不推断开关已改变', () async {
      final repository = _FakeHaRepository()..result = _result(withState: false);
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      await controller.toggleDevice(_deviceId);
      expect(repository.stateReads, 2);
      expect(controller.state.devices.single.isOn, isFalse);
      expect(controller.state.commandError, isNull);
    });

    test('回执无 state 时等待真实状态查询；查询失败不伪成功', () async {
      final repository = _FakeHaRepository()..result = _result(withState: false);
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      repository.fetchFailure = NasApiError(
        kind: NasApiErrorKind.network, message: 'network unavailable',
      );
      await controller.toggleDevice(_deviceId);
      expect(repository.stateReads, 2);
      expect(controller.state.devices.single.isOn, isFalse);
      expect(controller.state.commandError, contains('未确认成功'));
      expect(controller.state.isCommandLoading, isFalse);
    });

    for (final kind in [
      NasApiErrorKind.forbidden,
      NasApiErrorKind.unauthorized,
      NasApiErrorKind.timeout,
      NasApiErrorKind.server,
      NasApiErrorKind.conflict,
    ]) {
      test('${kind.name} 不改变本地开关状态并保留错误', () async {
        final repository = _FakeHaRepository()
          ..commandFailure = NasApiError(kind: kind, message: 'test failure');
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        await controller.toggleDevice(_deviceId);
        expect(controller.state.devices.single.isOn, isFalse);
        expect(controller.state.commandError, isNotNull);
        expect(controller.state.isCommandLoading, isFalse);
        if (kind == NasApiErrorKind.forbidden || kind == NasApiErrorKind.unauthorized) {
          await controller.toggleDevice(_deviceId);
          expect(repository.commands, hasLength(1));
          expect(controller.commandUnavailableReason(_deviceId), contains('权限'));
        }
      });
    }

    test('服务端 HA_UNSUPPORTED_COMMAND 给出明确错误', () async {
      final repository = _FakeHaRepository()
        ..commandFailure = NasApiError(
          kind: NasApiErrorKind.validation,
          code: 'HA_UNSUPPORTED_COMMAND',
          message: 'unsupported',
        );
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      await controller.toggleDevice(_deviceId);
      expect(controller.state.commandError, contains('不支持此命令'));
      expect(controller.state.devices.single.isOn, isFalse);
    });

    for (final response in <String, NasHaCommandResult>{
      'NAS 未接受': _result(accepted: false),
      '错误实体回执': _result(entityId: 'light.other'),
      '错误命令回执': _result(command: 'turn_off'),
      '错误实体状态': _result(stateEntityId: 'light.other'),
    }.entries) {
      test('${response.key} 不写入其他实体或伪成功', () async {
        final repository = _FakeHaRepository()..result = response.value;
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        await controller.toggleDevice(_deviceId);
        expect(controller.state.devices.single.isOn, isFalse);
        expect(controller.state.entityStates[_deviceId]!.state, 'off');
        expect(controller.state.commandError, isNotNull);
        expect(controller.state.isCommandLoading, isFalse);
      });
    }

    final forbiddenCases = <String, _FakeHaRepository Function()>{
      'NAS 未配置': () => _FakeHaRepository()..configured = false,
      'NAS 未登录': () => _FakeHaRepository()..signedIn = false,
      'HA 未配置': () => _FakeHaRepository()..hasIntegration = false,
      'HA 离线': () => _FakeHaRepository()..connected = false,
      '无权限': () => _FakeHaRepository()..permissions = [_permission(canControl: false)],
      '无 whitelist': () => _FakeHaRepository()..permissions = [],
      '禁止查看': () => _FakeHaRepository()..permissions = [_permission(canView: false)],
      '只允许 turn_on': () => _FakeHaRepository()
        ..permissions = [_permission(commands: ['turn_on'])],
      '设备不可控制': () => _FakeHaRepository()
        ..entities = [_entity(controllable: false)],
      'unsupported capability': () => _FakeHaRepository()
        ..entities = [_entity(capabilities: ['brightness'])],
      '状态过期': () => _FakeHaRepository()
        ..remoteState = _state(fetchedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 6))),
      '设备 unavailable': () => _FakeHaRepository()..remoteState = _state(value: 'unavailable'),
      '设备 unknown': () => _FakeHaRepository()..remoteState = _state(value: 'unknown'),
      '初次读取错配实体': () => _FakeHaRepository()..remoteState = _state(entityId: 'light.other'),
      '仅有 owner 权限不能借用': () => _FakeHaRepository()
        ..permissions = [_permission(role: 'owner')],
      'member 拒绝不能借用 owner grant': () => _FakeHaRepository()
        ..permissions = [_permission(role: 'owner'), _permission(canControl: false)],
    };
    for (final scenario in forbiddenCases.entries) {
      test('${scenario.key} 不提交任何命令', () async {
        final repository = scenario.value();
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        expect(controller.commandUnavailableReason(_deviceId), isNotNull);
        await controller.toggleDevice(_deviceId);
        expect(repository.commands, isEmpty);
        expect(controller.state.commandError, isNotNull);
        expect(controller.state.isCommandLoading, isFalse);
      });
    }

    test('未知当前 role 不猜测授权', () async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository, role: null);
      addTearDown(controller.dispose);
      await controller.toggleDevice(_deviceId);
      expect(repository.commands, isEmpty);
      expect(controller.state.commandError, contains('权限'));
    });

    for (final domain in ['scene', 'script', 'lock', 'cover', 'alarm_control_panel']) {
      test('$domain 即使上游标记可控也不扩展为 toggle', () async {
        final entityId = '$domain.test';
        final repository = _FakeHaRepository()
          ..entities = [_entity(entityId: entityId, domain: domain)]
          ..permissions = [_permission(entityId: entityId)]
          ..remoteState = _state(entityId: entityId);
        final controller = await _controller(repository);
        addTearDown(controller.dispose);
        await controller.toggleDevice('ha::$entityId');
        expect(repository.commands, isEmpty);
        expect(controller.state.commandError, contains('不支持'));
      });
    }

    test('返回过期状态保留真实值但提示并阻止再次操作', () async {
      final repository = _FakeHaRepository()
        ..result = _result(fetchedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 6)));
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      await controller.toggleDevice(_deviceId);
      expect(controller.state.haStatus, HaConnectionStatus.stale);
      expect(controller.state.message, contains('已过期'));
      await controller.toggleDevice(_deviceId);
      expect(repository.commands, hasLength(1));
    });

    test('刷新失败后保留最近设备值但禁止继续发命令', () async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      addTearDown(controller.dispose);
      repository.integrationFailure = NasApiError(
        kind: NasApiErrorKind.network, message: 'NAS unavailable',
      );
      await controller.refresh();
      expect(controller.state.nasOnline, isFalse);
      expect(controller.state.devices.single.isOn, isFalse);
      await controller.toggleDevice(_deviceId);
      expect(repository.commands, isEmpty);
      expect(controller.state.commandError, isNotNull);
    });

    test('控制器销毁后的迟到回执安全忽略', () async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      repository.pendingCommand = Completer<NasHaCommandResult>();
      final request = controller.toggleDevice(_deviceId);
      controller.dispose();
      repository.pendingCommand!.complete(_result());
      await expectLater(request, completes);
    });
  });

  group('共享家居页面集成', () {
    testWidgets('未分区设备保留真实房间，但既有三房间页面不构造其卡片', (tester) async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      await _pumpHome(tester, controller, screen: const SmartHomeScreen());
      expect(controller.state.devices.single.room, '未分区');
      expect(find.byKey(const ValueKey('smart-home-power-$_deviceId')), findsNothing);
      expect(repository.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final attribute in ['brightness', 'brightness_pct']) {
      testWidgets('关闭灯的 $attribute 为零时弹窗安全显示真实零亮度', (tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _FakeHaRepository()
          ..entities = [_entity(areaName: '客厅')]
          ..remoteState = _state(attributes: {attribute: 0});
        final controller = await _controller(repository);
        await _pumpHome(tester, controller, screen: const SmartHomeScreen());
        await _openControlSheet(tester, _deviceId);
        expect(controller.state.devices.single.brightness, 0);
        expect(find.text('当前亮度: 0%'), findsOneWidget);
        final slider = tester.widget<Slider>(find.byType(Slider));
        expect(slider.value, 1);
        expect(slider.onChanged, isNull);
        expect(repository.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('关灯回执亮度变为零时 Consumer 重建不触发 Slider 越界', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _FakeHaRepository()
        ..entities = [_entity(areaName: '客厅')]
        ..remoteState = _state(value: 'on', attributes: {'brightness_pct': 60})
        ..result = _result(command: 'turn_off', value: 'off', attributes: {'brightness_pct': 0});
      final controller = await _controller(repository);
      await _pumpHome(tester, controller, screen: const SmartHomeScreen());
      await _openControlSheet(tester, _deviceId);
      expect(find.text('当前亮度: 60%'), findsOneWidget);
      final power = find.byKey(const ValueKey('smart-home-sheet-power-$_deviceId'));
      await tester.tap(find.descendant(of: power, matching: find.byType(Switch)));
      await tester.pumpAndSettle();
      expect(repository.commands, [NasHaCommand.turnOff]);
      expect(controller.state.devices.single.brightness, 0);
      expect(tester.widget<SwitchListTile>(power).value, isFalse);
      expect(find.text('当前亮度: 0%'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1);
      expect(tester.widget<Slider>(find.byType(Slider)).onChanged, isNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final failure in ['403', 'timeout', 'mismatched_receipt']) {
      testWidgets('弹窗内显示 $failure 的真实失败反馈，不翻转设备状态', (tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _FakeHaRepository()..entities = [_entity(areaName: '客厅')];
        if (failure == 'mismatched_receipt') {
          repository.result = _result(command: 'turn_off');
        } else {
          repository.commandFailure = NasApiError(
            kind: failure == '403' ? NasApiErrorKind.forbidden : NasApiErrorKind.timeout,
            statusCode: failure == '403' ? 403 : null,
            message: 'test failure',
          );
        }
        final controller = await _controller(repository);
        await _pumpHome(tester, controller, screen: const SmartHomeScreen());
        await _openControlSheet(tester, _deviceId);
        final power = find.byKey(const ValueKey('smart-home-sheet-power-$_deviceId'));
        await tester.tap(find.descendant(of: power, matching: find.byType(Switch)));
        await tester.pumpAndSettle();
        expect(repository.commands, [NasHaCommand.turnOn]);
        expect(tester.widget<SwitchListTile>(power).value, isFalse);
        final error = controller.state.commandError!;
        final feedback = find.descendant(of: power, matching: find.textContaining(error));
        // Finding text in the obscured scaffold is insufficient: feedback
        // must be on the sheet, inside the viewport, and hit-testable.
        expect(feedback.hitTestable(), findsOneWidget);
        final sheetRect = tester.getRect(find.byType(BottomSheet));
        final feedbackRect = tester.getRect(feedback);
        expect(sheetRect.contains(feedbackRect.topLeft), isTrue);
        expect(sheetRect.contains(feedbackRect.bottomRight), isTrue);
        final viewport = Offset.zero & const Size(420, 1000);
        expect(viewport.contains(feedbackRect.topLeft), isTrue);
        expect(viewport.contains(feedbackRect.bottomRight), isTrue);
        expect(tester.widget<SwitchListTile>(power).isThreeLine, isTrue);
        expect(error, contains(failure == '403' ? '没有权限' : '未确认成功'));
        expect(controller.state.entityStates[_deviceId]!.state, 'off');
        if (failure == '403') {
          expect(tester.widget<SwitchListTile>(power).onChanged, isNull);
        }
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    for (final removal in ['removed', 'permission_revoked', 'logout']) {
      testWidgets('弹窗打开期间 $removal 后关闭，不保留旧设备快照', (tester) async {
        await tester.binding.setSurfaceSize(const Size(420, 1000));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = _FakeHaRepository()..entities = [_entity(areaName: '客厅')];
        final controller = await _controller(repository);
        await _pumpHome(tester, controller, screen: const SmartHomeScreen());
        await _openControlSheet(tester, _deviceId);
        final power = find.byKey(const ValueKey('smart-home-sheet-power-$_deviceId'));
        expect(power, findsOneWidget);
        if (removal == 'logout') {
          repository.signedIn = false;
        } else if (removal == 'permission_revoked') {
          repository.permissions = [];
        } else {
          repository.entities = [];
        }
        await controller.refresh();
        await tester.pumpAndSettle();
        expect(power, findsNothing);
        expect(find.byType(BottomSheet), findsNothing);
        expect(controller.state.devices, isEmpty);
        await controller.setDevicePower(_deviceId, true);
        expect(repository.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('控制器替换后关闭弹窗，旧控制器迟到回执不会污染新账号', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final repository = _FakeHaRepository()..entities = [_entity(areaName: '客厅')];
      final controller = await _controller(repository);
      final replacementRepository = _FakeHaRepository()..signedIn = false;
      final replacement = await _controller(replacementRepository);
      final source = StateProvider<SmartHomeController>((ref) => controller);
      await _pumpHome(tester, controller, screen: const SmartHomeScreen(), controllerSource: source);
      await _openControlSheet(tester, _deviceId);
      final power = find.byKey(const ValueKey('smart-home-sheet-power-$_deviceId'));
      repository.pendingCommand = Completer<NasHaCommandResult>();
      await tester.tap(find.descendant(of: power, matching: find.byType(Switch)));
      await tester.pump();
      expect(repository.commands, [NasHaCommand.turnOn]);
      final container = ProviderScope.containerOf(tester.element(find.byType(SmartHomeScreen)));
      container.read(source.notifier).state = replacement;
      await tester.pumpAndSettle();
      expect(power, findsNothing);
      expect(find.byType(BottomSheet), findsNothing);
      repository.pendingCommand!.complete(_result(command: 'turn_on'));
      await tester.pumpAndSettle();
      expect(replacement.state.devices, isEmpty);
      expect(replacement.state.commandError, isNull);
      expect(replacementRepository.commands, isEmpty);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('电视卡片使用明确 power 命令，回执期间禁用并保持真实状态', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const entityId = 'media_player.tv';
      final repository = _FakeHaRepository()
        ..entities = [_entity(entityId: entityId, domain: 'media_player',
          areaName: '客厅', capabilities: ['turn_on', 'turn_off'])]
        ..permissions = [_permission(entityId: entityId, commands: ['turn_on', 'turn_off'])]
        ..remoteState = _state(entityId: entityId);
      final controller = await _controller(repository);
      await _pumpHome(tester, controller, screen: const SmartHomeScreen());
      final power = find.byKey(const ValueKey('smart-home-power-ha::$entityId'));
      await tester.ensureVisible(power);
      repository.pendingCommand = Completer<NasHaCommandResult>();
      await tester.tap(power);
      await tester.pump();
      expect(repository.commands, [NasHaCommand.turnOn]);
      expect(tester.widget<Switch>(power).value, isFalse);
      expect(tester.widget<Switch>(power).onChanged, isNull);
      repository.pendingCommand!.complete(_result(
        entityId: entityId, stateEntityId: entityId, command: 'turn_on',
      ));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(power).value, isTrue);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('控制面板跟随回执刷新，未支持的音量操作不伪报已发送', (tester) async {
      await tester.binding.setSurfaceSize(const Size(420, 1000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      const entityId = 'media_player.tv';
      final repository = _FakeHaRepository()
        ..entities = [_entity(entityId: entityId, domain: 'media_player',
          areaName: '客厅', capabilities: ['turn_on', 'turn_off'])]
        ..permissions = [_permission(entityId: entityId, commands: ['turn_on', 'turn_off'])]
        ..remoteState = _state(entityId: entityId);
      final controller = await _controller(repository);
      await _pumpHome(tester, controller, screen: const SmartHomeScreen());
      await _openControlSheet(tester, 'ha::$entityId');
      final sheetPower = find.byKey(const ValueKey('smart-home-sheet-power-ha::$entityId'));
      repository.pendingCommand = Completer<NasHaCommandResult>();
      await tester.tap(find.descendant(of: sheetPower, matching: find.byType(Switch)));
      await tester.pump();
      expect(tester.widget<SwitchListTile>(sheetPower).onChanged, isNull);
      expect(tester.widget<SwitchListTile>(sheetPower).value, isFalse);
      repository.pendingCommand!.complete(_result(
        entityId: entityId, stateEntityId: entityId, command: 'turn_on',
      ));
      await tester.pumpAndSettle();
      expect(tester.widget<SwitchListTile>(sheetPower).value, isTrue);
      await tester.tap(find.text('音量 +'));
      await tester.pumpAndSettle();
      expect(find.textContaining('未开放音量控制，未发送请求'), findsWidgets);
      expect(find.textContaining('已发送音量'), findsNothing);
      expect(repository.commands, [NasHaCommand.turnOn]);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });

  group('首页 HA 快捷卡片', () {
    testWidgets('真实状态和 typed turn_on；命令完成前不翻转', (tester) async {
      final repository = _FakeHaRepository();
      final controller = await _controller(repository);
      repository.pendingCommand = Completer<NasHaCommandResult>();
      await _pumpHome(tester, controller);
      expect(find.text('智能家居预览（已连接）'), findsOneWidget);
      expect(find.text('客厅灯'), findsOneWidget);
      expect(find.text('示例设备，未连接'), findsNothing);
      final toggle = find.byKey(const ValueKey('home-ha-toggle-$_deviceId'));
      expect(tester.widget<Switch>(toggle).value, isFalse);
      await tester.tap(toggle);
      await tester.pump();
      expect(tester.widget<Switch>(toggle).value, isFalse);
      expect(tester.widget<Switch>(toggle).onChanged, isNull);
      expect(find.text('控制请求进行中'), findsOneWidget);
      await controller.setDevicePower(_deviceId, true);
      expect(repository.commands, [NasHaCommand.turnOn]);
      repository.pendingCommand!.complete(_result(command: 'turn_on'));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(toggle).value, isTrue);
      expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final domain in ['climate', 'media_player']) {
      for (final initiallyOn in [false, true]) {
        testWidgets('$domain 仅 turn_on/off 的真实能力仍可使用首页 Switch（初始 $initiallyOn）', (tester) async {
          final entityId = '$domain.test';
          final repository = _FakeHaRepository()
            ..entities = [_entity(entityId: entityId, domain: domain, capabilities: ['turn_on', 'turn_off'])]
            ..permissions = [_permission(entityId: entityId, commands: ['turn_on', 'turn_off'])]
            ..remoteState = _state(entityId: entityId, value: initiallyOn ? (domain == 'climate' ? 'cool' : 'playing') : 'off')
            ..result = _result(entityId: entityId, stateEntityId: entityId,
              command: initiallyOn ? 'turn_off' : 'turn_on', value: initiallyOn ? 'off' : 'on');
          final controller = await _controller(repository);
          await _pumpHome(tester, controller);
          final toggle = find.byType(Switch);
          expect(tester.widget<Switch>(toggle).value, initiallyOn);
          expect(tester.widget<Switch>(toggle).onChanged, isNotNull);
          await tester.tap(toggle);
          await tester.pumpAndSettle();
          expect(repository.commands, [initiallyOn ? NasHaCommand.turnOff : NasHaCommand.turnOn]);
          expect(tester.widget<Switch>(toggle).value, !initiallyOn);
          expect(controller.state.commandError, isNull);
          expect(tester.takeException(), isNull);
          await tester.pumpWidget(const SizedBox.shrink());
        });
      }
    }

    testWidgets('NAS 失败显示错误，不伪成功或翻转', (tester) async {
      final repository = _FakeHaRepository()
        ..commandFailure = NasApiError(kind: NasApiErrorKind.server, message: 'offline');
      final controller = await _controller(repository);
      await _pumpHome(tester, controller);
      await tester.tap(find.byType(Switch));
      await tester.pumpAndSettle();
      expect(tester.widget<Switch>(find.byType(Switch)).value, isFalse);
      expect(find.textContaining('控制请求未确认成功'), findsWidgets);
      expect(find.textContaining('执行指令已下发'), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    for (final scenario in <String, _FakeHaRepository Function()>{
      '未配置': () => _FakeHaRepository()..hasIntegration = false,
      '离线': () => _FakeHaRepository()..connected = false,
      '无权限': () => _FakeHaRepository()..permissions = [_permission(canControl: false)],
      '能力不支持': () => _FakeHaRepository()..entities = [_entity(capabilities: [])],
      '状态过期': () => _FakeHaRepository()
        ..remoteState = _state(fetchedAt: DateTime.now().toUtc().subtract(const Duration(minutes: 6))),
    }.entries) {
      testWidgets('${scenario.key} 不开放快捷开关，320px 卡片无布局异常', (tester) async {
        await tester.binding.setSurfaceSize(const Size(320, 720));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final repository = scenario.value();
        final controller = await _controller(repository);
        await _pumpHome(tester, controller);
        for (final toggle in tester.widgetList<Switch>(find.byType(Switch))) {
          expect(toggle.onChanged, isNull);
          expect(toggle.value, isFalse);
        }
        if (controller.state.haStatus == HaConnectionStatus.unconfigured) {
          expect(find.text('智能家居预览（未接入）'), findsOneWidget);
        }
        if (controller.state.devices.isEmpty) {
          expect(find.byType(Switch), findsNothing);
          expect(find.text(controller.state.message!), findsOneWidget);
        }
        expect(repository.commands, isEmpty);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }

    testWidgets('一个命令进行中同时禁用其他设备', (tester) async {
      const secondEntity = 'light.bedroom';
      final repository = _FakeHaRepository()
        ..entities = [_entity(), _entity(entityId: secondEntity, name: '卧室灯')]
        ..permissions = [_permission(), _permission(entityId: secondEntity)];
      final controller = await _controller(repository);
      repository.pendingCommand = Completer<NasHaCommandResult>();
      await _pumpHome(tester, controller);
      await tester.tap(find.byKey(const ValueKey('home-ha-toggle-$_deviceId')));
      await tester.pump();
      for (final toggle in tester.widgetList<Switch>(find.byType(Switch))) {
        expect(toggle.onChanged, isNull);
      }
      await controller.setDevicePower('ha::$secondEntity', true);
      expect(repository.commands, hasLength(1));
      repository.pendingCommand!.complete(_result(command: 'turn_on'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('scene/script 实体不会作为开关；场景沿用家居页未接入语义', (tester) async {
      final repository = _FakeHaRepository()
        ..entities = [_entity(entityId: 'scene.night', domain: 'scene')]
        ..permissions = [_permission(entityId: 'scene.night')];
      final controller = _SceneTestController(repository);
      await controller.refresh();
      controller.seedScene();
      await _pumpHome(tester, controller);
      expect(find.byType(Switch), findsNothing);
      await tester.tap(find.text('晚安'));
      await tester.pumpAndSettle();
      expect(find.text('场景快捷执行尚未接入，未执行【晚安】。'), findsOneWidget);
      expect(repository.commands, isEmpty);
      await tester.pumpWidget(const SizedBox.shrink());
    });

    testWidgets('首页 HA 服务行读取真实控制器状态，而非固定未接入', (tester) async {
      final controller = await _controller(_FakeHaRepository());
      await _pumpHome(tester, controller, sections: ['quick_intake']);
      final haRow = find.ancestor(of: find.text('HA服务'), matching: find.byType(Row)).first;
      expect(find.descendant(of: haRow, matching: find.text('已连接')), findsOneWidget);
      expect(find.descendant(of: haRow, matching: find.text('未接入')), findsNothing);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  });
}

Future<SmartHomeController> _controller(
  _FakeHaRepository repository, {String? role = 'member'}
) async {
  repository.actorRole = role ?? 'member';
  final controller = SmartHomeController(repository, nasAddress: 'http://nas.local', role: role);
  await controller.refresh();
  return controller;
}

Future<void> _pumpHome(
  WidgetTester tester,
  SmartHomeController controller, {
  List<String> sections = const ['smart_home_quick'],
  Widget screen = const HomeScreen(),
  StateProvider<SmartHomeController>? controllerSource,
}) async {
  final database = AppDatabase.forTesting(NativeDatabase.memory());
  addTearDown(database.close);
  await tester.pumpWidget(ProviderScope(
    overrides: [
      databaseProvider.overrideWithValue(database),
      smartHomeControllerProvider.overrideWith((ref) =>
          controllerSource == null ? controller : ref.watch(controllerSource)),
      nasConnectionServiceProvider.overrideWith((ref) {
        final service = _FakeNasConnectionService(database);
        ref.onDispose(service.close);
        return service;
      }),
      inventoryProvider.overrideWith((ref) => Stream.value(const <InventoryItem>[])),
      shoppingProvider.overrideWith((ref) => Stream.value(const <ShoppingEntry>[])),
      homeSectionOrderProvider.overrideWith((ref) => Stream.value(sections)),
      themeNameProvider.overrideWith((ref) => Stream.value(null)),
      aiConfigurationStatusProvider.overrideWith((ref) => Stream.value(false)),
      reminderSummaryProvider.overrideWith((ref) => const ReminderSummary(
        expired: [], expiring: [], lowStock: [],
      )),
    ],
    child: MaterialApp(home: screen),
  ));
  await tester.pumpAndSettle();
}

Future<void> _openControlSheet(WidgetTester tester, String deviceId) async {
  final cardPower = find.byKey(ValueKey('smart-home-power-$deviceId'));
  await tester.ensureVisible(cardPower);
  final card = find.ancestor(of: cardPower, matching: find.byType(Card));
  await tester.tap(find.descendant(of: card, matching: find.byIcon(Icons.tune_rounded)));
  await tester.pumpAndSettle();
  expect(find.byKey(ValueKey('smart-home-sheet-power-$deviceId')), findsOneWidget);
}

NasHaEntity _entity({
  String entityId = _entityId,
  String domain = 'light',
  String name = '客厅灯',
  String? areaName,
  bool controllable = true,
  List<String> capabilities = const ['on_off'],
}) => NasHaEntity(
  id: 'row-$entityId', integrationId: 'ha', entityId: entityId,
  domain: domain, name: name, areaName: areaName,
  isVisible: true, isControllable: controllable,
  capabilities: capabilities, currentState: 'off',
);

NasHaEntityPermission _permission({
  String entityId = _entityId,
  String role = 'member',
  bool canControl = true,
  bool canView = true,
  List<String> commands = const ['turn_on', 'turn_off', 'toggle'],
}) => NasHaEntityPermission(
  integrationId: 'ha', entityId: entityId, role: role,
  canView: canView, canControl: canControl, allowedCommands: commands,
);

NasHaEntityState _state({
  String entityId = _entityId,
  String value = 'off',
  DateTime? fetchedAt,
  Map<String, dynamic> attributes = const {},
}) => NasHaEntityState(
  entityId: entityId, state: value, attributes: attributes,
  fetchedAt: fetchedAt ?? DateTime.now().toUtc(),
);

NasHaCommandResult _result({
  bool accepted = true,
  bool withState = true,
  String value = 'on',
  String entityId = _entityId,
  String command = 'toggle',
  String stateEntityId = _entityId,
  DateTime? fetchedAt,
  Map<String, dynamic> attributes = const {},
}) => NasHaCommandResult(
  accepted: accepted, entityId: entityId, command: command,
  executedAt: DateTime.now().toUtc(),
  state: withState ? _state(entityId: stateEntityId, value: value, fetchedAt: fetchedAt, attributes: attributes) : null,
);

// Fake integrations, credentials and responses exist only in this test file.
// No production provider uses them and no network/token storage is involved.
class _FakeHaRepository extends NasSmartHomeRepository {
  _FakeHaRepository() : super(null);

  bool configured = true;
  bool signedIn = true;
  bool hasIntegration = true;
  bool connected = true;
  String actorRole = 'member';
  NasHaIntegrationStatus integrationStatus = NasHaIntegrationStatus.healthy;
  int managementTests = 0;
  int entityReads = 0;
  int permissionReads = 0;
  int integrationReads = 0;
  int stateReads = 0;
  List<NasHaEntity> entities = [_entity()];
  List<NasHaEntityPermission> permissions = [_permission()];
  NasHaEntityState? remoteState;
  NasHaCommandResult? result;
  NasApiError? commandFailure;
  NasApiError? fetchFailure;
  NasApiError? integrationFailure;
  Completer<NasHaCommandResult>? pendingCommand;
  final commands = <NasHaCommand>[];
  final commandTargets = <String>[];
  final requestIds = <String>[];

  @override
  bool get isConfigured => configured;
  @override
  Future<bool> restoreCredentials() async => signedIn;
  @override
  Future<List<NasHaIntegration>> listIntegrations() async {
    integrationReads++;
    if (integrationFailure != null) throw integrationFailure!;
    return hasIntegration ? [NasHaIntegration(
      id: 'ha', name: '家居', baseUrl: Uri.parse('http://ha.local:8123'),
      status: integrationStatus, createdAt: DateTime.now().toUtc(),
    )] : [];
  }
  @override
  Future<NasHaConnectionTestResult> testIntegration(String integrationId) async {
    managementTests++;
    // Match the NAS contract: member may list integrations/permissions, but
    // testing the managed HA connection requires owner/admin.
    if (actorRole != 'owner' && actorRole != 'admin') {
      throw NasApiError(
        kind: NasApiErrorKind.forbidden, statusCode: 403,
        message: 'only owner or admin can test Home Assistant integrations',
      );
    }
    return NasHaConnectionTestResult(
      connected: connected, checkedAt: DateTime.now().toUtc(),
    );
  }

  NasHaEntityPermission? _actorPermission(NasHaEntity entity) => permissions
      .where((permission) => permission.integrationId == entity.integrationId &&
          permission.entityId == entity.entityId && permission.role == actorRole)
      .firstOrNull;

  @override
  Future<List<NasHaEntity>> listEntities({String? integrationId, bool controllableOnly = false}) async {
    entityReads++;
    return entities.where((entity) {
      final permission = _actorPermission(entity);
      return (integrationId == null || entity.integrationId == integrationId) &&
          entity.isVisible && permission?.canView == true &&
          (!controllableOnly ||
              (entity.isControllable && permission?.canControl == true));
    }).toList();
  }
  @override
  Future<List<NasHaEntityPermission>> listPermissions() async {
    permissionReads++;
    // This family-level endpoint includes other roles; the client must not
    // mistake an owner's grant for the current member's permission.
    return permissions;
  }
  @override
  Future<NasHaEntityState> fetchEntityState({required String integrationId, required String entityId}) async {
    stateReads++;
    final entity = entities.where((item) => item.integrationId == integrationId &&
        item.entityId == entityId).firstOrNull;
    if (entity == null || _actorPermission(entity)?.canView != true) {
      throw NasApiError(kind: NasApiErrorKind.forbidden, statusCode: 403,
        message: 'entity is not visible to this member');
    }
    if (fetchFailure != null) throw fetchFailure!;
    if (!connected) {
      throw NasApiError(kind: NasApiErrorKind.server,
        message: 'Home Assistant state could not be read');
    }
    return remoteState ?? _state(entityId: entityId);
  }
  @override
  Future<NasHaCommandResult> sendCommand({
    required String integrationId,
    required String entityId,
    required NasHaCommand command,
    required String requestId,
    NasHaCommandParameters? parameters,
  }) async {
    commands.add(command);
    commandTargets.add('$integrationId::$entityId');
    requestIds.add(requestId);
    final entity = entities.where((item) => item.integrationId == integrationId &&
        item.entityId == entityId).firstOrNull;
    final permission = entity == null ? null : _actorPermission(entity);
    if (permission == null || !permission.canView || !permission.canControl ||
        !permission.allowedCommands.contains(nasHaCommandValue(command))) {
      throw NasApiError(kind: NasApiErrorKind.forbidden, statusCode: 403,
        message: 'entity command is not permitted for this member');
    }
    if (commandFailure != null) throw commandFailure!;
    if (pendingCommand != null) return pendingCommand!.future;
    return result ?? _result(
      entityId: entityId, stateEntityId: entityId, command: nasHaCommandValue(command),
    );
  }
  @override
  Future<List<NasHaConsumableGroup>> listConsumableGroups() async => [];
  @override
  Future<List<NasHaConsumableRecipe>> listConsumableRecipes() async => [];
  @override
  Future<List<NasHaLinkageRule>> listLinkageRules() async => [];
  @override
  Future<List<NasHaLinkageSuggestion>> listLinkageSuggestions({NasHaLinkageSuggestionStatus? status}) async => [];
}

class _FakeNasConnectionService extends NasConnectionService {
  _FakeNasConnectionService(AppDatabase database)
      : super(SettingsService(SettingsRepository(database)));
  @override
  Future<NasConnectionState> loadState() async =>
      const NasConnectionState(status: NasConnectionStatus.unconfigured);
}

class _SceneTestController extends SmartHomeController {
  _SceneTestController(NasSmartHomeRepository repository)
      : super(repository, nasAddress: 'http://nas.local', role: 'member');
  void seedScene() {
    state = state.copyWith(scenes: const [SmartScene(
      id: 'ha::scene.night', name: '晚安', icon: '🌙', description: '测试场景',
    )]);
  }
}
