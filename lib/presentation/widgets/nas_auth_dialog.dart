import 'package:flutter/material.dart';

import '../../application/nas_auth_validation.dart';

class NasAuthDialog extends StatefulWidget {
  const NasAuthDialog({
    super.key,
    required this.register,
    required this.onSubmit,
  });

  final bool register;
  final Future<String?> Function(String email, String password, String nickname)
  onSubmit;

  @override
  State<NasAuthDialog> createState() => _NasAuthDialogState();
}

class _NasAuthDialogState extends State<NasAuthDialog> {
  final _email = TextEditingController();
  final _password = TextEditingController();
  final _nickname = TextEditingController();
  final _formKey = GlobalKey<FormState>();
  bool _obscurePassword = true;
  bool _submitting = false;
  String? _error;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _nickname.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    if (_submitting || !(_formKey.currentState?.validate() ?? false)) return;
    FocusManager.instance.primaryFocus?.unfocus();
    setState(() {
      _submitting = true;
      _error = null;
    });
    String? error;
    try {
      error = await widget.onSubmit(
        _email.text.trim(),
        _password.text,
        _nickname.text.trim(),
      );
    } catch (_) {
      error = 'NAS 账号操作失败，请稍后重试。';
    }
    if (!mounted) return;
    setState(() {
      _submitting = false;
      _error = error;
    });
    if (error == null) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: !_submitting,
      child: AlertDialog(
        title: Text(widget.register ? '注册 NAS 账号' : '登录 NAS 账号'),
        content: SingleChildScrollView(
          child: Form(
            key: _formKey,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.register) ...[
                  TextFormField(
                    controller: _nickname,
                    enabled: !_submitting,
                    decoration: const InputDecoration(
                      labelText: '昵称',
                      prefixIcon: Icon(Icons.person_outline),
                    ),
                    validator: NasAuthValidation.nickname,
                  ),
                  const SizedBox(height: 12),
                ],
                TextFormField(
                  controller: _email,
                  enabled: !_submitting,
                  keyboardType: TextInputType.emailAddress,
                  decoration: const InputDecoration(
                    labelText: '邮箱',
                    prefixIcon: Icon(Icons.email_outlined),
                  ),
                  validator:
                      (value) =>
                          value == null ||
                                  !RegExp(
                                    r'^[^\s@]+@[^\s@]+$',
                                  ).hasMatch(value.trim())
                              ? '请输入有效邮箱'
                              : null,
                ),
                const SizedBox(height: 12),
                TextFormField(
                  controller: _password,
                  enabled: !_submitting,
                  obscureText: _obscurePassword,
                  enableSuggestions: false,
                  autocorrect: false,
                  decoration: InputDecoration(
                    labelText: '密码',
                    helperText:
                        widget.register
                            ? NasAuthValidation.passwordRequirement
                            : null,
                    helperMaxLines: 3,
                    errorMaxLines: 3,
                    prefixIcon: const Icon(Icons.lock_outline),
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword ? '显示密码' : '隐藏密码',
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed:
                          _submitting
                              ? null
                              : () => setState(
                                () => _obscurePassword = !_obscurePassword,
                              ),
                    ),
                  ),
                  validator:
                      (value) => NasAuthValidation.password(
                        value,
                        register: widget.register,
                      ),
                ),
                const SizedBox(height: 12),
                Text(
                  '账号请求会发送到你配置的 NAS。应用不会把密码写入本地设置。',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Semantics(
                    liveRegion: true,
                    child: Text(
                      _error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ),
                ],
                if (_submitting) ...[
                  const SizedBox(height: 12),
                  const LinearProgressIndicator(),
                ],
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed:
                _submitting ? null : () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: _submitting ? null : _submit,
            child: Text(widget.register ? '注册并登录' : '登录'),
          ),
        ],
      ),
    );
  }
}
