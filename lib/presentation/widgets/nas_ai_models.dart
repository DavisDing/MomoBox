import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/providers.dart';
import '../../application/backend_processing_error.dart';
import '../../data/nas/nas_api_error.dart';

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
            onPressed:
                models.isLoading
                    ? null
                    : () => ref.invalidate(nasAiModelsProvider),
            icon: const Icon(Icons.refresh),
          ),
        ),
        if (models.isLoading)
          const LinearProgressIndicator()
        else if (models.hasError)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(_modelFailureMessage(models.error!)),
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

String _modelFailureMessage(Object error) {
  if (error is BackendProcessingSetupException) return error.message;
  if (error is! NasApiError) {
    return '模型列表暂不可用，NAS 返回的数据无法识别，请更新 App 与 NAS 后端后刷新。';
  }
  final reason = switch (error.code) {
    'AI_NOT_CONFIGURED' || 'PROCESSOR_UNAVAILABLE' =>
      'NAS 尚未启用 AI 网关，请在 Compose 填写 AI_ENDPOINT 和 AI_API_KEY 后重建后端容器。',
    'AI_MODELS_AUTH_FAILED' =>
      'AI 网关拒绝了模型目录请求，请检查 NAS 的 AI_API_KEY 是否有效、是否有查看模型的权限。',
    'AI_MODELS_NOT_FOUND' =>
      'AI 网关没有提供模型目录，请检查 AI_ENDPOINT 的接口路径；无目录接口的服务可在 NAS 配置 AI_MODEL。',
    'AI_MODELS_REDIRECT' => 'AI 网关地址发生重定向，请在 NAS 的 AI_ENDPOINT 填写最终 API 地址。',
    'AI_MODELS_TIMEOUT' => 'NAS 获取 AI 模型目录超时，请检查 NAS 到 AI 网关的网络后刷新。',
    'AI_MODELS_UNREACHABLE' =>
      'NAS 无法连接 AI 网关，请检查容器网络、DNS、证书和 AI_ENDPOINT；localhost 指向后端容器自身。',
    'AI_MODELS_EMPTY' => 'AI 网关返回的可用模型为空，请检查该 Key 的模型授权及网关模型配置。',
    'AI_MODELS_INVALID_RESPONSE' =>
      'AI 网关未返回兼容的模型目录，请检查 AI_ENDPOINT 是否指向 API，而非管理网页。',
    'AI_MODELS_UPSTREAM_FAILED' => 'AI 网关的模型目录请求失败，请检查网关状态后刷新。',
    _ => switch (error.kind) {
      NasApiErrorKind.notFound => 'NAS 后端缺少模型目录接口，请更新后端镜像并重建容器。',
      NasApiErrorKind.unauthorized => 'NAS 登录已失效，请重新登录后刷新模型列表。',
      NasApiErrorKind.forbidden => 'NAS 家庭或设备权限尚未就绪，请在 NAS 设置中重试连接。',
      NasApiErrorKind.timeout => '连接 NAS 超时，请检查 NAS 地址和网络后刷新。',
      NasApiErrorKind.network ||
      NasApiErrorKind.invalidBaseUrl => '无法连接 NAS，请检查 NAS 地址和网络后刷新。',
      _ => '模型列表暂不可用，请检查 NAS 后端状态后刷新。',
    },
  };
  final requestId = error.requestId;
  // Only an actual UUID is shown; never echo arbitrary response text or URLs.
  if (requestId != null &&
      RegExp(
        r'^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$',
      ).hasMatch(requestId)) {
    return '$reason\n诊断编号：$requestId';
  }
  return reason;
}
