import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/models/live_session.dart';
import 'package:gymmane/models/workout.dart';
import 'package:gymmane/wear/link/remote_workout.dart';
import 'package:gymmane/wear/link/wear_command.dart';
import 'package:gymmane/wear/link/wear_command_executor.dart';
import 'package:gymmane/wear/link/wear_snapshot.dart';
import 'package:gymmane/wear/link/wear_workout_api.dart';

class FakeWearApi implements WearWorkoutApi {
  @override
  WorkoutSession? session;
  @override
  bool paused = false;
  @override
  bool parked = false;
  @override
  int elapsedSeconds = 120;
  @override
  int restTotal = 90;
  @override
  String effortMode = '';
  @override
  String workoutName = 'Push day';

  @override
  bool get complete => session?.complete ?? false;

  @override
  bool get hasData => session != null;

  void _set(int exercise, int set, void Function(SessionSet value) change) {
    change(session!.exercises[exercise].sets[set]);
  }

  @override
  void continueSession() => session!.complete = false;

  @override
  void finish({int? elapsedSeconds}) {
    session!.complete = true;
    session!.summaryDuration = elapsedSeconds;
  }

  @override
  void goNextPending() {
    final current = session!.currentIndex;
    for (var offset = 1; offset <= session!.exercises.length; offset++) {
      final index = (current + offset) % session!.exercises.length;
      if (session!.exercises[index].sets.any((set) => !set.done)) {
        session!.currentIndex = index;
        return;
      }
    }
  }

  @override
  void goToExercise(int index) => session!.currentIndex = index;

  @override
  void nextExercise() {
    final last = session!.exercises.length - 1;
    session!.currentIndex = (session!.currentIndex + 1).clamp(0, last);
  }

  @override
  void nudgeRest(int seconds) {
    final end = session!.restEndsAt;
    if (end != null) session!.restEndsAt = end.add(Duration(seconds: seconds));
  }

  @override
  void previousExercise() => session!.currentIndex = (session!.currentIndex - 1).clamp(0, 999);

  @override
  void resumeSession() => parked = false;

  @override
  void saveAndExit() => parked = true;

  @override
  void setKm(int exercise, int set, double km) => _set(exercise, set, (value) => value.km = km);

  @override
  void setKind(int exercise, int set, SetKind kind) => _set(exercise, set, (value) => value.kind = kind);

  @override
  void setReps(int exercise, int set, int reps) => _set(exercise, set, (value) => value.reps = reps);

  @override
  void setRepsRight(int exercise, int set, int reps) => _set(exercise, set, (value) => value.repsR = reps);

  @override
  void setRest(int seconds) {
    session!.restEndsAt = DateTime.now().add(Duration(seconds: seconds));
    restTotal = seconds;
  }

  @override
  void setRpe(int exercise, int set, double? rpe) => _set(exercise, set, (value) => value.rpe = rpe);

  @override
  void setSeconds(int exercise, int set, int seconds) => _set(exercise, set, (value) => value.sec = seconds);

  @override
  void setWeight(int exercise, int set, double kg) => _set(exercise, set, (value) => value.weight = kg);

  @override
  int normalRestAfter(int exercise, int set) => restAfter;

  @override
  Map<String, int> get restDefaults => const {'normal': 90, 'mini': 20, 'change': 0, 'side': 0};

  @override
  void adoptRest(DateTime endsAt, int totalSec) {
    adoptedRestEndsAt = endsAt;
    adoptedRestTotal = totalSec;
    session!.restEndsAt = endsAt;
  }

  int restAfter = 90;
  DateTime? adoptedRestEndsAt;
  int? adoptedRestTotal;

  @override
  void skipRest() {
    session!.restEndsAt = null;
    session!.restFrozen = null;
  }

  @override
  void togglePause() => paused = !paused;

  @override
  void toggleSet(int exercise, int set) => _set(exercise, set, (value) => value.done = !value.done);
}

