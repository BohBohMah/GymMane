import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../models/workout.dart';
import '../../state/fit_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/timer_panel.dart';
import '../link/remote_workout.dart';
import '../link/wear_command.dart';
import '../link/wear_link_client.dart';
import '../link/wear_link_status.dart';
import '../wear_shell.dart';

/// Watch-side companion screen. It mirrors the phone workout and never marks a
/// set as saved before the phone ack arrives.
class WearLinkScreen extends StatefulWidget {
  const WearLinkScreen({super.key});

  @override
  State<WearLinkScreen> createState() => _WearLinkScreenState();
}

class _WearLinkScreenState extends State<WearLinkScreen> {
  final WearLinkClient _client = WearLinkClient.instance;
  final TextEditingController _pin = TextEditingController();

  Timer? _ticker;
  Timer? _flashTimer;
  List<WearBondedDevice>? _devices;
  bool _loadingDevices = false;
  String? _acting;
  String? _flash;
  bool _flashOk = true;
  int _lastRest = 0;

  @override
  void initState() {
    super.initState();
    _client.attach();
    _client.status.addListener(_onValue);
    _client.workout.addListener(_onValue);
    _client.pinPrompt.addListener(_onValue);
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      final rest = _client.workout.value?.rest;
      final left = rest?.remaining().inSeconds ?? 0;
      if (rest != null && left <= 0 && _lastRest > 0) HapticFeedback.heavyImpact();
      _lastRest = left;
      setState(() {});
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _client.resume();
    });
  }

  @override
  void dispose() {
    _client.status.removeListener(_onValue);
    _client.workout.removeListener(_onValue);
    _client.pinPrompt.removeListener(_onValue);
    _ticker?.cancel();
    _flashTimer?.cancel();
    _pin.dispose();
    super.dispose();
  }

  void _onValue() {
    if (mounted) setState(() {});
  }

  void _showFlash(String text, bool ok) {
    _flashTimer?.cancel();
    setState(() {
      _flash = text;
      _flashOk = ok;
    });
    _flashTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _flash = null);
    });
  }

  Future<void> _run(
    String key,
    Future<WearAck> Function() action, {
    bool confirm = true,
  }) async {
    if (_acting != null) return;
    HapticFeedback.selectionClick();
    setState(() => _acting = key);
    final ack = await action();
    if (!mounted) return;
    setState(() => _acting = null);
    if (ack.ok) {
      if (confirm) HapticFeedback.lightImpact();
      if (confirm) _showFlash(t.wearLinkSaved, true);
    } else {
      HapticFeedback.heavyImpact();
      _showFlash(_ackMessage(ack), false);
    }
  }

  String _ackMessage(WearAck ack) => switch (ack.code) {
        'conflict' => t.wearLinkNotSaved,
        'offline' || 'timeout' => t.wearLinkOffline,
        'no_session' => t.wearLinkNoWorkout,
        'no_pending' => t.wearLinkNoWorkout,
        _ => '${t.wearLinkNotSaved} (${ack.code})',
      };

  Future<void> _loadDevices() async {
    if (_loadingDevices) return;
    setState(() => _loadingDevices = true);
    final list = await _client.bondedDevices();
    if (!mounted) return;
    setState(() {
      _devices = list;
      _loadingDevices = false;
    });
  }

  Future<void> _connect(WearBondedDevice device) async {
    if (_acting != null) return;
    setState(() => _acting = 'connect');
    final status = await _client.connect(device.address, device.name);
    if (!mounted) return;
    setState(() => _acting = null);
    if (status.error == 'not_bonded') {
      _showFlash(t.wearLinkNoDevices, false);
    }
  }

  Future<void> _submitPin() async {
    if (_acting != null) return;
    setState(() => _acting = 'pin');
    final ok = await _client.submitPin(_pin.text.trim());
    if (!mounted) return;
    setState(() => _acting = null);
    if (!ok) _showFlash(t.wearLinkPinWrong, false);
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    final status = _client.status.value;
    if (!status.supported) {
      return WearPage(children: [Text(t.wearLinkUnsupported, textAlign: TextAlign.center)]);
    }
    if (_client.pinPrompt.value != null) return _pinPage(gc, status);
    if (!status.enabled || !status.connected) return _linkPage(gc, status);
    return _workoutPage(gc, status, _client.workout.value);
  }

  Widget get _flashLine {
    final flash = _flash;
    if (flash == null) return const SizedBox.shrink();
    final gc = context.gc;
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Text(
        flash,
        textAlign: TextAlign.center,
        style: AppTheme.f(11, weight: FontWeight.w700, color: _flashOk ? gc.sage : gc.warn),
      ),
    );
  }

  Widget _statusDot(GymColors gc, WearLinkStatus status) {
    final color = switch (status.state) {
      WearLinkState.connected => gc.sage,
      WearLinkState.error => gc.danger,
      WearLinkState.connecting || WearLinkState.pairing => gc.accent,
      _ => gc.textTertiary,
    };
    final name = status.deviceName.isNotEmpty ? status.deviceName : status.address;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 5),
        Flexible(
          child: Text(
            name.isEmpty ? t.wearLinkOffline : name,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: AppTheme.f(11.5, weight: FontWeight.w600, color: gc.textSecondary),
          ),
        ),
        if (_acting != null) ...[
          const SizedBox(width: 6),
          SizedBox(
            width: 10,
            height: 10,
            child: CircularProgressIndicator(strokeWidth: 1.6, color: gc.textTertiary),
          ),
        ],
      ],
    );
  }

  Widget _linkPage(GymColors gc, WearLinkStatus status) {
    final devices = _devices;
    final error = switch (status.error) {
      'permission' || 'permission_denied' => t.wearLinkPermission,
      'not_bonded' => t.wearLinkNoDevices,
      '' => '',
      final code => '${t.wearLinkOffline} ($code)',
    };
    return WearPage(children: [
      Center(child: _statusDot(gc, status)),
      const SizedBox(height: 8),
      Text(t.wearLinkBody,
          textAlign: TextAlign.center,
          maxLines: 3,
          style: AppTheme.f(12, weight: FontWeight.w500, color: gc.textSecondary, height: 1.3)),
      if (error.isNotEmpty) ...[
        const SizedBox(height: 6),
        Text(error,
            textAlign: TextAlign.center,
            style: AppTheme.f(11.5, weight: FontWeight.w600, color: gc.warn)),
      ],
      const SizedBox(height: 10),
      if (devices == null)
        WearButton(
          label: _loadingDevices ? t.wearLinkConnecting : t.wearLinkConnect,
          icon: PhosphorIconsRegular.linkSimple,
          filled: true,
          onTap: _loadingDevices ? null : _loadDevices,
        )
      else ...[
        Text(t.wearLinkChoosePhone,
            textAlign: TextAlign.center,
            style: AppTheme.f(11, weight: FontWeight.w500, color: gc.textTertiary)),
        const SizedBox(height: 6),
        if (devices.isEmpty)
          Text(t.wearLinkNoDevices,
              textAlign: TextAlign.center,
              style: AppTheme.f(12, weight: FontWeight.w600, color: gc.warn))
        else
          for (final device in devices) ...[
            WearButton(
              label: device.name,
              icon: PhosphorIconsFill.deviceMobile,
              filled: _acting == 'connect',
              onTap: _acting == null ? () => _connect(device) : null,
            ),
            const SizedBox(height: 6),
          ],
        const SizedBox(height: 2),
        WearButton(
          label: t.wearLinkRefresh,
          icon: PhosphorIconsRegular.arrowsClockwise,
          onTap: _loadDevices,
        ),
      ],
      if (status.enabled) ...[
        const SizedBox(height: 8),
        WearButton(
          label: t.wearLinkDisconnect,
          icon: PhosphorIconsRegular.plugs,
          onTap: () => _client.disconnect(),
        ),
      ],
      if (status.address.isNotEmpty) ...[
        const SizedBox(height: 8),
        WearButton(
          label: t.wearLinkForget,
          icon: PhosphorIconsRegular.linkBreak,
          onTap: () async {
            await _client.forget();
            if (mounted) setState(() {});
          },
        ),
      ],
      const SizedBox(height: 8),
      _backButton(),
    ]);
  }

  Widget _pinPage(GymColors gc, WearLinkStatus status) {
    final phone = _client.pinPrompt.value ?? '';
    return WearPage(children: [
      Text(t.wearLinkLinkedTo(phone),
          textAlign: TextAlign.center,
          style: AppTheme.f(13, weight: FontWeight.w700, color: gc.text)),
      const SizedBox(height: 6),
      Text(t.wearLinkPinTitle,
          textAlign: TextAlign.center,
          style: AppTheme.f(11.5, weight: FontWeight.w500, color: gc.textSecondary)),
      const SizedBox(height: 8),
      TextField(
        controller: _pin,
        keyboardType: TextInputType.number,
        inputFormatters: [FilteringTextInputFormatter.digitsOnly, LengthLimitingTextInputFormatter(6)],
        textAlign: TextAlign.center,
        style: AppTheme.f(22, weight: FontWeight.w800, color: gc.text, letterSpacing: 4),
        decoration: InputDecoration(
          hintText: t.wearLinkPinHint,
          hintStyle: AppTheme.f(12, weight: FontWeight.w500, color: gc.textTertiary),
          filled: true,
          fillColor: gc.bgRaised,
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(18), borderSide: BorderSide.none),
          isDense: true,
          contentPadding: const EdgeInsets.symmetric(vertical: 12, horizontal: 10),
        ),
        onSubmitted: (_) => _submitPin(),
      ),
      const SizedBox(height: 10),
      WearButton(
        label: t.wearLinkConfirm,
        icon: PhosphorIconsBold.check,
        filled: true,
        onTap: _acting == null ? _submitPin : null,
      ),
      const SizedBox(height: 6),
      WearButton(
        label: t.cancel,
        icon: PhosphorIconsRegular.x,
        onTap: _acting == null
            ? () async {
                await _client.disconnect();
                if (mounted) setState(() {});
              }
            : null,
      ),
      _flashLine,
    ]);
  }

  Widget _workoutPage(GymColors gc, WearLinkStatus status, RemoteWorkout? workout) {
    if (workout == null || !workout.hasWorkout) {
      return WearPage(children: [
        Center(child: _statusDot(gc, status)),
        const SizedBox(height: 10),
        Text(t.wearLinkNoWorkout,
            textAlign: TextAlign.center,
            style: AppTheme.f(13, weight: FontWeight.w600, color: gc.textSecondary)),
        const SizedBox(height: 10),
        WearButton(
          label: t.wearLinkRefresh,
          icon: PhosphorIconsRegular.arrowsClockwise,
          filled: true,
          onTap: () => _client.requestState(),
        ),
        _flashLine,
        const SizedBox(height: 8),
        _backButton(),
      ]);
    }
    final exercises = workout.exercises;
    final exIndex = workout.currentIndex.clamp(0, exercises.isEmpty ? 0 : exercises.length - 1);
    final exercise = exercises.isEmpty ? null : exercises[exIndex];
    final pending = exercise?.pendingIndex ?? -1;
    final set = exercise != null && pending >= 0 ? exercise.sets[pending] : null;
    final rest = workout.rest;
    final restLeft = rest?.remaining() ?? Duration.zero;
    final resting = rest != null && (rest.frozenSeconds != null || restLeft > Duration.zero);
    final previous = exercise == null || pending <= 0 ? null : _previousSet(exercise, pending);

    return WearPage(children: [
      Center(child: _statusDot(gc, status)),
      const SizedBox(height: 6),
      Text(
        workout.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: AppTheme.f(12, weight: FontWeight.w700, color: gc.textSecondary),
      ),
      const SizedBox(height: 2),
      Center(
        child: Text(
          '${exIndex + 1}/${exercises.length}  ·  ${t.wearLinkSets(workout.doneSets, workout.totalSets)}',
          style: AppTheme.f(11, weight: FontWeight.w600, color: gc.textTertiary),
        ),
      ),
      const SizedBox(height: 6),
      if (resting) ...[
        _restCard(gc, rest, restLeft),
        const SizedBox(height: 8),
      ],
      if (exercise != null)
        Text(
          t.catalogName(exercise.id, exercise.name),
          maxLines: 2,
          textAlign: TextAlign.center,
          overflow: TextOverflow.ellipsis,
          style: AppTheme.f(15, weight: FontWeight.w800, color: gc.text, height: 1.15),
        ),
      if (exercise?.linkedNext == true) ...[
        const SizedBox(height: 2),
        Row(mainAxisAlignment: MainAxisAlignment.center, children: [
          Icon(PhosphorIconsBold.link, size: 10, color: gc.brass),
          const SizedBox(width: 4),
          Text(t.superset, style: AppTheme.f(10, weight: FontWeight.w700, color: gc.brass)),
        ]),
      ],
      const SizedBox(height: 8),
      if (workout.finished)
        _summaryCard(gc, workout)
      else if (set != null && exercise != null) ...[
        _setCard(gc, exercise.id, exercise.sets, pending, set),
        const SizedBox(height: 6),
        if (previous != null)
          Text(
            '${t.wearLinkPrev}: ${_setValue(previous, exercise.id)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            textAlign: TextAlign.center,
            style: AppTheme.f(10.5, weight: FontWeight.w600, color: gc.textTertiary),
          ),
        const SizedBox(height: 6),
        ..._editors(gc, exIndex, pending, set, exercise.id),
        const SizedBox(height: 6),
        _rpeRow(gc, exIndex, pending, set),
        const SizedBox(height: 8),
        WearButton(
          label: _acting == 'set' ? t.wearLinkWaiting : t.wearLinkComplete,
          icon: PhosphorIconsBold.check,
          filled: true,
          onTap: _acting == null ? () => _run('set', () => _client.completeSet(exIndex, pending)) : null,
        ),
      ] else
        WearButton(
          label: t.wearLinkRefresh,
          icon: PhosphorIconsRegular.arrowsClockwise,
          onTap: _acting == null ? () => _client.requestState() : null,
        ),
      if (!workout.finished) ...[
        const SizedBox(height: 8),
        Row(children: [
          Expanded(
            child: WearIconButton(
              icon: PhosphorIconsBold.caretLeft,
              label: t.back,
              onTap: _acting == null && exIndex > 0
                  ? () => _run('nav', () => _client.goToExercise(exIndex - 1))
                  : null,
            ),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: WearIconButton(
              icon: PhosphorIconsBold.caretRight,
              label: t.nextExercise,
              onTap: _acting == null && exIndex < exercises.length - 1
                  ? () => _run('nav', () => _client.goToExercise(exIndex + 1))
                  : null,
            ),
          ),
        ]),
        const SizedBox(height: 6),
        WearButton(
          label: workout.status == RemoteStatus.paused ? t.resumeWorkout : t.pauseWorkout,
          icon: workout.status == RemoteStatus.paused ? PhosphorIconsFill.play : PhosphorIconsFill.pause,
          onTap: _acting == null
              ? () => _run(
                    'pause',
                    () => workout.status == RemoteStatus.paused
                        ? _client.resumeWorkout()
                        : _client.pause(),
                  )
              : null,
        ),
      ],
      _flashLine,
      const SizedBox(height: 8),
      WearButton(
        label: t.wearLinkDisconnect,
        icon: PhosphorIconsRegular.plugs,
        onTap: () => _client.disconnect(),
      ),
      const SizedBox(height: 6),
      _backButton(),
    ]);
  }

  Widget _backButton() => WearButton(
        label: t.back,
        icon: PhosphorIconsBold.caretLeft,
        onTap: () => fit.popRoute(fallback: 'home'),
      );

  Widget _restCard(GymColors gc, RemoteRest rest, Duration left) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(color: gc.bgRaised, borderRadius: BorderRadius.circular(22)),
      child: Column(children: [
        Text(
          rest.switchSides ? t.switchSides : t.rest,
          style: AppTheme.f(10.5, weight: FontWeight.w700, color: gc.textSecondary),
        ),
        Text(
          clockLabel(left.inSeconds),
          style: AppTheme.f(28, weight: FontWeight.w800, color: gc.text, height: 1.1),
        ),
        const SizedBox(height: 6),
        Row(children: [
          Expanded(child: _tiny(gc, '-15', () => _run('rest', () => _client.nudgeRest(-15), confirm: false))),
          const SizedBox(width: 4),
          Expanded(
            child: _tiny(gc, t.skip, () => _run('rest', () => _client.skipRest(), confirm: false), strong: true),
          ),
          const SizedBox(width: 4),
          Expanded(child: _tiny(gc, '+15', () => _run('rest', () => _client.nudgeRest(15), confirm: false))),
        ]),
      ]),
    );
  }

  Widget _summaryCard(GymColors gc, RemoteWorkout workout) {
    final summary = workout.summary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: gc.bgRaised, borderRadius: BorderRadius.circular(22)),
      child: Column(children: [
        Icon(PhosphorIconsFill.trophy, size: 22, color: gc.ember),
        const SizedBox(height: 4),
        Text(t.wearLinkSessionDone,
            textAlign: TextAlign.center,
            style: AppTheme.f(13, weight: FontWeight.w700, color: gc.text)),
        if (summary != null) ...[
          const SizedBox(height: 4),
          Text(
            '${summary.sets} · ${fit.weightValue(summary.volumeKg.toDouble())} ${fit.units}',
            style: AppTheme.f(11.5, weight: FontWeight.w600, color: gc.textSecondary),
          ),
        ],
      ]),
    );
  }

  Widget _setCard(GymColors gc, String exerciseId, List<RemoteSet> sets, int pending, RemoteSet set) {
    final kind = switch (set.kind) {
      SetKind.warmup => t.setTypeWarmup,
      SetKind.drop => t.setTypeDrop,
      SetKind.failure => t.setTypeFailure,
      SetKind.restPause => t.setTypeRestPause,
      SetKind.cluster => t.setTypeCluster,
      SetKind.normal => '',
    };
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(color: gc.bgRaised, borderRadius: BorderRadius.circular(22)),
      child: Column(children: [
        Text(
          '${t.wearLinkSet} ${pending + 1}/${sets.length}${kind.isEmpty ? '' : ' · $kind'}',
          style: AppTheme.f(10.5, weight: FontWeight.w700, color: gc.textSecondary),
        ),
        const SizedBox(height: 2),
        Text(
          _setValue(set, exerciseId),
          textAlign: TextAlign.center,
          style: AppTheme.f(20, weight: FontWeight.w800, color: gc.text, height: 1.1),
        ),
        if (set.half) ...[
          const SizedBox(height: 2),
          Text('1/2', style: AppTheme.f(10, weight: FontWeight.w700, color: gc.warn)),
        ],
      ]),
    );
  }

  RemoteSet? _previousSet(RemoteExercise exercise, int pending) {
    for (var i = pending - 1; i >= 0; i--) {
      if (exercise.sets[i].done) return exercise.sets[i];
    }
    return null;
  }

  String _setValue(RemoteSet set, String exerciseId) {
    if (set.km != null) {
      return '${fit.distanceLabelFor(exerciseId, set.km!)} · ${clockLabel(set.sec ?? 0)}';
    }
    if (set.sec != null) return clockLabel(set.sec!);
    final reps = set.repsRight == null ? '${set.reps}' : '${set.reps}/${set.repsRight}';
    return '$reps × ${fit.weightValue(set.weight)} ${fit.units}';
  }

  List<Widget> _editors(GymColors gc, int exIndex, int pending, RemoteSet set, String exerciseId) {
    if (set.km != null) {
      return [
        _stepper(
          gc,
          fit.distanceUnitFor(exerciseId).toUpperCase(),
          fit.distanceValueFor(exerciseId, set.km!),
          () => _run(
            'km',
            () => _client.updateSet(exIndex, pending, km: (set.km! - 0.1).clamp(0.0, 1000.0)),
          ),
          () => _run(
            'km',
            () => _client.updateSet(exIndex, pending, km: (set.km! + 0.1).clamp(0.0, 1000.0)),
          ),
        ),
        const SizedBox(height: 6),
        _stepper(
          gc,
          t.timeCol,
          clockLabel(set.sec ?? 0),
          () => _run('sec',
              () => _client.updateSet(exIndex, pending, sec: ((set.sec ?? 0) - 60).clamp(0, 86400))),
          () => _run('sec',
              () => _client.updateSet(exIndex, pending, sec: ((set.sec ?? 0) + 60).clamp(0, 86400))),
        ),
      ];
    }
    if (set.sec != null) {
      return [
        _stepper(
          gc,
          t.timeCol,
          clockLabel(set.sec!),
          () => _run('sec',
              () => _client.updateSet(exIndex, pending, sec: (set.sec! - 15).clamp(0, 86400))),
          () => _run('sec',
              () => _client.updateSet(exIndex, pending, sec: (set.sec! + 15).clamp(0, 86400))),
        ),
      ];
    }
    final step = fit.units == 'lb' ? 5 / 2.2046226218487757 : 2.5;
    return [
      _stepper(
        gc,
        t.repsCol,
        '${set.reps}',
        () => _run('reps', () => _client.updateSet(exIndex, pending, reps: (set.reps - 1).clamp(0, 999))),
        () => _run('reps', () => _client.updateSet(exIndex, pending, reps: (set.reps + 1).clamp(0, 999))),
      ),
      const SizedBox(height: 6),
      _stepper(
        gc,
        fit.units.toUpperCase(),
        fit.weightValue(set.weight),
        () => _run(
          'weight',
          () => _client.updateSet(
            exIndex,
            pending,
            weight: _roundKg((set.weight - step).clamp(0.0, 1000.0)),
          ),
        ),
        () => _run(
          'weight',
          () => _client.updateSet(
            exIndex,
            pending,
            weight: _roundKg((set.weight + step).clamp(0.0, 1000.0)),
          ),
        ),
      ),
    ];
  }

  Widget _rpeRow(GymColors gc, int exIndex, int pending, RemoteSet set) {
    return Column(children: [
      Text('RPE', style: AppTheme.f(10, weight: FontWeight.w700, color: gc.textTertiary)),
      const SizedBox(height: 4),
      Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          for (final value in const [6, 7, 8, 9, 10]) ...[
            if (value != 6) const SizedBox(width: 3),
            Expanded(
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: _acting == null
                    ? () => _run(
                          'rpe',
                          () => _client.updateSet(
                            exIndex,
                            pending,
                            rpe: value.toDouble(),
                            clearRpe: set.rpe == value.toDouble(),
                          ),
                          confirm: false,
                        )
                    : null,
                child: Container(
                  height: 32,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: set.rpe == value.toDouble() ? gc.text : gc.bgRaised,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Text(
                    '$value',
                    style: AppTheme.f(12, weight: FontWeight.w700,
                        color: set.rpe == value.toDouble() ? gc.bg : gc.textSecondary),
                  ),
                ),
              ),
            ),
          ],
        ],
      ),
    ]);
  }

  Widget _stepper(GymColors gc, String label, String value, VoidCallback onDec, VoidCallback onInc) {
    return Row(children: [
      _round(gc, PhosphorIconsBold.minus, onDec, '−$label'),
      Expanded(
        child: Column(children: [
          Text(label, style: AppTheme.f(9.5, weight: FontWeight.w700, color: gc.textTertiary)),
          Text(value, style: AppTheme.f(15, weight: FontWeight.w800, color: gc.text)),
        ]),
      ),
      _round(gc, PhosphorIconsBold.plus, onInc, '+$label'),
    ]);
  }

  Widget _round(GymColors gc, IconData icon, VoidCallback onTap, String label) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _acting == null ? onTap : null,
        child: Container(
          width: 42,
          height: 42,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: gc.bgRaised2, borderRadius: BorderRadius.circular(16)),
          child: Icon(
            icon,
            size: 16,
            color: _acting == null ? gc.text : gc.textTertiary,
          ),
        ),
      ),
    );
  }

  Widget _tiny(GymColors gc, String label, VoidCallback onTap, {bool strong = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _acting == null ? onTap : null,
      child: Container(
        height: 36,
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: strong ? gc.text : gc.bgRaised2,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Text(
          label,
          style: AppTheme.f(11, weight: FontWeight.w700, color: strong ? gc.bg : gc.textSecondary),
        ),
      ),
    );
  }

  double _roundKg(double value) => (value * 100).round() / 100;
}
