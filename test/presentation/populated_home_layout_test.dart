import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/data/nas/nas_api_client.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/domain/models/home_environment.dart';
import 'package:momo_box/domain/models/smart_home_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/controllers/smart_home_controller.dart';
import 'package:momo_box/presentation/screens/smart_home_screen.dart';
import 'package:momo_box/presentation/widgets/momo_components.dart';

const _notice = '部分设备当前没有控制权限，控制请求仍以 NAS 服务端授权为准。';

class _PopulatedHome extends SmartHomeController {
  _PopulatedHome(super.repository, DeviceType type)
    : super(nasAddress: 'https://nas.example') {
    state = SmartHomeState(
      devices: [
        SmartDevice(
          id: 'device',
          name: '客厅靠近阳台的长名称家居设备',
          room: '一楼客厅与阳台区域',
          type: type,
          isOn: true,
          statusText: '当前状态已从家庭设备读取，仅允许查看',
        ),
      ],
      logs: [
        ConsumableLinkageLog(
          id: 'log',
          deviceName: '洗衣房的家庭洗衣机',
          eventSummary: '已完成一次完整洗衣程序',
          consumableName: '家庭日常使用的浓缩洗衣液',
          quantity: 1,
          unit: '件',
          status: ConsumableActionStatus.insufficientStock,
          timestamp: DateTime.utc(2026, 11, 13),
          purchaseSuggestions: const [
            ConsumablePurchaseSuggestion(
              productId: 'product',
              productName: '需要补充的家庭浓缩洗衣液',
              quantity: 2,
              unit: '件',
            ),
          ],
        ),
      ],
      haStatus: HaConnectionStatus.online,
      haAddress: 'http://ha.local:8123',
      nasAddress: 'https://nas.example',
      nasOnline: true,
      message: _notice,
    );
  }

  @override
  Future<void> refresh() async {}
}

void main() {
  for (final width in [320.0, 390.0]) {
    for (final scale in [1.0, 2.0, 3.4]) {
      testWidgets('populated HA notice stays separated at $width / $scale', (
        tester,
      ) async {
        await _mount(tester, width, scale, DeviceType.light);
        final scroll = find.byType(Scrollable).first;
        await tester.scrollUntilVisible(
          find.text(_notice),
          200,
          scrollable: scroll,
        );
        await tester.pumpAndSettle();
        final notice =
            find
                .ancestor(
                  of: find.text(_notice),
                  matching: find.byType(MomoCard),
                )
                .first;
        final header = find.text('家里的设备');
        final badge = find.text('HA 已连接');
        expect(
          tester.getTopLeft(notice).dy - tester.getBottomLeft(header).dy,
          greaterThanOrEqualTo(12),
        );
        expect(
          tester.getTopLeft(notice).dy - tester.getBottomLeft(badge).dy,
          greaterThanOrEqualTo(12),
        );
        await tester.scrollUntilVisible(
          find.text('客厅靠近阳台的长名称家居设备'),
          200,
          scrollable: scroll,
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.scrollUntilVisible(
          find.text('耗材建议：家庭日常使用的浓缩洗衣液 × 1 件'),
          200,
          scrollable: scroll,
        );
        await tester.pumpAndSettle();
        expect(find.text('• 需要补充的家庭浓缩洗衣液 × 2 件'), findsOneWidget);
        expect(tester.takeException(), isNull);
        await tester.pumpWidget(const SizedBox.shrink());
      });
    }
  }
  for (final type in [DeviceType.light, DeviceType.climate, DeviceType.tv]) {
    testWidgets('long $type control sheet scrolls on a small screen', (
      tester,
    ) async {
      await _mount(tester, 320, 3.4, type);
      await tester.scrollUntilVisible(
        find.text('客厅靠近阳台的长名称家居设备'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('客厅靠近阳台的长名称家居设备'));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final sheet = find.byType(BottomSheet);
      final bottom = switch (type) {
        DeviceType.light => '当前亮度: 80%',
        DeviceType.climate => '设定温度',
        _ => '静音',
      };
      await tester.ensureVisible(
        find.descendant(of: sheet, matching: find.text(bottom)),
      );
      await tester.pumpAndSettle();
      expect(
        find.descendant(of: sheet, matching: find.text(bottom)).hitTestable(),
        findsOneWidget,
      );
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
    });
  }
}

Future<void> _mount(
  WidgetTester tester,
  double width,
  double scale,
  DeviceType type,
) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 640);
  tester.platformDispatcher.textScaleFactorTestValue = scale;
  addTearDown(tester.view.reset);
  addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
  final api = NasApiClient('https://nas.example');
  addTearDown(api.close);
  final repository = NasSmartHomeRepository.withSession(
    api,
    isSessionCurrent: () => true,
  );
  addTearDown(repository.close);
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        smartHomeControllerProvider.overrideWith(
          (ref) => _PopulatedHome(repository, type),
        ),
        homeEnvironmentProvider.overrideWith(
          (ref) => const AsyncData(HomeEnvironment()),
        ),
        environmentClockProvider.overrideWith(
          (ref) => Stream.value(DateTime.utc(2026, 11, 13)),
        ),
      ],
      child: MaterialApp(
        theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
        home: const SmartHomeScreen(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}
