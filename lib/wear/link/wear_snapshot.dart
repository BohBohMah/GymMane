import 'dart:convert';

import '../../models/live_session.dart';
import 'wear_workout_api.dart';

class WearSnapshot {
  WearSnapshot({required this.rev, required this.bootId, required this.json, required this.fingerprint});

  final int rev;
  final String bootId;
  final Map<String, dynamic> json;
  final String fingerprint;

  String encode() => jsonEncode(json);
}

class WearSnapshotBuilder {
  WearSnapshotBuilder(this.api);

  final WearWorkoutApi api;

  String workoutId() {
    final session = api.session;
    if (session == null) return '';
    return session.sessionId;
  }

  Map<String, dynamic> build({required int rev, required String bootId}) {
    final session = api.session;
    final now = DateTime.now();
    final semantic = _semantic(session);
    return {
      'snapshotVersion': 1,
      'rev': rev,
      'bootId': bootId,
      'elapsedSec': api.elapsedSeconds,
      'serverNow': now.toIso8601String(),
      ...semantic,
    };
  }

  String fingerprint() => jsonEncode(_semantic(api.session));

  Map<String, dynamic> _semantic(WorkoutSession? session) => {
    'status': _status(session),
    'workoutId': workoutId(),
    'name': api.workoutName,
    'startedAt': session?.loggedAt?.toIso8601String(),
    'currentIndex': session?.currentIndex ?? 0,
    'paused': api.paused,
    'effortMode': api.effortMode,
    'restDefaults': api.restDefaults,
    'rest': _rest(session),
    'summary': _summary(session),
    'exercises': _exercises(session),
  };

  String _status(WorkoutSession? session) {
    if (session == null) return 'idle';
    if (session.complete) return 'complete';
    if (api.paused) return 'paused';
    if (api.parked) return 'parked';
    return 'active';
  }

  Map<String, dynamic>? _rest(WorkoutSession? session) {
    if (session == null) return null;
    final frozen = session.restFrozen;
    final endsAt = session.restEndsAt;
    if (frozen == null && endsAt == null) return null;
    return {
      if (endsAt != null) 'endsAt': endsAt.toIso8601String(),
      'frozenSec': ?frozen,
      'totalSec': api.restTotal,
      'switchSides': session.restSwitch,
    };
  }

  Map<String, dynamic>? _summary(WorkoutSession? session) {
    if (session == null) return null;
    if (!session.complete &&
        session.summaryVolume == null &&
        session.summarySets == null &&
        session.summaryDuration == null) {
      return null;
    }
    return {
      'volumeKg': session.summaryVolume ?? 0,
      'sets': session.summarySets ?? 0,
      'durationSec': session.summaryDuration ?? api.elapsedSeconds,
    };
  }

  List<Map<String, dynamic>> _exercises(WorkoutSession? session) {
    if (session == null) return const [];
    return [
      for (var exerciseIndex = 0; exerciseIndex < session.exercises.length; exerciseIndex++)
        {
          'id': session.exercises[exerciseIndex].id,
          'name': session.exercises[exerciseIndex].name,
          'primary': session.exercises[exerciseIndex].primary,
          'linkedNext': session.exercises[exerciseIndex].linkedNext,
          'sets': [
            for (var index = 0; index < session.exercises[exerciseIndex].sets.length; index++)
              _set(exerciseIndex, session.exercises[exerciseIndex].sets[index], index),
          ],
        },
    ];
  }

  Map<String, dynamic> _set(int exerciseIndex, SessionSet set, int index) {
    final restAfter = api.normalRestAfter(exerciseIndex, index);
    return {
      'index': index,
      'setId': set.setId,
      'reps': set.reps,
      if (set.repsR != null) 'repsRight': set.repsR,
      'weight': set.weight,
      'done': set.done,
      if (set.half && !set.done) 'half': true,
      'kind': set.kind.name,
      if (set.rpe != null) 'rpe': set.rpe,
      if (set.sec != null) 'sec': set.sec,
      if (set.km != null) 'km': set.km,
      if (set.rest != null) 'restSec': set.rest,
      if (restAfter > 0) 'restAfterSec': restAfter,
      if (set.goal != null) 'goal': set.goal,
      if (set.note.isNotEmpty) 'note': set.note,
    };
  }
}
