import 'package:flutter/material.dart';

import '../../widgets/rolling_text.dart';

const wearMotionDuration = Duration(milliseconds: 180);
const _motionCurve = Curves.easeOutCubic;

class WearPageTransitions extends PageTransitionsBuilder {
  const WearPageTransitions({required this.reduced});

  final bool reduced;

  @override
  Duration get transitionDuration => reduced ? Duration.zero : wearMotionDuration;

  @override
  Duration get reverseTransitionDuration => transitionDuration;

  @override
  Widget buildTransitions<T>(
    PageRoute<T> route,
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
    Widget child,
  ) {
    if (reduced) return child;
    return _appear(animation.drive(CurveTween(curve: _motionCurve)), const Offset(0, 0.06), child);
  }
}

/// Animate updates to the current content without keeping old interactive
/// controls or scroll views alive while they leave.
class WearEnter extends StatefulWidget {
  const WearEnter({super.key, required this.identity, required this.child});

  final Object identity;
  final Widget child;

  @override
  State<WearEnter> createState() => _WearEnterState();
}

class _WearEnterState extends State<WearEnter> with SingleTickerProviderStateMixin {
  late final _controller = AnimationController(vsync: this, duration: wearMotionDuration, value: 1);
  late final _progress = _controller.drive(CurveTween(curve: _motionCurve));
  bool _reduced = false;
  Offset _from = const Offset(0, 0.04);

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _reduced = MediaQuery.disableAnimationsOf(context);
    if (_reduced) _controller.value = 1;
  }

  @override
  void didUpdateWidget(WearEnter oldWidget) {
    super.didUpdateWidget(oldWidget);
    final previous = oldWidget.identity;
    final current = widget.identity;
    if (_reduced || current == previous) return;
    _from = current is int && previous is int ? Offset(current > previous ? 0.10 : -0.10, 0) : const Offset(0, 0.04);
    _controller.forward(from: 0);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => _appear(_progress, _from, widget.child);
}

Widget _appear(Animation<double> progress, Offset from, Widget child) => FadeTransition(
  opacity: progress.drive(Tween(begin: 0.65, end: 1.0)),
  child: SlideTransition(
    position: progress.drive(Tween(begin: from, end: Offset.zero)),
    transformHitTests: false,
    child: child,
  ),
);

class WearRollingDigits extends StatelessWidget {
  const WearRollingDigits(this.label, {super.key, required this.style, this.countsDown});

  final String label;
  final TextStyle style;
  final bool? countsDown;

  @override
  Widget build(BuildContext context) => MediaQuery.disableAnimationsOf(context)
      ? Text(label, style: style)
      : RollingText(label, style: style, countsDown: countsDown, duration: wearMotionDuration);
}
