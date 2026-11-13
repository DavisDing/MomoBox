class NasAiModel {
  const NasAiModel(this.id, {this.isDefault = false});
  final String id;
  final bool isDefault;
  static List<NasAiModel> parse(Object? raw) {
    if (raw is! List || raw.length > 500) {
      throw const FormatException('NAS 模型列表无效');
    }
    final seen = <String>{};
    return raw
        .map((item) {
          if (item is! Map ||
              item['id'] is! String ||
              (item['id'] as String).trim().isEmpty) {
            throw const FormatException('NAS 模型名称无效');
          }
          return NasAiModel(
            item['id'] as String,
            isDefault: item['default'] == true,
          );
        })
        .where((model) => seen.add(model.id))
        .toList(growable: false);
  }
}
