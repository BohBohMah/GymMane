import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'remote_workout.dart';
import 'wear_command.dart';
import 'wear_link_diagnostics.dart';
import 'wear_link_status.dart';
import 'wear_offline_journal.dart';
import 'wear_offline_journal_file.dart';

/// A phone the watch is already bonded with.
class WearBondedDevice {
  const WearBondedDevice({required this.address, required this.name});

  final String address;
  final String name;

  static WearBondedDevice? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final address = raw['address'] as String? ?? '';
    if (address.isEmpty) return null;
    final name = raw['name'] as String? ?? '';
    return WearBondedDevice(address: address, name: name.isEmpty ? address : name);
  }
}

/// Watch-side half of the local link. It mirrors the phone snapshot and sends
/// idempotent commands, waiting for the phone ack before reporting success.
class WearLinkClient {
  WearLinkClient._();

  static final instance = WearLinkClient._();
  static const _channel = MethodChannel('gymmane/wearlink');

  final ValueNotifier<WearLinkStatus> status = ValueNotifier(const WearLinkStatus());
  final ValueNotifier<RemoteWorkout?> workout = ValueNotifier(null);
  final ValueNotifier<String?> pinPrompt = ValueNotifier(null);
  final ValueNotifier<bool> finishing = ValueNotifier(false);

  final Map<String, Completer<WearAck>> _pending = {};
  String? _sendingId;
  String? _sendingAction;
  String? _sendingWorkoutId;
  int? _sendingBaseRev;
  List<String> _sendingOperationIds = const [];
  bool _sendingContainsDiscard = false;
  int _rev = 0;
  bool _attached = false;
  bool _resuming = false;
  Timer? _reconnectTimer;
  WearOfflineJournal? _journal;
  Future<void>? _initializing;
  Map<String, dynamic>? _authoritative;
  Map<String, dynamic>? _deferredState;

  bool get _supported => debugSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Test hook so widget/unit tests can exercise the channel on any host.
  @visibleForTesting
  static bool? debugSupportedOverride;

  void attach() {
    if (!_supported || _attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_onNativeCall);
    unawaited(_ensureJournal());
    if (Platform.isAndroid) {
      _reconnectTimer ??= Timer.periodic(const Duration(seconds: 8), (_) {
        final current = status.value;
        if (current.enabled && !current.connected && current.address.isNotEmpty) {
          unawaited(resume());
        }
      });
    }
  }

  Future<void> _ensureJournal() => _initializing ??= () async {
    if (_journal != null) return;
    if (debugSupportedOverride == true && !Platform.isAndroid) {
      _journal = WearOfflineJournal(write: (_) async {});
    } else {
      final directory = await getApplicationSupportDirectory();
      _journal = await WearOfflineJournalFile(directory).open();
    }
    final saved = _journal?.state?['snapshot'];
    if (saved is Map) {
      final json = Map<String, dynamic>.from(saved);
      _rev = (json['rev'] as num?)?.toInt() ?? 0;
    }
    _publishJournal();
  }();

