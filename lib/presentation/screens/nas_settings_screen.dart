import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../app/momo_theme.dart';
import '../../application/nas_connection_service.dart';
import '../../application/nas_auth_service.dart';
import '../../domain/models/nas_family_device_models.dart';
import '../../domain/models/nas_models.dart';
import '../controllers/nas_account_controller.dart';
import '../controllers/providers.dart';
import '../widgets/app_feedback.dart';

class NasSettingsScreen extends ConsumerStatefulWidget {
  const NasSettingsScreen({super.key});

  @override
  ConsumerState<NasSettingsScreen> createState() => _NasSettingsScreenState();
}

class _NasSettingsScreenState extends ConsumerState<NasSettingsScreen> {
  final _serverUrlController = TextEditingController();
  final _familyCodeController = TextEditingController();
  bool _autoSync = true;
  bool _syncImages = true;
  bool _controllersInitialized = false;

  @override
  void dispose() {
    _serverUrlController.dispose();
    _familyCodeController.dispose();
    super.dispose();
  }

  String _statusTitle(NasConnectionState state) {
    return switch (state.status) {
      NasConnectionStatus.unconfigured => '未配置',
      NasConnectionStatus.checking => '连接中',
      NasConnectionStatus.connected => '已连接',
      NasConnectionStatus.unavailable => '服务不可用',
      NasConnectionStatus.failed => '连接失败',
    };
  }

  Color _statusColor(BuildContext context, NasConnectionStatus status) {
    return switch (status) {
      NasConnectionStatus.connected => Colors.green,
      NasConnectionStatus.checking => Theme.of(context).colorScheme.primary,
      NasConnectionStatus.unconfigured => Colors.blueGrey,
      NasConnectionStatus.unavailable || NasConnectionStatus.failed => Colors.orange,
    };
  }

  Future<void> _testConnection() async {
    FocusManager.instance.primaryFocus?.unfocus();
    await ref.read(nasConnectionProvider.notifier).refresh(
          serverUrl: _serverUrlController.text,
          familyCode: _familyCodeController.text,
        );
    if (!mounted) return;
    final connection = ref.read(nasConnectionProvider);
    showAppSnackBar(
      context,
      SnackBar(content: Text(connection.message ?? _statusTitle(connection))),
    );

    if (connection.status == NasConnectionStatus.connected) {
      await ref.read(nasAccountProvider.notifier).restore();
    }
  }

  Future<void> _login() async {
    final request = await _showAuthDialog(register: false);
    if (request is! NasLoginRequest || !mounted) return;
    await ref.read(nasAccountProvider.notifier).login(request);
    if (!mounted) return;
    _showAccountResult();
  }

  Future<void> _register() async {
    final request = await _showAuthDialog(register: true);
    if (request is! NasRegisterRequest || !mounted) return;
    await ref.read(nasAccountProvider.notifier).register(request);
    if (!mounted) return;
    _showAccountResult();
  }

  void _showAccountResult() {
    final account = ref.read(nasAccountProvider);
    final message = account.errorMessage ??
        (account.isAuthenticated ? 'NAS 账号已登录。' : 'NAS 账号操作未完成。');
    showAppSnackBar(context, SnackBar(content: Text(message)));
  }

