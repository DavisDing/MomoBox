import 'package:flutter_test/flutter_test.dart';
import 'package:momo_box/application/ai_client_helper.dart';

void main() {
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
