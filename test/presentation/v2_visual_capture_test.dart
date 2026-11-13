import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_box_app.dart';
import 'package:momo_box/application/inventory_service.dart';
import 'package:momo_box/application/network_status_source.dart';
import 'package:momo_box/core/database/app_database.dart';
import 'package:momo_box/data/repositories/nas_smart_home_repository.dart';
import 'package:momo_box/data/repositories/inventory_repository.dart';
import 'package:momo_box/data/repositories/settings_repository.dart';
import 'package:momo_box/domain/models/home_environment.dart';
import 'package:momo_box/domain/models/inventory_models.dart';
import 'package:momo_box/domain/models/nas_homeassistant_models.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/controllers/smart_home_controller.dart';
import 'package:momo_box/presentation/widgets/momo_still_life.dart';
import 'package:momo_box/presentation/widgets/momo_components.dart';
import 'package:momo_box/presentation/widgets/momo_mobile_layout.dart';

// These are actual Flutter pages, with isolated local test data. Captures are
// rendering evidence, not an installed APK or a live NAS/HA acceptance test.
void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'V2 ${brightness.name}: five production routes render above the dock',
      (tester) async {
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(390, 844);
        tester.view.padding = const FakeViewPadding(top: 24, bottom: 24);
        tester.view.viewPadding = const FakeViewPadding(top: 24, bottom: 24);
        tester.platformDispatcher.platformBrightnessTestValue = brightness;
        addTearDown(tester.view.reset);
        addTearDown(tester.platformDispatcher.clearPlatformBrightnessTestValue);

        final fontPath = Platform.environment['MOMO_UI_FONT'];
        if (fontPath != null) {
          final bytes = await tester.runAsync(
            () => File(fontPath).readAsBytes(),
          );
          for (final family in ['Roboto', 'Ahem']) {
            final loader = FontLoader(family)
              ..addFont(Future.value(ByteData.sublistView(bytes!)));
            await loader.load();
          }
          final icons = FontLoader('MaterialIcons')
            ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
          await icons.load();
        }

        final database = AppDatabase.forTesting(NativeDatabase.memory());
        try {
          final theme = Platform.environment['MOMO_UI_THEME'];
          if (theme != null) {
            await SettingsRepository(database).setValue('theme', theme);
          }
          final service = InventoryService(InventoryRepository(database));
          for (final (name, category, location, unit, days) in [
            ('有机纯牛奶', '食品生鲜', '厨房 · 冷藏区', '盒', 3),
            ('维生素 C', '健康护理', '客厅 · 药品抽屉', '瓶', 14),
            ('燕麦片', '食品生鲜', '厨房 · 储物柜', '袋', 120),
            ('植物洗手液', '家居清洁', '洗手间', '瓶', 180),
          ]) {
            await service.intake(
              IntakeDraft(
                name: name,
                category: category,
                location: location,
                unit: unit,
                quantity: 3,
                expiryDate: DateTime.now().add(Duration(days: days)),
              ),
            );
          }
          final boundaryKey = GlobalKey();
          final now = DateTime.now().toUtc();
          await tester.pumpWidget(
            ProviderScope(
              overrides: [
          nasAppAccessProvider.overrideWithValue(NasAppAccess.connected),
          legacyClientCleanupProvider.overrideWith((ref) async {}),
                databaseProvider.overrideWithValue(database),
                syncNetworkStatusSourceProvider.overrideWithValue(
                  _OfflineNetwork(),
                ),
                homeEnvironmentProvider.overrideWith(
                  (ref) => AsyncData(HomeEnvironment(
                    indoorTemperature: EnvironmentReading(23.6, '客厅传感器', now),
                    indoorHumidity: EnvironmentReading(48, '客厅传感器', now),
                    outdoorTemperature: EnvironmentReading(
                      18,
                      'Open-Meteo · 测试城市',
                      now,
                    ),
                    apparentTemperature: EnvironmentReading(
                      17,
                      'Open-Meteo · 测试城市',
                      now,
                    ),
                  )),
                ),
                environmentClockProvider.overrideWith(
                  (ref) => Stream.value(now),
                ),
                aiConfigurationStatusProvider.overrideWith(
                  (ref) => Stream.value(false),
                ),
                smartHomeControllerProvider.overrideWith(
                  (ref) => SmartHomeController(
                    _VisualHaRepository(),
                    nasAddress: 'http://fixture.invalid',
                    role: 'member',
                  ),
                ),
              ],
              child: RepaintBoundary(
                key: boundaryKey,
                child: const MomoBoxApp(enableMediaReconciliation: false),
              ),
            ),
          );
          await _frames(tester);
          final container = ProviderScope.containerOf(
            tester.element(find.byType(MomoBoxApp)),
          );
          final router = container.read(appRouterProvider);
          expect(router.routeInformationProvider.value.uri.path, '/');
          expect(find.byType(MomoStillLife), findsOneWidget);
          expect(find.text('记录新物品').hitTestable(), findsOneWidget);
          expect(find.text('最近需要关注').hitTestable(), findsOneWidget);

          for (final (route, name) in [
            ('/', 'today'),
            ('/assistant', 'assistant'),
            ('/inventory', 'inventory'),
            ('/smart-home', 'home'),
            ('/settings', 'settings'),
          ]) {
            router.go(route);
            await _frames(tester);
            if (route != '/assistant') {
              final scroll = find.byType(Scrollable).first;
              expect(
                tester.state<ScrollableState>(scroll).position.pixels,
                0,
                reason: route,
              );
            }
            expect(tester.takeException(), isNull, reason: route);
            final bar = tester.widget<NavigationBar>(
              find.byType(NavigationBar),
            );
            expect(
              bar.destinations.map(
                (destination) => (destination as NavigationDestination).label,
              ),
              ['助手', '物品', '今日', '家居', '设置'],
            );
            if (route == '/assistant') {
              expect(find.text('生活的小事，\n一起理清楚。'), findsOneWidget);
              expect(find.byTooltip('发送消息').hitTestable(), findsOneWidget);
            }
            final directory = Platform.environment['MOMO_UI_CAPTURE_DIR'];
            if (directory != null) {
              final todayLayout = route == '/' ? _todayLayout(tester) : null;
              final boundary =
                  boundaryKey.currentContext!.findRenderObject()!
                      as RenderRepaintBoundary;
              await tester.runAsync(() async {
                final image = await boundary.toImage(pixelRatio: 2);
                final bytes = await image.toByteData(
                  format: ui.ImageByteFormat.png,
                );
                await Directory(directory).create(recursive: true);
                await File(
                  '$directory/${brightness.name}-$name-fixture.png',
                ).writeAsBytes(bytes!.buffer.asUint8List());
                if (todayLayout != null) {
                  await File(
                    '$directory/${brightness.name}-today-layout.json',
                  ).writeAsString(todayLayout);
                }
                image.dispose();
              });
            }
          }
          final directory = Platform.environment['MOMO_UI_CAPTURE_DIR'];
          if (directory != null) {
            await tester.runAsync(() => _writeOverview(directory, brightness));
          }
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          await tester.pump(Duration.zero);
          await tester.runAsync(database.close);
        }
      },
    );
  }
}

