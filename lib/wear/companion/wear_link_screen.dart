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
import 'wear_companion_clock.dart';
import 'wear_dashboard.dart';
import 'wear_exercise_guide.dart';
import 'wear_weight_picker.dart';

/// Watch-side companion screen. The current workout remains usable from the
/// durable watch journal while the phone is temporarily unavailable.
class WearLinkScreen extends StatefulWidget {
  const WearLinkScreen({super.key, this.embedded = true});

  final bool embedded;

  @override
  State<WearLinkScreen> createState() => _WearLinkScreenState();
}

class _WearLinkScreenState extends State<WearLinkScreen> with WidgetsBindingObserver {
  final WearLinkClient _client = WearLinkClient.instance;
  String _pin = '';

  Timer? _ticker;
  final _restSeconds = ValueNotifier<int?>(null);
  bool _foreground = true;
  Timer? _flashTimer;
  List<WearBondedDevice>? _devices;
  bool _loadingDevices = false;
  String? _acting;
  String? _flash;
  bool _flashOk = true;
  bool _confirmFinish = false;
  bool _showHome = false;
  bool _showLink = false;
  WearSection _section = WearSection.home;
  static const _openChannel = MethodChannel('gymmane/open');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _client.attach();
    _client.status.addListener(_onValue);
    _client.workout.addListener(_onValue);
    _client.pinPrompt.addListener(_onValue);
    _client.finishing.addListener(_onValue);
    _client.rejectedEdits.addListener(_onRejectedEdit);
    _client.home.addListener(_onValue);
    if (!widget.embedded) {
      _openChannel.setMethodCallHandler((call) async {
        if (call.method == 'open') _openTile(call.arguments);
      });
      unawaited(_takeTile());
    }
    _updateRest();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _client.resume();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _client.status.removeListener(_onValue);
    _client.workout.removeListener(_onValue);
    _client.pinPrompt.removeListener(_onValue);
    _client.finishing.removeListener(_onValue);
    _client.rejectedEdits.removeListener(_onRejectedEdit);
    _client.home.removeListener(_onValue);
    if (!widget.embedded) _openChannel.setMethodCallHandler(null);
    _ticker?.cancel();
    _restSeconds.dispose();
    _flashTimer?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
    _updateRest();
    if (_foreground) {
      unawaited(_client.resume());
    }
  }

  void _onValue() {
    if (!mounted) return;
    if (_client.workout.value?.hasWorkout != true) _confirmFinish = false;
    _updateRest();
    setState(() {});
  }

  void _onRejectedEdit() {
    if (mounted) _showFlash(t.wearLinkNotSaved, false);
  }

  Future<void> _takeTile() async {
    try {
      _openTile(await _openChannel.invokeMethod<String>('take'));
    } on MissingPluginException {
      // Non-Android previews do not expose tile launches.
    }
  }

  void _openTile(Object? route) {
    if (!mounted || (route != 'wear/workout' && route != 'wear/nutrition')) return;
    Navigator.of(context).popUntil((route) => route.isFirst);
    setState(() {
      _showLink = false;
      _showHome = route == 'wear/nutrition';
      _section = _showHome ? WearSection.nutrition : WearSection.home;
    });
  }

  Future<void> _homeAction(String action, Map<String, dynamic> args) async {
    if (_acting != null) return;
    setState(() => _acting = 'home');
    final ack = await _client.homeCommand(action, args: args);
    if (!mounted) return;
    setState(() {
      _acting = null;
      if (ack.ok && (action == 'startRoutine' || action == 'startExercises')) {
        _showHome = false;
        _section = WearSection.home;
      }
    });
    if (!ack.ok) {
      _showFlash(ack.code == 'active_session' ? t.continueWorkout : _ackMessage(ack), false);
    } else if (ack.code != 'queued' && action != 'startRoutine' && action != 'startExercises') {
      _showFlash(t.wearLinkSaved, true);
    }
  }

  void _updateRest({bool tick = false}) {
    final rest = _client.workout.value?.rest;
    final remaining = rest?.remaining().inMilliseconds ?? 0;
    final left = (remaining / 1000).ceil();
    if (tick && left == 0 && (_restSeconds.value ?? 0) > 0) {
      unawaited(HapticFeedback.heavyImpact());
    }
    _restSeconds.value = left > 0 || rest?.frozenSeconds != null ? left : null;
    final needsTicks = _foreground && !_client.finishing.value && rest?.frozenSeconds == null && left > 0;
    if (needsTicks) {
      _ticker ??= Timer.periodic(const Duration(seconds: 1), (_) => _updateRest(tick: true));
    } else {
      _ticker?.cancel();
      _ticker = null;
    }
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

  Future<void> _run(String key, Future<WearAck> Function() action, {bool confirm = true}) async {
    if (_acting != null) return;
    HapticFeedback.selectionClick();
    setState(() => _acting = key);
    final ack = await action();
    if (!mounted) return;
    setState(() => _acting = null);
    if (ack.ok) {
      if (confirm) HapticFeedback.lightImpact();
    } else {
      HapticFeedback.heavyImpact();
      _showFlash(_ackMessage(ack), false);
    }
  }

  Future<void> _queueEdit(Future<WearAck> Function() action) async {
    HapticFeedback.selectionClick();
    final ack = await action();
    if (!mounted || ack.ok) return;
    HapticFeedback.heavyImpact();
    _showFlash(_ackMessage(ack), false);
  }

  String _ackMessage(WearAck ack) => switch (ack.code) {
    'conflict' => t.wearLinkNotSaved,
    'offline' || 'timeout' => t.wearLinkOffline,
    'no_session' => t.wearLinkNoWorkout,
    'no_pending' => t.wearLinkNoWorkout,
    'finishing' => t.wearLinkWaiting,
    _ => '${t.wearLinkNotSaved} (${ack.code})',
  };

  Future<void> _finishWorkout() async {
    if (_acting != null) return;
    setState(() {
      _confirmFinish = false;
      _acting = 'finish';
    });
    final ack = await _client.finishAndDiscard();
    if (!mounted) return;
    setState(() => _acting = null);
    if (ack.ok) {
      HapticFeedback.lightImpact();
      _showFlash(_client.status.value.connected ? t.wearLinkWaiting : t.wearLinkOffline, true);
    } else {
      HapticFeedback.heavyImpact();
      _showFlash(_ackMessage(ack), false);
    }
  }

  Future<void> _completeWorkout() async {
    if (_acting != null) return;
    setState(() => _acting = 'finish');
    final ack = await _client.finishAndSave();
    if (!mounted) return;
    setState(() => _acting = null);
    if (ack.ok) {
      HapticFeedback.lightImpact();
      if (widget.embedded) fit.popRoute(fallback: 'home');
    } else {
      HapticFeedback.heavyImpact();
      _showFlash(_ackMessage(ack), false);
    }
  }

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
    final ok = await _client.submitPin(_pin);
    if (!mounted) return;
    setState(() => _acting = null);
    if (!ok) _showFlash(t.wearLinkPinWrong, false);
  }

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    final status = _client.status.value;
    final workout = _client.workout.value;
    if (!widget.embedded) {
      final pin = _client.pinPrompt.value != null;
      final link = _showLink && !status.connected;
      final training = !_showHome && workout?.hasWorkout == true;
      final canGoBack = pin || link || training || _section != WearSection.home;
      final content = pin
          ? _pinPage(gc, status)
          : link
          ? _linkPage(gc, status)
          : training
          ? _workoutPage(gc, status, workout)
          : _dashboard(gc, status, workout);
      return PopScope<Object?>(
        canPop: !canGoBack,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop || !canGoBack) return;
          if (pin) unawaited(_client.disconnect());
          if (_confirmFinish) {
            setState(() => _confirmFinish = false);
          } else {
            _goHome();
          }
        },
        child: Column(
          children: [
            WearCompanionClock(workout: workout),
            Expanded(child: content),
          ],
        ),
      );
    }
    if (!status.supported) {
      return WearPage(children: [Text(t.wearLinkUnsupported, textAlign: TextAlign.center)]);
    }
    if (_client.pinPrompt.value != null) return _pinPage(gc, status);
    if ((!status.enabled || !status.connected) && !(_client.workout.value?.hasWorkout ?? false)) {
      return _linkPage(gc, status);
    }
    return _workoutPage(gc, status, _client.workout.value);
  }

  Widget _dashboard(GymColors gc, WearLinkStatus status, RemoteWorkout? workout) => WearDashboard(
        data: _client.home.value,
        section: _section,
        connected: status.connected,
        busy: _acting != null,
        workoutActive: workout?.hasWorkout == true,
        setSection: (next) => setState(() => _section = next),
        action: _homeAction,
        header: _statusDot(gc, status),
        feedback: _flashLine,
        openWorkout: () => setState(() => _showHome = false),
        openLink: () => setState(() => _showLink = true),
        pendingNutrition: _client.nutritionPending.value,
      );

  void _goHome() => setState(() {
    _showHome = true;
    _showLink = false;
    _section = WearSection.home;
  });

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
    return Semantics(
      label: 'GymMane',
      value: status.connected ? t.wearLinkPhoneConnectedTo('GymMane') : t.wearLinkOffline,
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
        Text(
          'GymMane',
          style: AppTheme.f(11.5, weight: FontWeight.w700, color: gc.textSecondary),
        ),
        const SizedBox(width: 6),
        Container(
          width: 7,
          height: 7,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        ],
      ),
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
    return WearPage(
      children: [
        Center(child: _statusDot(gc, status)),
        const SizedBox(height: 8),
        Text(
          t.wearLinkBody,
          textAlign: TextAlign.center,
          maxLines: 3,
          style: AppTheme.f(12, weight: FontWeight.w500, color: gc.textSecondary, height: 1.3),
        ),
        if (error.isNotEmpty) ...[
          const SizedBox(height: 6),
          Text(
            error,
            textAlign: TextAlign.center,
            style: AppTheme.f(11.5, weight: FontWeight.w600, color: gc.warn),
          ),
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
          Text(
            t.wearLinkChoosePhone,
            textAlign: TextAlign.center,
            style: AppTheme.f(11, weight: FontWeight.w500, color: gc.textTertiary),
          ),
          const SizedBox(height: 6),
          if (devices.isEmpty)
            Text(
              t.wearLinkNoDevices,
              textAlign: TextAlign.center,
              style: AppTheme.f(12, weight: FontWeight.w600, color: gc.warn),
            )
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
      ],
    );
  }

  Widget _pinPage(GymColors gc, WearLinkStatus status) {
    final phone = _client.pinPrompt.value ?? '';
    return WearPage(
      children: [
        Text(
          t.wearLinkLinkedTo(phone),
          textAlign: TextAlign.center,
          style: AppTheme.f(13, weight: FontWeight.w700, color: gc.text),
        ),
        const SizedBox(height: 6),
        Text(
          t.wearLinkPinTitle,
          textAlign: TextAlign.center,
          style: AppTheme.f(11.5, weight: FontWeight.w500, color: gc.textSecondary),
        ),
        const SizedBox(height: 8),
        Text(
          _pin.isEmpty ? t.wearLinkPinHint : '●' * _pin.length,
          textAlign: TextAlign.center,
          style: AppTheme.f(20, weight: FontWeight.w800, color: gc.text, letterSpacing: 4),
        ),
        for (final row in const [
          ['1', '2', '3'],
          ['4', '5', '6'],
          ['7', '8', '9'],
          ['', '0', '⌫'],
        ])
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              for (final key in row)
                SizedBox(
                  width: 48,
                  height: 42,
                  child: key.isEmpty
                      ? const SizedBox.shrink()
                      : TextButton(
                          onPressed: _acting != null
                              ? null
                              : () => setState(() {
                                  if (key == '⌫') {
                                    if (_pin.isNotEmpty) _pin = _pin.substring(0, _pin.length - 1);
                                  } else if (_pin.length < 6) {
                                    _pin += key;
                                  }
                                }),
                          child: Text(
                            key,
                            style: AppTheme.f(17, weight: FontWeight.w700, color: gc.text),
                          ),
                        ),
                ),
            ],
          ),
        const SizedBox(height: 10),
        WearButton(
          label: t.wearLinkConfirm,
          icon: PhosphorIconsBold.check,
          filled: true,
          onTap: _acting == null && _pin.length == 6 ? _submitPin : null,
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
      ],
    );
  }

  Widget _workoutPage(GymColors gc, WearLinkStatus status, RemoteWorkout? workout) {
    if (_client.finishing.value) return _finishingPage(gc, status, workout);
    if (_confirmFinish) return _discardConfirmPage(gc);
    if (workout == null || !workout.hasWorkout) {
      return WearPage(
        children: [
          Center(child: _statusDot(gc, status)),
          const SizedBox(height: 10),
          Text(
            workout == null ? t.wearLinkConnecting : t.wearLinkNoWorkout,
            textAlign: TextAlign.center,
            style: AppTheme.f(13, weight: FontWeight.w600, color: gc.textSecondary),
          ),
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
        ],
      );
    }
    final exercises = workout.exercises;
    final exIndex = workout.currentIndex.clamp(0, exercises.isEmpty ? 0 : exercises.length - 1);
    final exercise = exercises.isEmpty ? null : exercises[exIndex];
    final pending = exercise?.pendingIndex ?? -1;
    final set = exercise != null && pending >= 0 ? exercise.sets[pending] : null;
    final rest = workout.rest;
    final previous = exercise == null || pending <= 0 ? null : _previousSet(exercise, pending);

    return WearPage(
      scaleEdges: false,
      children: [
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
        if (exercise != null)
          Material(
            color: gc.bgRaised,
            borderRadius: BorderRadius.circular(22),
            child: InkWell(
              borderRadius: BorderRadius.circular(22),
              onTap: () => showWearExerciseGuide(
                context,
                id: exercise.id,
                name: exercise.name,
                customSteps: exercise.guide,
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(minHeight: 44),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Row(
                    children: [
                      Expanded(
                        child: Text(
                          t.catalogName(exercise.id, exercise.name),
                          maxLines: 2,
                          textAlign: TextAlign.center,
                          overflow: TextOverflow.ellipsis,
                          style: AppTheme.f(14, weight: FontWeight.w800, color: gc.text, height: 1.15),
                        ),
                      ),
                      Tooltip(
                        message: t.howTo,
                        child: Icon(PhosphorIconsRegular.info, size: 14, color: gc.textSecondary),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        if (exercise?.linkedNext == true) ...[
          const SizedBox(height: 2),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(PhosphorIconsBold.link, size: 10, color: gc.brass),
              const SizedBox(width: 4),
              Text(
                t.superset,
                style: AppTheme.f(10, weight: FontWeight.w700, color: gc.brass),
              ),
            ],
          ),
        ],
        const SizedBox(height: 8),
        if (rest != null)
          ValueListenableBuilder<int?>(
            valueListenable: _restSeconds,
            builder: (context, left, _) => left == null
                ? const SizedBox.shrink()
                : Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _restCard(gc, rest, Duration(seconds: left)),
                  ),
          ),
        if (workout.finished)
          _summaryCard(gc, workout)
        else if (set != null && exercise != null) ...[
          _setCard(gc, exercise, pending, set),
          const SizedBox(height: 8),
          WearButton(
            label: t.wearLinkComplete,
            icon: PhosphorIconsBold.check,
            filled: true,
            onTap: _acting == null ? () => _run('set', () => _client.completeSet(exIndex, pending)) : null,
          ),
          const SizedBox(height: 6),
          if (previous != null)
            Text(
              '${t.wearLinkPrev}: ${_setValue(previous, exercise)}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
              style: AppTheme.f(10.5, weight: FontWeight.w600, color: gc.textTertiary),
            ),
          const SizedBox(height: 6),
          ..._editors(gc, exIndex, pending, set, exercise),
          const SizedBox(height: 6),
          if (workout.effortMode.isNotEmpty) _rpeRow(gc, exIndex, pending, set, workout.effortMode),
        ] else
          WearButton(
            label: t.wearLinkRefresh,
            icon: PhosphorIconsRegular.arrowsClockwise,
            onTap: _acting == null ? () => _client.requestState() : null,
          ),
        if (!workout.finished) ...[
          const SizedBox(height: 8),
          Row(
            children: [
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
            ],
          ),
          const SizedBox(height: 6),
          WearButton(
            label: workout.status == RemoteStatus.paused ? t.resumeWorkout : t.pauseWorkout,
            icon: workout.status == RemoteStatus.paused ? PhosphorIconsFill.play : PhosphorIconsFill.pause,
            onTap: _acting == null
                ? () => _run(
                    'pause',
                    () => workout.status == RemoteStatus.paused ? _client.resumeWorkout() : _client.pause(),
                  )
                : null,
          ),
          const SizedBox(height: 6),
          WearButton(
            label: t.finishSession,
            icon: PhosphorIconsBold.flagCheckered,
            filled: true,
            onTap: _acting == null ? _completeWorkout : null,
          ),
          const SizedBox(height: 6),
          WearButton(
            label: t.discard,
            icon: PhosphorIconsRegular.trash,
            color: gc.danger,
            onTap: _acting == null ? () => setState(() => _confirmFinish = true) : null,
          ),
        ],
        _flashLine,
        const SizedBox(height: 6),
        _backButton(),
      ],
    );
  }

  Widget _backButton() => WearButton(
    label: widget.embedded ? t.back : t.home,
    icon: PhosphorIconsBold.caretLeft,
    onTap: widget.embedded ? () => fit.popRoute(fallback: 'home') : _goHome,
  );

  Widget _discardConfirmPage(GymColors gc) {
    return WearPage(
      children: [
        Icon(PhosphorIconsBold.warningCircle, size: 30, color: gc.danger),
        const SizedBox(height: 8),
        Text(
          t.discardTitle,
          textAlign: TextAlign.center,
          style: AppTheme.f(15, weight: FontWeight.w800, color: gc.text, height: 1.15),
        ),
        const SizedBox(height: 4),
        Text(
          t.discardBody,
          textAlign: TextAlign.center,
          style: AppTheme.f(11.5, weight: FontWeight.w500, color: gc.textSecondary),
        ),
        const SizedBox(height: 10),
        WearButton(
          label: t.discard,
          icon: PhosphorIconsRegular.trash,
          filled: true,
          color: gc.danger,
          onTap: _acting == null ? _finishWorkout : null,
        ),
        const SizedBox(height: 6),
        WearButton(
          label: t.cancelCaps,
          onTap: _acting == null ? () => setState(() => _confirmFinish = false) : null,
        ),
      ],
    );
  }

  Widget _finishingPage(GymColors gc, WearLinkStatus status, RemoteWorkout? workout) {
    final connected = status.connected;
    return WearPage(
      children: [
        Center(child: _statusDot(gc, status)),
        const SizedBox(height: 10),
        Icon(PhosphorIconsBold.flagCheckered, size: 28, color: gc.brass),
        const SizedBox(height: 8),
        Text(
          t.finishSession,
          textAlign: TextAlign.center,
          style: AppTheme.f(14, weight: FontWeight.w800, color: gc.text),
        ),
        const SizedBox(height: 4),
        Text(
          connected ? t.wearLinkWaiting : t.wearLinkOffline,
          textAlign: TextAlign.center,
          style: AppTheme.f(11.5, weight: FontWeight.w600, color: gc.textSecondary),
        ),
        const SizedBox(height: 4),
        Text(
          '${workout?.doneSets ?? 0}/${workout?.totalSets ?? 0}',
          style: AppTheme.f(10.5, weight: FontWeight.w600, color: gc.textTertiary),
        ),
        _flashLine,
        const SizedBox(height: 8),
        WearButton(
          label: t.wearLinkRefresh,
          icon: PhosphorIconsRegular.arrowsClockwise,
          onTap: connected ? () => _client.requestState() : null,
        ),
        const SizedBox(height: 6),
        _backButton(),
      ],
    );
  }

  Widget _restCard(GymColors gc, RemoteRest rest, Duration left) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 10),
      decoration: BoxDecoration(color: gc.bgRaised, borderRadius: BorderRadius.circular(22)),
      child: Column(
        children: [
          Text(
            rest.switchSides ? t.switchSides : t.rest,
            style: AppTheme.f(10.5, weight: FontWeight.w700, color: gc.textSecondary),
          ),
          Text(
            clockLabel(left.inSeconds),
            style: AppTheme.f(28, weight: FontWeight.w800, color: gc.text, height: 1.1),
          ),
          const SizedBox(height: 6),
          Row(
            children: [
              Expanded(
                child: _tiny(gc, '-15', () => _run('rest', () => _client.nudgeRest(-15), confirm: false)),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _tiny(
                  gc,
                  t.skip,
                  () => _run('rest', () => _client.skipRest(), confirm: false),
                  strong: true,
                ),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: _tiny(gc, '+15', () => _run('rest', () => _client.nudgeRest(15), confirm: false)),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _summaryCard(GymColors gc, RemoteWorkout workout) {
    final summary = workout.summary;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: gc.bgRaised, borderRadius: BorderRadius.circular(22)),
      child: Column(
        children: [
          Icon(PhosphorIconsFill.trophy, size: 22, color: gc.ember),
          const SizedBox(height: 4),
          Text(
            t.wearLinkSessionDone,
            textAlign: TextAlign.center,
            style: AppTheme.f(13, weight: FontWeight.w700, color: gc.text),
          ),
          if (summary != null) ...[
            const SizedBox(height: 4),
            Text(
              '${summary.sets} · ${fit.weightValue(summary.volumeKg.toDouble())} ${fit.units}',
              style: AppTheme.f(11.5, weight: FontWeight.w600, color: gc.textSecondary),
            ),
          ],
        ],
      ),
    );
  }

  Widget _setCard(GymColors gc, RemoteExercise exercise, int pending, RemoteSet set) {
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
      child: Column(
        children: [
          Text(
            '${t.wearLinkSet} ${pending + 1}/${exercise.sets.length}${kind.isEmpty ? '' : ' · $kind'}',
            style: AppTheme.f(10.5, weight: FontWeight.w700, color: gc.textSecondary),
          ),
          const SizedBox(height: 2),
          if (set.km == null && set.sec == null)
            _weightRow(gc, exercise, set)
          else
            Text(
              _setValue(set, exercise),
              textAlign: TextAlign.center,
              style: AppTheme.f(20, weight: FontWeight.w800, color: gc.text, height: 1.1),
            ),
          if (set.half) ...[
            const SizedBox(height: 2),
            Text(
              '1/2',
              style: AppTheme.f(10, weight: FontWeight.w700, color: gc.warn),
            ),
          ],
        ],
      ),
    );
  }

  RemoteSet? _previousSet(RemoteExercise exercise, int pending) {
    for (var i = pending - 1; i >= 0; i--) {
      if (exercise.sets[i].done) return exercise.sets[i];
    }
    return null;
  }

  String _weightUnit(RemoteExercise ex) => ex.weightUnit ?? fit.unitsFor(ex.id);
  String _distanceUnit(RemoteExercise ex) => ex.distanceUnit ?? fit.distanceUnitFor(ex.id);

  String _weightValue(RemoteExercise ex, double kg) {
    final value = _weightUnit(ex) == 'lb' ? kg * 2.20462 : kg;
    return fmt((value * 100).round() / 100);
  }

  Future<void> _editWeight(RemoteExercise exercise, RemoteSet set) async {
    final workoutId = _client.workout.value?.workoutId;
    final unit = _weightUnit(exercise);
    final factor = unit == 'lb' ? 2.20462 : 1.0;
    final chosen = await Navigator.of(context).push<double>(
      MaterialPageRoute(
        builder: (_) => WearWeightPicker(
          initial: _weightValue(exercise, set.weight),
          unit: unit,
          maximum: 1000 * factor,
        ),
      ),
    );
    if (!mounted || chosen == null) return;
    final live = _client.workout.value;
    if (live == null || live.workoutId != workoutId || live.finished) return;
    final exerciseIndex = live.exercises.indexWhere(
      (entry) => entry.id == exercise.id && entry.sets.any((item) => item.setId == set.setId),
    );
    if (exerciseIndex < 0) return;
    final setIndex = live.exercises[exerciseIndex].sets.indexWhere((item) => item.setId == set.setId);
    await _queueEdit(() => _client.updateSet(exerciseIndex, setIndex, weight: chosen / factor));
  }

  Widget _weightRow(GymColors gc, RemoteExercise exercise, RemoteSet set) {
    final reps = set.repsRight == null ? '${set.reps}' : '${set.reps}/${set.repsRight}';
    final style = AppTheme.f(18, weight: FontWeight.w800, color: gc.text);
    return Wrap(
      alignment: WrapAlignment.center,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Text('$reps ×', style: style),
        TextButton(
          onPressed: () => _editWeight(exercise, set),
          child: Text('${_weightValue(exercise, set.weight)} ${_weightUnit(exercise)}', style: style),
        ),
      ],
    );
  }

  String _distanceValue(RemoteExercise ex, double km) {
    final value = _distanceUnit(ex) == 'mi' ? km / 1.609344 : km;
    return fmt((value * 100).round() / 100);
  }

  String _setValue(RemoteSet set, RemoteExercise exercise) {
    if (set.km != null) {
      return '${_distanceValue(exercise, set.km!)} ${_distanceUnit(exercise)} · ${clockLabel(set.sec ?? 0)}';
    }
    if (set.sec != null) return clockLabel(set.sec!);
    final reps = set.repsRight == null ? '${set.reps}' : '${set.reps}/${set.repsRight}';
    return '$reps × ${_weightValue(exercise, set.weight)} ${_weightUnit(exercise)}';
  }

  List<Widget> _editors(GymColors gc, int exIndex, int pending, RemoteSet set, RemoteExercise exercise) {
    if (set.km != null) {
      final delta = _distanceUnit(exercise) == 'mi' ? 0.1609344 : 0.1;
      return [
        _stepper(
          gc,
          _distanceUnit(exercise).toUpperCase(),
          _distanceValue(exercise, set.km!),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'km', delta: -delta)),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'km', delta: delta)),
        ),
        const SizedBox(height: 6),
        _stepper(
          gc,
          t.timeCol,
          clockLabel(set.sec ?? 0),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'sec', delta: -60)),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'sec', delta: 60)),
        ),
      ];
    }
    if (set.sec != null) {
      return [
        _stepper(
          gc,
          t.timeCol,
          clockLabel(set.sec!),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'sec', delta: -15)),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'sec', delta: 15)),
        ),
      ];
    }
    final step = exercise.weightStepKg ?? fit.fromShownFor(exercise.id, fit.weightStepFor(exercise.id));
    return [
      _stepper(
        gc,
        set.repsRight == null ? t.repsCol : t.repsLeftCol,
        '${set.reps}',
        () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'reps', delta: -1)),
        () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'reps', delta: 1)),
      ),
      const SizedBox(height: 6),
      if (set.repsRight case final right?) ...[
        _stepper(
          gc,
          t.repsRightCol,
          '$right',
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'repsRight', delta: -1)),
          () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'repsRight', delta: 1)),
        ),
        const SizedBox(height: 6),
      ],
      _stepper(
        gc,
        _weightUnit(exercise).toUpperCase(),
        _weightValue(exercise, set.weight),
        () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'weight', delta: -step)),
        () => _queueEdit(() => _client.adjustSet(exIndex, pending, field: 'weight', delta: step)),
        onEdit: () => _editWeight(exercise, set),
      ),
    ];
  }

  Widget _rpeRow(GymColors gc, int exIndex, int pending, RemoteSet set, String mode) {
    final rir = mode == 'rir';
    final values = rir ? const [0, 1, 2, 3, 4] : const [6, 7, 8, 9, 10];
    return Column(
      children: [
        Text(
          rir ? 'RIR' : 'RPE',
          style: AppTheme.f(10, weight: FontWeight.w700, color: gc.textTertiary),
        ),
        const SizedBox(height: 4),
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            for (final value in values) ...[
              if (value != values.first) const SizedBox(width: 3),
              Expanded(
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTap: () => _queueEdit(
                    () => _client.updateSet(
                      exIndex,
                      pending,
                      rpe: (rir ? 10 - value : value).toDouble(),
                      clearRpe: set.rpe == (rir ? 10 - value : value).toDouble(),
                    ),
                  ),
                  child: Container(
                    height: 32,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: set.rpe == (rir ? 10 - value : value).toDouble() ? gc.text : gc.bgRaised,
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      '$value',
                      style: AppTheme.f(
                        12,
                        weight: FontWeight.w700,
                        color: set.rpe == (rir ? 10 - value : value).toDouble() ? gc.bg : gc.textSecondary,
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ],
        ),
      ],
    );
  }

  Widget _stepper(GymColors gc, String label, String value, VoidCallback onDec, VoidCallback onInc, {VoidCallback? onEdit}) {
    final valueLabel = Text(value, style: AppTheme.f(15, weight: FontWeight.w800, color: gc.text));
    return Row(
      children: [
        _round(gc, PhosphorIconsBold.minus, onDec, '−$label'),
        Expanded(
          child: Column(
            children: [
              Text(
                label,
                style: AppTheme.f(9.5, weight: FontWeight.w700, color: gc.textTertiary),
              ),
              if (onEdit == null)
                valueLabel
              else
                TextButton(onPressed: onEdit, child: valueLabel),
            ],
          ),
        ),
        _round(gc, PhosphorIconsBold.plus, onInc, '+$label'),
      ],
    );
  }

  Widget _round(GymColors gc, IconData icon, VoidCallback onTap, String label) {
    return Semantics(
      button: true,
      label: label,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: Container(
          width: 48,
          height: 48,
          alignment: Alignment.center,
          decoration: BoxDecoration(color: gc.bgRaised2, borderRadius: BorderRadius.circular(16)),
          child: Icon(icon, size: 16, color: gc.text),
        ),
      ),
    );
  }

  Widget _tiny(GymColors gc, String label, VoidCallback onTap, {bool strong = false}) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: _acting == null ? onTap : null,
      child: Container(
        height: 44,
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
}
