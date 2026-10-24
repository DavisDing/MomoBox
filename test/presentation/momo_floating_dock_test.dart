import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/app/momo_typography.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/app_scaffold.dart';
import 'package:momo_box/presentation/widgets/momo_floating_dock.dart';

const _palettes = [
  MomoPalette.defaultPalette,
  MomoPalette.momoPalette,
  MomoPalette.doraemonPalette,
  MomoPalette.forestPalette,
  MomoPalette.sakuraPalette,
];

List<NavigationDestination> _destinations(MomoPalette palette) => [
  const NavigationDestination(icon: Icon(Icons.home), label: '首页'),
  NavigationDestination(
    icon: Icon(palette.inventoryIcon),
    label: palette.inventoryLabel,
  ),
  NavigationDestination(
    icon: Padding(
      padding: const EdgeInsets.all(5),
      child: Text(
        palette.mascot,
        style: const TextStyle(fontSize: 22, height: 1),
      ),
    ),
    label: palette.mascotName,
  ),
  const NavigationDestination(icon: Icon(Icons.hub), label: '家居'),
  const NavigationDestination(icon: Icon(Icons.person), label: '我的'),
];

void main() {
  for (final palette in _palettes) {
    for (final brightness in Brightness.values) {
      testWidgets(
        '${palette.skin.name} ${brightness.name}: endpoints, labels and safe insets',
        (tester) async {
          addTearDown(tester.view.reset);
          tester.view.devicePixelRatio = 1;
          final destinations = _destinations(palette);
          for (final width in [280.0, 320.0, 800.0]) {
            tester.view.physicalSize = Size(width, width == 800 ? 360 : 640);
            for (final scale in [1.0, 1.3, 3.4]) {
              for (final selected in [0, 4]) {
                final media = MediaQueryData(
                  size: tester.view.physicalSize,
                  padding: const EdgeInsets.fromLTRB(12, 44, 8, 34),
                  viewPadding: const EdgeInsets.fromLTRB(12, 44, 8, 34),
                  textScaler: MomoTextScaler(
                    TextScaler.linear(scale / 1.7),
                    1.7,
                  ),
                );
                await tester.pumpWidget(
                  MaterialApp(
                    theme: buildMomoTheme(palette, brightness),
                    home: MediaQuery(
                      data: media,
                      child: Scaffold(
                        extendBody: true,
                        bottomNavigationBar: MomoFloatingCapsuleDock(
                          selectedIndex: selected,
                          onDestinationSelected: (_) {},
                          destinations: destinations,
                          palette: palette,
                        ),
                      ),
                    ),
                  ),
                );
                await tester.pumpAndSettle();
                expect(
                  tester.takeException(),
                  isNull,
                  reason: '$width, $scale, $selected',
                );

                final dock = find.byType(MomoFloatingCapsuleDock);
                final clip = find.descendant(
                  of: dock,
                  matching: find.byType(ClipRRect),
                );
                final clipRect = tester.getRect(clip);
                expect(clipRect.bottom, closeTo(media.size.height - 34, 0.01));
                expect(
                  tester.getSize(dock).height,
                  closeTo(
                    clipRect.height + 34 + MomoDockLayout.topSpacing,
                    0.01,
                  ),
                );
                final borderRadius = tester
                    .widget<ClipRRect>(clip)
                    .borderRadius
                    .resolve(TextDirection.ltr);
                final capsule =
                    Path()..addRRect(borderRadius.toRRect(clipRect));
                final indicatorFinder = find.descendant(
                  of: dock,
                  matching: find.byType(NavigationIndicator),
                );
                final indicator = tester.widget<NavigationIndicator>(
                  indicatorFinder.at(selected),
                );
                final indicatorRect = tester.getRect(
                  indicatorFinder.at(selected),
                );
                final paintedPath = indicator.shape!
                    .getOuterPath(Offset.zero & indicatorRect.size)
                    .shift(indicatorRect.topLeft);
                final bounds = paintedPath.getBounds();
                Offset? outsidePoint;
                // Test the painted path, not just clipping: clipping an oversized
                // indicator can hide the defect while still chopping its shape.
                for (var x = bounds.left + 0.5; x < bounds.right; x += 1) {
                  for (var y = bounds.top + 0.5; y < bounds.bottom; y += 1) {
                    final point = Offset(x, y);
                    if (paintedPath.contains(point) &&
                        !capsule.contains(point)) {
                      outsidePoint = point;
                    }
                  }
                }
                expect(
                  outsidePoint,
                  isNull,
                  reason: '$width, $scale, $selected',
                );
                final navRect = tester.getRect(find.byType(NavigationBar));
                final cell = navRect.width / destinations.length;
                expect(
                  bounds.left,
                  greaterThanOrEqualTo(navRect.left + cell * selected + 3.9),
                );
                expect(
                  bounds.right,
                  lessThanOrEqualTo(navRect.left + cell * (selected + 1) - 3.9),
                );
                for (var index = 0; index < destinations.length; index++) {
                  final label = find.descendant(
                    of: dock,
                    matching: find.text(destinations[index].label),
                  );
                  final labelRect = tester.getRect(label);
                  expect(
                    labelRect.top,
                    greaterThanOrEqualTo(
                      tester.getRect(indicatorFinder.at(index)).bottom,
                    ),
                  );
                  expect(
                    labelRect.bottom,
                    lessThanOrEqualTo(clipRect.bottom - 6),
                  );
                  expect(
                    labelRect.left,
                    greaterThanOrEqualTo(navRect.left + cell * index),
                  );
                  expect(
                    labelRect.right,
                    lessThanOrEqualTo(navRect.left + cell * (index + 1)),
                  );
                  expect(
                    tester.widget<Text>(label).style!.fontSize,
                    closeTo(12 * scale, 0.001),
                  );
                }
              }
            }
          }
        },
      );
    }
  }

  testWidgets(
    'high contrast uses opaque theme surface and disables backdrop filtering',
    (tester) async {
      for (final palette in _palettes) {
        for (final brightness in Brightness.values) {
          final theme = buildMomoTheme(palette, brightness);
          await tester.pumpWidget(
            MaterialApp(
              theme: theme,
              home: MediaQuery(
                data: const MediaQueryData(highContrast: true),
                child: Scaffold(
                  bottomNavigationBar: MomoFloatingCapsuleDock(
                    selectedIndex: 0,
                    onDestinationSelected: (_) {},
                    destinations: _destinations(palette),
                    palette: palette,
                  ),
                ),
              ),
            ),
          );
          await tester.pumpAndSettle();
          final dock = find.byType(MomoFloatingCapsuleDock);
          final blur = find.descendant(
            of: dock,
            matching: find.byType(BackdropFilter),
          );
          expect(tester.widget<BackdropFilter>(blur).enabled, isFalse);
          final glass =
              find
                  .descendant(of: blur, matching: find.byType(DecoratedBox))
                  .first;
          final decoration =
              tester.widget<DecoratedBox>(glass).decoration as BoxDecoration;
          expect(decoration.color, theme.colorScheme.surface);
          expect(
            decoration.border,
            Border.all(color: theme.colorScheme.onSurface),
          );
          final shadow =
              find
                  .ancestor(
                    of: find.descendant(
                      of: dock,
                      matching: find.byType(ClipRRect),
                    ),
                    matching: find.byType(DecoratedBox),
                  )
                  .first;
          expect(
            (tester.widget<DecoratedBox>(shadow).decoration as BoxDecoration)
                .boxShadow,
            isNotEmpty,
          );
        }
      }
    },
  );

  testWidgets(
    'native destinations retain selection, positional semantics, tap and keyboard activation',
    (tester) async {
      var selected = 0;
      await tester.pumpWidget(
        MaterialApp(
          home: StatefulBuilder(
            builder:
                (context, setState) => Scaffold(
                  bottomNavigationBar: MomoFloatingCapsuleDock(
                    selectedIndex: selected,
                    onDestinationSelected:
                        (value) => setState(() => selected = value),
                    destinations: _destinations(MomoPalette.defaultPalette),
                    palette: MomoPalette.defaultPalette,
                  ),
                ),
          ),
        ),
      );
      final homeNode = tester.getSemantics(find.text('首页'));
      expect(homeNode.flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(homeNode.flagsCollection.isButton, isTrue);
      expect(
        homeNode.getSemanticsData().hasAction(ui.SemanticsAction.tap),
        isTrue,
      );
      expect(homeNode.label, contains('Tab 1 of 5'));
      await tester.tap(find.text('我的'));
      await tester.pumpAndSettle();
      expect(selected, 4);
      expect(
        tester.getSemantics(find.text('我的')).flagsCollection.isSelected,
        ui.Tristate.isTrue,
      );
      expect(
        tester.getSemantics(find.text('首页')).flagsCollection.isSelected,
        ui.Tristate.isFalse,
      );
      Focus.of(tester.element(find.text('首页'))).requestFocus();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(selected, 0);
    },
  );

  for (final slivers in [false, true]) {
    testWidgets(
      '${slivers ? 'slivers' : 'explicit ListView padding'}: shared inset survives nested Scaffold and last item is tappable',
      (tester) async {
        addTearDown(tester.view.reset);
        tester.view.devicePixelRatio = 1;
        tester.view.physicalSize = const Size(320, 640);
        tester.view.padding = const FakeViewPadding(bottom: 34);
        tester.view.viewPadding = const FakeViewPadding(bottom: 34);
        final controller = ScrollController();
        addTearDown(controller.dispose);
        var taps = 0;
        final router = _router(
          _InsetPage(
            slivers: slivers,
            controller: controller,
            onTap: () => taps++,
          ),
        );
        addTearDown(router.dispose);
        await _pumpShell(tester, router);
        for (final scale in [1.0, 1.3, 3.4]) {
          await _pumpShell(tester, router, scale: scale);
          controller.jumpTo(controller.position.maxScrollExtent);
          await tester.pump();
          final inset = MomoDockInsets.bottomOf(
            tester.element(find.byKey(const Key('last-item'))),
          );
          expect(
            inset,
            closeTo(
              tester.getSize(find.byType(MomoFloatingCapsuleDock)).height,
              0.01,
            ),
          );
          final lastItem = find.byKey(const Key('last-item'));
          final dockTop =
              tester.getTopLeft(find.byType(MomoFloatingCapsuleDock)).dy;
          expect(tester.getBottomLeft(lastItem).dy, lessThanOrEqualTo(dockTop));
          final previousTaps = taps;
          await tester.tap(lastItem);
          expect(taps, previousTaps + 1);
          expect(tester.takeException(), isNull);
        }
        await tester.pumpWidget(const SizedBox.shrink());
      },
    );
  }

  testWidgets(
    'inventory default FAB clears the last item and keyboard hides both overlays',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      final controller = ScrollController();
      addTearDown(controller.dispose);
      var taps = 0;
      final router = _router(
        _InsetPage(slivers: true, controller: controller, onTap: () => taps++),
      );
      addTearDown(router.dispose);
      await _pumpShell(tester, router);
      router.go('/inventory');
      await tester.pumpAndSettle();
      for (final scale in [1.0, 1.3, 3.4]) {
        await _pumpShell(tester, router, scale: scale);
        controller.jumpTo(controller.position.maxScrollExtent);
        await tester.pump();
        final lastItem = find.byKey(const Key('last-item'));
        final fab = find.byType(FloatingActionButton);
        final dock = find.byType(MomoFloatingCapsuleDock);
        expect(
          MomoDockInsets.bottomOf(tester.element(lastItem)),
          closeTo(
            tester.getSize(dock).height + tester.getSize(fab).height + 12,
            0.01,
          ),
        );
        expect(
          tester.getBottomLeft(lastItem).dy,
          lessThan(tester.getTopLeft(fab).dy),
        );
        final previousTaps = taps;
        await tester.tap(lastItem);
        expect(taps, previousTaps + 1);
        expect(tester.takeException(), isNull);
      }
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      controller.jumpTo(controller.position.maxScrollExtent);
      await tester.pump();
      expect(find.byType(FloatingActionButton), findsNothing);
      expect(find.byType(NavigationBar), findsNothing);
      expect(
        MomoDockInsets.bottomOf(
          tester.element(find.byKey(const Key('last-item'))),
        ),
        0,
      );
      tester.view.viewInsets = const FakeViewPadding();
      await tester.pumpAndSettle();
      expect(find.byType(FloatingActionButton), findsOneWidget);
      expect(find.byType(NavigationBar), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );

  testWidgets(
    'keyboard and rail clear the inset; shell pushes inherit it, independent routes and sheets do not',
    (tester) async {
      addTearDown(tester.view.reset);
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = const Size(320, 640);
      final router = _router(const _InsetProbe());
      addTearDown(router.dispose);
      await _pumpShell(tester, router);
      double inset(Finder finder) =>
          MomoDockInsets.bottomOf(tester.element(finder));
      final probe = find.byKey(const Key('inset-probe'));
      expect(inset(probe), greaterThan(0));
      final shellContext = tester.element(probe);
      Navigator.of(shellContext).push(
        MaterialPageRoute<void>(
          builder: (_) => const _InsetProbe(label: 'push-probe'),
        ),
      );
      await tester.pumpAndSettle();
      expect(
        inset(find.byKey(const Key('push-probe'))),
        closeTo(
          tester.getSize(find.byType(MomoFloatingCapsuleDock)).height,
          0.01,
        ),
      );
      Navigator.of(tester.element(find.byKey(const Key('push-probe')))).pop();
      await tester.pumpAndSettle();
      showModalBottomSheet<void>(
        context: tester.element(probe),
        builder: (_) => const _InsetProbe(label: 'sheet-probe'),
      );
      await tester.pumpAndSettle();
      expect(inset(find.byKey(const Key('sheet-probe'))), 0);
      Navigator.of(tester.element(find.byKey(const Key('sheet-probe')))).pop();
      await tester.pumpAndSettle();
      tester.view.viewInsets = const FakeViewPadding(bottom: 280);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsNothing);
      expect(inset(probe), 0);
      tester.view.viewInsets = const FakeViewPadding();
      tester.view.physicalSize = const Size(800, 360);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationBar), findsOneWidget);
      expect(inset(probe), greaterThan(0));
      tester.view.physicalSize = const Size(1024, 768);
      await tester.pumpAndSettle();
      expect(find.byType(NavigationRail), findsOneWidget);
      expect(find.byTooltip('AI 助手'), findsOneWidget);
      final aiNode = tester.getSemantics(
        find.byWidgetPredicate(
          (widget) => widget is IconButton && widget.tooltip == 'AI 助手',
        ),
      );
      expect(aiNode.getSemanticsData().tooltip, 'AI 助手');
      expect(aiNode.flagsCollection.isButton, isTrue);
      final railHome = tester.getSemantics(
        find.descendant(
          of: find.byType(NavigationRail),
          matching: find.text('首页'),
        ),
      );
      expect(railHome.label, contains('Tab 1 of 4'));
      expect(railHome.flagsCollection.isSelected, ui.Tristate.isTrue);
      expect(inset(probe), 0);
      router.go('/independent');
      await tester.pumpAndSettle();
      expect(inset(find.byKey(const Key('independent-probe'))), 0);
      expect(find.byType(MomoFloatingCapsuleDock), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
    },
  );
}

