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
    final at = session.loggedAt;
    return at == null ? 'live' : at.millisecondsSinceEpoch.toString();
  }

  Map<String, dynamic> build({required int rev, required String bootId}) {
    final session = api.session;
    final now = DateTime.now();
    final semantic = _semantic(session);
    return {
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
      for (final exercise in session.exercises)
        {
          'id': exercise.id,
          'name': exercise.name,
          'primary': exercise.primary,
          'linkedNext': exercise.linkedNext,
          'sets': [
            for (var index = 0; index < exercise.sets.length; index++) _set(index, exercise.sets[index]),
          ],
        },
    ];
  }

  Map<String, dynamic> _set(int index, SessionSet set) => {
    'index': index,
    'reps': set.reps,
    if (set.repsR != null) 'repsRight': set.repsR,
    'weight': set.weight,
    'done': set.done,
    if (set.half && !set.done) 'half': true,
    'kind': set.kind.name,
    if (set.rpe != null) 'rpe': set.rpe,
    if (set.sec != null) 'sec': set.sec,
    if (set.km != null) 'km': set.km,
    if (set.note.isNotEmpty) 'note': set.note,
  };
}
