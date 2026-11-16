import 'dart:io' show Platform;
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../state/fit_state.dart';
import 'fit_wear_workout_api.dart';
import 'wear_command.dart';
import 'wear_command_executor.dart';
import 'wear_link_diagnostics.dart';
import 'wear_link_status.dart';
import 'wear_snapshot.dart';

class WearLinkServer {
  WearLinkServer._();

  static final instance = WearLinkServer._();
  static const _channel = MethodChannel('gymmane/wearlink');

  final ValueNotifier<WearLinkStatus> status = ValueNotifier(const WearLinkStatus());

  final WearSnapshotBuilder _snapshots = WearSnapshotBuilder(FitWearWorkoutApi());
  final WearCommandExecutor _executor = WearCommandExecutor(FitWearWorkoutApi());
  final WearCommandLedger _ledger = WearCommandLedger();
  final String _bootId = _randomId();

  int _rev = 0;
  String _lastFingerprint = '';
  WearSnapshot? _lastSnapshot;
  bool _attached = false;
  bool _applying = false;
  bool _dirtyWhileApplying = false;
  Future<int>? _pushTask;

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

    final known = _ledger.fetch(command.id);
    if (known != null) return known.toJson();

    wearLinkDiagnostic('phone command action=${command.action} rev=$_rev');
    _applying = true;
    try {
      final execution = _executor.execute(command, _rev);
      final rev = execution.changed || command.action == 'requestState' ? await _push(force: true) : _rev;
      final ack = WearAck(
        id: command.id,
        ok: execution.ok,
        rev: rev,
        code: execution.code,
        message: execution.message,
      );
      _ledger.remember(ack);
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
    final fingerprint = _snapshots.fingerprint();
    if (!force && fingerprint == _lastFingerprint) return _rev;
    _lastFingerprint = fingerprint;
    _rev += 1;
    final snapshot = WearSnapshot(
      rev: _rev,
      bootId: _bootId,
      json: _snapshots.build(rev: _rev, bootId: _bootId),
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
