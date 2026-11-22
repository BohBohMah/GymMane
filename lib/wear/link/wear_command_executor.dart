import '../../models/live_session.dart';
import '../../models/workout.dart';
import 'wear_command.dart';
import 'wear_workout_api.dart';

class WearCommandExecutor {
  WearCommandExecutor(this.api);

  final WearWorkoutApi api;

  WearExecution execute(WearCommand command, int currentRev) {
    if (command.action != 'requestState' &&
        command.workoutId != null &&
        command.workoutId != api.session?.sessionId) {
      return WearExecution.conflict;
    }
    if (command.action != 'requestState' && command.baseRev != currentRev) {
      return WearExecution.conflict;
    }
    return switch (command.action) {
      'requestState' => WearExecution.unchanged,
      'completeSet' => _complete(command.args),
      'uncompleteSet' => _uncomplete(command.args),
      'updateSet' => _update(command.args),
      'adjustSet' => _adjust(command.args),
      'nextExercise' => _simple(() => api.nextExercise(), needsSession: true),
      'prevExercise' => _simple(() => api.previousExercise(), needsSession: true),
      'goNextPending' => _simple(() => api.goNextPending(), needsSession: true),
      'goToExercise' => _goTo(command.args),
      'pause' => _pause(true),
      'resume' => _pause(false),
      'skipRest' => _skipRest(),
      'nudgeRest' => _nudgeRest(command.args),
      'setRest' => _setRest(command.args),
      'finish' => _finish(command.args),
      'continueSession' => _continue(),
      'saveExit' => _saveExit(command.args),
      'resumeSession' => _resumeSession(),
      _ => WearExecution.unsupported,
    };
  }

  WearExecution _simple(void Function() action, {required bool needsSession}) {
    if (needsSession && api.session == null) return WearExecution.noSession;
    action();
    return WearExecution.changedOk;
  }

  WearExecution _complete(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    final targetsExplicitly = args.containsKey('exerciseIndex') || args.containsKey('setIndex');
    final explicit = _indices(args);
    if (targetsExplicitly && explicit == null) return WearExecution.invalid;
    final (exerciseIndex, setIndex) = explicit ?? _currentPending(session) ?? (-1, -1);
    if (exerciseIndex < 0) return WearExecution.noPending;
    final set = session.exercises[exerciseIndex].sets[setIndex];
    if (set.done || (set.half && args['firstSide'] == true)) return WearExecution.unchanged;
    final rest = _replayedRest(args);
    api.toggleSet(exerciseIndex, setIndex, startRecovery: rest == null && args['keepRest'] != true);
    if (rest != null) api.adoptRest(rest.$1, rest.$2, switchSides: set.half);
    final updated = api.session;
    if (updated != null &&
        exerciseIndex == updated.currentIndex &&
        updated.exercises[exerciseIndex].sets.every((item) => item.done) &&
        updated.exercises.any((exercise) => exercise.sets.any((item) => !item.done))) {
      api.goNextPending();
    }
    return WearExecution.changedOk;
  }

  /// A completion replayed after an offline period carries the deadline of the
  /// rest that already started on the watch. Adopting it keeps both devices at
  /// the same remaining time instead of restarting a full rest on the phone.
  ///
  /// Prefer the original deadline so time spent sending the batch also counts.
  /// Use the remaining duration if the two device clocks disagree.
  (DateTime, int)? _replayedRest(Map<String, dynamic> args) {
    final total = ((args['restTotalSec'] as num?)?.toInt() ?? 0).clamp(0, 3600);
    final sentRemaining = (args['restRemainingSec'] as num?)?.toInt();
    final raw = args['restEndsAt'];
    final endsAt = raw is String ? DateTime.tryParse(raw) : null;
    if (sentRemaining != null) {
      final left = sentRemaining.clamp(0, 3600);
      final fromRemaining = DateTime.now().add(Duration(seconds: left));
      final matchingClocks = endsAt != null && endsAt.difference(fromRemaining).inMilliseconds.abs() <= 5000;
      return (left > 0 && matchingClocks ? endsAt : fromRemaining, total > left ? total : left);
    }
    return endsAt == null ? null : (endsAt, total);
  }

  WearExecution _uncomplete(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    final indices = _indices(args);
    if (indices == null) return WearExecution.invalid;
    final (exerciseIndex, setIndex) = indices;
    final set = session.exercises[exerciseIndex].sets[setIndex];
    if (!set.done && !set.half) return WearExecution.unchanged;
    api.toggleSet(exerciseIndex, setIndex);
    return WearExecution.changedOk;
  }

