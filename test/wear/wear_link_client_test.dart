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
