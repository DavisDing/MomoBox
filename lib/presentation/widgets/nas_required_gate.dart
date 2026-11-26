import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import '../controllers/providers.dart';
import '../controllers/nas_setup_controller.dart';
import '../screens/nas_settings_screen.dart';
import '../screens/sync_settings_screen.dart';

class NasRequiredGate extends ConsumerStatefulWidget {
  const NasRequiredGate({required this.child, super.key});
  final Widget child;
  @override
  ConsumerState<NasRequiredGate> createState() => _NasRequiredGateState();
}

class _NasRequiredGateState extends ConsumerState<NasRequiredGate>
    with WidgetsBindingObserver {
  Timer? _timer;
  final _setupNavigator = GlobalKey<NavigatorState>();
  bool _checking = false;
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer.periodic(const Duration(seconds: 30), (_) => _reconnect());
  }

  Future<void> _reconnect() async {
    if (_checking || !mounted) return;
    if (WidgetsBinding.instance.lifecycleState != null &&
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    _checking = true;
    try {
      await reconnectNas(ref);
    } finally {
      _checking = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _start();
      unawaited(_reconnect());
    } else {
      _timer?.cancel();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final access = ref.watch(nasAppAccessProvider);
    if (access == NasAppAccess.setup) {
      // MaterialApp.builder is above the app Router. Setup needs its own
      // navigator for login dialogs and conflict review before business access.
      return Navigator(
        key: _setupNavigator,
        onGenerateRoute:
            (_) =>
                MaterialPageRoute<void>(builder: (_) => const _NasSetupPage()),
      );
    }
    return Column(
      children: [
        if (access == NasAppAccess.cached)
          SafeArea(
            bottom: false,
            child: Material(
              color: Theme.of(context).colorScheme.secondaryContainer,
              child: ListTile(
                dense: true,
                title: const Text('NAS 连接未就绪 · 正在查看缓存'),
                subtitle: const Text('恢复连接后自动同步；AI、OCR 和家居控制需要连接 NAS。'),
                trailing: IconButton(
                  tooltip: '重连 NAS',
                  onPressed: _reconnect,
                  icon: const Icon(Icons.refresh),
                ),
              ),
            ),
          ),
        Expanded(
          key: const ValueKey('nas-business-content'),
          child: widget.child,
        ),
      ],
    );
  }
}

enum _SetupAction { retry, diagnostics, reset }

class _NasSetupPage extends ConsumerStatefulWidget {
  const _NasSetupPage();

  @override
  ConsumerState<_NasSetupPage> createState() => _NasSetupPageState();
}

class _NasSetupPageState extends ConsumerState<_NasSetupPage> {
  NasSetupStatus? _shownProblem;
  bool _dialogOpen = false;

  Future<void> _showProblem(NasSetupState problem) async {
    if (_dialogOpen) return;
    _dialogOpen = true;
    _shownProblem = problem.status;
    try {
      final mismatch = problem.status == NasSetupStatus.workspaceMismatch;
      final action = await showDialog<_SetupAction>(
        context: context,
        builder: (dialogContext) => AlertDialog(
          scrollable: true,
          title: Text(mismatch ? '此手机仍关联原家庭' : '家庭接入未完成'),
          content: Text(problem.message ?? '请重试或查看连接与同步状态。'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('返回连接页'),
            ),
            if (mismatch)
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_SetupAction.reset),
                child: const Text('清除本机数据并继续'),
              )
            else ...[
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_SetupAction.diagnostics),
                child: const Text('查看连接与同步状态'),
              ),
              TextButton(
                onPressed: () =>
                    Navigator.of(dialogContext).pop(_SetupAction.retry),
                child: const Text('重试连接'),
              ),
            ],
          ],
        ),
      );
      if (!mounted) return;
      switch (action) {
        case _SetupAction.retry:
          _shownProblem = null;
          unawaited(ref.read(nasSetupProvider.notifier).prepare());
        case _SetupAction.diagnostics:
          await Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const SyncSettingsScreen()),
          );
        case _SetupAction.reset:
          await _confirmReset(problem);
        case null:
          break;
      }
    } finally {
      _dialogOpen = false;
      if (mounted) setState(() {});
    }
  }

  Future<void> _confirmReset(NasSetupState problem) async {
    if (!identical(ref.read(nasSetupProvider), problem)) return;
    final account = ref.read(nasAccountProvider);
    final family = account.family.current?.family.name;
    final email = account.auth.user?.email;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        scrollable: true,
        title: const Text('确认清除本机数据？'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            const Text('将删除此手机上的库存、采购、历史、图片缓存、待同步变更等本机资料。操作无法撤销，NAS 上的数据会保留。'),
            if (family != null) ...[
              const SizedBox(height: 12),
              Text('随后连接「$family」'),
              if (email != null) Text(email),
            ],
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            style: TextButton.styleFrom(
              foregroundColor: Theme.of(dialogContext).colorScheme.error,
            ),
            onPressed: () => Navigator.of(dialogContext).pop(true),
            child: const Text('确认清除并继续'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    _shownProblem = null;
    await ref.read(nasSetupProvider.notifier).resetLocalWorkspace(problem);
  }

  @override
  Widget build(BuildContext context) {
    final setup = ref.watch(nasSetupProvider);
    final hasProblem =
        setup.status == NasSetupStatus.failed ||
        setup.status == NasSetupStatus.workspaceMismatch;
    final isCurrentRoute = ModalRoute.of(context)?.isCurrent == true;
    if (setup.status == NasSetupStatus.connectionRequired ||
        setup.status == NasSetupStatus.inviteRequired) {
      _shownProblem = null;
    }
    if (hasProblem &&
        isCurrentRoute &&
        !_dialogOpen &&
        _shownProblem != setup.status) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted &&
            ModalRoute.of(context)?.isCurrent == true &&
            identical(ref.read(nasSetupProvider), setup) &&
            _shownProblem != setup.status) {
          unawaited(_showProblem(setup));
        }
      });
    }
    return NasSettingsScreen.setup(
      feedback: switch (setup.status) {
        NasSetupStatus.preparing => Padding(
          padding: const EdgeInsets.only(top: 12),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(setup.message ?? '正在连接家庭并同步数据…'),
              const SizedBox(height: 8),
              const LinearProgressIndicator(),
            ],
          ),
        ),
        NasSetupStatus.failed || NasSetupStatus.workspaceMismatch => Align(
          alignment: Alignment.centerLeft,
          child: TextButton(
            onPressed: () => unawaited(_showProblem(setup)),
            child: Text(
              setup.status == NasSetupStatus.workspaceMismatch
                  ? '处理本机数据归属'
                  : '查看连接问题',
            ),
          ),
        ),
        _ => const SizedBox.shrink(),
      },
    );
  }
}