  WearExecution _update(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    final indices = _indices(args);
    if (indices == null) return WearExecution.invalid;
    final (exerciseIndex, setIndex) = indices;

    final reps = args.containsKey('reps') ? _int(args, 'reps') : null;
    if (args.containsKey('reps') && (reps == null || reps < 0 || reps > 999)) {
      return WearExecution.invalid;
    }
    final repsRight = args.containsKey('repsRight') ? _int(args, 'repsRight') : null;
    if (args.containsKey('repsRight') && (repsRight == null || repsRight < 0 || repsRight > 999)) {
      return WearExecution.invalid;
    }
    final weight = args.containsKey('weight') ? _double(args, 'weight') : null;
    if (args.containsKey('weight') && (weight == null || weight < 0 || weight > 1000)) {
      return WearExecution.invalid;
    }
    final seconds = args.containsKey('sec') ? _int(args, 'sec') : null;
    if (args.containsKey('sec') && (seconds == null || seconds < 0 || seconds > 86400)) {
      return WearExecution.invalid;
    }
    final km = args.containsKey('km') ? _double(args, 'km') : null;
    if (args.containsKey('km') && (km == null || km < 0 || km > 1000)) {
      return WearExecution.invalid;
    }
    final rpe = args.containsKey('rpe') ? _double(args, 'rpe') : null;
    if (args.containsKey('rpe') && args['rpe'] != null && (rpe == null || rpe < 1 || rpe > 10)) {
      return WearExecution.invalid;
    }
    SetKind? kind;
    if (args.containsKey('kind')) {
      kind = _kind(args['kind']);
      if (kind == null) return WearExecution.invalid;
    }
    if (!args.containsKey('reps') &&
        !args.containsKey('repsRight') &&
        !args.containsKey('weight') &&
        !args.containsKey('sec') &&
        !args.containsKey('km') &&
        !args.containsKey('rpe') &&
        !args.containsKey('kind')) {
      return WearExecution.invalid;
    }

    if (args.containsKey('reps')) api.setReps(exerciseIndex, setIndex, reps!);
    if (args.containsKey('repsRight')) api.setRepsRight(exerciseIndex, setIndex, repsRight!);
    if (args.containsKey('weight')) api.setWeight(exerciseIndex, setIndex, weight!);
    if (args.containsKey('sec')) api.setSeconds(exerciseIndex, setIndex, seconds!);
    if (args.containsKey('km')) api.setKm(exerciseIndex, setIndex, km!);
    if (args.containsKey('rpe')) api.setRpe(exerciseIndex, setIndex, args['rpe'] == null ? null : rpe);
    if (kind != null) api.setKind(exerciseIndex, setIndex, kind);
    return WearExecution.changedOk;
  }

  WearExecution _adjust(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    final indices = _indices(args);
    if (indices == null) return WearExecution.invalid;
    final (exerciseIndex, setIndex) = indices;
    final set = session.exercises[exerciseIndex].sets[setIndex];
    final field = args['field'];
    final delta = args['delta'];
    if (field is! String || delta is! num || !delta.isFinite) return WearExecution.invalid;
    switch (field) {
      case 'weight':
        final value = (set.weight + delta).clamp(0, 1000);
        api.setWeight(exerciseIndex, setIndex, value.toDouble());
      case 'reps':
        final value = (set.reps + delta).clamp(0, 999);
        if (value != value.round()) return WearExecution.invalid;
        api.setReps(exerciseIndex, setIndex, value.toInt());
      case 'repsRight':
        final value = ((set.repsR ?? set.reps) + delta).clamp(0, 999);
        if (value != value.round()) return WearExecution.invalid;
        api.setRepsRight(exerciseIndex, setIndex, value.toInt());
      case 'sec':
        final value = ((set.sec ?? 0) + delta).clamp(0, 86400);
        if (value != value.round()) return WearExecution.invalid;
        api.setSeconds(exerciseIndex, setIndex, value.toInt());
      case 'km':
        final value = ((set.km ?? 0) + delta).clamp(0, 1000);
        api.setKm(exerciseIndex, setIndex, value.toDouble());
      default:
        return WearExecution.invalid;
    }
    return WearExecution.changedOk;
  }

  WearExecution _goTo(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    final index = _int(args, 'index');
    if (index == null || index < 0 || index >= session.exercises.length) return WearExecution.invalid;
    if (session.currentIndex == index) return WearExecution.unchanged;
    api.goToExercise(index);
    return WearExecution.changedOk;
  }

