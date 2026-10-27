import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/presentation/widgets/momo_glass_components.dart';

void main() {
  testWidgets('顶部玻璃栏不绘制额外底部分隔线', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: buildMomoTheme(MomoPalette.defaultPalette, Brightness.light),
        home: const Scaffold(
          appBar: MomoGlassAppBar(title: Text('Page')),
        ),
      ),
    );
    final decorated = tester.widget<DecoratedBox>(
      find.descendant(
        of: find.byType(AppBar),
        matching: find.byType(DecoratedBox),
      ),
    );
    final decoration = decorated.decoration as BoxDecoration;
    expect(decoration.border, isNull);
  });

  for (final brightness in Brightness.values) {
    for (final sliver in [false, true]) {
      testWidgets(
        '${brightness.name} ${sliver ? 'sliver' : 'glass'} 顶部与页面底色连续，滚动不变色',
        (tester) async {
          tester.view.devicePixelRatio = 1;
          tester.view.physicalSize = const Size(390, 844);
          tester.view.padding = const FakeViewPadding(top: 24);
          tester.view.viewPadding = const FakeViewPadding(top: 24);
          addTearDown(tester.view.reset);

          for (final palette in MomoPalette.allPalettes) {
            for (final highContrast in [false, true]) {
              final theme = buildMomoTheme(palette, brightness);
              final boundaryKey = GlobalKey();
              final rows = List.generate(
                30,
                (index) => SizedBox(
                  height: 96,
                  child: Center(child: Text('Item $index')),
                ),
              );
              await tester.pumpWidget(
                MaterialApp(
                  theme: theme,
                  builder: (context, child) => MediaQuery(
                    data: MediaQuery.of(context).copyWith(
                      highContrast: highContrast,
                    ),
                    child: child!,
                  ),
                  home: RepaintBoundary(
                    key: boundaryKey,
                    child: Scaffold(
                      appBar: sliver
                          ? null
                          : const MomoGlassAppBar(title: Text('Page')),
                      body: sliver
                          ? CustomScrollView(
                              slivers: [
                                const SliverAppBar(
                                  pinned: true,
                                  title: Text('Page'),
                                ),
                                SliverList.list(children: rows),
                              ],
                            )
                          : ListView(children: rows),
                    ),
                  ),
                ),
              );
              await tester.pumpAndSettle();

              Future<void> checkTop() async {
                final boundary = tester.renderObject<RenderRepaintBoundary>(
                  find.byKey(boundaryKey),
                );
                final pixels = await tester.runAsync(() async {
                  final image = await boundary.toImage(pixelRatio: 1);
                  try {
                    return await image.toByteData(
                      format: ui.ImageByteFormat.rawRgba,
                    );
                  } finally {
                    image.dispose();
                  }
                });
                expect(pixels, isNotNull);
                final expected = theme.scaffoldBackgroundColor.toARGB32();
                // Sample clear space in the status bar, toolbar and body.
                // Check composited pixels, including Material tint and glass.
                for (final y in [12, 48, 140]) {
                  final offset = (y * 390 + 380) * 4;
                  final channels = [
                    (expected >> 16) & 0xff,
                    (expected >> 8) & 0xff,
                    expected & 0xff,
                    255,
                  ];
                  for (var channel = 0; channel < 4; channel++) {
                    expect(
                      pixels!.getUint8(offset + channel),
                      closeTo(channels[channel], 1),
                      reason:
                          '${palette.storedValue}, highContrast=$highContrast, '
                          'y=$y, channel=$channel',
                    );
                  }
                }
                final overlays = tester.widgetList<
                    AnnotatedRegion<SystemUiOverlayStyle>>(
                  find.byType(AnnotatedRegion<SystemUiOverlayStyle>),
                );
                expect(
                  overlays.any((region) =>
                      region.value.statusBarColor == Colors.transparent &&
                      region.value.statusBarIconBrightness ==
                          (brightness == Brightness.dark
                              ? Brightness.light
                              : Brightness.dark)),
                  isTrue,
                );
                expect(tester.takeException(), isNull);
              }

              await checkTop();
              await tester.drag(find.byType(Scrollable), const Offset(0, -300));
              await tester.pumpAndSettle();
              await checkTop();
            }
          }
        },
      );
    }
  }
}
