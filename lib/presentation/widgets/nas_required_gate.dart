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

class _NasSetupPage extends ConsumerWidget {
  const _NasSetupPage();
  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final setup = ref.watch(nasSetupProvider);
    return Scaffold(
      body: Column(
        children: [
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * .4,
            ),
            child: SafeArea(
              bottom: false,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(12),
                  child: Column(
                    children: [
                      const Text('连接家庭 NAS 后开始使用'),
                      if (setup.message != null) Text(setup.message!),
                      if (setup.status == NasSetupStatus.preparing)
                        const LinearProgressIndicator(),
                      if (setup.status == NasSetupStatus.failed)
                        Wrap(
                          children: [
                            TextButton(
                              onPressed:
                                  () =>
                                      ref
                                          .read(nasSetupProvider.notifier)
                                          .prepare(),
                              child: const Text('重试连接'),
                            ),
                            TextButton(
                              onPressed:
                                  () => Navigator.of(context).push(
                                    MaterialPageRoute<void>(
                                      builder:
                                          (_) => const SyncSettingsScreen(),
                                    ),
                                  ),
                              child: const Text('查看连接与同步状态'),
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const Expanded(child: NasSettingsScreen()),
        ],
      ),
    );
  }
}