String _todayLayout(WidgetTester tester) {
  final regions = {
    'household': find.byType(MomoHouseholdBar),
    'header': find.byType(MomoPageHeader),
    'hero':
        find
            .ancestor(
              of: find.text('今天，先照顾这些'),
              matching: find.byType(MomoCard),
            )
            .first,
    'quickIntake':
        find
            .ancestor(of: find.text('记录新物品'), matching: find.byType(MomoCard))
            .first,
    'attentionHeading': find.text('最近需要关注'),
  };
  return const JsonEncoder.withIndent('  ').convert({
    for (final entry in regions.entries)
      entry.key: {
        'top': tester.getRect(entry.value).top,
        'height': tester.getRect(entry.value).height,
        'bottom': tester.getRect(entry.value).bottom,
      },
  });
}

Future<void> _frames(WidgetTester tester) async {
  for (var frame = 0; frame < 20; frame++) {
    await tester.pump(const Duration(milliseconds: 50));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
  }
}

class _OfflineNetwork implements NetworkStatusSource {
  @override
  Stream<NetworkAvailability> get changes => const Stream.empty();
  @override
  Future<NetworkAvailability> get current async => NetworkAvailability.offline;
  @override
  void dispose() {}
}

Future<void> _writeOverview(String directory, Brightness brightness) async {
  final recorder = ui.PictureRecorder();
  final canvas = Canvas(recorder);
  const width = 1260;
  const height = 966;
  canvas.drawColor(const Color(0xFFEAE9E4), BlendMode.src);
  void label(String text, double x, double y, double size) {
    final painter = TextPainter(
      textDirection: TextDirection.ltr,
      text: TextSpan(
        text: text,
        style: TextStyle(
          fontFamily: 'Roboto',
          fontSize: size,
          color: const Color(0xFF51674B),
        ),
      ),
    )..layout();
    painter.paint(canvas, Offset(x, y));
    painter.dispose();
  }

  label('MomoBox · Flutter UI · isolated test data', 24, 15, 18);
  final images = <ui.Image>[];
  final pages = [('assistant', '助手'), ('today', '今日'), ('home', '家居')];
  for (var index = 0; index < pages.length; index++) {
    final (name, title) = pages[index];
    final bytes =
        await File(
          '$directory/${brightness.name}-$name-fixture.png',
        ).readAsBytes();
    final codec = await ui.instantiateImageCodec(bytes);
    final image = (await codec.getNextFrame()).image;
    codec.dispose();
    images.add(image);
    final left = 24.0 + index * 414;
    label(title, left, 48, 14);
    canvas.drawImageRect(
      image,
      Rect.fromLTWH(0, 0, image.width.toDouble(), image.height.toDouble()),
      Rect.fromLTWH(left, 76, 390, 844),
      Paint(),
    );
  }
  label(
    'Rendered from production Flutter pages. Test inventory and device responses.',
    24,
    940,
    13,
  );
  final picture = recorder.endRecording();
  final overview = await picture.toImage(width, height);
  final data = await overview.toByteData(format: ui.ImageByteFormat.png);
  await File(
    '$directory/overview-${brightness.name}-fixture.png',
  ).writeAsBytes(data!.buffer.asUint8List());
  for (final image in images) {
    image.dispose();
  }
  overview.dispose();
  picture.dispose();
}

