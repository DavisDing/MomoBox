import 'dart:convert';

/// Matches the NAS registration endpoint's Unicode and bcrypt size limits.
abstract final class NasAuthValidation {
  static const passwordRequirement = '至少 12 个字符，最多 72 个 UTF-8 字节（中文通常占 3 字节）';

  static String? password(String? value, {required bool register}) {
    final text = value ?? '';
    if (text.isEmpty) return '请输入密码';
    if (!register) return null;
    if (text.runes.length < 12) return '密码至少 12 个字符';
    if (utf8.encode(text).length > 72) return '密码不能超过 72 个 UTF-8 字节';
    return null;
  }

  static String? nickname(String? value) {
    final text = value?.trim() ?? '';
    if (text.isEmpty) return '请输入昵称';
    if (text.runes.length > 80) return '昵称不能超过 80 个字符';
    return null;
  }
}
