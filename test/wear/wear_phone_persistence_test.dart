import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/models/live_session.dart';
import 'package:gymmane/services/local_store.dart';
import 'package:gymmane/state/fit_state.dart';
import 'package:gymmane/wear/link/wear_link_server.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('phone state and operation record are saved together in the normal store', () async {
    SharedPreferences.setMockInitialValues({});
    await Store.instance.init();
    final fit = FitState();
    var notifications = 0;
    fit.addListener(() => notifications++);
    fit.session = WorkoutSession()
      ..exercises = [
        SessionExercise('exercise', 'Example', 'test', [SessionSet(8, 20, false)]),
      ];
    fit.applyWearTransaction(() {
      fit.session!.exercises.first.sets.first.weight = 25;
      fit.wearAppliedOperations['operation'] = 'signature';
      fit.setSessionWeight(0, 0, 25);
      fit.setSessionReps(0, 0, 10);
      fit.persistNow();
    });
    expect(Store.instance.load(), isEmpty);
    expect(notifications, 1);
    await fit.persistWearTransaction();
    final loaded = Store.instance.load();
    final restored = WorkoutSession.fromJson((loaded['live'] as Map).cast<String, dynamic>());
    expect(restored.exercises.first.sets.first.weight, 25);
    expect((loaded['wearAppliedOperations'] as Map)['operation'], 'signature');
    fit.dispose();
  });

  test('phone command persists before acknowledgement and duplicate is not reapplied', () async {
    final server = WearLinkServer.instance;
    fit.wearAppliedOperations.clear();
    fit.session = WorkoutSession()
      ..exercises = [
        SessionExercise('exercise', 'Example', 'test', [SessionSet(8, 20, false)]),
      ];
    final set = fit.session!.exercises.first.sets.first;
    final command = {
      'id': 'durable-command',
      'baseRev': 0,
      'action': 'updateSet',
      'workoutId': fit.session!.sessionId,
      'args': {
        'exerciseIndex': 0,
        'exerciseId': 'exercise',
        'setIndex': 0,
        'setId': set.setId,
        'weight': 25.0,
      },
    };
    final replies = await Future.wait([server.debugCommand(command), server.debugCommand(command)]);
    expect(replies.every((reply) => reply['ok'] == true), isTrue);
    final saved = Store.instance.load();
    final restored = WorkoutSession.fromJson((saved['live'] as Map).cast<String, dynamic>());
    expect(restored.exercises.first.sets.first.weight, 25);
    expect((saved['wearAppliedOperations'] as Map).containsKey('durable-command'), isTrue);
    fit.session = null;
    fit.wearAppliedOperations.clear();
    fit.loadFromStore();
    final restoredSet = fit.session!.exercises.first.sets.first;
    restoredSet.weight = 30;
    final duplicate = await server.debugCommand(command);
    expect(duplicate['ok'], isTrue);
    expect(restoredSet.weight, 30);
    final invalid = await server.debugCommand({...command, 'action': 'completeSet'});
    expect(invalid['code'], 'duplicate_id');
  });

  test('a watch discard removes the live session and publishes idle', () async {
    SharedPreferences.setMockInitialValues({});
    await Store.instance.init();
    final server = WearLinkServer.instance;
    fit.wearAppliedOperations.clear();
    fit.setWearLink(true);
    fit.session = WorkoutSession()
      ..exercises = [
        SessionExercise('exercise', 'Example', 'test', [SessionSet(8, 20, true)]),
      ];
    final command = {
      'id': 'watch-discard',
      'baseRev': server.debugRevision,
      'action': 'saveExit',
      'workoutId': fit.session!.sessionId,
      'args': <String, dynamic>{},
    };
    final reply = await server.debugCommand(command);
    expect(reply['ok'], isTrue);
    expect(fit.session, isNull);
    expect(Store.instance.load().containsKey('live'), isFalse);
    fit.setWearLink(false);
  });

  test('a synchronization batch applies and persists many edits at once', () async {
    SharedPreferences.setMockInitialValues({});
    await Store.instance.init();
    final server = WearLinkServer.instance;
    fit.wearAppliedOperations.clear();
    fit.session = WorkoutSession()
      ..exercises = [
        SessionExercise('exercise', 'Example', 'test', [SessionSet(8, 20, false)]),
      ];
    final session = fit.session!;
    final set = session.exercises.first.sets.first;
    Map<String, dynamic> adjustment(String id, String field, num delta) => {
      'id': id,
      'baseRev': server.debugRevision,
      'action': 'adjustSet',
      'workoutId': session.sessionId,
      'args': {
        'exerciseIndex': 0,
        'exerciseId': 'exercise',
        'setIndex': 0,
        'setId': set.setId,
        'field': field,
        'delta': delta,
      },
    };

    final reply = await server.debugCommand({
      'id': 'batch-command',
      'baseRev': server.debugRevision,
      'action': 'syncBatch',
      'workoutId': session.sessionId,
      'args': {
        'operations': [
          adjustment('batch-1', 'weight', 2.5),
          adjustment('batch-2', 'weight', 2.5),
          adjustment('batch-3', 'reps', 1),
        ],
      },
    });

    expect(reply['ok'], isTrue);
    expect(set.weight, 25);
    expect(set.reps, 9);
    final saved = Store.instance.load();
    final operations = saved['wearAppliedOperations'] as Map;
    expect(operations.keys, containsAll(['batch-1', 'batch-2', 'batch-3', 'batch-command']));
  });
}
