import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../../domain/models/home_environment.dart';
import '../controllers/providers.dart';
import '../screens/environment_settings_screen.dart';

class HomeEnvironmentCard extends ConsumerWidget {
  const HomeEnvironmentCard({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final async = ref.watch(homeEnvironmentProvider);
    // The composer supplies current authorized HA readings and same-city
    // weather while refreshing; it never retains the previous HA context.
    final data = async.valueOrNull ?? const HomeEnvironment();
    final theme = Theme.of(context);
    final now = ref.watch(environmentClockProvider).valueOrNull ?? DateTime.now();
    String number(EnvironmentReading? reading, String unit) => reading == null ? '—' :
      '${reading.value.toStringAsFixed(reading.value % 1 == 0 ? 0 : 1)}$unit';
    String age(EnvironmentReading? reading) {
      if (reading == null) return '未接入';
      final minutes = now.toUtc().difference(reading.observedAt.toUtc()).inMinutes;
      return reading.isStale(now) ? '上次数据' : minutes < 1 ? '刚刚' : '$minutes 分钟前';
    }
    Widget place({required String label, required IconData icon,
      required EnvironmentReading? main, required EnvironmentReading? secondary,
      required String secondaryLabel, required String secondaryUnit}) {
      final source = main?.source.startsWith('Open-Meteo') == true ? '公共天气' : 'HA';
      return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(children: [Icon(icon,size:14,color:theme.colorScheme.primary), const SizedBox(width:4),
          Flexible(child:Text(label,style:theme.textTheme.bodySmall))]),
        const SizedBox(height:5),
        Wrap(crossAxisAlignment:WrapCrossAlignment.center,spacing:6,runSpacing:2,children:[
          Text(number(main,'°'),style:theme.textTheme.headlineLarge),
          Text('$secondaryLabel ${number(secondary,secondaryUnit)}',style:theme.textTheme.bodySmall),
        ]),
        const SizedBox(height:5),
        Text(main == null ? '未接入' : '$source · ${age(main)}',style:theme.textTheme.bodySmall?.copyWith(
          color: main?.isStale(now) == true ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant)),
        if (secondary != null && (secondary.source != main?.source || secondary.observedAt != main?.observedAt))
          Text('$secondaryLabel：${secondary.source.startsWith('Open-Meteo') ? '公共天气' : 'HA'} · ${age(secondary)}',
            style:theme.textTheme.bodySmall?.copyWith(color:secondary.isStale(now)
              ? theme.colorScheme.error : theme.colorScheme.onSurfaceVariant)),
      ]);
    }
    return Container(
      key: const ValueKey('home-environment-summary'),
      padding: const EdgeInsets.fromLTRB(15,4,15,14),
      decoration:BoxDecoration(color:theme.colorScheme.primaryContainer,
        borderRadius:BorderRadius.circular(20)),
      child:Column(crossAxisAlignment:CrossAxisAlignment.start,children:[
        Row(children:[Expanded(child:Text('环境速览',style:theme.textTheme.bodySmall)),
          if (async.isLoading) const SizedBox.square(dimension:14,child:CircularProgressIndicator(strokeWidth:2)),
          if (MediaQuery.textScalerOf(context).scale(14) > 21)
            IconButton(tooltip:'环境数据来源',icon:const Icon(Icons.tune_rounded),
              onPressed:() => Navigator.of(context,rootNavigator:true).push(MaterialPageRoute<void>(
                builder:(_) => const EnvironmentSettingsScreen())))
          else Tooltip(message:'环境数据来源',child:TextButton(
            style:TextButton.styleFrom(minimumSize:const Size(44,44),padding:const EdgeInsets.only(left:8)),
            onPressed:() => Navigator.of(context,rootNavigator:true).push(MaterialPageRoute<void>(
              builder:(_) => const EnvironmentSettingsScreen())),
            child:Text('数据来源 ›',style:theme.textTheme.bodySmall))),
        ]),
        LayoutBuilder(builder:(context,constraints) {
          final stack = MediaQuery.textScalerOf(context).scale(14) > 23 || constraints.maxWidth < 250;
          final indoor = place(label:'室内',icon:Icons.thermostat_outlined,
            main:data.indoorTemperature,secondary:data.indoorHumidity,secondaryLabel:'湿度',secondaryUnit:'%');
          final outdoor = place(label:'室外',icon:Icons.cloud_outlined,
            main:data.outdoorTemperature,secondary:data.apparentTemperature,secondaryLabel:'体感',secondaryUnit:'°');
          return stack ? Column(crossAxisAlignment:CrossAxisAlignment.stretch,children:[indoor,const Divider(height:20),outdoor]) :
            Row(crossAxisAlignment:CrossAxisAlignment.start,children:[Expanded(child:indoor),
              const SizedBox(width:12),Expanded(child:Container(
                padding:const EdgeInsets.only(left:14),decoration:BoxDecoration(border:Border(left:BorderSide(
                  color:theme.colorScheme.primary.withValues(alpha:.15)))),child:outdoor))]);
        }),
        if (data.message != null || async.hasError) ...[const SizedBox(height:8),
          Text(data.message ?? '环境数据暂不可用，可下拉重试',style:theme.textTheme.bodySmall)],
      ]),
    );
  }
}
