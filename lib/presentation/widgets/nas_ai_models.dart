import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/providers.dart';

class NasAiModels extends ConsumerWidget {
  const NasAiModels({super.key});
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final models = ref.watch(nasAiModelsProvider);
    final selected = ref.watch(selectedAiModelProvider).valueOrNull;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ListTile(
          title: const Text('NAS AI 模型'),
          subtitle: const Text('地址和密钥由 NAS Compose 管理，手机仅选择模型。'),
          trailing: IconButton(
            tooltip: '刷新模型列表',
            onPressed: () => ref.invalidate(nasAiModelsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (models.isLoading)
          const LinearProgressIndicator()
        else if (models.hasError)
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text('模型列表暂不可用，请检查 NAS 连接与 AI 部署配置后刷新。'),
          )
        else ...[
          if (selected?.isNotEmpty == true &&
              !models.value!.any((model) => model.id == selected))
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('原选模型已不可用，请重新选择。'),
            ),
          RadioGroup<String>(
            groupValue: selected ?? '',
            onChanged: (model) async {
              final identity = ref.read(syncWorkspaceIdentityProvider);
              if (identity == null || model == null) return;
              await ref
                  .read(settingsRepositoryProvider)
                  .setValue(nasAiSelectionKey(identity), model);
            },
            child: Column(
              children: [
                const RadioListTile<String>(value: '', title: Text('NAS 默认模型')),
                for (final model in models.value ?? [])
                  RadioListTile<String>(
                    value: model.id,
                    title: Text(model.id),
                    subtitle: model.isDefault ? const Text('NAS 默认') : null,
                  ),
              ],
            ),
          ),
        ],
      ],
    );
  }

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder:
        (_) => const FractionallySizedBox(
          heightFactor: .7,
          child: SingleChildScrollView(child: NasAiModels()),
        ),
  );
}
