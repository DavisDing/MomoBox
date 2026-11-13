import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/app/momo_theme.dart';
import 'package:momo_box/domain/models/home_environment.dart';
import 'package:momo_box/presentation/controllers/providers.dart';
import 'package:momo_box/presentation/widgets/home_environment_card.dart';

void main() {
  for(final width in [280.0,320.0,390.0]) {
    for(final scale in [1.0,1.3,3.4]) {
      testWidgets('environment $width / $scale remains readable and unconfigured values stay empty',(tester) async {
        tester.view.devicePixelRatio=1;
        tester.view.physicalSize=Size(width,844);
        addTearDown(tester.view.reset);
        final now=DateTime.utc(2026,11,9,8);
        await tester.pumpWidget(ProviderScope(overrides:[
          homeEnvironmentProvider.overrideWith((ref) => AsyncData(HomeEnvironment(
            outdoorTemperature:EnvironmentReading(18,'Open-Meteo · 示例城市',now),
            apparentTemperature:EnvironmentReading(17,'Open-Meteo · 示例城市',now)))),
          environmentClockProvider.overrideWith((ref)=>Stream.value(now)),
        ],child:MaterialApp(theme:buildMomoTheme(MomoPalette.defaultPalette,Brightness.light),
          home:MediaQuery(data:MediaQueryData(textScaler:TextScaler.linear(scale)),
            child:const Scaffold(body:SingleChildScrollView(child:Padding(padding:EdgeInsets.all(16),child:HomeEnvironmentCard())))))));
        await tester.pumpAndSettle();
        expect(find.text('未接入'),findsOneWidget);
        expect(find.text('湿度 —'),findsOneWidget);
        expect(find.text('18°'),findsOneWidget);
        expect(find.text('体感 17°'),findsOneWidget);
        expect(find.byTooltip('环境数据来源'),findsOneWidget);
        expect(tester.takeException(),isNull);
      });
    }
  }
  testWidgets('separate weather sources and stale status remain visible',(tester) async {
    final now=DateTime.utc(2026,11,9,8);
    await tester.pumpWidget(ProviderScope(overrides:[
      homeEnvironmentProvider.overrideWith((ref) => AsyncData(HomeEnvironment(
        outdoorTemperature:EnvironmentReading(18,'室外传感器',now),
        apparentTemperature:EnvironmentReading(17,'Open-Meteo · 城市',now,stale:true)))),
      environmentClockProvider.overrideWith((ref)=>Stream.value(now)),
    ],child:MaterialApp(home:Scaffold(body:HomeEnvironmentCard()))));
    await tester.pumpAndSettle();
    expect(find.text('HA · 刚刚'),findsOneWidget);
    expect(find.text('体感：公共天气 · 上次数据'),findsOneWidget);
    expect(tester.takeException(),isNull);
  });
}
