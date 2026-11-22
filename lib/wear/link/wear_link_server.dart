import 'dart:async';
import 'dart:convert';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../state/fit_state.dart';
import 'fit_wear_workout_api.dart';
import 'wear_command.dart';
import 'wear_command_executor.dart';
import 'wear_home.dart';
import 'wear_link_diagnostics.dart';
import 'wear_link_status.dart';
import 'wear_snapshot.dart';
import 'wear_workout_handoff.dart';

class WearLinkServer {
  WearLinkServer._();

  static final instance = WearLinkServer._();
  static const _channel = MethodChannel('gymmane/wearlink');

  final ValueNotifier<WearLinkStatus> status = ValueNotifier(const WearLinkStatus());

  final WearSnapshotBuilder _snapshots = WearSnapshotBuilder(
    FitWearWorkoutApi(),
    displayFor: (id) => {
      'weightUnit': fit.unitsFor(id),
      'weightStepKg': fit.fromShownFor(id, fit.weightStepFor(id)),
      'distanceUnit': fit.distanceUnitFor(id),
    },
    sideRestFor: (index, set) => fit.restsBetweenSides(index, set) ? fit.sideRestSeconds : 0,
    customStepsFor: (id) {
      final steps = fit.customExercises.where((ex) => ex.id == id).firstOrNull?.steps;
      if (steps == null || steps.isEmpty) return null;
      return [for (final step in steps.take(8)) String.fromCharCodes(step.runes.take(240))];
    },
  );
  final WearCommandExecutor _executor = WearCommandExecutor(FitWearWorkoutApi());
  final WearHomePhone _home = WearHomePhone(fit);
  final String _bootId = _randomId();
  Future<void> _commandTail = Future.value();

  int _rev = 0;
  String _lastFingerprint = '';
  WearSnapshot? _lastSnapshot;
  bool _attached = false;
  bool _applying = false;
  bool _dirtyWhileApplying = false;
  Future<int>? _pushTask;
  List<String>? _durableOperationIds;
  List<String> _durableNutritionIds = const [];

  void _captureDurableOperations() {
    final ids = fit.wearAppliedOperations.keys;
    _durableOperationIds = ids.skip(max(0, ids.length - 96)).toList();
    final nutrition = fit.wearAppliedOperations.entries.where((entry) {
      return wearNutritionActions.any((action) => entry.value.startsWith('{"action":"home/$action",'));
    }).map((entry) => entry.key).toList();
    _durableNutritionIds = nutrition.skip(max(0, nutrition.length - 96)).toList();
  }

  bool get _supported => !kIsWeb && Platform.isAndroid;

