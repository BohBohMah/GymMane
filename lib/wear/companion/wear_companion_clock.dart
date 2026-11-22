import 'dart:async';

import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/timer_panel.dart';
import '../link/remote_workout.dart';
import 'wear_motion.dart';

class WearCompanionClock extends StatefulWidget {
  const WearCompanionClock({super.key, required this.workout});

  final RemoteWorkout? workout;

  @override
  State<WearCompanionClock> createState() => _WearCompanionClockState();
}

class _WearCompanionClockState extends State<WearCompanionClock> with WidgetsBindingObserver {
  Timer? _timer;
  bool _foreground = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _schedule();
  }

  @override
  void didUpdateWidget(WearCompanionClock oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.workout?.status != widget.workout?.status) _schedule();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _schedule();
    if (_foreground) setState(() {});
  }

  void _schedule() {
    _timer?.cancel();
    if (!_foreground) return;
    final now = DateTime.now();
    final millis = widget.workout?.status == RemoteStatus.active
        ? 1000 - now.millisecond
        : 60000 - now.second * 1000 - now.millisecond;
    _timer = Timer(Duration(milliseconds: millis), () {
      setState(() {});
      _schedule();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    final workout = widget.workout;
    final elapsed = workout?.summary?.durationSeconds;
    final seconds = workout?.finished == true ? elapsed ?? workout!.elapsedSeconds : workout?.liveElapsedSeconds;
    final style = AppTheme.f(11, weight: FontWeight.w800, color: gc.textSecondary);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: FittedBox(
        fit: BoxFit.scaleDown,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            WearRollingDigits(TimeOfDay.now().format(context), style: style, countsDown: false),
            if (workout?.hasWorkout == true && seconds != null) ...[
              const SizedBox(width: 8),
              Semantics(
                label: t.duration,
                child: Row(
                  children: [
                    Icon(
                      workout?.status == RemoteStatus.paused ? PhosphorIconsBold.pause : PhosphorIconsRegular.timer,
                      color: gc.accent,
                      size: 13,
                    ),
                    const SizedBox(width: 3),
                    WearRollingDigits(clockLabel(seconds), style: style, countsDown: false),
                  ],
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