GoRouter _router(Widget page) => GoRouter(
  routes: [
    ShellRoute(
      builder: (_, _, child) => AppScaffold(child: child),
      routes: [
        for (final path in ['/', '/inventory', '/settings', '/smart-home'])
          GoRoute(path: path, builder: (_, _) => page),
      ],
    ),
    GoRoute(
      path: '/independent',
      builder: (_, _) => const _InsetProbe(label: 'independent-probe'),
    ),
  ],
);

Future<void> _pumpShell(
  WidgetTester tester,
  GoRouter router, {
  double scale = 1,
}) async {
  await tester.pumpWidget(
    ProviderScope(
      overrides: [
        themeNameProvider.overrideWith((_) => Stream.value('doraemon')),
      ],
      child: MaterialApp.router(
        theme: buildMomoTheme(MomoPalette.doraemonPalette, Brightness.light),
        routerConfig: router,
        builder:
            (context, child) => MediaQuery(
              data: MediaQuery.of(
                context,
              ).copyWith(textScaler: TextScaler.linear(scale)),
              child: child!,
            ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

class _InsetPage extends StatelessWidget {
  const _InsetPage({
    required this.slivers,
    required this.controller,
    required this.onTap,
  });

  final bool slivers;
  final ScrollController controller;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Scaffold(
    body: Builder(
      builder: (context) {
        // Match the production pages: a nested Scaffold plus explicit padding.
        final bottom = MomoDockInsets.bottomOf(context);
        final children = [
          for (var i = 0; i < 25; i++)
            SizedBox(height: 50, child: Text('Item $i')),
          TextButton(
            key: const Key('last-item'),
            onPressed: onTap,
            child: const Text('Last item'),
          ),
        ];
        return slivers
            ? CustomScrollView(
              controller: controller,
              slivers: [
                SliverList.list(children: children),
                SliverToBoxAdapter(child: SizedBox(height: bottom + 12)),
              ],
            )
            : ListView(
              controller: controller,
              padding: EdgeInsets.fromLTRB(16, 12, 16, bottom + 12),
              children: children,
            );
      },
    ),
  );
}

class _InsetProbe extends StatelessWidget {
  const _InsetProbe({this.label = 'inset-probe'});
  final String label;

  @override
  Widget build(BuildContext context) =>
      Scaffold(body: Text(label, key: Key(label)));
}