  WearExecution _pause(bool pause) {
    if (api.session == null) return WearExecution.noSession;
    if (api.paused == pause) return WearExecution.unchanged;
    api.togglePause();
    return WearExecution.changedOk;
  }

  WearExecution _skipRest() {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    if (session.restEndsAt == null && session.restFrozen == null) return WearExecution.unchanged;
    api.skipRest();
    return WearExecution.changedOk;
  }

  WearExecution _nudgeRest(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    if (session.restEndsAt == null && session.restFrozen == null) return WearExecution.invalid;
    final seconds = _int(args, 'seconds') ?? 15;
    if (seconds == 0 || seconds < -300 || seconds > 300) return WearExecution.invalid;
    api.nudgeRest(seconds);
    return WearExecution.changedOk;
  }

  WearExecution _setRest(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    final seconds = _int(args, 'seconds');
    if (seconds == null || seconds < 0 || seconds > 3600) return WearExecution.invalid;
    api.setRest(seconds);
    return WearExecution.changedOk;
  }

  WearExecution _finish(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    if (session.complete) return WearExecution.unchanged;
    final elapsed = args['elapsedSec'];
    if (elapsed != null && (elapsed is! int || elapsed < 0 || elapsed > 604800)) return WearExecution.invalid;
    api.finish(elapsedSeconds: elapsed as int?);
    return WearExecution.changedOk;
  }

  WearExecution _continue() {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    if (!session.complete) return WearExecution.invalid;
    api.continueSession();
    return WearExecution.changedOk;
  }

  WearExecution _saveExit(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return WearExecution.noSession;
    if (args['requiresCompleted'] == true && !session.complete) return WearExecution.invalid;
    api.saveAndExit();
    return WearExecution.changedOk;
  }

  WearExecution _resumeSession() {
    final session = api.session;
    if (session == null || session.complete) return WearExecution.noSession;
    if (!api.parked) return WearExecution.unchanged;
    api.resumeSession();
    return WearExecution.changedOk;
  }

  (int, int)? _indices(Map<String, dynamic> args) {
    final session = api.session;
    if (session == null) return null;
    final exerciseIndex = _int(args, 'exerciseIndex');
    final setIndex = _int(args, 'setIndex');
    if (exerciseIndex == null || setIndex == null) return null;
    if (exerciseIndex < 0 || exerciseIndex >= session.exercises.length) return null;
    final sets = session.exercises[exerciseIndex].sets;
    if (setIndex < 0 || setIndex >= sets.length) return null;
    if (args.containsKey('exerciseId') && args['exerciseId'] != session.exercises[exerciseIndex].id) {
      return null;
    }
    if (args.containsKey('setId') && args['setId'] != sets[setIndex].setId) return null;
    return (exerciseIndex, setIndex);
  }

  (int, int)? _currentPending(WorkoutSession session) {
    if (session.exercises.isEmpty) return null;
    final start = session.currentIndex.clamp(0, session.exercises.length - 1);
    for (var offset = 0; offset < session.exercises.length; offset++) {
      final index = (start + offset) % session.exercises.length;
      final pending = session.exercises[index].sets.indexWhere((set) => !set.done);
      if (pending >= 0) return (index, pending);
    }
    return null;
  }

  int? _int(Map<String, dynamic> args, String key) => (args[key] as num?)?.toInt();

  double? _double(Map<String, dynamic> args, String key) => (args[key] as num?)?.toDouble();

  SetKind? _kind(Object? raw) {
    if (raw is num) {
      final index = raw.toInt();
      return index >= 0 && index < SetKind.values.length ? SetKind.values[index] : null;
    }
    if (raw is String) {
      return switch (raw) {
        'normal' => SetKind.normal,
        'warmup' => SetKind.warmup,
        'drop' => SetKind.drop,
        'failure' => SetKind.failure,
        'restpause' || 'restPause' => SetKind.restPause,
        'cluster' => SetKind.cluster,
        _ => null,
      };
    }
    return null;
  }
}

class WearCommandLedger {
  WearCommandLedger({this.limit = 128});

  final int limit;
  final Map<String, WearAck> _acks = {};
  final List<String> _order = [];

  WearAck? fetch(String id) => _acks[id];

  void remember(WearAck ack) {
    if (_acks.containsKey(ack.id)) return;
    _acks[ack.id] = ack;
    _order.add(ack.id);
    while (_order.length > limit) {
      _acks.remove(_order.removeAt(0));
    }
  }

  int get size => _acks.length;

  void clear() {
    _acks.clear();
    _order.clear();
  }
}
