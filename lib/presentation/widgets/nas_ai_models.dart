import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/providers.dart';
import '../../application/backend_processing_error.dart';
import '../../data/nas/nas_api_error.dart';

class NasAiModels extends ConsumerStatefulWidget {
  const NasAiModels({super.key});

  @override
  ConsumerState<NasAiModels> createState() => _NasAiModelsState();

  static Future<void> show(BuildContext context) => showModalBottomSheet<void>(
    context: context,
    useSafeArea: true,
    isScrollControlled: true,
    builder:
        (context) => Padding(
          padding: EdgeInsets.only(
            bottom: MediaQuery.viewInsetsOf(context).bottom,
          ),
          child: LayoutBuilder(
            builder:
                (context, constraints) => ConstrainedBox(
                  constraints: BoxConstraints(
                    maxHeight: constraints.maxHeight * .7,
                  ),
                  child: const SafeArea(top: false, child: NasAiModels()),
                ),
          ),
        ),
  );
}

class _NasAiModelsState extends ConsumerState<NasAiModels> {
  static const _shortCatalogLimit = 6;

  final _searchController = TextEditingController();
  String _query = '';
  bool _showAll = false;
  bool _saving = false;
  String? _saveError;

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  Future<void> _selectModel(String? model) async {
    if (model == null || _saving) return;
    final identity = ref.read(syncWorkspaceIdentityProvider);
    if (identity == null) {
      setState(() => _saveError = '家庭工作区尚未就绪，暂时无法切换模型。');
      return;
    }
    setState(() {
      _saving = true;
      _saveError = null;
    });
    try {
      await ref
          .read(settingsRepositoryProvider)
          .setValue(nasAiSelectionKey(identity), model);
    } catch (_) {
      if (mounted) setState(() => _saveError = '模型选择未保存，请重试。');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final models = ref.watch(nasAiModelsProvider);
    final selected = ref.watch(selectedAiModelProvider).valueOrNull ?? '';
    final catalog = models.valueOrNull ?? const [];
    final results =
        _query.isEmpty
            ? catalog
            : catalog
                .where((model) => model.id.toLowerCase().contains(_query))
                .toList();
    final canToggleCatalog =
        _query.isEmpty && catalog.length > _shortCatalogLimit;

    return RadioGroup<String>(
      groupValue: selected,
      onChanged: _selectModel,
      child: CustomScrollView(
        shrinkWrap: true,
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        slivers: [
          SliverList.list(
            children: [
              ListTile(
                title: const Text('选择 AI 模型'),
                subtitle:
                    selected.isEmpty
                        ? null
                        : Text(
                          '当前模型 · $selected',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
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
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 8,
                  ),
                  child: TextField(
                    controller: _searchController,
                    textInputAction: TextInputAction.search,
                    onTapOutside:
                        (_) => FocusManager.instance.primaryFocus?.unfocus(),
                    decoration: InputDecoration(
                      labelText: '搜索模型',
                      prefixIcon: const Icon(Icons.search_rounded),
                      suffixIcon:
                          _searchController.text.isEmpty
                              ? null
                              : IconButton(
                                tooltip: '清除模型搜索',
                                icon: const Icon(Icons.close_rounded),
                                onPressed: () {
                                  _searchController.clear();
                                  setState(() => _query = '');
                                },
                              ),
                    ),
                    onChanged:
                        (value) =>
                            setState(() => _query = value.trim().toLowerCase()),
                  ),
                ),
                if (selected.isNotEmpty &&
                    !catalog.any((model) => model.id == selected))
                  const Padding(
                    padding: EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Text('原选模型已不可用，请重新选择。'),
                  ),
                if (_saveError != null)
                  Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 8,
                    ),
                    child: Text(
                      _saveError!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                RadioListTile<String>(
                  value: '',
                  title: const Text('NAS 默认模型'),
                  enabled: !_saving,
                ),
                if (_query.isNotEmpty && results.isEmpty)
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('没有匹配的模型'),
                  ),
                if (canToggleCatalog)
                  Semantics(
                    expanded: _showAll,
                    child: ListTile(
                      title: Text('全部模型（${catalog.length}）'),
                      trailing: Icon(
                        _showAll ? Icons.expand_less : Icons.expand_more,
                      ),
                      onTap: () => setState(() => _showAll = !_showAll),
                    ),
                  ),
              ],
            ],
          ),
          if (!models.isLoading &&
              !models.hasError &&
              (!canToggleCatalog || _showAll))
            SliverList.builder(
              itemCount: results.length,
              itemBuilder: (context, index) {
                final model = results[index];
                return RadioListTile<String>(
                  key: ValueKey(model.id),
                  value: model.id,
                  title: Text(model.id),
                  subtitle: model.isDefault ? const Text('NAS 默认') : null,
                  enabled: !_saving,
                );
              },
            ),
        ],
      ),
    );
  }
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
