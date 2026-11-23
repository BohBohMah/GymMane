import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'remote_workout.dart';
import 'wear_command.dart';
import 'wear_home.dart';
import 'wear_link_diagnostics.dart';
import 'wear_link_status.dart';
import 'wear_nutrition_journal.dart';
import 'wear_offline_journal.dart';
import 'wear_offline_journal_file.dart';
import 'wear_workout_handoff.dart';

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

/// Watch-side half of the local link. Edits are visible after a local commit
/// and retained until the phone acknowledges them.
class WearLinkClient {
  WearLinkClient._();

  static final instance = WearLinkClient._();
  static const _channel = MethodChannel('gymmane/wearlink');

  final ValueNotifier<WearLinkStatus> status = ValueNotifier(const WearLinkStatus());
  final ValueNotifier<RemoteWorkout?> workout = ValueNotifier(null);
  final ValueNotifier<String?> pinPrompt = ValueNotifier(null);
  final ValueNotifier<bool> finishing = ValueNotifier(false);
  final ValueNotifier<int> rejectedEdits = ValueNotifier(0);
  final ValueNotifier<Map<String, dynamic>?> home = ValueNotifier(null);
  final ValueNotifier<int> nutritionPending = ValueNotifier(0);
  String? _homeRequestId;
  Completer<WearAck>? _homeReply;
  WearNutritionJournal? _nutrition;
  String? _nutritionInFlight;
  Timer? _nutritionTimeout;
  bool _nutritionReady = false;

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
  Timer? _ackWatchdog;
  Timer? _initialStateTimer;
  bool? _nativeSyncPending;
  bool _reconciling = false;
  bool _waitForState = false;
  bool _singleCommandsOnly = false;
  bool _adoptionBlocked = false;
  bool _completedBlocked = false;
  Future<void> _syncTail = Future.value();
  WearOfflineJournal? _journal;
  Future<void>? _initializing;
  Map<String, dynamic>? _authoritative;
  Map<String, dynamic>? _deferredState;

  bool get _supported => debugSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Test hook so widget/unit tests can exercise the channel on any host.
  @visibleForTesting
  static bool? debugSupportedOverride;

  @visibleForTesting
  Duration ackTimeout = const Duration(seconds: 15);

  void attach() {
    if (!_supported || _attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_onNativeCall);
    unawaited(_ensureJournal().catchError((Object error) {
      wearLinkDiagnostic('watch journal initialization failed type=${error.runtimeType}');
    }));
    if (Platform.isAndroid) {
      _reconnectTimer ??= Timer.periodic(const Duration(seconds: 8), (_) {
        final current = status.value;
        if (current.enabled && !current.connected && current.address.isNotEmpty) {
          unawaited(resume());
        }
      });
    }
  }

  Future<void> _ensureJournal() => _initializing ??= _openJournals().onError((Object error, StackTrace stack) {
    _initializing = null;
    Error.throwWithStackTrace(error, stack);
  });

  Future<void> _openJournals() async {
    if (debugSupportedOverride == true && !Platform.isAndroid) {
      _journal = WearOfflineJournal(write: (_) async {});
      _nutrition = WearNutritionJournal(write: (_) async {});
    } else {
      final directory = await getApplicationSupportDirectory();
      final journal = await WearOfflineJournalFile(directory).open();
      final file = WearJournalFile(directory, 'wear_nutrition_journal_v1.json');
      final nutrition = WearNutritionJournal(write: file.write);
      await file.restore(nutrition.restore);
      _journal = journal;
      _nutrition = nutrition;
    }
    final saved = _journal?.snapshot;
    if (saved != null) {
      _rev = (saved['rev'] as num?)?.toInt() ?? 0;
    }
    _publishJournal();
    _publishNutrition();
  }

