import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';
import 'package:momo_box/application/backend_processing_error.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/data/nas/nas_sync_api.dart';

void main() {
  test('NAS missing model configuration explains setup without sending phone credentials', () async {
    var phoneCalls = 0;
    final nasCalls = <http.Request>[];
    final api = NasSyncApi('https://nas.example', accessToken: 'nas-session',
      client: MockClient((request) async {
        nasCalls.add(request);
        return http.Response('{"backend_ai":false}', 200);
      }));
    addTearDown(api.close);
    final executor = AiFallbackExecutor(backendResolver: () async => api,
      client: MockClient((_) async { phoneCalls++; return http.Response('{}', 200); }));
    addTearDown(executor.close);
    try {
      await executor.execute(configs: const [AiEndpointConfig(
        level: AiApiLevel.primary, endpoint: 'https://phone.example/v1',
        apiKey: 'private-phone-key', model: 'phone-model')],
        systemPrompt: 'connection test', userPrompt: 'OK');
      fail('missing NAS configuration was accepted');
    } on BackendProcessingSetupException catch (error) {
      expect(aiFailureMessage(error), contains('AI_ENDPOINT'));
      expect(aiFailureMessage(error), contains('手机上的模型配置仅用于单机模式'));
    }
    expect(phoneCalls, 0);
    expect(nasCalls.single.url.path, '/api/v1/capabilities');
    expect(nasCalls.single.body, isEmpty);
  });

  for (final code in ['AI_RESULT_UNKNOWN', 'PROCESSING_BUSY', 'PROCESSOR_UNAVAILABLE', 'PROCESSING_FAILED']) {
    test('NAS $code gets safe actionable feedback and no automatic retry', () async {
      var calls = 0;
      final api = NasSyncApi('https://nas.example', accessToken: 'session',
        client: MockClient((request) async {
          calls++;
          if (request.url.path.endsWith('/capabilities')) {
            return http.Response('{"backend_ai":true}', 200);
          }
          return http.Response(jsonEncode({'error': {'code': code,
            'message': 'upstream api_key=private-secret https://private.example'}}),
            code == 'PROCESSOR_UNAVAILABLE' ? 503 : 409);
        }));
      addTearDown(api.close);
      final executor = AiFallbackExecutor(backendResolver: () async => api);
      addTearDown(executor.close);
      try {
        await executor.execute(configs: [], systemPrompt: 'test', userPrompt: 'OK');
        fail('NAS error was accepted');
      } on NasApiError catch (error) {
        final message = aiFailureMessage(error);
        expect(message, contains('NAS'));
        expect(message, isNot(contains('private-secret')));
        expect(message, isNot(contains('private.example')));
        if (code == 'AI_RESULT_UNKNOWN') expect(message, contains('核实'));
      }
      expect(calls, 2);
    });
  }

  for (final entry in {
    NasApiErrorKind.unauthorized: '重新登录',
    NasApiErrorKind.forbidden: '注册当前设备',
    NasApiErrorKind.notFound: '更新 NAS 后端',
    NasApiErrorKind.network: '网络',
    NasApiErrorKind.timeout: '核实处理结果',
  }.entries) {
    test('NAS ${entry.key} does not report a phone API key failure', () {
      final message = aiFailureMessage(NasApiError(kind: entry.key, message: 'api_key=secret'));
      expect(message, contains(entry.value));
      expect(message, isNot(contains('secret')));
    });
  }
}
