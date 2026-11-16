import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/wear/link/wear_link_client.dart';
import 'package:gymmane/wear/link/wear_link_status.dart';

const _channel = MethodChannel('gymmane/wearlink');

const _connected = {
  'supported': true,
  'enabled': true,
  'state': 'connected',
  'deviceName': 'Pixel',
  'address': 'AA:BB',
  'error': '',
  'pairingCode': '',
  'sdk': 33,
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  late List<MethodCall> calls;

  WearLinkClient client() => WearLinkClient.instance;

  Future<void> native(String method, [Object? arguments]) async {
    ServicesBinding.instance.channelBuffers.push(
      _channel.name,
      const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments)),
      (_) {},
    );
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    WearLinkClient.debugSupportedOverride = true;
    calls = [];
    client()
      ..attach()
      ..resetForTest();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'sendCommand') return null;
      if (call.method == 'requestPermissions') return null;
      if (call.method == 'clientStatus') return _connected;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    WearLinkClient.debugSupportedOverride = null;
    client().resetForTest();
  });

  test('a command waits for the phone ack', () async {
    await native('clientEvent', _connected);
    final future = client().completeSet(0, 1);
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'sendCommand');
    final sent = calls.single.arguments as Map;
    expect(sent['action'], 'completeSet');
    expect((sent['args'] as Map)['setIndex'], 1);

    var done = false;
    future.then((_) => done = true);
    await Future<void>.delayed(Duration.zero);
    expect(done, isFalse, reason: 'must not report success before the ack');

    await native('state', {
      'rev': 2,
      'bootId': 'b',
      'status': 'active',
      'workoutId': 'w',
      'name': 'Push',
      'currentIndex': 0,
      'exercises': [
        {
          'id': 'bench',
          'name': 'Bench',
          'primary': 'chest',
          'sets': [
            {'index': 0, 'reps': 8, 'weight': 60.0, 'done': true, 'kind': 'normal'},
          ],
        },
      ],
      'serverNow': DateTime.now().toIso8601String(),
    });
    expect(client().workout.value!.doneSets, 1);

    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
    await future;
    expect(done, isTrue);
  });

  test('a conflict asks the phone for a fresh state', () async {
    await native('clientEvent', _connected);
    final future = client().pause();
    await Future<void>.delayed(Duration.zero);
    final sent = calls.single.arguments as Map;
    await native('ack', {'id': sent['id'], 'ok': false, 'rev': 7, 'code': 'conflict'});
    final ack = await future;
    expect(ack.ok, isFalse);
    expect(ack.code, 'conflict');
    expect(calls.map((call) => call.method), contains('requestState'));

    final next = client().nextExercise();
    await Future<void>.delayed(Duration.zero);
    final retried = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect(retried['baseRev'], 7);
    await native('ack', {'id': retried['id'], 'ok': true, 'rev': 8, 'code': 'ok'});
    await next;
  });

  test('offline commands fail without touching the transport', () async {
    final ack = await client().skipRest();
    expect(ack.ok, isFalse);
    expect(ack.code, 'offline');
    expect(calls, isEmpty);
  });

  test('resuming an already connected client requests a fresh snapshot', () async {
    await client().resume();
    expect(calls.map((call) => call.method), containsAllInOrder(['clientStatus', 'requestState']));
  });

  test('unrelated refresh ack does not release a pending command', () async {
    await native('clientEvent', _connected);
    final first = client().pause();
    final second = client().nextExercise();
    await Future<void>.delayed(Duration.zero);
    final sent = calls.single.arguments as Map;
    await native('ack', {'id': 'refresh', 'ok': true, 'rev': 2, 'code': 'ok'});
    expect(calls.where((c) => c.method == 'sendCommand').length, 1);
    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    await first;
    await Future<void>.delayed(Duration.zero);
    final next = calls.where((c) => c.method == 'sendCommand').last.arguments as Map;
    expect(next['baseRev'], 3);
    await native('ack', {'id': next['id'], 'ok': true, 'rev': 4, 'code': 'ok'});
    await second;
  });

  test('timed out command releases queue and late ack does not release next', () async {
    await native('clientEvent', _connected);
    final first = client().command('pause', timeout: const Duration(milliseconds: 20));
    final second = client().nextExercise();
    await Future<void>.delayed(Duration.zero);
    final old = calls.single.arguments as Map;
    expect((await first).code, 'timeout');
    await Future<void>.delayed(Duration.zero);
    final next = calls.where((c) => c.method == 'sendCommand').last.arguments as Map;
    final third = client().prevExercise();
    await native('ack', {'id': old['id'], 'ok': true, 'rev': 1, 'code': 'ok'});
    expect(calls.where((c) => c.method == 'sendCommand').length, 2);
    await native('ack', {'id': next['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
    await second;
    await Future<void>.delayed(Duration.zero);
    final last = calls.where((c) => c.method == 'sendCommand').last.arguments as Map;
    await native('ack', {'id': last['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    await third;
  });

  test('disconnect fails pending and queued commands', () async {
    await native('clientEvent', _connected);
    final first = client().pause();
    final second = client().nextExercise();
    await native('clientEvent', {..._connected, 'state': 'connecting'});
    expect((await first).code, 'offline');
    expect((await second).code, 'offline');
  });

  test('native status and pin prompts update the notifiers', () async {
    await native('clientEvent', {
      'supported': true,
      'enabled': true,
      'state': 'pairing',
      'deviceName': 'Pixel',
      'address': 'AA:BB',
      'error': '',
      'pairingCode': '',
      'sdk': 33,
    });
    expect(client().status.value.state, WearLinkState.pairing);
    await native('pinRequired', {'phoneName': 'Pixel'});
    expect(client().pinPrompt.value, 'Pixel');
  });

  test('nested rest and summary maps survive the native method codec', () async {
    await native('clientEvent', _connected);
    final endsAt = DateTime.now().add(const Duration(seconds: 90));
    await native('state', {
      'rev': 3,
      'bootId': 'test',
      'status': 'active',
      'workoutId': 'live',
      'rest': {'endsAt': endsAt.toIso8601String(), 'totalSec': 90, 'switchSides': false},
      'summary': {'volumeKg': 100, 'sets': 2, 'durationSec': 60},
      'exercises': [],
      'serverNow': DateTime.now().toIso8601String(),
    });
    final workout = client().workout.value!;
    expect(workout.rest?.totalSeconds, 90);
    expect(workout.rest?.remaining().inSeconds, greaterThan(80));
    expect(workout.summary?.sets, 2);
  });

  test('forgetting clears the mirrored workout', () async {
    await native('clientEvent', _connected);
    await native('state', {
      'rev': 1,
      'bootId': 'b',
      'status': 'idle',
      'workoutId': '',
      'name': 'GymMane',
      'currentIndex': 0,
      'exercises': [],
      'serverNow': DateTime.now().toIso8601String(),
    });
    expect(client().workout.value, isNotNull);
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      return {
        'supported': true,
        'enabled': false,
        'state': 'disabled',
        'deviceName': '',
        'address': '',
        'error': '',
        'pairingCode': '',
        'sdk': 33,
      };
    });
    await client().forget();
    expect(client().workout.value, isNull);
    expect(client().status.value.enabled, isFalse);
  });
}