  @visibleForTesting
  void resetForTest() {
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(WearAck(id: entry.key, ok: false, rev: 0, code: 'reset'));
      }
    }
    _pending.clear();
    _sendingId = null;
    _sendingAction = null;
    _sendingWorkoutId = null;
    _sendingBaseRev = null;
    _sendingOperationIds = const [];
    _sendingContainsDiscard = false;
    _deferredState = null;
    _rev = 0;
    status.value = const WearLinkStatus();
    workout.value = null;
    pinPrompt.value = null;
    finishing.value = false;
    _journal = WearOfflineJournal(write: (_) async {});
    _initializing = Future.value();
    _authoritative = null;
    _deferredState = null;
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'clientEvent':
        final raw = call.arguments;
        if (raw is Map) {
          status.value = WearLinkStatus.fromMap(raw);
          wearLinkDiagnostic(
            'watch native event state=${status.value.state.name} '
            'enabled=${status.value.enabled} error=${status.value.error}',
          );
          if (!status.value.connected) {
            pinPrompt.value = null;
            _queuePendingOffline();
          } else {
            pinPrompt.value = null;
            unawaited(_pump());
            unawaited(requestState());
          }
        }
        return null;
      case 'pinRequired':
        final raw = call.arguments;
        final name = raw is Map ? raw['phoneName'] as String? : null;
        pinPrompt.value = name == null || name.isEmpty ? 'GymMane' : name;
        return null;
      case 'state':
        final raw = call.arguments;
        if (raw is Map) {
          await _ensureJournal();
          final data = Map<String, dynamic>.from(raw);
          data.putIfAbsent('snapshotVersion', () => 1);
          wearLinkDiagnostic('watch Dart received state ${wearSnapshotSummary(data)}');
          final incomingRev = (data['rev'] as num?)?.toInt();
          final id = data['workoutId'];
          final incomingWorkoutId = id is String ? id : '';
          if (_sendingId != null &&
              incomingWorkoutId.isNotEmpty &&
              incomingWorkoutId == _sendingWorkoutId) {
            final baseRev = _sendingBaseRev;
            if (incomingRev != null && baseRev != null && incomingRev <= baseRev) {
              wearLinkDiagnostic(
                'watch ignored state from previous command rev=$incomingRev base=$baseRev',
              );
              return null;
            }
            // The phone publishes the post-command snapshot just before its
            // acknowledgement. Defer it so relative edits are not replayed a
            // second time on top of a state that already contains them.
            _deferredState = data;
            if (incomingRev != null && incomingRev > _rev) _rev = incomingRev;
            wearLinkDiagnostic('watch deferred in-flight state rev=$incomingRev');
            return null;
          }
          if (_sendingWorkoutId != null && _sendingWorkoutId != incomingWorkoutId) {
            _settlePendingForNewWorkout();
          }
          if (id is String && id.isNotEmpty) {
            if (_isStaleWorkoutState(data)) {
              wearLinkDiagnostic('watch ignored stale workout snapshot rev=$incomingRev');
              return null;
            }
            _authoritative = data;
            _rev = incomingRev ?? _rev;
            await _journal!.rebase(data);
            _publishJournal();
          } else if (_isStaleIdle(data)) {
            wearLinkDiagnostic('watch ignored stale idle snapshot rev=$incomingRev');
          } else {
            // The phone is authoritative when it has no workout: stop locally
            // and drop any queued edits instead of resurrecting a discarded
            // session on the next command.
            await _journal!.clear();
            _authoritative = data;
            _rev = incomingRev ?? _rev;
            workout.value = RemoteWorkout.fromJson(data);
            finishing.value = false;
            wearLinkDiagnostic('watch stopped because the phone has no workout');
          }
          unawaited(_pump());
        }
        return null;
      case 'ack':
        final raw = call.arguments;
        if (raw is Map) await _onAck(Map<String, dynamic>.from(raw));
        return null;
    }
    return null;
  }

  Future<void> _onAck(Map<String, dynamic> raw) async {
    await _ensureJournal();
    final ack = WearAck(
      id: raw['id'] as String? ?? '',
      ok: raw['ok'] as bool? ?? false,
      rev: (raw['rev'] as num?)?.toInt() ?? _rev,
      code: raw['code'] as String? ?? 'error',
      message: raw['message'] as String?,
    );
    if (ack.rev > _rev) _rev = ack.rev;
    if (_sendingId != ack.id) return;
    final sentOperationIds = _sendingOperationIds;
    final rawDeferredState = _deferredState;
    final deferredRev = (rawDeferredState?['rev'] as num?)?.toInt();
    final deferredState = deferredRev == null || deferredRev < ack.rev ? null : rawDeferredState;
    _deferredState = null;
    final discard = _sendingAction == 'saveExit' || _sendingContainsDiscard;
    _sendingId = null;
    _sendingAction = null;
    _sendingWorkoutId = null;
    _sendingBaseRev = null;
    _sendingOperationIds = const [];
    _sendingContainsDiscard = false;
    if (ack.ok) {
      try {
        await _journal!.acknowledgeMany(sentOperationIds.isEmpty ? [ack.id] : sentOperationIds);
      } catch (_) {
        // The idle snapshot may already have cleared the journal.
      }
      if (discard) {
        await _stopLocally();
      } else if (deferredState != null) {
        _authoritative = deferredState;
        _rev = (deferredState['rev'] as num?)?.toInt() ?? _rev;
        await _journal!.rebase(deferredState);
        _publishJournal();
      } else {
        _publishJournal();
      }
      final completer = _pending.remove(ack.id);
      if (completer != null && !completer.isCompleted) completer.complete(ack);
      final queued = _journal!.state?['pending'] as List?;
      if (queued == null || queued.isEmpty) unawaited(requestState());
      unawaited(_pump());
    } else if (ack.code == 'conflict') {
      unawaited(requestState());
    } else if (const {'offline', 'timeout', 'error'}.contains(ack.code)) {
      // A stale native "connected" state can race with a broken GATT link.
      // Keep the durable operation and silently rebuild the connection.
      _publishJournal();
      unawaited(resume());
    } else if (discard) {
      if (ack.code == 'no_session') {
        // The phone already has no workout, so the discard is confirmed.
        await _stopLocally();
        unawaited(requestState());
        unawaited(_pump());
      } else {
        // Keep the durable finish intent; a later reconnect retries it.
        _publishJournal();
      }
      final completer = _pending.remove(ack.id);
      if (completer != null && !completer.isCompleted) completer.complete(ack);
    } else if (sentOperationIds.length > 1) {
      // A batch is atomic on the phone. Keep every local operation until a
      // fresh snapshot confirms the base revision, then retry the same queue.
      _publishJournal();
      unawaited(requestState());
    } else {
      final authority = _authoritative;
      final authorityId = authority?['workoutId'];
      if (authority != null && authorityId is String && authorityId.isNotEmpty) {
        await _journal!.rebase(authority, acknowledge: ack.id);
      } else if (authority != null) {
        await _journal!.clear();
      }
      _publishJournal();
      final completer = _pending.remove(ack.id);
      if (completer != null && !completer.isCompleted) completer.complete(ack);
      unawaited(_pump());
    }
  }

  Future<List<WearBondedDevice>> bondedDevices() async {
    if (!_supported) return const [];
    try {
      final raw = await _channel.invokeMethod<List>('bondedDevices');
      return [for (final item in raw ?? const []) ?WearBondedDevice.fromMap(item)];
    } catch (_) {
      return const [];
    }
  }

  Future<WearLinkStatus> connect(String address, String name) async {
    if (!_supported) return const WearLinkStatus();
    final result = await _channel.invokeMethod<Map>('startClient', {'address': address, 'name': name});
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    return next;
  }

  Future<void> resume() async {
    if (!_supported || _resuming) return;
    _resuming = true;
    try {
      final current = await refresh();
      if (current.connected) {
        await requestState();
        unawaited(_pump());
        return;
      }
      if (!current.enabled || current.address.isEmpty) return;
      await connect(current.address, current.deviceName);
    } finally {
      _resuming = false;
    }
  }

  Future<WearLinkStatus> refresh() async {
    if (!_supported) return status.value;
    try {
      final result = await _channel.invokeMethod<Map>('clientStatus');
      final next = WearLinkStatus.fromMap(result);
      status.value = next;
      return next;
    } catch (_) {
      return status.value;
    }
  }

  Future<WearLinkStatus> disconnect() async {
    if (!_supported) return const WearLinkStatus();
    final result = await _channel.invokeMethod<Map>('stopClient');
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    pinPrompt.value = null;
    return next;
  }

  Future<WearLinkStatus> forget() async {
    if (!_supported) return const WearLinkStatus();
    final result = await _channel.invokeMethod<Map>('forgetPhone');
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    await _ensureJournal();
    await _journal!.clear();
    _authoritative = null;
    _deferredState = null;
    workout.value = null;
    pinPrompt.value = null;
    finishing.value = false;
    return next;
  }

  Future<bool> submitPin(String pin) async {
    if (!_supported) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('submitPin', {'pin': pin});
      if (ok == true) pinPrompt.value = null;
      return ok == true;
    } catch (_) {
      return false;
    }
  }

  Future<void> requestState() async {
    if (!_supported) return;
    try {
      await _channel.invokeMethod<void>('requestState');
    } catch (_) {}
  }

  Future<WearAck> command(
    String action, {
    Map<String, dynamic> args = const {},
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await _ensureJournal();
    final id = _newId();
    final current = workout.value;
    if (current == null || !current.hasWorkout) {
      return WearAck(id: id, ok: false, rev: _rev, code: 'no_session');
    }
    if (_hasPendingDiscard()) {
      return WearAck(id: id, ok: false, rev: _rev, code: 'finishing');
    }
    final identified = _identify(action, args, current);
    final operation = WearCommand(
      id: id,
      baseRev: _rev,
      action: action,
      args: identified,
      workoutId: current.workoutId,
    );
    try {
      await _journal!.apply(operation.toJson());
      _publishJournal();
    } catch (_) {
      return WearAck(id: id, ok: false, rev: _rev, code: 'invalid');
    }
    if (status.value.connected) unawaited(_pump());
    return WearAck(id: id, ok: true, rev: _rev, code: 'queued');
  }

  Future<WearAck> completeSet(int exerciseIndex, int setIndex) =>
      command('completeSet', args: {'exerciseIndex': exerciseIndex, 'setIndex': setIndex});

  Future<WearAck> uncompleteSet(int exerciseIndex, int setIndex) =>
      command('uncompleteSet', args: {'exerciseIndex': exerciseIndex, 'setIndex': setIndex});

  Future<WearAck> updateSet(
    int exerciseIndex,
    int setIndex, {
    int? reps,
    int? repsRight,
    double? weight,
    int? sec,
    double? km,
    double? rpe,
    bool clearRpe = false,
  }) {
    final args = <String, dynamic>{'exerciseIndex': exerciseIndex, 'setIndex': setIndex};
    if (reps != null) args['reps'] = reps;
    if (repsRight != null) args['repsRight'] = repsRight;
    if (weight != null) args['weight'] = weight;
    if (sec != null) args['sec'] = sec;
    if (km != null) args['km'] = km;
    if (clearRpe) {
      args['rpe'] = null;
    } else if (rpe != null) {
      args['rpe'] = rpe;
    }
    return command('updateSet', args: args);
  }

  Future<WearAck> adjustSet(int exerciseIndex, int setIndex, {required String field, required num delta}) =>
      command(
        'adjustSet',
        args: {'exerciseIndex': exerciseIndex, 'setIndex': setIndex, 'field': field, 'delta': delta},
      );

  Future<WearAck> nextExercise() => command('nextExercise');

  Future<WearAck> prevExercise() => command('prevExercise');

  Future<WearAck> goToExercise(int index) => command('goToExercise', args: {'index': index});

  Future<WearAck> pause() => command('pause');

  Future<WearAck> resumeWorkout() => command('resume');

  /// Ends the workout from the watch and asks the phone to discard it.
  ///
  /// The request is committed to the journal before anything is sent, so it
  /// survives an app restart or a dead connection. It is queued after every
  /// pending edit, and the local snapshot is only removed once the phone
  /// confirms (or reports that it already has no workout).
  Future<WearAck> finishAndDiscard() async {
    await _ensureJournal();
    final current = workout.value;
    if (current == null || !current.hasWorkout) {
      return WearAck(id: _newId(), ok: false, rev: _rev, code: 'no_session');
    }
    if (_hasPendingDiscard()) {
      return WearAck(id: _newId(), ok: true, rev: _rev, code: 'queued');
    }
    final id = _newId();
    final operation = WearCommand(
      id: id,
      baseRev: _rev,
      action: 'saveExit',
      args: const {},
      workoutId: current.workoutId,
    );
    try {
      await _journal!.apply(operation.toJson());
      _publishJournal();
    } catch (_) {
      return WearAck(id: id, ok: false, rev: _rev, code: 'invalid');
    }
    unawaited(_pump());
    return WearAck(id: id, ok: true, rev: _rev, code: 'queued');
  }

  /// Completes the workout, saves every completed set on the phone, then exits.
  /// Both operations are committed locally first, so the sequence survives an
  /// offline period, an app restart, or a broken connection.
  Future<WearAck> finishAndSave() async {
    await _ensureJournal();
    final current = workout.value;
    if (current == null || !current.hasWorkout) {
      return WearAck(id: _newId(), ok: false, rev: _rev, code: 'no_session');
    }
    if (_hasPendingDiscard()) {
      return WearAck(id: _newId(), ok: true, rev: _rev, code: 'queued');
    }
    final finishId = _newId();
    final exitId = _newId();
    try {
      await _journal!.apply(
        WearCommand(
          id: finishId,
          baseRev: _rev,
          action: 'finish',
          args: const {},
          workoutId: current.workoutId,
        ).toJson(),
      );
      await _journal!.apply(
        WearCommand(
          id: exitId,
          baseRev: _rev,
          action: 'saveExit',
          args: const {},
          workoutId: current.workoutId,
        ).toJson(),
      );
      _publishJournal();
    } catch (_) {
      return WearAck(id: finishId, ok: false, rev: _rev, code: 'invalid');
    }
    if (status.value.connected) unawaited(_pump());
    return WearAck(id: finishId, ok: true, rev: _rev, code: 'queued');
  }

  bool _hasPendingDiscard() => _sendingAction == 'saveExit' || _pendingAction('saveExit') != null;

  String? _pendingAction(String action) {
    final pending = _journal?.state?['pending'];
    if (pending is! List) return null;
    for (final entry in pending) {
      if (entry is Map && entry['action'] == action) return action;
    }
    return null;
  }

  Future<WearAck> skipRest() => command('skipRest');

  Future<WearAck> nudgeRest(int seconds) => command('nudgeRest', args: {'seconds': seconds});

  Future<void> _pump() async {
    await _ensureJournal();
    if (_sendingId != null || !status.value.connected) return;
    final pending = _journal!.state?['pending'] as List?;
    if (pending == null || pending.isEmpty) return;
    const maxBatch = 48;
    final count = pending.length >= 3 ? min(pending.length, maxBatch) : 1;
    final queued = <WearCommand>[];
    for (final item in pending.take(count)) {
      final command = WearCommand.fromJson(Map<String, dynamic>.from(item as Map));
      if (command == null) return;
      queued.add(_withCurrentRest(command));
    }
    final command = queued.length == 1
        ? WearCommand(
            id: queued.first.id,
            baseRev: _rev,
            action: queued.first.action,
            args: queued.first.args,
            workoutId: queued.first.workoutId,
          )
        : WearCommand(
            id: _newId(),
            baseRev: _rev,
            action: 'syncBatch',
            args: {'operations': [for (final operation in queued) operation.toJson()]},
            workoutId: queued.first.workoutId,
          );
    _sendingId = command.id;
    _sendingAction = command.action;
    _sendingWorkoutId = command.workoutId;
    _sendingBaseRev = command.baseRev;
    _sendingOperationIds = [for (final operation in queued) operation.id];
    _sendingContainsDiscard = queued.any((operation) => operation.action == 'saveExit');
    await _send(command);
  }

  WearCommand _withCurrentRest(WearCommand queued) {
    final args = Map<String, dynamic>.from(queued.args);
    final restEndsAt = args['restEndsAt'];
    if (restEndsAt is String) {
      final end = DateTime.tryParse(restEndsAt);
      if (end != null) {
        final milliseconds = end.difference(DateTime.now()).inMilliseconds;
        args['restRemainingSec'] = milliseconds <= 0 ? 0 : (milliseconds / 1000).ceil();
      }
    }
    return WearCommand(
      id: queued.id,
      baseRev: _rev,
      action: queued.action,
      args: args,
      workoutId: queued.workoutId,
    );
  }

  Future<void> _send(WearCommand command) async {
    try {
      await _channel.invokeMethod<void>('sendCommand', command.toJson());
    } catch (_) {
      if (_sendingId == command.id) {
        _sendingId = null;
        _sendingAction = null;
        _sendingWorkoutId = null;
        _sendingBaseRev = null;
        _sendingOperationIds = const [];
        _sendingContainsDiscard = false;
      }
      final completer = _pending.remove(command.id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(WearAck(id: command.id, ok: false, rev: _rev, code: 'error'));
      }
      unawaited(_pump());
    }
  }

  void _queuePendingOffline() {
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(WearAck(id: entry.key, ok: true, rev: _rev, code: 'queued'));
      }
    }
    _pending.clear();
    _sendingId = null;
    _sendingAction = null;
    _sendingWorkoutId = null;
    _sendingBaseRev = null;
    _sendingOperationIds = const [];
    _sendingContainsDiscard = false;
    _deferredState = null;
  }

  /// A snapshot for another workout, or for no workout, means any command in
  /// flight belongs to a session that no longer exists. Release the pump
  /// instead of waiting for an acknowledgement that can no longer be trusted.
  void _settlePendingForNewWorkout() {
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(WearAck(id: entry.key, ok: false, rev: _rev, code: 'no_session'));
      }
    }
    _pending.clear();
    _sendingId = null;
    _sendingAction = null;
    _sendingWorkoutId = null;
    _sendingBaseRev = null;
    _sendingOperationIds = const [];
    _sendingContainsDiscard = false;
    _deferredState = null;
  }

  Map<String, dynamic> _identify(String action, Map<String, dynamic> args, RemoteWorkout workout) {
    final result = Map<String, dynamic>.from(args);
    if (const {'updateSet', 'adjustSet', 'completeSet', 'uncompleteSet'}.contains(action)) {
      final exerciseIndex = result['exerciseIndex'] as int?;
      final setIndex = result['setIndex'] as int?;
      if (exerciseIndex != null &&
          setIndex != null &&
          exerciseIndex >= 0 &&
          exerciseIndex < workout.exercises.length &&
          setIndex >= 0 &&
          setIndex < workout.exercises[exerciseIndex].sets.length) {
        result['exerciseId'] = workout.exercises[exerciseIndex].id;
        result['setId'] = workout.exercises[exerciseIndex].sets[setIndex].setId;
      }
    }
    return result;
  }

  void _publishJournal() {
    final raw = _journal?.state?['snapshot'];
    if (raw is Map) workout.value = RemoteWorkout.fromJson(Map<String, dynamic>.from(raw));
    finishing.value = _hasPendingDiscard();
  }

  /// A snapshot is stale only when it comes from the same phone process and
  /// predates the revision the watch already knows. A new boot id is accepted
  /// because the phone may have restarted with a lower revision.
  bool _isStaleIdle(Map<String, dynamic> data) {
    final current = workout.value;
    if (current == null || !current.hasWorkout) return false;
    final boot = data['bootId'] as String?;
    if (boot != null && boot.isNotEmpty && current.bootId.isNotEmpty && boot != current.bootId) {
      return false;
    }
    final rev = (data['rev'] as num?)?.toInt();
    return rev != null && rev < _rev;
  }

  bool _isStaleWorkoutState(Map<String, dynamic> data) {
    final current = workout.value;
    if (current == null || !current.hasWorkout || data['workoutId'] != current.workoutId) return false;
    final boot = data['bootId'] as String?;
    if (boot != null && boot.isNotEmpty && current.bootId.isNotEmpty && boot != current.bootId) {
      return false;
    }
    final rev = (data['rev'] as num?)?.toInt();
    return rev != null && rev < _rev;
  }

  /// Removes the local workout only after the phone confirmed the discard.
  Future<void> _stopLocally() async {
    try {
      await _journal?.clear();
    } catch (_) {}
    final current = workout.value;
    final idle = _authoritative;
    finishing.value = false;
    if (idle != null && idle['status'] == 'idle') {
      workout.value = RemoteWorkout.fromJson(idle);
    } else if (current != null) {
      workout.value = RemoteWorkout(
        rev: _rev,
        bootId: current.bootId,
        workoutId: '',
        status: RemoteStatus.idle,
        name: current.name,
        elapsedSeconds: 0,
        currentIndex: 0,
        exercises: const [],
        serverNow: DateTime.now(),
      );
    }
    _authoritative = null;
    _deferredState = null;
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(List.generate(12, (_) => random.nextInt(256)));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
