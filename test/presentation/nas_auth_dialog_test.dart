import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:momo_box/application/nas_auth_validation.dart';
import 'package:momo_box/data/nas/nas_api_error.dart';
import 'package:momo_box/presentation/widgets/nas_auth_dialog.dart';

void main() {
  test('NAS family and registration errors give actionable guidance', () {
    final familyError = NasApiError.fromResponse(
      http.Response(
        jsonEncode({
          'error': {
            'code': 'HA_UNAUTHORIZED',
            'message': 'authenticated family member is required',
          },
        }),
        401,
      ),
    );
    expect(familyError.message, contains('创建或加入家庭'));
    expect(familyError.message, contains('重新登录'));
    final passwordError = NasApiError.fromResponse(
      http.Response(
        jsonEncode({
          'error': {
            'code': 'VALIDATION_FAILED',
            'message':
                'password must be at least 12 characters and at most 72 UTF-8 bytes',
          },
        }),
        400,
      ),
    );
    expect(passwordError.message, contains('密码至少 12 个字符'));
    expect(passwordError.message, contains('72'));
  });

  test('registration matches NAS character and UTF-8 byte limits', () {
    String? validate(String value) =>
        NasAuthValidation.password(value, register: true);
    expect(validate('a' * 11), isNotNull);
    expect(validate('a' * 12), isNull);
    expect(validate('a' * 72), isNull);
    expect(validate('a' * 73), isNotNull);
    expect(validate('中' * 24), isNull);
    expect(validate('中' * 25), isNotNull);
    expect(validate('😀' * 11), isNotNull);
    expect(validate('😀' * 12), isNull);
    expect(validate('😀' * 18), isNull);
    expect(validate('😀' * 19), isNotNull);
    expect(NasAuthValidation.password('old', register: false), isNull);
    expect(NasAuthValidation.password('', register: false), isNotNull);
    expect(NasAuthValidation.nickname('😀' * 80), isNull);
    expect(NasAuthValidation.nickname('😀' * 81), isNotNull);
  });

  testWidgets(
    'shows password rules before submission and keeps all fields after validation failure',
    (tester) async {
      var calls = 0;
      await _open(tester, (email, password, nickname) async {
        calls++;
        return null;
      });
      expect(find.text(NasAuthValidation.passwordRequirement), findsOneWidget);
      await _fill(tester, password: '12345678');
      await tester.tap(find.text('注册并登录'));
      await tester.pumpAndSettle();
      expect(find.text('密码至少 12 个字符'), findsOneWidget);
      expect(calls, 0);
      _expectFields(tester, '12345678');
      await tester.tap(find.byTooltip('显示密码'));
      await tester.pump();
      expect(
        tester.widget<EditableText>(find.byType(EditableText).last).obscureText,
        isFalse,
      );
    },
  );

  testWidgets(
    'server rejection keeps dialog and input; retry waits for success without duplicate submission',
    (tester) async {
      final response = Completer<String?>();
      var calls = 0;
      await _open(tester, (email, password, nickname) async {
        calls++;
        expect(email, 'user@example.com');
        expect(password, 'valid-password');
        expect(nickname, '家人');
        return calls == 1 ? '该邮箱已注册，请直接登录。' : response.future;
      });
      await _fill(tester);
      await tester.tap(find.text('注册并登录'));
      await tester.pumpAndSettle();
      expect(find.text('该邮箱已注册，请直接登录。'), findsOneWidget);
      _expectFields(tester, 'valid-password');
      await tester.tap(find.text('注册并登录'));
      await tester.pump();
      expect(find.byType(NasAuthDialog), findsOneWidget);
      expect(
        tester.widget<FilledButton>(find.byType(FilledButton)).onPressed,
        isNull,
      );
      expect(
        tester
            .widget<TextButton>(find.widgetWithText(TextButton, '取消'))
            .onPressed,
        isNull,
      );
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(NasAuthDialog), findsOneWidget);
      expect(calls, 2);
      response.complete(null);
      await tester.pumpAndSettle();
      expect(find.byType(NasAuthDialog), findsNothing);
      expect(find.text('完成'), findsOneWidget);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'network failure is retryable without exposing exception contents',
    (tester) async {
      await _open(tester, (_, _, _) async => throw StateError('secret'));
      await _fill(tester);
      await tester.tap(find.text('注册并登录'));
      await tester.pumpAndSettle();
      expect(find.text('NAS 账号操作失败，请稍后重试。'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      _expectFields(tester, 'valid-password');
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();
      expect(find.byType(NasAuthDialog), findsNothing);
      expect(tester.takeException(), isNull);
    },
  );
}

Future<void> _open(
  WidgetTester tester,
  Future<String?> Function(String, String, String) submit,
) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder:
              (context) => TextButton(
                child: const Text('打开'),
                onPressed: () async {
                  final success = await showDialog<bool>(
                    context: context,
                    barrierDismissible: false,
                    builder:
                        (_) => NasAuthDialog(register: true, onSubmit: submit),
                  );
                  if (success == true && context.mounted) {
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('完成')));
                  }
                },
              ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
}

Future<void> _fill(
  WidgetTester tester, {
  String password = 'valid-password',
}) async {
  await tester.enterText(find.byType(TextFormField).at(0), '家人');
  await tester.enterText(find.byType(TextFormField).at(1), 'user@example.com');
  await tester.enterText(find.byType(TextFormField).at(2), password);
}

void _expectFields(WidgetTester tester, String password) {
  final fields =
      tester.widgetList<TextFormField>(find.byType(TextFormField)).toList();
  expect(fields[0].controller!.text, '家人');
  expect(fields[1].controller!.text, 'user@example.com');
  expect(fields[2].controller!.text, password);
}
