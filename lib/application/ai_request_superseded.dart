/// 仅表示当前服务调用已经被后续请求替代，不代表 AI 服务本身失败。
class AiRequestSupersededException implements Exception {
  const AiRequestSupersededException(this.requestToken);

  final String requestToken;

  @override
  String toString() => 'AI 请求已被更新的请求替代。';
}
