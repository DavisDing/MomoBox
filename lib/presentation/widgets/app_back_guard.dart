import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';

/// Only intercept the shell's root route. Routes and modal overlays above it
/// retain their normal back behavior (including dismissing an open keyboard).
class AppBackGuard extends StatefulWidget {
  const AppBackGuard({required this.child, super.key});

  final Widget child;

  @override
  State<AppBackGuard> createState() => _AppBackGuardState();
}

class _AppBackGuardState extends State<AppBackGuard>
    with WidgetsBindingObserver {
  Timer? _exitTimer;
  String? _location;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final location = GoRouterState.of(context).uri.path;
    if (_location != location) {
      _exitTimer?.cancel();
      _exitTimer = null;
      _location = location;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) {
      _exitTimer?.cancel();
      _exitTimer = null;
    }
  }

  @override
  void dispose() {
    _exitTimer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _handleBack(bool didPop, Object? result) {
    if (didPop) return;
    final router = GoRouter.of(context);
    if (_location != '/') {
      router.go('/');
      return;
    }
    final messenger = ScaffoldMessenger.of(context);
    if (_exitTimer?.isActive ?? false) {
      _exitTimer?.cancel();
      _exitTimer = null;
      messenger.hideCurrentSnackBar();
      SystemNavigator.pop();
      return;
    }
    _exitTimer = Timer(const Duration(seconds: 2), () {});
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(
        const SnackBar(
          content: Text('再按一次退出软件'),
          duration: Duration(seconds: 2),
        ),
      );
  }

  @override
  Widget build(BuildContext context) {
    final isAndroid = Theme.of(context).platform == TargetPlatform.android;
    return PopScope<Object?>(
      canPop: !isAndroid,
      onPopInvokedWithResult: isAndroid ? _handleBack : null,
      child: widget.child,
    );
  }
}