  @visibleForTesting
  void resetForTest() {
    _resetFlight();
    _stopWaitingForInitialState();
    _singleCommandsOnly = false;
    _adoptionBlocked = false;
    _completedBlocked = false;
    ackTimeout = const Duration(seconds: 15);
    _waitForState = false;
    _reconciling = false;
    _rev = 0;
    status.value = const WearLinkStatus();
    workout.value = null;
    pinPrompt.value = null;
    finishing.value = false;
    rejectedEdits.value = 0;
    home.value = null;
    nutritionPending.value = 0;
    _nutritionReady = false;
    _clearNutritionFlight();
    _journal = WearOfflineJournal(write: (_) async {});
    _nutrition = WearNutritionJournal(write: (_) async {});
    _initializing = Future.value();
    _authoritative = null;
    _deferredState = null;
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    if (call.method == 'state' || call.method == 'ack') {
      // Platform calls can arrive while the preceding journal write awaits I/O.
      // Process them in wire order and suspend sending until reconciliation ends.
      final next = _syncTail.then((_) async {
        _reconciling = true;
        try {
          await _handleNativeCall(call);
        } catch (error) {
          wearLinkDiagnostic('watch sync event failed type=${error.runtimeType}');
        } finally {
          _reconciling = false;
        }
        unawaited(_pump());
        unawaited(_pumpNutrition());
      });
      _syncTail = next;
      await next;
      return null;
    }
    return _handleNativeCall(call);
  }

