import 'dart:async';
import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'remote_workout.dart';
import 'wear_command.dart';
import 'wear_link_status.dart';

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

  final Map<String, Completer<WearAck>> _pending = {};
  final List<WearCommand> _queue = [];
  bool _sending = false;
  int _rev = 0;
  bool _attached = false;

  bool get _supported =>
      debugSupportedOverride ?? (!kIsWeb && Platform.isAndroid);

  /// Test hook so widget/unit tests can exercise the channel on any host.
  @visibleForTesting
  static bool? debugSupportedOverride;

  void attach() {
    if (!_supported || _attached) return;
    _attached = true;
    _channel.setMethodCallHandler(_onNativeCall);
  }

  @visibleForTesting
  void resetForTest() {
    for (final entry in _pending.entries) {
      if (!entry.value.isCompleted) {
        entry.value.complete(WearAck(id: entry.key, ok: false, rev: 0, code: 'reset'));
      }
    }
    _pending.clear();
    _queue.clear();
    _sending = false;
    _rev = 0;
    status.value = const WearLinkStatus();
    workout.value = null;
    pinPrompt.value = null;
  }

  Future<Object?> _onNativeCall(MethodCall call) async {
    switch (call.method) {
      case 'clientEvent':
        final raw = call.arguments;
        if (raw is Map) {
          status.value = WearLinkStatus.fromMap(raw);
          if (!status.value.connected) workout.value = null;
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
          final snapshot = RemoteWorkout.fromJson(Map<String, dynamic>.from(raw));
          _rev = snapshot.rev;
          workout.value = snapshot;
        }
        return null;
      case 'ack':
        final raw = call.arguments;
        if (raw is Map) _onAck(Map<String, dynamic>.from(raw));
        return null;
    }
    return null;
  }

  void _onAck(Map<String, dynamic> raw) {
    final ack = WearAck(
      id: raw['id'] as String? ?? '',
      ok: raw['ok'] as bool? ?? false,
      rev: (raw['rev'] as num?)?.toInt() ?? _rev,
      code: raw['code'] as String? ?? 'error',
      message: raw['message'] as String?,
    );
    if (ack.rev > _rev) _rev = ack.rev;
    _sending = false;
    final completer = _pending.remove(ack.id);
    if (completer != null && !completer.isCompleted) completer.complete(ack);
    if (ack.code == 'conflict') unawaited(requestState());
    _pump();
  }

  Future<List<WearBondedDevice>> bondedDevices() async {
    if (!_supported) return const [];
    try {
      final raw = await _channel.invokeMethod<List>('bondedDevices');
      return [
        for (final item in raw ?? const []) ?WearBondedDevice.fromMap(item),
      ];
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
    if (!_supported) return;
    final current = await refresh();
    if (!current.enabled || current.address.isEmpty || current.connected) return;
    await connect(current.address, current.deviceName);
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
    workout.value = null;
    pinPrompt.value = null;
    return next;
  }

  Future<WearLinkStatus> forget() async {
    if (!_supported) return const WearLinkStatus();
    final result = await _channel.invokeMethod<Map>('forgetPhone');
    final next = WearLinkStatus.fromMap(result);
    status.value = next;
    workout.value = null;
    pinPrompt.value = null;
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
    final id = _newId();
    if (!status.value.connected) {
      return WearAck(id: id, ok: false, rev: _rev, code: 'offline');
    }
    final completer = Completer<WearAck>();
    _pending[id] = completer;
    _queue.add(WearCommand(id: id, baseRev: _rev, action: action, args: args));
    _pump();
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pending.remove(id);
      _queue.removeWhere((command) => command.id == id);
      return WearAck(id: id, ok: false, rev: _rev, code: 'timeout');
    }
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

  Future<WearAck> nextExercise() => command('nextExercise');

  Future<WearAck> prevExercise() => command('prevExercise');

  Future<WearAck> goToExercise(int index) => command('goToExercise', args: {'index': index});

  Future<WearAck> pause() => command('pause');

  Future<WearAck> resumeWorkout() => command('resume');

  Future<WearAck> skipRest() => command('skipRest');

  Future<WearAck> nudgeRest(int seconds) => command('nudgeRest', args: {'seconds': seconds});

  void _pump() {
    if (_sending || _queue.isEmpty) return;
    final command = _queue.removeAt(0);
    _sending = true;
    unawaited(_send(command));
  }

  Future<void> _send(WearCommand command) async {
    try {
      await _channel.invokeMethod<void>('sendCommand', command.toJson());
    } catch (_) {
      _sending = false;
      final completer = _pending.remove(command.id);
      if (completer != null && !completer.isCompleted) {
        completer.complete(WearAck(id: command.id, ok: false, rev: _rev, code: 'error'));
      }
      _pump();
    }
  }

  static String _newId() {
    final random = Random.secure();
    final bytes = Uint8List.fromList(List.generate(12, (_) => random.nextInt(256)));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }
}