  Future<Object?> _showAuthDialog({required bool register}) {
    final emailController = TextEditingController();
    final passwordController = TextEditingController();
    final nicknameController = TextEditingController();
    final formKey = GlobalKey<FormState>();

    return showDialog<Object?>(
      context: context,
      builder: (dialogContext) {
        var obscurePassword = true;
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: Text(register ? '注册 NAS 账号' : '登录 NAS 账号'),
              content: Form(
                key: formKey,
                child: SingleChildScrollView(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (register) ...[
                        TextFormField(
                          controller: nicknameController,
                          decoration: const InputDecoration(
                            labelText: '昵称',
                            prefixIcon: Icon(Icons.person_outline),
                          ),
                          validator: (value) => value == null || value.trim().isEmpty
                              ? '请输入昵称'
                              : null,
                        ),
                        const SizedBox(height: 12),
                      ],
                      TextFormField(
                        controller: emailController,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: '邮箱',
                          prefixIcon: Icon(Icons.email_outlined),
                        ),
                        validator: (value) => value == null || !value.contains('@')
                            ? '请输入有效邮箱'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: passwordController,
                        obscureText: obscurePassword,
                        decoration: InputDecoration(
                          labelText: '密码',
                          prefixIcon: const Icon(Icons.lock_outline),
                          suffixIcon: IconButton(
                            tooltip: obscurePassword ? '显示密码' : '隐藏密码',
                            icon: Icon(obscurePassword
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined),
                            onPressed: () => setDialogState(
                              () => obscurePassword = !obscurePassword,
                            ),
                          ),
                        ),
                        validator: (value) => value == null || value.length < 8
                            ? '密码至少 8 位'
                            : null,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '账号请求会发送到你配置的 NAS。应用不会把密码写入本地设置。',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () {
                    if (!(formKey.currentState?.validate() ?? false)) return;
                    if (register) {
                      Navigator.of(dialogContext).pop(
                        NasRegisterRequest(
                          email: emailController.text.trim(),
                          password: passwordController.text,
                          nickname: nicknameController.text.trim(),
                        ),
                      );
                    } else {
                      Navigator.of(dialogContext).pop(
                        NasLoginRequest(
                          email: emailController.text.trim(),
                          password: passwordController.text,
                        ),
                      );
                    }
                  },
                  child: Text(register ? '注册并登录' : '登录'),
                ),
              ],
            );
          },
        );
      },
    ).whenComplete(() {
      emailController.dispose();
      passwordController.dispose();
      nicknameController.dispose();
    });
  }

  Future<void> _createFamily() async {
    final controller = TextEditingController();
    final formKey = GlobalKey<FormState>();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('创建家庭'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '家庭名称',
              prefixIcon: Icon(Icons.home_work_outlined),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? '请输入家庭名称'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(controller.text.trim());
              }
            },
            child: const Text('创建'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await ref.read(nasAccountProvider.notifier).createFamily(name);
    if (mounted) _showFamilyResult();
  }

  Future<void> _joinFamily() async {
    final code = _familyCodeController.text.trim();
    if (code.isEmpty) {
      showAppSnackBar(context, const SnackBar(content: Text('请先填写邀请码。')));
      return;
    }
    await ref.read(nasAccountProvider.notifier).joinFamily(code);
    if (mounted) _showFamilyResult();
  }

  void _showFamilyResult() {
    final account = ref.read(nasAccountProvider);
    showAppSnackBar(
      context,
      SnackBar(
        content: Text(
          account.family.errorMessage ??
              account.errorMessage ??
              (account.family.hasFamily ? '家庭已更新。' : '家庭操作未完成。'),
        ),
      ),
    );
  }

  Future<void> _createInvite() async {
    final invite = await ref.read(nasAccountProvider.notifier).createInvite();
    if (!mounted || invite == null) {
      if (mounted) _showFamilyResult();
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('家庭邀请码'),
        content: SelectableText(
          '邀请码：${invite.code}\n\n有效期至：${_formatDateTime(invite.expiresAt)}\n剩余次数：${invite.remainingUses}',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('关闭'),
          ),
        ],
      ),
    );
  }

  Future<void> _registerDevice() async {
    final controller = TextEditingController(text: '我的手机');
    final formKey = GlobalKey<FormState>();
    final name = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('注册当前设备'),
        content: Form(
          key: formKey,
          child: TextFormField(
            controller: controller,
            autofocus: true,
            decoration: const InputDecoration(
              labelText: '设备名称',
              prefixIcon: Icon(Icons.phone_android_outlined),
            ),
            validator: (value) => value == null || value.trim().isEmpty
                ? '请输入设备名称'
                : null,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              if (formKey.currentState?.validate() ?? false) {
                Navigator.of(dialogContext).pop(controller.text.trim());
              }
            },
            child: const Text('注册'),
          ),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await ref.read(nasAccountProvider.notifier).registerCurrentDevice(
          deviceName: name,
        );
    if (mounted) _showDeviceResult();
  }

  Future<void> _revokeDevice(NasDeviceDto device) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('撤销设备？'),
        content: Text('撤销“${device.deviceName}”后，该设备将不能继续使用 NAS 同步。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('撤销'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await ref.read(nasAccountProvider.notifier).revokeDevice(device.id);
    if (mounted) _showDeviceResult();
  }

  void _showDeviceResult() {
    final account = ref.read(nasAccountProvider);
    showAppSnackBar(
      context,
      SnackBar(content: Text(account.devices.errorMessage ?? account.errorMessage ?? '设备状态已更新。')),
    );
  }

  String _formatDateTime(DateTime value) {
    final local = value.toLocal();
    String twoDigits(int number) => number.toString().padLeft(2, '0');
    return '${local.year}-${twoDigits(local.month)}-${twoDigits(local.day)} '
        '${twoDigits(local.hour)}:${twoDigits(local.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    final palette = MomoPalette.fromStoredValue(ref.watch(themeNameProvider).valueOrNull);
    final connection = ref.watch(nasConnectionProvider);
    final account = ref.watch(nasAccountProvider);
    final statusColor = _statusColor(context, connection.status);

    if (!_controllersInitialized && connection.serverUrl.isNotEmpty) {
      _serverUrlController.text = connection.serverUrl;
      _familyCodeController.text = connection.familyCode;
      _controllersInitialized = true;
    }

    return Scaffold(
      appBar: AppBar(title: const Text('NAS 协同与家庭共享')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          _buildConnectionSummary(context, connection, statusColor),
          const SizedBox(height: 12),
          _buildConnectionCard(context, palette, connection),
          const SizedBox(height: 12),
          _buildAccountCard(context, account, connection),
          if (account.isAuthenticated) ...[
            const SizedBox(height: 12),
            _buildFamilyCard(context, account, palette),
            if (account.family.hasFamily) ...[
              const SizedBox(height: 12),
              _buildDeviceCard(context, account, palette),
            ],
          ],
          const SizedBox(height: 12),
          _buildScopeCard(context, connection, statusColor),
        ],
      ),
    );
  }

  Widget _buildConnectionSummary(
    BuildContext context,
    NasConnectionState state,
    Color statusColor,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Row(
          children: [
            Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.15),
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.dns_rounded, color: statusColor, size: 24),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('NAS 协同服务', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16)),
                  const SizedBox(height: 4),
                  Text(
                    state.serverUrl.isEmpty ? '配置服务地址后进行真实健康检查' : state.serverUrl,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
                ],
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: statusColor.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(12),
              ),
              child: Text(
                _statusTitle(state),
                style: TextStyle(fontSize: 12, color: statusColor, fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildConnectionCard(
    BuildContext context,
    MomoPalette palette,
    NasConnectionState state,
  ) {
    final isChecking = state.status == NasConnectionStatus.checking;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('NAS 服务端配置', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
            const SizedBox(height: 12),
            TextField(
              controller: _serverUrlController,
              keyboardType: TextInputType.url,
              decoration: const InputDecoration(
                labelText: 'NAS 服务器地址',
                hintText: 'http://192.168.x.x:8080',
                prefixIcon: Icon(Icons.link_rounded),
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _familyCodeController,
              decoration: const InputDecoration(
                labelText: '邀请码（用于加入家庭，可选）',
                hintText: '如 MOMO-FAMILY-888',
                prefixIcon: Icon(Icons.group_work_outlined),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '地址会保存在本地设置；账号凭据由安全存储管理。没有连接 NAS 时仍可继续使用本地模式。',
              style: Theme.of(context).textTheme.bodySmall,
            ),
            const SizedBox(height: 8),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('局域网自动双向同步', style: TextStyle(fontSize: 14)),
              subtitle: const Text('保存偏好；具体同步由 NAS 账户与同步协议状态决定', style: TextStyle(fontSize: 12)),
              value: _autoSync,
              activeTrackColor: palette.primary,
              onChanged: (v) => setState(() => _autoSync = v),
            ),
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: const Text('同步物资照片与包装原图', style: TextStyle(fontSize: 14)),
              subtitle: const Text('保存偏好；服务端未开放媒体同步时不会上传', style: TextStyle(fontSize: 12)),
              value: _syncImages,
              activeTrackColor: palette.primary,
              onChanged: (v) => setState(() => _syncImages = v),
            ),
            const SizedBox(height: 12),
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                style: FilledButton.styleFrom(backgroundColor: palette.primary),
                onPressed: isChecking ? null : _testConnection,
                icon: isChecking
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.network_check_rounded),
                label: Text(isChecking ? '检测中…' : '测试并保存 NAS 连接'),
              ),
            ),
            if (state.message != null) ...[
              const SizedBox(height: 8),
              Text(state.message!, style: TextStyle(fontSize: 12, color: _statusColor(context, state.status))),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildAccountCard(
    BuildContext context,
    NasAccountState account,
    NasConnectionState connection,
  ) {
    final normalizedInput = NasConnectionService.normalizeServerUrl(_serverUrlController.text);
    final canUseAccount = connection.status == NasConnectionStatus.connected &&
        normalizedInput != null &&
        normalizedInput == connection.serverUrl;
    final auth = account.auth;
    final isBusy = account.status == NasAccountStatus.restoring ||
        account.status == NasAccountStatus.signingIn ||
        account.status == NasAccountStatus.signingOut;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('NAS 账号', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                if (isBusy) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            if (!canUseAccount)
              const Text('请先测试并保存可用的 NAS 地址，再登录或注册账号。', style: TextStyle(fontSize: 12))
            else if (auth.isAuthenticated) ...[
              Text(auth.user?.nickname ?? '已登录', style: const TextStyle(fontWeight: FontWeight.bold)),
              if (auth.user?.email != null) Text(auth.user!.email, style: const TextStyle(fontSize: 12, color: Colors.grey)),
              const SizedBox(height: 10),
              Row(
                children: [
                  OutlinedButton.icon(
                    onPressed: isBusy ? null : () => ref.read(nasAccountProvider.notifier).refreshFamilyAndDevices(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新家庭与设备'),
                  ),
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: isBusy ? null : () => ref.read(nasAccountProvider.notifier).logout(),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('退出登录'),
                  ),
                ],
              ),
            ] else ...[
              Text(
                auth.status == NasAuthStatus.error ? '登录状态异常，请重试或检查 NAS 服务。' : '未登录 NAS 账号。',
                style: const TextStyle(fontSize: 12),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: isBusy ? null : _login,
                    icon: const Icon(Icons.login, size: 18),
                    label: const Text('登录'),
                  ),
                  OutlinedButton.icon(
                    onPressed: isBusy ? null : _register,
                    icon: const Icon(Icons.person_add_alt_1, size: 18),
                    label: const Text('注册账号'),
                  ),
                ],
              ),
            ],
            if (account.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(account.errorMessage!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildFamilyCard(
    BuildContext context,
    NasAccountState account,
    MomoPalette palette,
  ) {
    final family = account.family;
    final isLoading = family.status == NasFamilyStatus.loading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('家庭与邀请码', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                if (isLoading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            if (family.hasFamily) ...[
              Text(family.current!.family.name, style: const TextStyle(fontWeight: FontWeight.bold)),
              const SizedBox(height: 4),
              Text('角色：${family.current!.membership.role} · 成员：${family.members.length} 人', style: const TextStyle(fontSize: 12, color: Colors.grey)),
              if (family.members.isNotEmpty) ...[
                const SizedBox(height: 8),
                ...family.members.map(
                  (member) => ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    leading: const Icon(Icons.person_outline, size: 20),
                    title: Text(member.nickname),
                    subtitle: Text('${member.email} · ${member.role}'),
                  ),
                ),
              ],
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: palette.primary),
                    onPressed: isLoading ? null : _createInvite,
                    icon: const Icon(Icons.qr_code_2, size: 18),
                    label: const Text('生成邀请码'),
                  ),
                  OutlinedButton.icon(
                    onPressed: isLoading ? null : () => ref.read(nasAccountProvider.notifier).refreshFamilyAndDevices(),
                    icon: const Icon(Icons.refresh, size: 18),
                    label: const Text('刷新成员'),
                  ),
                ],
              ),
            ] else ...[
              const Text('当前账号还没有家庭。你可以创建新家庭，或使用上方邀请码加入已有家庭。', style: TextStyle(fontSize: 12)),
              const SizedBox(height: 10),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  FilledButton.icon(
                    style: FilledButton.styleFrom(backgroundColor: palette.primary),
                    onPressed: isLoading ? null : _createFamily,
                    icon: const Icon(Icons.add_home_work_outlined, size: 18),
                    label: const Text('创建家庭'),
                  ),
                  OutlinedButton.icon(
                    onPressed: isLoading ? null : _joinFamily,
                    icon: const Icon(Icons.group_add_outlined, size: 18),
                    label: const Text('使用邀请码加入'),
                  ),
                ],
              ),
            ],
            if (family.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(family.errorMessage!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ],
            if (family.membersErrorMessage != null) ...[
              const SizedBox(height: 4),
              Text(family.membersErrorMessage!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildDeviceCard(
    BuildContext context,
    NasAccountState account,
    MomoPalette palette,
  ) {
    final devices = account.devices;
    final isLoading = devices.status == NasDeviceStatus.loading;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Expanded(child: Text('已注册设备', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14))),
                if (isLoading) const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)),
              ],
            ),
            const SizedBox(height: 8),
            if (devices.devices.isEmpty)
              const Text('当前家庭还没有注册设备。', style: TextStyle(fontSize: 12))
            else
              ...devices.devices.map(
                (device) => ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  leading: Icon(
                    device.id == devices.currentDeviceId ? Icons.phone_android : Icons.devices_other,
                    color: device.id == devices.currentDeviceId ? palette.primary : null,
                  ),
                  title: Text(device.deviceName),
                  subtitle: Text('${device.platform}${device.isCurrent == true ? ' · 当前设备' : ''}'),
                  trailing: IconButton(
                    tooltip: '撤销设备',
                    onPressed: isLoading ? null : () => _revokeDevice(device),
                    icon: const Icon(Icons.remove_circle_outline),
                  ),
                ),
              ),
            const SizedBox(height: 4),
            OutlinedButton.icon(
              onPressed: isLoading ? null : _registerDevice,
              icon: const Icon(Icons.app_registration, size: 18),
              label: Text(devices.status == NasDeviceStatus.needsRegistration ? '注册当前设备' : '重新注册当前设备'),
            ),
            if (devices.errorMessage != null) ...[
              const SizedBox(height: 8),
              Text(devices.errorMessage!, style: TextStyle(fontSize: 12, color: Theme.of(context).colorScheme.error)),
            ],
          ],
        ),
      ),
    );
  }

  Widget _buildScopeCard(
    BuildContext context,
    NasConnectionState state,
    Color statusColor,
  ) {
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('当前接入范围', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
            const SizedBox(height: 6),
            Text(
              '客户端会调用 NAS 的 /api/v1/health 进行真实可用性检测，并可在此管理账号、家庭成员邀请码和设备注册。库存同步仍由独立同步流程负责；没有登录 NAS 时，本地库存和采购功能不受影响。',
              style: TextStyle(fontSize: 12, height: 1.5, color: Theme.of(context).textTheme.bodySmall?.color),
            ),
            if (state.message != null) ...[
              const SizedBox(height: 8),
              Text(state.message!, style: TextStyle(fontSize: 12, color: statusColor)),
            ],
          ],
        ),
      ),
    );
  }
}
