import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';

/// Retarget from the presentation value and velocity, including a release
/// before the press has settled. Native buttons still own gestures and focus.
class MomoPressScale extends StatefulWidget {
  const MomoPressScale({required this.pressed, required this.child, super.key});

  final bool pressed;
  final Widget child;

  @override
  State<MomoPressScale> createState() => _MomoPressScaleState();
}

class _MomoPressScaleState extends State<MomoPressScale>
    with SingleTickerProviderStateMixin {
  late final _controller = AnimationController.unbounded(vsync: this, value: 1);
  bool _reduceMotion = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduceMotion = MediaQuery.disableAnimationsOf(context) ||
        MediaQuery.accessibleNavigationOf(context);
    _retarget();
  }

  @override
  void didUpdateWidget(MomoPressScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.pressed != widget.pressed) _retarget();
  }

  void _retarget() {
    if (_reduceMotion) {
      _controller.value = 1;
      return;
    }
    final target = widget.pressed ? 0.975 : 1.0;
    _controller.animateWith(SpringSimulation(
      const SpringDescription(mass: 1, stiffness: 440, damping: 42),
      _controller.value,
      target,
      _controller.velocity,
    ));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => ScaleTransition(
    scale: _controller,
    child: widget.child,
  );
}