  void attach() {
    if (!_supported) {
      status.value = const WearLinkStatus();
      return;
    }
    if (_attached) return;
    _attached = true;
    wearLinkDiagnostic(
      'phone attach enabled=${fit.wearLink} route=${fit.route} '
      'hasSession=${fit.session != null}',
    );
    _channel.setMethodCallHandler(_onNativeCall);
    fit.addListener(_onFit);
    if (fit.wearLink) _start();
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'command':
        return _onCommand(call.arguments);
      case 'linkEvent':
        final raw = call.arguments;
        if (raw is Map) {
          status.value = WearLinkStatus.fromMap(raw);
          wearLinkDiagnostic(
            'phone native event state=${status.value.state.name} '
            'enabled=${status.value.enabled} error=${status.value.error}',
          );
        }
        return null;
      case 'stateRequested':
        return _lastSnapshot?.encode();
    }
    return null;
  }

  Future<Map<String, dynamic>> _onCommand(Object? raw) async {
    if (raw is! Map) throw PlatformException(code: 'bad-command', message: 'invalid arguments');
    final command = WearCommand.fromJson(Map<String, dynamic>.from(raw));
    if (command == null) throw PlatformException(code: 'bad-command', message: 'invalid command');
    final result = Completer<Map<String, dynamic>>();
    _commandTail = _commandTail.then((_) async {
      try {
        result.complete(await _executeCommand(command));
      } catch (error, stack) {
        result.completeError(error, stack);
      }
    });
    return result.future;
  }

  @visibleForTesting
  Future<Map<String, dynamic>> debugCommand(Map<String, dynamic> command) => _onCommand(command);

  @visibleForTesting
  int get debugRevision => _rev;

  Future<Map<String, dynamic>> _executeCommand(WearCommand command) async {
    if (_durableOperationIds == null) _captureDurableOperations();
    final signature = _commandSignature(command);
    final known = fit.wearAppliedOperations[command.id];
    if (known != null) {
      if (!_matchesSignature(command, known)) {
        return WearAck(id: command.id, ok: false, rev: _rev, code: 'duplicate_id').toJson();
      }
      // A previous write may have failed after the in-memory mutation. Retry
      // saving before confirming it instead of executing the mutation twice.
      await fit.persistWearTransaction();
      _captureDurableOperations();
      final rev = await _push(force: true);
      return WearAck(id: command.id, ok: true, rev: rev, code: 'ok').toJson();
    }

    wearLinkDiagnostic('phone command action=${command.action} rev=$_rev');
    _applying = true;
    try {
      final execution = fit.applyWearTransaction(() {
        final execution = command.action.startsWith('home/')
            ? _home.execute(command)
            : const {'adoptWorkout', 'uploadCompletedWorkout'}.contains(command.action)
                ? _adoptWorkout(command)
            : command.action == 'syncBatch'
                ? _executeBatch(command)
                : _executor.execute(command, _rev);
        if (execution.ok && command.action != 'requestState') {
          fit.wearAppliedOperations[command.id] = signature;
        }
        return execution;
      });
      if ((execution.ok || execution.changed) && command.action != 'requestState') {
        await fit.persistWearTransaction();
        _captureDurableOperations();
      }
      final nutrition = wearNutritionActions.any((action) => command.action == 'home/$action');
      final sendsState = execution.changed || command.action == 'requestState' || (nutrition && execution.ok);
      final rev = sendsState ? await _push(force: true) : _rev;
      final ack = WearAck(
        id: command.id,
        ok: execution.ok,
        rev: rev,
        code: execution.code,
        message: execution.message,
      );
      wearLinkDiagnostic(
        'phone command result action=${command.action} '
        'ok=${ack.ok} code=${ack.code} rev=${ack.rev}',
      );
      return ack.toJson();
    } finally {
      _applying = false;
      if (_dirtyWhileApplying) {
        _dirtyWhileApplying = false;
        _push();
      }
    }
  }

  WearExecution _adoptWorkout(WearCommand command) {
    final payload = readWearHandoff(command.args, command.workoutId, DateTime.now());
    if (payload == null) return WearExecution.invalid;
    if (command.action == 'uploadCompletedWorkout') {
      if (!payload.save) return WearExecution.invalid;
      fit.logWearWorkout(payload.session, payload.elapsed);
      return WearExecution.changedOk;
    }
    final current = fit.session;
    if (current != null) {
      return current.sessionId == command.workoutId
          ? WearExecution.unchanged
          : const WearExecution(ok: false, code: 'active_session');
    }
    fit.adoptWearWorkout(
      payload.session, elapsed: payload.elapsed, paused: payload.paused, restDuration: payload.rest,
    );
    if (payload.save) {
      fit.finishSession(elapsedOverride: payload.elapsed);
      fit.saveAndExit();
    }
    return WearExecution.changedOk;
  }

  WearExecution _executeBatch(WearCommand batch) {
    final raw = batch.args['operations'];
    if (raw is! List || raw.isEmpty || raw.length > 48) return WearExecution.invalid;
    final session = fit.session;
    if (session == null) return WearExecution.noSession;
    if (batch.workoutId != null && batch.workoutId != session.sessionId) return WearExecution.conflict;
    if (batch.baseRev != _rev) return WearExecution.conflict;

    final operations = <WearCommand>[];
    final ids = <String>{};
    for (final item in raw) {
      if (item is! Map || item.keys.any((key) => key is! String)) return WearExecution.invalid;
      final parsed = WearCommand.fromJson(Map<String, dynamic>.from(item));
      if (parsed == null ||
          parsed.action == 'syncBatch' ||
          parsed.action == 'requestState' ||
          parsed.action.startsWith('home/') ||
          parsed.workoutId != batch.workoutId ||
          parsed.id == batch.id ||
          !ids.add(parsed.id)) {
        return WearExecution.invalid;
      }
      final known = fit.wearAppliedOperations[parsed.id];
      if (known != null && !_matchesSignature(parsed, known)) {
        return const WearExecution(ok: false, code: 'duplicate_id');
      }
      operations.add(parsed);
    }

    var changed = false;
    for (final operation in operations) {
      if (fit.wearAppliedOperations.containsKey(operation.id)) continue;
      final current = WearCommand(
        id: operation.id,
        baseRev: _rev,
        action: operation.action,
        args: operation.args,
        workoutId: operation.workoutId,
      );
      final execution = _executor.execute(current, _rev);
      if (!execution.ok) {
        // Keep a successfully executed prefix durable. The watch can retry
        // individually to identify the rejected operation.
        return WearExecution(ok: false, code: 'batch_partial', changed: changed);
      }
      fit.wearAppliedOperations[operation.id] = _commandSignature(operation);
      changed = true;
    }
    return WearExecution(ok: true, code: 'ok', changed: changed);
  }

  String _commandSignature(WearCommand command, {bool legacy = false}) => jsonEncode({
    'action': command.action,
    'args': !legacy && command.action == 'completeSet'
        ? (Map<String, dynamic>.of(command.args)..remove('restRemainingSec'))
        : command.args,
    'workoutId': command.workoutId,
  });

  bool _matchesSignature(WearCommand command, String known) {
    if (_commandSignature(command) == known) return true;
    if (command.action != 'completeSet') return false;
    // Pre-upgrade records included the rest value calculated at send time.
    try {
      final legacy = jsonDecode(known);
      if (legacy is! Map || legacy['args'] is! Map) return false;
      (legacy['args'] as Map).remove('restRemainingSec');
      return jsonEncode(legacy) == _commandSignature(command);
    } on FormatException {
      return false;
    }
  }

  void _onFit() {
    if (!fit.wearLink || _applying) {
      if (_applying && fit.wearLink) _dirtyWhileApplying = true;
      wearLinkDiagnostic('phone fit change skipped enabled=${fit.wearLink} applying=$_applying');
      return;
    }
    wearLinkDiagnostic(
      'phone fit change route=${fit.route} hasSession=${fit.session != null} '
      'complete=${fit.session?.complete ?? false}',
    );
    _push();
  }

  Future<void> _start() async {
    final result = await _invokeWithPermission('startServer');
    status.value = WearLinkStatus.fromMap(result);
    wearLinkDiagnostic(
      'phone server start enabled=${status.value.enabled} '
      'state=${status.value.state.name} error=${status.value.error}',
    );
    if (!status.value.enabled) return;
    await _push(force: true);
  }

  Future<void> setEnabled(bool on) async {
    if (!_supported) return;
    if (!on) {
      await _channel.invokeMethod<void>('stop');
      fit.setWearLink(false);
      status.value = WearLinkStatus.fromMap(await _readStatus());
      return;
    }
    final result = await _invokeWithPermission('startServer');
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    fit.setWearLink(next.enabled);
    wearLinkDiagnostic(
      'phone server enabled=${next.enabled} '
      'state=${next.state.name} error=${next.error}',
    );
    if (next.enabled) await _push(force: true);
  }

  Future<WearLinkStatus> beginPairing() async {
    if (!_supported) return const WearLinkStatus();
    final result = await _invokeWithPermission('beginPairing');
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    return next;
  }

  Future<void> cancelPairing() async {
    if (!_supported) return;
    final result = await _channel.invokeMethod<Map>('cancelPairing');
    status.value = WearLinkStatus.fromMap(result);
  }

  Future<void> forget() async {
    if (!_supported) return;
    final result = await _channel.invokeMethod<Map>('forget');
    status.value = WearLinkStatus.fromMap(result);
  }

  Future<WearLinkStatus> refresh() async {
    if (!_supported) return status.value;
    final next = WearLinkStatus.fromMap(await _readStatus());
    status.value = next;
    return next;
  }

  Future<void> resume() async {
    if (!_supported || !fit.wearLink) return;
    try {
      final next = WearLinkStatus.fromMap(await _channel.invokeMethod<Map>('wakeServer'));
      status.value = next;
      if (next.enabled) await _push();
    } on PlatformException {
      // Resume must remain usable while Bluetooth is off or permission changed.
    } on MissingPluginException {
      // Older host builds lack the screen-resume hook.
    }
  }

  Future<Map<dynamic, dynamic>?> _readStatus() async {
    try {
      return await _channel.invokeMethod<Map>('status');
    } catch (_) {
      return null;
    }
  }

  Future<Map<dynamic, dynamic>?> _invokeWithPermission(String method) async {
    var result = await _channel.invokeMethod<Map>(method);
    if (result?['code'] == 'permission') {
      await _channel.invokeMethod<Map>('requestPermissions');
      result = await _channel.invokeMethod<Map>(method);
    }
    return result;
  }

  /// Pushes are serialized so a snapshot built before a command can never
  /// overwrite the state that the command produced. A caller that arrives while
  /// a push is in flight waits for it and runs one more push afterwards.
  Future<int> _push({bool force = false}) {
    if (!_supported || !fit.wearLink) {
      wearLinkDiagnostic('phone snapshot push skipped supported=$_supported enabled=${fit.wearLink}');
      return Future.value(_rev);
    }
    final active = _pushTask;
    if (active != null) {
      return active.then((_) => _push(force: force));
    }
    final task = _runPush(force: force);
    _pushTask = task;
    return task.whenComplete(() {
      if (identical(_pushTask, task)) _pushTask = null;
    });
  }

  Future<int> _runPush({required bool force}) async {
    if (_durableOperationIds == null) _captureDurableOperations();
    final json = _snapshots.build(rev: _rev + 1, bootId: _bootId);
    // The watch uses this as the elapsed-time anchor. During the phone's
    // start countdown the workout clock has not started yet.
    final countdown = fit.countdownUntil;
    if (json['status'] == 'active' && countdown != null && countdown.isAfter(DateTime.now())) {
      json['serverNow'] = countdown.toIso8601String();
    }
    final home = _home.snapshot();
    final fingerprint = '${_snapshots.fingerprintOf(json)}${jsonEncode(home)}';
    if (!force && fingerprint == _lastFingerprint) return _rev;
    if (fingerprint != _lastFingerprint) _rev += 1;
    _lastFingerprint = fingerprint;
    final snapshot = WearSnapshot(
      rev: _rev,
      bootId: _bootId,
      json: {
        ...json,
        'rev': _rev,
        'home': {...home, 'nutritionReceipts': _durableNutritionIds},
        'appliedOperationIds': _durableOperationIds,
      },
      fingerprint: fingerprint,
    );
    _lastSnapshot = snapshot;
    wearLinkDiagnostic(
      'phone snapshot prepared ${wearSnapshotSummary(snapshot.json)} '
      'route=${fit.route} connected=${status.value.connected} force=$force',
    );
    try {
      await _channel.invokeMethod<void>('update', {'json': snapshot.encode()});
      wearLinkDiagnostic('phone snapshot handed to native rev=$_rev');
    } catch (error) {
      wearLinkDiagnostic('phone snapshot channel failed type=${error.runtimeType}');
    }
    return _rev;
  }

  Future<void> pushNow() => _push(force: true);

  static String _randomId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(List.generate(16, (_) => random.nextInt(256)));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
