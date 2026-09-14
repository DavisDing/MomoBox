import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:momo_box/application/ai_fallback_executor.dart';

void main() {
  group('AiFallbackExecutor Tests', () {
    const primaryConfig = AiEndpointConfig(
      level: AiApiLevel.primary,
      endpoint: 'https://primary.example.com/v1',
      apiKey: 'key_primary',
      model: 'primary-model',
      timeout: Duration(milliseconds: 100),
    );

    const secondaryConfig = AiEndpointConfig(
      level: AiApiLevel.secondary,
      endpoint: 'https://secondary.example.com/v1',
      apiKey: 'key_secondary',
      model: 'secondary-model',
      timeout: Duration(milliseconds: 100),
    );

    const fallbackConfig = AiEndpointConfig(
      level: AiApiLevel.fallback,
      endpoint: 'https://fallback.example.com/v1',
      apiKey: 'key_fallback',
      model: 'fallback-model',
      timeout: Duration(milliseconds: 100),
    );

    test('优先调用主 API 且成功时，不调用副 API 与兜底模型', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'primary.example.com') {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Primary success response'}
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Should not be reached', 500);
      });

      final executor = AiFallbackExecutor(client: mockClient);
      final response = await executor.execute(
        configs: [primaryConfig, secondaryConfig, fallbackConfig],
        systemPrompt: 'System',
        userPrompt: 'User',
      );

      expect(response.usedLevel, AiApiLevel.primary);
      expect(response.content, 'Primary success response');
      expect(response.traceLogs.length, 1);
      expect(response.traceLogs.first.isSuccess, true);
    });

    test('主 API 返回 500 失败时，自动降级调用副 API', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'primary.example.com') {
          return http.Response('Internal Server Error', 500);
        }
        if (request.url.host == 'secondary.example.com') {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Secondary success response'}
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Should not be reached', 500);
      });

      final executor = AiFallbackExecutor(client: mockClient);
      final response = await executor.execute(
        configs: [primaryConfig, secondaryConfig, fallbackConfig],
        systemPrompt: 'System',
        userPrompt: 'User',
      );

      expect(response.usedLevel, AiApiLevel.secondary);
      expect(response.content, 'Secondary success response');
      expect(response.traceLogs.length, 2);
      expect(response.traceLogs[0].isSuccess, false);
      expect(response.traceLogs[0].failureReason, contains('500'));
      expect(response.traceLogs[1].isSuccess, true);
    });

    test('主、副 API 均超时时，自动降级调用兜底模型', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'primary.example.com' || request.url.host == 'secondary.example.com') {
          // 模拟耗时大于超时阈值
          await Future.delayed(const Duration(milliseconds: 200));
          return http.Response('Timeout', 200);
        }
        if (request.url.host == 'fallback.example.com') {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Fallback model response'}
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Not found', 404);
      });

      final executor = AiFallbackExecutor(client: mockClient);
      final response = await executor.execute(
        configs: [primaryConfig, secondaryConfig, fallbackConfig],
        systemPrompt: 'System',
        userPrompt: 'User',
      );

      expect(response.usedLevel, AiApiLevel.fallback);
      expect(response.content, 'Fallback model response');
      expect(response.traceLogs.length, 3);
      expect(response.traceLogs[0].isSuccess, false);
      expect(response.traceLogs[1].isSuccess, false);
      expect(response.traceLogs[2].isSuccess, true);
    });

    test('返回内容为空或格式解析失败时触发降级', () async {
      final mockClient = MockClient((request) async {
        if (request.url.host == 'primary.example.com') {
          // 返回空 content
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': '   '}
                }
              ]
            }),
            200,
          );
        }
        if (request.url.host == 'secondary.example.com') {
          return http.Response(
            jsonEncode({
              'choices': [
                {
                  'message': {'content': 'Valid text from secondary'}
                }
              ]
            }),
            200,
          );
        }
        return http.Response('Error', 500);
      });

      final executor = AiFallbackExecutor(client: mockClient);
      final response = await executor.execute(
        configs: [primaryConfig, secondaryConfig, fallbackConfig],
        systemPrompt: 'System',
        userPrompt: 'User',
      );

      expect(response.usedLevel, AiApiLevel.secondary);
      expect(response.content, 'Valid text from secondary');
      expect(response.traceLogs[0].isSuccess, false);
      expect(response.traceLogs[0].failureReason, contains('为空'));
    });

    test('全链路三级 API 均失败时，抛出标准异常并记录完整追踪', () async {
      final mockClient = MockClient((request) async {
        return http.Response('Gateway Timeout', 504);
      });

      final executor = AiFallbackExecutor(client: mockClient);

      expect(
        () async => executor.execute(
          configs: [primaryConfig, secondaryConfig, fallbackConfig],
          systemPrompt: 'System',
          userPrompt: 'User',
        ),
        throwsA(isA<AiFallbackException>()),
      );
    });
  });
}
