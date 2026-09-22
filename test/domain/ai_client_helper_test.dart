import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_client_helper.dart';

void main() {
  test('Responses skips reasoning and joins all message text parts', () {
    expect(AiClientHelper.extractResponseText({
      'output': [
        {'type': 'reasoning', 'summary': [{'text': 'private reasoning'}]},
        {'type': 'message', 'content': [
          {'type': 'output_text', 'text': '第一段'},
          {'type': 'output_text', 'text': '第二段'},
        ]},
      ],
    }), '第一段\n第二段');
  });
  test('chat content arrays and full URLs with query are recognized', () {
    expect(AiClientHelper.extractResponseText({'choices': [
      {'message': {'content': [{'type': 'text', 'text': '你好'}]}}
    ]}), '你好');
    expect(AiClientHelper.resolveProtocol('https://example.com/v1/responses?key=test', 'auto'), 'responses');
  });
  group('AiClientHelper tests', () {
    test('resolveProtocol correctly detects explicit endings', () {
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1/responses', 'chat'),
        'responses',
      );
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1/chat/completions', 'responses'),
        'chat',
      );
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1/chat/completions/', 'auto'),
        'chat',
      );
    });

    test('resolveProtocol preserves manual preference when URL is base only', () {
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1', 'chat'),
        'chat',
      );
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1', 'responses'),
        'responses',
      );
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1', 'auto'),
        'auto',
      );
      expect(
        AiClientHelper.resolveProtocol('https://api.openai.com/v1', ''),
        'auto',
      );
    });

    test('URI generators append paths properly', () {
      final chatUri = AiClientHelper.chatCompletionUri('https://api.openai.com/v1');
      expect(chatUri.toString(), 'https://api.openai.com/v1/chat/completions');

      final alreadyChat = AiClientHelper.chatCompletionUri('https://api.openai.com/v1/chat/completions');
      expect(alreadyChat.toString(), 'https://api.openai.com/v1/chat/completions');

      final respUri = AiClientHelper.responsesUri('https://api.openai.com/v1');
      expect(respUri.toString(), 'https://api.openai.com/v1/responses');

      final alreadyResp = AiClientHelper.responsesUri('https://api.openai.com/v1/responses');
      expect(alreadyResp.toString(), 'https://api.openai.com/v1/responses');
    });

    test('sanitizeEndpoint removes query and fragment from diagnostics', () {
      expect(
        AiClientHelper.sanitizeEndpoint(
          'https://api.example.com/v1?api_key=secret#fragment',
        ),
        'https://api.example.com/v1',
      );
      expect(
        AiClientHelper.sanitizeEndpoint('not-a-url?token=secret#x'),
        'not-a-url',
      );
    });

    test('URI path normalization preserves query and diagnostics remove credentials', () {
      expect(AiClientHelper.chatCompletionUri('https://example.com/v1/?tenant=a').toString(),
          'https://example.com/v1/chat/completions?tenant=a');
      expect(AiClientHelper.responsesUri('https://example.com/v1/responses/?tenant=a').toString(),
          'https://example.com/v1/responses?tenant=a');
      expect(AiClientHelper.sanitizeEndpoint('https://user:secret@example.com/v1?key=secret'),
          'https://example.com/v1');
    });

    test('extractResponseText extracts from both Responses API and Chat Completions', () {
      // Chat format
      final chatJson = {
        'choices': [
          {
            'message': {'content': 'Hello from chat'},
          }
        ]
      };
      expect(AiClientHelper.extractResponseText(chatJson), 'Hello from chat');

      // Responses format with output content list
      final respJson1 = {
        'output': [
          {
            'content': [
              {'text': 'Hello from responses content'}
            ]
          }
        ]
      };
      expect(AiClientHelper.extractResponseText(respJson1), 'Hello from responses content');

      // Responses format with output_text
      final respJson2 = {
        'output_text': 'Hello from output_text',
      };
      expect(AiClientHelper.extractResponseText(respJson2), 'Hello from output_text');
    });
  });
}
