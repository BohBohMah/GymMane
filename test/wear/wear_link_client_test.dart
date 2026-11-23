import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/catalog/exercise_catalog.dart';
import 'package:gymmane/wear/link/wear_workout_handoff.dart';
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

  Future<void> activeWorkout({int rev = 1, double weight = 60, int reps = 8, List<String> applied = const []}) => native('state', {
    'snapshotVersion': 1,
    'rev': rev,
    'bootId': 'b',
    'status': 'active',
    'workoutId': 'w',
    'name': 'Push',
    'currentIndex': 0,
    'appliedOperationIds': applied,
    'restDefaults': {'normal': 90, 'mini': 20, 'change': 0, 'side': 0},
    'exercises': [
      {
        'id': 'bench',
        'name': 'Bench',
        'primary': 'chest',
        'sets': [
          {
            'index': 0,
            'setId': 'set-0',
            'reps': reps,
            'weight': weight,
            'done': false,
            'kind': 'normal',
            'restAfterSec': 120,
          },
          {
            'index': 1,
            'setId': 'set-1',
            'reps': 8,
            'weight': 60.0,
            'done': false,
            'kind': 'normal',
            'restAfterSec': 120,
          },
        ],
      },
    ],
    'serverNow': DateTime.now().toIso8601String(),
  });

  Future<void> idleWorkout({int rev = 2, String boot = 'b'}) => native('state', {
    'snapshotVersion': 1,
    'rev': rev,
    'bootId': boot,
    'status': 'idle',
    'workoutId': '',
    'name': 'GymMane',
    'currentIndex': 0,
    'exercises': [],
    'serverNow': DateTime.now().toIso8601String(),
  });

  setUp(() {
    WearLinkClient.debugSupportedOverride = true;
    calls = [];
    client()
      ..attach()
      ..resetForTest();
    messenger.setMockMethodCallHandler(_channel, (call) async {
      calls.add(call);
      if (call.method == 'sendCommand') return null;
      if (call.method == 'clientStatus') return _connected;
      return null;
    });
  });

  tearDown(() {
    messenger.setMockMethodCallHandler(_channel, null);
    WearLinkClient.debugSupportedOverride = null;
    client().resetForTest();
  });

  test('an offline start sends the latest workout checkpoint as soon as the link returns', () async {
    final start = await client().homeCommand('startExercises', args: {'ids': [kExercises.first.id]});
    expect(start.ok, true);
    final original = client().workout.value!;
    expect((await client().updateSet(0, 0, weight: 8.25, reps: 7)).ok, true);
    expect((await client().completeSet(0, 0)).ok, true);
    await native('clientEvent', _connected);
    final send = calls.where((call) => call.method == 'sendCommand').single.arguments as Map;
    expect(send['action'], 'adoptWorkout');
    expect(send['workoutId'], original.workoutId);
    final payload = readWearHandoff(Map<String, dynamic>.from(send['args'] as Map),
        original.workoutId, DateTime.now());
    expect(payload!.session.exercises.first.sets.first.weight, 8.25);
    expect(payload.session.exercises.first.sets.first.reps, 7);
    expect(payload.session.exercises.first.sets.first.done, true);
    await idleWorkout();
    expect(client().workout.value!.workoutId, original.workoutId);
    await native('ack', {'id': send['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    expect(client().workout.value!.doneSets, 1);
  });

  test('a finished offline workout frees the watch to start another one', () async {
    final exercises = {'ids': [kExercises.first.id]};
    expect((await client().homeCommand('startExercises', args: exercises)).ok, true);
    final first = client().workout.value!.workoutId;
    expect((await client().completeSet(0, 0)).ok, true);
    expect((await client().finishAndSave()).ok, true);
    expect(client().workout.value?.hasWorkout, false);
    expect((await client().homeCommand('startExercises', args: exercises)).ok, true);
    final second = client().workout.value!.workoutId;
    expect(second, isNot(first));
    await native('clientEvent', _connected);
    var sent = calls.where((call) => call.method == 'sendCommand').single.arguments as Map;
    expect(sent['workoutId'], second);
    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
    sent = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect(sent['action'], 'uploadCompletedWorkout');
    expect(sent['workoutId'], first);
  });

  test('a command updates immediately and stays queued until the phone ack', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();
    final future = client().completeSet(0, 0);
    await Future<void>.delayed(Duration.zero);
    expect(calls.single.method, 'sendCommand');
    final sent = calls.single.arguments as Map;
    expect(sent['action'], 'completeSet');
    expect((sent['args'] as Map)['setIndex'], 0);

    final optimistic = await future;
    expect(optimistic.ok, isTrue);
    expect(optimistic.code, 'queued');
    expect(client().workout.value!.doneSets, 1);

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
            {'index': 0, 'setId': 'set-0', 'reps': 8, 'weight': 60.0, 'done': true, 'kind': 'normal'},
          ],
        },
      ],
      'serverNow': DateTime.now().toIso8601String(),
    });
    expect(client().workout.value!.doneSets, 1);

    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
  });

  test('an offline completion starts the rest locally and sends its deadline', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();
    final future = client().completeSet(0, 0);
    await Future<void>.delayed(Duration.zero);

    final rest = client().workout.value!.rest;
    expect(rest, isNotNull);
    expect(rest!.totalSeconds, 120);

    final sent = calls.single.arguments as Map;
    final args = sent['args'] as Map;
    expect(DateTime.parse(args['restEndsAt'] as String), rest.endsAt);
    expect(args['restTotalSec'], 120);

    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 1, 'code': 'ok'});
    await future;
  });

  test('an idle phone snapshot clears a workout with unsynced edits', () async {
    await activeWorkout(rev: 1);
    final ack = await client().updateSet(0, 0, weight: 65);
    expect(ack.code, 'queued');
    expect(client().workout.value!.exercises.first.sets.first.weight, 65);

    await idleWorkout(rev: 2);

    expect(client().workout.value!.hasWorkout, isFalse);
    expect(client().finishing.value, isFalse);
    expect(client().workout.value!.exercises, isEmpty);
  });

  test('a stale idle snapshot cannot wipe the current workout', () async {
    await activeWorkout(rev: 5);
    await idleWorkout(rev: 3);
    expect(client().workout.value!.hasWorkout, isTrue);
  });

  test('finishing offline keeps the workout and refuses further edits', () async {
    await activeWorkout(rev: 1);
    final ack = await client().finishAndDiscard();
    expect(ack.ok, isTrue);
    expect(client().finishing.value, isTrue);
    expect(client().workout.value!.hasWorkout, isTrue);

    final edit = await client().updateSet(0, 0, weight: 70);
    expect(edit.ok, isFalse);
    expect(edit.code, 'finishing');
    expect(client().workout.value!.exercises.first.sets.first.weight, 60);
  });

  test('finish sends every queued edit before discarding and clears after ack', () async {
    await activeWorkout(rev: 1);
    await client().updateSet(0, 0, weight: 65);
    await client().finishAndDiscard();

    await native('clientEvent', _connected);
    await activeWorkout(rev: 4);
    await Future<void>.delayed(Duration.zero);

    Map sentCommand() => calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    final sent = sentCommand();
    final operations = (sent['args'] as Map)['operations'] as List;
    expect(operations.map((op) => op['action']), ['updateSet', 'saveExit']);
    expect(operations.first['args']['weight'], 65);
    expect(client().workout.value!.hasWorkout, isTrue);

    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 6, 'code': 'ok'});
    await Future<void>.delayed(Duration.zero);
    expect(client().workout.value!.hasWorkout, isFalse);
    expect(client().finishing.value, isFalse);
  });

  test('complete and save queues finish before exit and works offline-first', () async {
    await native('clientEvent', _connected);
    await activeWorkout(rev: 1);
    calls.clear();

    final ack = await client().finishAndSave();
    expect(ack.ok, isTrue);
    expect(client().workout.value!.finished, isTrue);
    expect(client().finishing.value, isTrue);
    await Future<void>.delayed(Duration.zero);

    Map sentCommand() => calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    final sent = sentCommand();
    final operations = (sent['args'] as Map)['operations'] as List;
    expect(operations.map((op) => op['action']), ['finish', 'saveExit']);
    expect(operations.last['args']['requiresCompleted'], true);

    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    await Future<void>.delayed(Duration.zero);
    expect(client().workout.value!.hasWorkout, isFalse);
    expect(client().finishing.value, isFalse);
  });

  test('an idle phone snapshot during a discard stops the watch safely', () async {
    await activeWorkout(rev: 1);
    await client().finishAndDiscard();
    await native('clientEvent', _connected);
    await activeWorkout(rev: 2);
    await Future<void>.delayed(Duration.zero);
    final sent = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect(sent['action'], 'saveExit');

    await idleWorkout(rev: 3);
    expect(client().workout.value!.hasWorkout, isFalse);
    expect(client().finishing.value, isFalse);

    // The late acknowledgement must be harmless after the idle snapshot.
    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    await Future<void>.delayed(Duration.zero);
    expect(client().workout.value!.hasWorkout, isFalse);
  });

  test('a late rejected ack after an idle snapshot cannot revive the workout', () async {
    await native('clientEvent', _connected);
    await activeWorkout(rev: 1);
    calls.clear();
    final pending = client().pause();
    await Future<void>.delayed(Duration.zero);
    final sent = calls.where((call) => call.method == 'sendCommand').single.arguments as Map;

    await idleWorkout(rev: 2);
    expect(client().workout.value!.hasWorkout, isFalse);

    await native('ack', {'id': sent['id'], 'ok': false, 'rev': 2, 'code': 'no_session'});
    final ack = await pending;
    expect(ack.ok, isTrue);
    expect(ack.code, 'queued');
    expect(client().workout.value!.hasWorkout, isFalse);
  });

  test('a discarded session acknowledged as missing still clears the watch', () async {
    await activeWorkout(rev: 1);
    await client().finishAndDiscard();
    await native('clientEvent', _connected);
    await activeWorkout(rev: 2);
    await Future<void>.delayed(Duration.zero);
    final sent = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;

    await native('ack', {'id': sent['id'], 'ok': false, 'rev': 2, 'code': 'no_session'});
    await Future<void>.delayed(Duration.zero);
    expect(client().workout.value!.hasWorkout, isFalse);
    expect(client().finishing.value, isFalse);
  });

  test('a conflict asks the phone for a fresh state', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();
    final future = client().pause();
    await Future<void>.delayed(Duration.zero);
    final sent = calls.single.arguments as Map;
    await native('ack', {'id': sent['id'], 'ok': false, 'rev': 7, 'code': 'conflict'});
    expect(calls.map((call) => call.method), contains('requestState'));
    await activeWorkout(rev: 7);
    await Future<void>.delayed(Duration.zero);
    final retried = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect(retried['id'], sent['id']);
    expect(retried['baseRev'], 7);
    await native('ack', {'id': retried['id'], 'ok': true, 'rev': 8, 'code': 'ok'});
    expect((await future).ok, isTrue);
  });

  test('offline commands are durably applied without touching the transport', () async {
    await activeWorkout();
    calls.clear();
    final ack = await client().updateSet(0, 0, weight: 65);
    expect(ack.ok, isTrue);
    expect(ack.code, 'queued');
    expect(client().workout.value!.exercises.first.sets.first.weight, 65);
    expect(calls, isEmpty);
  });

  test('a home action works with a connected phone and no workout', () async {
    final day = DateTime.now().toIso8601String().split('T').first;
    final offline = await client().homeCommand('water', args: {'ml': 250});
    expect(offline.ok, false);
    expect(calls.where((call) => call.method == 'sendCommand'), isEmpty);

    await native('clientEvent', _connected);
    await native('state', {
      'rev': 1,
      'bootId': 'b',
      'status': 'idle',
      'workoutId': '',
      'exercises': [],
      'home': {'day': day, 'nutrition': true, 'water': 0, 'glass': 250, 'nutritionReceipts': []},
    });
    final pending = client().homeCommand('water', args: {'day': day, 'ml': 250});
    await Future<void>.delayed(Duration.zero);
    final sent = calls.where((call) => call.method == 'sendCommand').single.arguments as Map;
    expect(sent['action'], 'home/water');
    expect(sent.containsKey('workoutId'), false);
    await native('state', {
      'rev': 2,
      'bootId': 'b',
      'status': 'idle',
      'workoutId': '',
      'exercises': [],
      'home': {'day': day, 'nutrition': true, 'water': 250, 'glass': 250, 'nutritionReceipts': [sent['id']]},
    });
    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
    expect((await pending).ok, true);
    expect(client().home.value!['water'], 250);
    expect(client().workout.value!.hasWorkout, false);
  });

  test('offline creatine and its undo are sent in order on reconnect', () async {
    final day = DateTime.now().toIso8601String().split('T').first;
    Future<void> receiveHome({List<String> receipts = const [], bool taken = false}) => native('state', {
      'rev': 5,
      'bootId': 'b',
      'status': 'idle',
      'workoutId': '',
      'exercises': [],
      'home': {
        'day': day,
        'nutrition': true,
        'nutritionReceipts': receipts,
        'supplements': [{'id': 'creatine', 'done': taken}],
      },
    });
    await native('clientEvent', _connected);
    await receiveHome();
    await native('clientEvent', {..._connected, 'state': 'connecting'});
    for (final taken in [true, false]) {
      final ack = await client().homeCommand(
        'supplement',
        args: {'day': day, 'id': 'creatine', 'taken': taken},
      );
      expect(ack.code, 'queued');
      expect(client().home.value!['supplements'][0]['done'], taken);
    }
    expect(client().nutritionPending.value, 2);
    expect(calls.where((call) => call.method == 'sendCommand'), isEmpty);
    await native('clientEvent', _connected);
    await receiveHome();
    List<Map> sent() => calls.where((call) => call.method == 'sendCommand').map((c) => c.arguments as Map).toList();
    final first = sent().single;
    expect(first['args']['taken'], true);
    await receiveHome(receipts: [first['id'] as String], taken: true);
    expect(client().home.value!['supplements'][0]['done'], false);
    await native('ack', {'id': first['id'], 'ok': true, 'rev': 5, 'code': 'ok'});
    final second = sent().last;
    expect(second['args']['taken'], false);
    await receiveHome(receipts: [second['id'] as String]);
    await native('ack', {'id': second['id'], 'ok': true, 'rev': 5, 'code': 'ok'});
    expect(client().nutritionPending.value, 0);
    expect(client().home.value!['supplements'][0]['done'], false);
  });

  test('rapid connected weight taps update locally without losing any taps', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();

    final replies = await Future.wait([
      client().adjustSet(0, 0, field: 'weight', delta: 2.5),
      client().adjustSet(0, 0, field: 'weight', delta: 2.5),
      client().adjustSet(0, 0, field: 'weight', delta: 2.5),
    ]);

    expect(replies.every((ack) => ack.ok && ack.code == 'queued'), isTrue);
    expect(client().workout.value!.exercises.first.sets.first.weight, 67.5);
    expect(calls.where((call) => call.method == 'sendCommand').length, 1);
  });

  test('reconnect reads the phone revision before replaying absolute weight', () async {
    await activeWorkout(weight: 20);
    await client().adjustSet(0, 0, field: 'weight', delta: 20);
    calls.clear();

    await native('clientEvent', {..._connected, 'pushesInitialState': true});
    expect(calls.where((call) => call.method == 'sendCommand'), isEmpty);
    await activeWorkout(rev: 2, weight: 40);

    final sent = calls.where((call) => call.method == 'sendCommand').single.arguments as Map;
    expect(sent['baseRev'], 2);
    expect(sent['action'], 'updateSet');
    expect((sent['args'] as Map)['weight'], 40);
    expect((sent['args'] as Map).containsKey('delta'), false);
    expect(client().workout.value!.exercises.first.sets.first.weight, 40);

    // The snapshot confirms durability even if the Bluetooth ACK was lost.
    await activeWorkout(rev: 3, weight: 40, applied: [sent['id'] as String]);
    await client().adjustSet(0, 0, field: 'weight', delta: 2.5);
    await Future<void>.delayed(Duration.zero);
    final next = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect((next['args'] as Map)['weight'], 42.5);
  });

  test('late phone states never make rapid connected taps jump backwards', () async {
    await native('clientEvent', _connected);
    await activeWorkout(reps: 10);
    calls.clear();

    await client().adjustSet(0, 0, field: 'reps', delta: 1);
    await client().adjustSet(0, 0, field: 'reps', delta: 1);
    expect(client().workout.value!.exercises.first.sets.first.reps, 12);

    Map lastCommand() => calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    final first = lastCommand();
    await native('ack', {'id': first['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
    await Future<void>.delayed(Duration.zero);
    final second = lastCommand();
    expect(second['baseRev'], 2);

    // This is the result of the first press, arriving while the second is in flight.
    await activeWorkout(rev: 2, reps: 11);
    expect(client().workout.value!.exercises.first.sets.first.reps, 12);

    await native('ack', {'id': second['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    await activeWorkout(rev: 3, reps: 12);
    expect(client().workout.value!.exercises.first.sets.first.reps, 12);
  });

  test('offline backlog is transmitted as one synchronization batch', () async {
    await activeWorkout();
    calls.clear();
    await client().adjustSet(0, 0, field: 'weight', delta: 2.5);
    await client().adjustSet(0, 0, field: 'weight', delta: 2.5);
    await client().adjustSet(0, 0, field: 'reps', delta: 1);

    await native('clientEvent', _connected);
    await Future<void>.delayed(Duration.zero);
    final sentCalls = calls.where((call) => call.method == 'sendCommand').toList();
    expect(sentCalls.length, 1);
    final batch = sentCalls.single.arguments as Map;
    expect(batch['action'], 'syncBatch');
    expect(((batch['args'] as Map)['operations'] as List).length, 3);

    // Native sends the resulting state immediately before the acknowledgement.
    // It must not make the watch replay the relative edits twice.
    await activeWorkout(rev: 2, weight: 65, reps: 9);
    expect(client().workout.value!.exercises.first.sets.first.weight, 65);
    expect(client().workout.value!.exercises.first.sets.first.reps, 9);
    await native('ack', {'id': batch['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
    expect(client().workout.value!.exercises.first.sets.first.weight, 65);
    expect(client().workout.value!.exercises.first.sets.first.reps, 9);
  });

  test('queued offline edit replays with stable identities after reconnect', () async {
    await activeWorkout();
    calls.clear();
    final queued = await client().updateSet(0, 0, weight: 67.5);
    expect(queued.code, 'queued');

    await native('clientEvent', _connected);
    await Future<void>.delayed(Duration.zero);
    final first = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect(first['baseRev'], 1);
    await native('ack', {'id': first['id'], 'ok': false, 'rev': 4, 'code': 'conflict'});
    await activeWorkout(rev: 4);
    await Future<void>.delayed(Duration.zero);
    final sent = calls.where((call) => call.method == 'sendCommand').last.arguments as Map;
    expect(sent['action'], 'updateSet');
    expect(sent['baseRev'], 4);
    expect((sent['args'] as Map)['exerciseId'], 'bench');
    expect((sent['args'] as Map)['setId'], 'set-0');
    expect((sent['args'] as Map)['weight'], 67.5);
    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 5, 'code': 'ok'});
    expect(client().workout.value!.exercises.first.sets.first.weight, 67.5);
  });

  test('resuming an already connected client requests a fresh snapshot', () async {
    await client().resume();
    expect(calls.map((call) => call.method), containsAllInOrder(['clientStatus', 'requestState']));
  });

  test('unrelated refresh ack does not release a pending command', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();
    final first = await client().pause();
    final second = await client().nextExercise();
    await Future<void>.delayed(Duration.zero);
    final sent = calls.single.arguments as Map;
    await native('ack', {'id': 'refresh', 'ok': true, 'rev': 2, 'code': 'ok'});
    expect(calls.where((c) => c.method == 'sendCommand').length, 1);
    await native('ack', {'id': sent['id'], 'ok': true, 'rev': 3, 'code': 'ok'});
    expect(first.ok, isTrue);
    await Future<void>.delayed(Duration.zero);
    final next = calls.where((c) => c.method == 'sendCommand').last.arguments as Map;
    expect(next['baseRev'], 3);
    await native('ack', {'id': next['id'], 'ok': true, 'rev': 4, 'code': 'ok'});
    expect(second.ok, isTrue);
  });

  test('timed out command remains durable and retries with the same id', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();
    client().ackTimeout = const Duration(milliseconds: 20);
    final first = client().pause();
    await Future<void>.delayed(Duration.zero);
    final old = calls.single.arguments as Map;
    expect((await first).code, 'queued');
    await Future<void>.delayed(const Duration(milliseconds: 40));
    expect(calls.map((call) => call.method), contains('requestState'));
    await activeWorkout();
    await Future<void>.delayed(Duration.zero);
    final retry = calls.where((c) => c.method == 'sendCommand').last.arguments as Map;
    expect(retry['id'], old['id']);
    await native('ack', {'id': retry['id'], 'ok': true, 'rev': 2, 'code': 'ok'});
  });

  test('phone state with a durable receipt recovers a lost acknowledgement', () async {
    await native('clientEvent', _connected);
    await activeWorkout(reps: 10);
    client().ackTimeout = const Duration(milliseconds: 20);
    calls.clear();
    await client().adjustSet(0, 0, field: 'reps', delta: 1);
    await Future<void>.delayed(Duration.zero);
    final sent = calls.single.arguments as Map;
    await Future<void>.delayed(const Duration(milliseconds: 40));
    await activeWorkout(rev: 2, reps: 11, applied: [sent['id'] as String]);
    expect(client().workout.value!.exercises.first.sets.first.reps, 11);
    expect(calls.where((call) => call.method == 'sendCommand'), hasLength(1));
  });

  test('disconnect keeps pending commands queued on the watch', () async {
    await native('clientEvent', _connected);
    await activeWorkout();
    calls.clear();
    final first = client().pause();
    final second = client().nextExercise();
    await native('clientEvent', {..._connected, 'state': 'connecting'});
    expect((await first).code, 'queued');
    expect((await second).code, 'queued');
    expect(client().workout.value, isNotNull);
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