/// In-memory NAS boundary used only by the rendering test. All device state
/// still passes through the production controller, and commands cannot leave.
class _VisualHaRepository extends NasSmartHomeRepository {
  _VisualHaRepository() : super(null);

  static const devices = [
    ('light.living', '客厅主灯', '客厅', 'light'),
    ('climate.living', '空调', '客厅', 'climate'),
    ('switch.washer', '洗衣机', '生活阳台', 'switch'),
    ('light.bedroom', '卧室灯', '卧室', 'light'),
  ];

  @override
  bool get isConfigured => true;

  @override
  Future<bool> restoreCredentials() async => true;

  @override
  Future<List<NasHaIntegration>> listIntegrations() async => [
    NasHaIntegration(
      id: 'fixture',
      name: '渲染测试',
      baseUrl: Uri.parse('http://fixture.invalid'),
      status: NasHaIntegrationStatus.healthy,
      createdAt: DateTime.now().toUtc(),
    ),
  ];

  @override
  Future<List<NasHaEntity>> listEntities({
    String? integrationId,
    bool controllableOnly = false,
  }) async => [
    for (final (id, name, room, domain) in devices)
      NasHaEntity(
        id: id,
        integrationId: 'fixture',
        entityId: id,
        domain: domain,
        name: name,
        areaName: room,
        isVisible: true,
        isControllable: true,
        capabilities: const ['on_off'],
        currentState: 'on',
      ),
  ];

  @override
  Future<List<NasHaEntityPermission>> listPermissions() async => [
    for (final (id, _, _, _) in devices)
      NasHaEntityPermission(
        integrationId: 'fixture',
        entityId: id,
        role: 'member',
        canView: true,
        canControl: true,
        allowedCommands: const ['turn_on', 'turn_off'],
      ),
  ];

  @override
  Future<NasHaEntityState> fetchEntityState({
    required String integrationId,
    required String entityId,
  }) async => NasHaEntityState(
    entityId: entityId,
    state:
        entityId.startsWith('climate.')
            ? 'heat'
            : entityId.startsWith('switch.')
            ? 'off'
            : 'on',
    fetchedAt: DateTime.now().toUtc(),
    attributes:
        entityId.startsWith('climate.')
            ? const {'temperature': 24, 'hvac_mode': 'heat'}
            : const {'brightness_pct': 60},
  );

  @override
  Future<List<NasHaConsumableGroup>> listConsumableGroups() async => [];
  @override
  Future<List<NasHaConsumableRecipe>> listConsumableRecipes() async => [];
  @override
  Future<List<NasHaLinkageRule>> listLinkageRules() async => [];
  @override
  Future<List<NasHaLinkageSuggestion>> listLinkageSuggestions({
    NasHaLinkageSuggestionStatus? status,
  }) async => [];

  @override
  Future<NasHaCommandResult> sendCommand({
    required String integrationId,
    required String entityId,
    required NasHaCommand command,
    required String requestId,
    NasHaCommandParameters? parameters,
  }) => throw StateError('Rendering fixture does not execute commands');
}