FakeWearApi apiWithSession({bool withRest = false}) {
  final session = WorkoutSession()
    ..name = 'Push day'
    ..loggedAt = DateTime(2026, 11, 15, 18)
    ..currentIndex = 0;
  session.exercises = [
    SessionExercise('bench', 'Bench press', 'chest', [SessionSet(8, 60, false), SessionSet(8, 62.5, false)]),
    SessionExercise('row', 'Row', 'back', [
      SessionSet(10, 40, true),
      SessionSet(10, 42.5, false),
    ], linkedNext: true),
  ];
  if (withRest) session.restEndsAt = DateTime.now().add(const Duration(seconds: 75));
  return FakeWearApi()..session = session;
}

WearCommand command(String action, {int baseRev = 0, Map<String, dynamic> args = const {}}) =>
    WearCommand(id: 'cmd-1', baseRev: baseRev, action: action, args: args);

void main() {
  test('session identities survive persistence and differ for new workouts', () {
    final first = apiWithSession().session!;
    final second = apiWithSession().session!;
    expect(first.sessionId, isNot(second.sessionId));
    final restored = WorkoutSession.fromJson(first.toJson());
    expect(restored.sessionId, first.sessionId);
    expect(WearSnapshotBuilder(FakeWearApi()..session = restored).workoutId(), first.sessionId);
    final legacy = first.toJson()..remove('sid');
    final migrated = WorkoutSession.fromJson(legacy);
    expect(migrated.sessionId, isNotEmpty);
    expect(WorkoutSession.fromJson(migrated.toJson()).sessionId, migrated.sessionId);
    expect(restored.exercises.first.sets.first.setId, first.exercises.first.sets.first.setId);
    expect(first.exercises.first.sets.first.copy().setId, isNot(first.exercises.first.sets.first.setId));
  });

  group('WearCommand', () {
    test('rejects missing or oversized ids', () {
      expect(WearCommand.fromJson(const {'action': 'pause'}), isNull);
      expect(WearCommand.fromJson(const {'id': '', 'action': 'pause'}), isNull);
      expect(WearCommand.fromJson({'id': 'x' * 81, 'action': 'pause'}), isNull);
      expect(WearCommand.fromJson(const {'id': 'ok'}), isNull);
    });

    test('round-trips args', () {
      const source = WearCommand(
        id: 'a1',
        baseRev: 7,
        action: 'updateSet',
        args: {'exerciseIndex': 0, 'setIndex': 1, 'weight': 62.5},
      );
      final parsed = WearCommand.fromJson(source.toJson())!;
      expect(parsed.id, 'a1');
      expect(parsed.baseRev, 7);
      expect(parsed.action, 'updateSet');
      expect(parsed.args['weight'], 62.5);
    });
  });

  test('snapshot follows phone effort mode and changes fingerprint', () {
    final api = apiWithSession();
    final builder = WearSnapshotBuilder(api);
    final off = builder.fingerprint();
    expect(RemoteWorkout.fromJson(builder.build(rev: 1, bootId: 'b')).effortMode, '');
    api.effortMode = 'rpe';
    expect(builder.fingerprint(), isNot(off));
    expect(RemoteWorkout.fromJson(builder.build(rev: 2, bootId: 'b')).effortMode, 'rpe');
    api.effortMode = 'rir';
    expect(RemoteWorkout.fromJson(builder.build(rev: 3, bootId: 'b')).effortMode, 'rir');
    expect(RemoteWorkout.fromJson({'effortMode': 'unexpected'}).effortMode, '');
  });

  group('WearCommandExecutor', () {
    test('rejects command targeting a different workout even at current revision', () {
      final api = apiWithSession();
      final action = WearCommand(
        id: 'stale',
        baseRev: 0,
        action: 'completeSet',
        workoutId: 'different-session',
        args: const {'exerciseIndex': 0, 'setIndex': 0},
      );
      expect(WearCommandExecutor(api).execute(action, 0).code, 'conflict');
      expect(api.session!.exercises[0].sets[0].done, isFalse);
    });

    test('rejects an index that now points at a different set', () {
      final api = apiWithSession();
      final original = api.session!.exercises[0].sets.first;
      api.session!.exercises[0].sets.insert(0, SessionSet(10, 10, false));
      final action = WearCommand(
        id: 'moved',
        baseRev: 0,
        action: 'completeSet',
        workoutId: api.session!.sessionId,
        args: {
          'exerciseIndex': 0,
          'exerciseId': api.session!.exercises[0].id,
          'setIndex': 0,
          'setId': original.setId,
        },
      );
      expect(WearCommandExecutor(api).execute(action, 0).ok, isFalse);
      expect(api.session!.exercises[0].sets.first.done, isFalse);
    });

    test('completes the current pending set', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(api).execute(command('completeSet'), 0);
      expect(result.ok, isTrue);
      expect(result.changed, isTrue);
      expect(api.session!.exercises[0].sets[0].done, isTrue);
    });

    test('moves to the next exercise after completing the last local set', () {
      final api = apiWithSession();
      api.session!.exercises[0].sets[0].done = true;
      final result = WearCommandExecutor(api).execute(
        command('completeSet', args: const {'exerciseIndex': 0, 'setIndex': 1}),
        0,
      );
      expect(result.ok, isTrue);
      expect(api.session!.currentIndex, 1);
    });

    test('completing an already done set changes nothing', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(
        api,
      ).execute(command('completeSet', args: const {'exerciseIndex': 1, 'setIndex': 0}), 0);
      expect(result.ok, isTrue);
      expect(result.changed, isFalse);
      expect(api.session!.exercises[1].sets[0].done, isTrue);
    });

    test('adopts the rest deadline of a completion replayed from the watch', () {
      final api = apiWithSession();
      final endsAt = DateTime.now().add(const Duration(seconds: 30));
      final result = WearCommandExecutor(api).execute(
        command(
          'completeSet',
          args: {
            'exerciseIndex': 0,
            'setIndex': 0,
            'restEndsAt': endsAt.toIso8601String(),
            'restTotalSec': 120,
          },
        ),
        0,
      );
      expect(result.ok, isTrue);
      expect(api.adoptedRestEndsAt, endsAt);
      expect(api.adoptedRestTotal, 120);
      expect(api.session!.exercises[0].sets[0].done, isTrue);
    });

    test('prefers the remaining seconds sent by the watch over the deadline', () {
      final api = apiWithSession();
      // A skewed deadline that would be far in the past must not win.
      final before = DateTime.now();
      final result = WearCommandExecutor(api).execute(
        command(
          'completeSet',
          args: {
            'exerciseIndex': 0,
            'setIndex': 0,
            'restEndsAt': DateTime(2020).toIso8601String(),
            'restTotalSec': 120,
            'restRemainingSec': 30,
          },
        ),
        0,
      );
      expect(result.ok, isTrue);
      final endsAt = api.adoptedRestEndsAt!;
      expect(endsAt.difference(before).inSeconds, inInclusiveRange(29, 31));
      expect(api.adoptedRestTotal, 120);
    });

    test('an elapsed replayed rest is not restarted', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(api).execute(
        command(
          'completeSet',
          args: {
            'exerciseIndex': 0,
            'setIndex': 0,
            'restEndsAt': DateTime.now().subtract(const Duration(minutes: 1)).toIso8601String(),
            'restTotalSec': 120,
            'restRemainingSec': 0,
          },
        ),
        0,
      );
      expect(result.ok, isTrue);
      expect(api.adoptedRestEndsAt!.isAfter(DateTime.now()), isFalse);
      expect(api.adoptedRestTotal, 120);
    });

    test('stale base revision is a conflict', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(api).execute(command('pause', baseRev: 2), 3);
      expect(result.ok, isFalse);
      expect(result.code, 'conflict');
      expect(api.paused, isFalse);
    });

    test('requestState ignores the base revision', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(api).execute(command('requestState', baseRev: 99), 3);
      expect(result.ok, isTrue);
      expect(result.changed, isFalse);
    });

    test('updates reps and weight with limits', () {
      final api = apiWithSession();
      final executor = WearCommandExecutor(api);
      final ok = executor.execute(
        command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'reps': 12, 'weight': 70.0}),
        0,
      );
      expect(ok.ok, isTrue);
      expect(api.session!.exercises[0].sets[0].reps, 12);
      expect(api.session!.exercises[0].sets[0].weight, 70);

      final badReps = executor.execute(
        command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'reps': 1000}),
        0,
      );
      expect(badReps.code, 'invalid');
      final badWeight = executor.execute(
        command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'weight': -1.0}),
        0,
      );
      expect(badWeight.code, 'invalid');
    });

    test('applies queued relative adjustments in order', () {
      final api = apiWithSession();
      final executor = WearCommandExecutor(api);
      for (var i = 0; i < 3; i++) {
        final result = executor.execute(
          command(
            'adjustSet',
            args: const {'exerciseIndex': 0, 'setIndex': 0, 'field': 'weight', 'delta': 2.5},
          ),
          0,
        );
        expect(result.ok, isTrue);
      }
      expect(api.session!.exercises[0].sets[0].weight, 67.5);
    });

    test('sets and clears RPE', () {
      final api = apiWithSession();
      final executor = WearCommandExecutor(api);
      executor.execute(command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'rpe': 8.0}), 0);
      expect(api.session!.exercises[0].sets[0].rpe, 8);
      final cleared = executor.execute(
        command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'rpe': null}),
        0,
      );
      expect(cleared.ok, isTrue);
      expect(api.session!.exercises[0].sets[0].rpe, isNull);
      final invalid = executor.execute(
        command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'rpe': 11.0}),
        0,
      );
      expect(invalid.code, 'invalid');
    });

    test('keeps special set kinds', () {
      final api = apiWithSession();
      final executor = WearCommandExecutor(api);
      final result = executor.execute(
        command('updateSet', args: const {'exerciseIndex': 0, 'setIndex': 0, 'kind': 'warmup'}),
        0,
      );
      expect(result.ok, isTrue);
      expect(api.session!.exercises[0].sets[0].kind, SetKind.warmup);
    });

    test('skips and nudges the rest timer', () {
      final api = apiWithSession(withRest: true);
      final executor = WearCommandExecutor(api);
      final before = api.session!.restEndsAt!;
      final nudge = executor.execute(command('nudgeRest', args: const {'seconds': 15}), 0);
      expect(nudge.ok, isTrue);
      expect(api.session!.restEndsAt!.difference(before).inSeconds, 15);

      final skipped = executor.execute(command('skipRest'), 0);
      expect(skipped.ok, isTrue);
      expect(api.session!.restEndsAt, isNull);
    });

    test('nudges the rest timer in both directions', () {
      final api = apiWithSession(withRest: true);
      final executor = WearCommandExecutor(api);
      final before = api.session!.restEndsAt!;
      final down = executor.execute(command('nudgeRest', args: const {'seconds': -15}), 0);
      expect(down.ok, isTrue);
      expect(api.session!.restEndsAt!.difference(before).inSeconds, -15);
      final zero = executor.execute(command('nudgeRest', args: const {'seconds': 0}), 0);
      expect(zero.code, 'invalid');
    });

    test('an explicit but out of range set is invalid, never a fallback', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(
        api,
      ).execute(command('completeSet', args: const {'exerciseIndex': 0, 'setIndex': 9}), 0);
      expect(result.ok, isFalse);
      expect(result.code, 'invalid');
      expect(api.session!.exercises[0].sets.any((set) => set.done), isFalse);
    });

    test('nudging without rest is invalid', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(api).execute(command('nudgeRest', args: const {'seconds': 15}), 0);
      expect(result.code, 'invalid');
    });

    test('rejects an out of range exercise', () {
      final api = apiWithSession();
      final result = WearCommandExecutor(api).execute(command('goToExercise', args: const {'index': 9}), 0);
      expect(result.code, 'invalid');
    });

    test('reports a missing session', () {
      final result = WearCommandExecutor(FakeWearApi()).execute(command('pause'), 0);
      expect(result.code, 'no_session');
    });
  });

  group('WearSnapshotBuilder', () {
    test('mirrors the workout, rest and special fields', () {
      final api = apiWithSession(withRest: true);
      final session = api.session!;
      session.exercises[0].sets[1]
        ..half = true
        ..repsR = 6
        ..rpe = 9
        ..kind = SetKind.drop;
      session.exercises[1].sets[0].note = 'slow';
      final builder = WearSnapshotBuilder(api);
      final json = builder.build(rev: 4, bootId: 'boot');
      expect(json['rev'], 4);
      expect(json['bootId'], 'boot');
      expect(json['status'], 'active');
      expect(json['workoutId'], session.sessionId);
      expect((json['rest'] as Map)['totalSec'], 90);
      expect((json['rest'] as Map)['endsAt'], isNotNull);
      final exercises = json['exercises'] as List;
      expect(exercises.length, 2);
      final first = exercises[0] as Map;
      expect(first['name'], 'Bench press');
      final second = (first['sets'] as List)[1] as Map;
      expect(second['half'], isTrue);
      expect(second['repsRight'], 6);
      expect(second['rpe'], 9.0);
      expect(second['kind'], 'drop');
      expect(((exercises[1] as Map)['sets'] as List)[0]['note'], 'slow');
      expect(json['restDefaults'], FakeWearApi().restDefaults);
      expect((((first['sets'] as List)[0]) as Map)['restAfterSec'], 90);
    });

    test('reports idle without a session and paused with pause', () {
      final idle = WearSnapshotBuilder(FakeWearApi()).build(rev: 1, bootId: 'b');
      expect(idle['status'], 'idle');
      expect(idle['exercises'], isEmpty);

      final api = apiWithSession()..paused = true;
      final paused = WearSnapshotBuilder(api).build(rev: 2, bootId: 'b');
      expect(paused['status'], 'paused');
    });

    test('fingerprint ignores rev and boot id', () {
      final api = apiWithSession();
      final builder = WearSnapshotBuilder(api);
      final a = builder.fingerprint();
      final b = builder.fingerprint();
      expect(a, b);
    });
  });

  group('RemoteWorkout', () {
    test('elapsed time waits for a future start countdown anchor', () {
      final workout = RemoteWorkout.fromJson({
        'status': 'active',
        'workoutId': 'countdown',
        'elapsedSec': 0,
        'serverNow': DateTime.now().add(const Duration(seconds: 5)).toIso8601String(),
      });
      expect(workout.liveElapsedSeconds, 0);
    });
    test('parses the phone snapshot', () {
      final api = apiWithSession(withRest: true);
      final json = WearSnapshotBuilder(api).build(rev: 3, bootId: 'abc');
      final remote = RemoteWorkout.fromJson(json);
      expect(remote.rev, 3);
      expect(remote.bootId, 'abc');
      expect(remote.hasWorkout, isTrue);
      expect(remote.status, RemoteStatus.active);
      expect(remote.currentExercise!.name, 'Bench press');
      expect(remote.currentExercise!.pendingIndex, 0);
      expect(remote.doneSets, 1);
      expect(remote.totalSets, 4);
      expect(remote.rest, isNotNull);
      expect(remote.rest!.totalSeconds, 90);
      expect(remote.rest!.remaining().inSeconds, greaterThan(60));
    });

    test('frozen rest does not count down', () {
      final rest = RemoteRest(
        endsAt: DateTime.now().add(const Duration(minutes: 5)),
        totalSeconds: 60,
        switchSides: false,
        frozenSeconds: 42,
      );
      expect(rest.remaining().inSeconds, 42);
      expect(rest.running, isFalse);
    });

    test('an empty snapshot stays idle', () {
      final remote = RemoteWorkout.fromJson(WearSnapshotBuilder(FakeWearApi()).build(rev: 1, bootId: 'b'));
      expect(remote.hasWorkout, isFalse);
      expect(remote.exercises, isEmpty);
      expect(remote.currentExercise, isNull);
    });
  });

  group('WearCommandLedger', () {
    test('returns the first ack for a duplicate id', () {
      final ledger = WearCommandLedger(limit: 2);
      const ack = WearAck(id: 'a', ok: true, rev: 5, code: 'ok');
      ledger.remember(ack);
      ledger.remember(const WearAck(id: 'a', ok: false, rev: 9, code: 'error'));
      expect(ledger.fetch('a')!.ok, isTrue);
      expect(ledger.fetch('a')!.rev, 5);
    });

    test('keeps only the newest ids', () {
      final ledger = WearCommandLedger(limit: 2);
      for (final id in ['a', 'b', 'c']) {
        ledger.remember(WearAck(id: id, ok: true, rev: 1, code: 'ok'));
      }
      expect(ledger.fetch('a'), isNull);
      expect(ledger.fetch('b'), isNotNull);
      expect(ledger.size, 2);
    });
  });
}