  Future<Object?> _handleNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'clientEvent':
        final raw = call.arguments;
        if (raw is Map) {
          final wasConnected = status.value.connected;
          status.value = WearLinkStatus.fromMap(raw);
          wearLinkDiagnostic(
            'watch native event state=${status.value.state.name} '
            'enabled=${status.value.enabled} error=${status.value.error}',
          );
          if (!status.value.connected) {
            _stopWaitingForInitialState();
            _adoptionBlocked = false;
            _completedBlocked = false;
            pinPrompt.value = null;
            _resetFlight();
            _clearNutritionFlight();
            _nutritionReady = false;
            _waitForState = false;
          } else if (!wasConnected) {
            pinPrompt.value = null;
            if (raw['pushesInitialState'] == true) {
              _initialStateTimer = Timer(const Duration(milliseconds: 1200), () {
                _initialStateTimer = null;
                unawaited(requestState());
                unawaited(_pump());
              });
            } else {
              unawaited(requestState());
            }
            unawaited(_pump());
          }
        }
        return null;
      case 'pinRequired':
        final raw = call.arguments;
        final name = raw is Map ? raw['phoneName'] as String? : null;
        pinPrompt.value = name == null || name.isEmpty ? 'GymMane' : name;
        return null;
      case 'home':
        final raw = call.arguments;
        if (raw is Map) await _receiveHome(Map<String, dynamic>.from(raw));
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
          if (!_journal!.hasLocalDraft && _isStaleState(data)) return null;
          _stopWaitingForInitialState();
          final dashboard = data.remove('home');
          if (dashboard is Map) await _receiveHome(Map<String, dynamic>.from(dashboard));
          if (_journal!.hasLocalDraft) {
            if (_waitForState) {
              _waitForState = false;
              _ackWatchdog?.cancel();
              _ackWatchdog = null;
            }
            final rawAdoption = _journal!.pendingOperations(1).firstOrNull;
            final adoption = rawAdoption?['action'] == 'adoptWorkout' ? rawAdoption : null;
            final same = incomingWorkoutId == workout.value?.workoutId;
            final receipts = data['appliedOperationIds'];
            final received = adoption != null && receipts is List && receipts.contains(adoption['id']);
            if (incomingRev != null) _rev = incomingRev;
            _authoritative = data;
            if (incomingWorkoutId.isEmpty) _adoptionBlocked = false;
            if (!same && !received) return null;
            if (adoption != null && _sendingId == adoption['id']) {
              _deferredState = data;
              return null;
            }
            if (!same) {
              await _stopLocally();
              return null;
            }
            await _journal!.rebase(data, acknowledge: [if (adoption != null) adoption['id'] as String]);
            _publishJournal();
            return null;
          }
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
            final receipts = data['appliedOperationIds'];
            final id = _sendingId;
            if (id != null && incomingRev != null && receipts is List &&
                _sendingOperationIds.isNotEmpty && _sendingOperationIds.every(receipts.contains)) {
              await _onAck({'id': id, 'ok': true, 'rev': incomingRev, 'code': 'ok'});
              return null;
            }
            wearLinkDiagnostic('watch deferred in-flight state rev=$incomingRev');
            return null;
          }
          if (_sendingWorkoutId != null && _sendingWorkoutId != incomingWorkoutId &&
              _sendingAction != 'uploadCompletedWorkout') {
            _resetFlight();
          }
          if (id is String && id.isNotEmpty) {
            await _journal!.rebase(data);
            _authoritative = data;
            _rev = incomingRev ?? _rev;
            _publishJournal();
          } else {
            // The phone is authoritative when it has no workout: stop locally
            // and drop any queued edits instead of resurrecting a discarded
            // session on the next command.
            await _journal!.clear();
            _authoritative = data;
            _rev = incomingRev ?? _rev;
            workout.value = RemoteWorkout.fromJson(data);
            finishing.value = false;
            _updateNativeSyncPriority();
            wearLinkDiagnostic('watch stopped because the phone has no workout');
          }
          if (_waitForState) {
            _waitForState = false;
            _ackWatchdog?.cancel();
            _ackWatchdog = null;
          }
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
    if (_homeRequestId == ack.id) {
      final reply = _homeReply;
      if (reply != null && !reply.isCompleted) reply.complete(ack);
      return;
    }
    if (_nutritionInFlight == ack.id) {
      _clearNutritionFlight();
      if (const {'offline', 'timeout', 'error'}.contains(ack.code)) {
        _retryNutrition();
      } else {
        await _nutrition!.settle(ack.id, accepted: ack.ok);
        _publishNutrition();
        if (!ack.ok) rejectedEdits.value++;
      }
      return;
    }
    if (_sendingId != ack.id) return;
    final sentOperationIds = _sendingOperationIds;
    final rawDeferredState = _deferredState;
    final deferredRev = (rawDeferredState?['rev'] as num?)?.toInt();
    final deferredState = deferredRev == null || deferredRev < ack.rev ? null : rawDeferredState;
    final discard = _sendingAction == 'saveExit' || _sendingContainsDiscard;
    final adoption = _sendingAction == 'adoptWorkout';
    final completed = _sendingAction == 'uploadCompletedWorkout';
    _resetFlight();
    if (ack.rev > _rev) _rev = ack.rev;
    if (completed) {
      if (ack.ok) {
        await _journal!.acknowledgeCompleted(ack.id);
        _updateNativeSyncPriority();
      } else if (const {'offline', 'timeout', 'error'}.contains(ack.code)) {
        _retryAfterFailure();
      } else {
        _completedBlocked = true;
        rejectedEdits.value++;
      }
      return;
    }
    if (adoption && !ack.ok) {
      if (ack.code == 'active_session') {
        _adoptionBlocked = true;
        await _journal!.reopenAdoption(ack.id);
        await requestState();
      } else if (const {'offline', 'timeout', 'error'}.contains(ack.code)) {
        _retryAfterFailure();
      } else {
        _adoptionBlocked = true;
        rejectedEdits.value++;
      }
      return;
    }
    if (ack.ok) {
      if (discard) {
        await _stopLocally();
      } else if (deferredState != null) {
        await _journal!.rebase(deferredState, acknowledge: sentOperationIds);
        _authoritative = deferredState;
        _rev = (deferredState['rev'] as num?)?.toInt() ?? _rev;
        _publishJournal();
      } else {
        await _journal!.acknowledgeMany(sentOperationIds);
        _publishJournal();
      }
      if (deferredState == null && !discard && !_journal!.hasPending) {
        unawaited(requestState());
      }
    } else if (ack.code == 'conflict') {
      if (deferredState == null) {
        _refreshBeforeSending();
      } else {
        await _journal!.rebase(deferredState);
        _authoritative = deferredState;
        _publishJournal();
      }
    } else if (const {'offline', 'timeout', 'error'}.contains(ack.code)) {
      // A stale native "connected" state can race with a broken GATT link.
      // Keep the durable operation and silently rebuild the connection.
      _retryAfterFailure();
    } else if (sentOperationIds.length > 1) {
      // Resolve incompatible peers or a rejected batch operation individually.
      _singleCommandsOnly = true;
      if (deferredState != null) {
        await _journal!.rebase(deferredState);
        _authoritative = deferredState;
        _publishJournal();
      } else {
        _refreshBeforeSending();
      }
    } else if (discard && ack.code != 'invalid') {
      if (ack.code == 'no_session') {
        // The phone already has no workout, so the discard is confirmed.
        await _stopLocally();
        unawaited(requestState());
        unawaited(_pump());
      } else {
        // Keep the durable finish intent; a later reconnect retries it.
        _publishJournal();
      }
      if (ack.code != 'no_session') _retryAfterFailure();
    } else {
      final authority = _authoritative;
      final authorityId = authority?['workoutId'];
      if (authority != null && authorityId is String && authorityId.isNotEmpty) {
        await _journal!.rebase(authority, acknowledge: [ack.id]);
      } else if (authority != null) {
        await _journal!.clear();
      }
      _publishJournal();
      rejectedEdits.value++;
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
    await _ensureJournal();
    if (!_nutrition!.acceptsPeer(address) && _nutrition!.pendingCount > 0) {
      rejectedEdits.value++;
      return status.value;
    }
    final result = await _channel.invokeMethod<Map>('startClient', {'address': address, 'name': name});
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    return next;
  }

  Future<void> resume() async {
    if (!_supported || _resuming) return;
    _resuming = true;
    try {
      await _ensureJournal();
      _publishNutrition();
      final current = await refresh();
      if (current.connected) {
        await requestState();
        unawaited(_pump());
        return;
      }
      if (!current.enabled || current.address.isEmpty) return;
      final next = await _channel.invokeMethod<Map>('resumeClient');
      if (next != null) status.value = WearLinkStatus.fromMap(next);
    } on PlatformException {
      // A background retry must never prompt for permission.
    } on MissingPluginException {
      // Older native hosts may not support the silent resume method.
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
    await _ensureJournal();
    if (_journal!.hasLocalDraft || _journal!.hasPending || _journal!.firstCompleted != null) {
      rejectedEdits.value++;
      return status.value;
    }
    final result = await _channel.invokeMethod<Map>('forgetPhone');
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    await _ensureJournal();
    await _journal!.clear();
    _clearNutritionFlight();
    _nutritionReady = false;
    await _nutrition!.clear();
    _authoritative = null;
    _deferredState = null;
    workout.value = null;
    _publishNutrition();
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

  Future<WearAck> homeCommand(String action, {Map<String, dynamic> args = const {}}) async {
    final id = _newId();
    WearAck failure(String code) => WearAck(id: id, ok: false, rev: _rev, code: code);
    if (wearNutritionActions.contains(action)) {
      await _ensureJournal();
      final currentPeer = status.value.address;
      if (currentPeer.isNotEmpty && !_nutrition!.acceptsPeer(currentPeer)) return failure('offline');
      try {
        await _nutrition!.enqueue(WearCommand(id: id, baseRev: _rev, action: 'home/$action', args: args));
      } catch (_) {
        return failure('invalid');
      }
      _publishNutrition();
      unawaited(_pumpNutrition());
      return WearAck(id: id, ok: true, rev: _rev, code: 'queued');
    }
    if (!status.value.connected && const {'startRoutine', 'startExercises'}.contains(action)) {
      await _ensureJournal();
      if (_journal!.snapshot != null) return failure('active_session');
      try {
        final draft = watchWorkoutDraft(action, args, home.value, id);
        if (draft == null) return failure('invalid');
        await _journal!.initialize(draft);
        _publishJournal();
        unawaited(_pump());
        return WearAck(id: id, ok: true, rev: _rev, code: 'queued');
      } catch (_) {
        return failure('invalid');
      }
    }
    if (!status.value.connected || home.value == null) return failure('offline');
    if (_homeReply != null) return failure('busy');
    final reply = Completer<WearAck>();
    _homeReply = reply;
    _homeRequestId = id;
    try {
      final command = WearCommand(id: id, baseRev: _rev, action: 'home/$action', args: args);
      await _channel.invokeMethod<void>('sendCommand', command.toJson()).timeout(ackTimeout);
      return await reply.future.timeout(ackTimeout);
    } on TimeoutException {
      unawaited(requestState());
      return failure('timeout');
    } on PlatformException {
      return failure('offline');
    } finally {
      _homeReply = null;
      _homeRequestId = null;
    }
  }

  void _publishNutrition() {
    home.value = _nutrition?.view(DateTime.now());
    nutritionPending.value = _nutrition?.pendingCount ?? 0;
    _updateNativeSyncPriority();
  }

  Future<void> _receiveHome(Map<String, dynamic> dashboard) async {
    if (!status.value.connected) return;
    final peer = status.value.address;
    await _ensureJournal();
    await _nutrition!.rebase(dashboard, peer);
    if (!status.value.connected || status.value.address != peer) return;
    _nutritionReady = dashboard.containsKey('nutritionReceipts');
    _publishNutrition();
    unawaited(_pumpNutrition());
  }

  Future<void> _pumpNutrition() async {
    if (!_nutritionReady || !status.value.connected || _reconciling ||
        _nutritionInFlight != null || _nutritionTimeout != null) {
      return;
    }
    final journal = _nutrition;
    final command = journal?.first;
    if (journal == null || command == null || !journal.acceptsPeer(status.value.address)) return;
    _nutritionInFlight = command.id;
    _nutritionTimeout = Timer(ackTimeout, _retryNutrition);
    try {
      await _channel.invokeMethod<void>('sendCommand', command.toJson());
    } catch (_) {
      if (_nutritionInFlight == command.id) _retryNutrition();
    }
  }

  void _retryNutrition() {
    _clearNutritionFlight();
    unawaited(requestState());
    _nutritionTimeout = Timer(const Duration(seconds: 2), () {
      _nutritionTimeout = null;
      unawaited(_pumpNutrition());
    });
  }

  void _clearNutritionFlight() {
    _nutritionTimeout?.cancel();
    _nutritionTimeout = null;
    _nutritionInFlight = null;
  }

  Future<WearAck> command(
    String action, {
    Map<String, dynamic> args = const {},
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
    if (await _journal!.discardUnsentDraft()) {
      await _stopLocally();
      return WearAck(id: id, ok: true, rev: _rev, code: 'ok');
    }
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
      if (await _journal!.archiveUnsentDraft((snapshot) => WearCommand(
        id: finishId, baseRev: _rev, action: 'uploadCompletedWorkout',
        args: wearHandoffPayload(snapshot), workoutId: current.workoutId,
      ).toJson())) {
        await _stopLocally(clearJournal: false);
        unawaited(_pump());
        return WearAck(id: finishId, ok: true, rev: _rev, code: 'queued');
      }
      await _journal!.applyAll([
        WearCommand(
          id: finishId,
          baseRev: _rev,
          action: 'finish',
          args: const {},
          workoutId: current.workoutId,
        ).toJson(),
        WearCommand(
          id: exitId,
          baseRev: _rev,
          action: 'saveExit',
          args: const {'requiresCompleted': true},
          workoutId: current.workoutId,
        ).toJson(),
      ]);
      _publishJournal();
    } catch (_) {
      return WearAck(id: finishId, ok: false, rev: _rev, code: 'invalid');
    }
    if (status.value.connected) unawaited(_pump());
    return WearAck(id: finishId, ok: true, rev: _rev, code: 'queued');
  }

  bool _hasPendingDiscard() => _journal?.hasAction('saveExit') ?? false;

  Future<WearAck> skipRest() => command('skipRest');

  Future<WearAck> nudgeRest(int seconds) => command('nudgeRest', args: {'seconds': seconds});

  Future<void> _pump() async {
    await _ensureJournal();
    if (_sendingId != null || _reconciling || _waitForState ||
        _ackWatchdog != null || !status.value.connected) {
      return;
    }
    if (_initialStateTimer != null && _journal!.hasPending && !_journal!.hasLocalDraft) return;
    if (_journal!.hasLocalDraft && !_adoptionBlocked) {
      try {
        await _journal!.prepareAdoption((snapshot) => WearCommand(
          id: _newId(), baseRev: _rev, action: 'adoptWorkout',
          args: wearHandoffPayload(snapshot), workoutId: snapshot['workoutId'] as String,
        ).toJson());
      } catch (_) {
        _adoptionBlocked = true;
        rejectedEdits.value++;
        return;
      }
      if (_sendingId != null || _reconciling || !status.value.connected) return;
    }
    const maxBatch = 48;
    final pending = _journal!.hasLocalDraft && _adoptionBlocked
        ? <Map<String, dynamic>>[]
        : _journal!.pendingOperations(_singleCommandsOnly || _journal!.hasLocalDraft ? 1 : maxBatch);
    final archived = pending.isEmpty && !_completedBlocked ? _journal!.firstCompleted : null;
    if (archived case final completed?) {
      pending.add(completed);
    }
    if (pending.isEmpty) return;
    final queued = <WearCommand>[];
    for (final item in pending) {
      final command = WearCommand.fromJson(item);
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
    _sendingContainsDiscard = queued.any((operation) => operation.action == 'saveExit' ||
        (operation.action == 'adoptWorkout' && operation.args['status'] == 'complete'));
    _ackWatchdog = Timer(ackTimeout, () {
      _resetFlight();
      _refreshBeforeSending();
    });
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
        _resetFlight();
        _retryAfterFailure();
      }
    }
  }

  void _retryAfterFailure() {
    _ackWatchdog?.cancel();
    _ackWatchdog = Timer(const Duration(milliseconds: 600), () {
      _ackWatchdog = null;
      unawaited(resume());
    });
  }

  void _stopWaitingForInitialState() {
    _initialStateTimer?.cancel();
    _initialStateTimer = null;
  }

  void _refreshBeforeSending() {
    _waitForState = true;
    _ackWatchdog?.cancel();
    _ackWatchdog = Timer(const Duration(seconds: 5), () {
      _ackWatchdog = null;
      _waitForState = false;
      unawaited(_pump());
    });
    unawaited(requestState());
  }

  void _resetFlight() {
    _ackWatchdog?.cancel();
    _ackWatchdog = null;
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
    final raw = _journal?.snapshot;
    if (raw != null) workout.value = RemoteWorkout.fromJson(raw);
    finishing.value = _hasPendingDiscard();
    _updateNativeSyncPriority();
  }

  void _updateNativeSyncPriority() {
    if (!Platform.isAndroid) return;
    final pending = _journal?.hasPending == true || _journal?.hasLocalDraft == true ||
        _journal?.hasCompleted == true || (_nutrition?.pendingCount ?? 0) > 0;
    if (pending == _nativeSyncPending) return;
    _nativeSyncPending = pending;
    unawaited(_channel.invokeMethod<void>('setSyncPending', {'pending': pending}).catchError((Object _) {}));
  }

  /// A snapshot is stale only when it comes from the same phone process and
  /// predates the revision the watch already knows. A new boot id is accepted
  /// because the phone may have restarted with a lower revision.
  bool _isStaleState(Map<String, dynamic> data) {
    final current = workout.value;
    if (current == null || !current.hasWorkout) return false;
    final boot = data['bootId'] as String?;
    if (boot != null && boot.isNotEmpty && current.bootId.isNotEmpty && boot != current.bootId) {
      return false;
    }
    final rev = (data['rev'] as num?)?.toInt();
    return rev != null && rev < _rev;
  }


  /// Removes the local workout only after the phone confirmed the discard.
  Future<void> _stopLocally({bool clearJournal = true}) async {
    try {
      if (clearJournal) await _journal?.clear();
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
    _updateNativeSyncPriority();
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(List.generate(12, (_) => random.nextInt(256)));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
