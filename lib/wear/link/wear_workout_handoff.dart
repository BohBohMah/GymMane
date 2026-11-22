import 'dart:convert';

import '../../models/live_session.dart';
import '../../models/workout.dart';
import '../../state/fit_state.dart';

Map<String, dynamic>? watchWorkoutDraft(
  String action,
  Map<String, dynamic> args,
  Map<String, dynamic>? home,
  String id,
) {
  final data = home ?? const {};
  WorkoutSession? draft;
  if (action == 'startRoutine') {
    final rows = (data['routines'] as List?)?.whereType<Map>();
    final raw = rows?.where((row) => row['id'] == args['id']).firstOrNull?['draft'];
    if (raw is Map) {
      draft = WorkoutSession.fromJson({...Map<String, dynamic>.from(raw), 'sid': id});
    }
  } else if (action == 'startExercises') {
    final ids = args['ids'];
    if (ids is! List || ids.isEmpty || ids.length > 20 || ids.toSet().length != ids.length) return null;
    final custom = (data['custom'] as List?)?.whereType<Map>() ?? const <Map>[];
    draft = WorkoutSession(sessionId: id);
    for (final item in ids) {
      if (item is! String || fit.isArchived(item)) return null;
      final exercise = fit.exerciseById(item);
      final cached = custom.where((row) => row['id'] == item).firstOrNull;
      if (exercise != null) {
        draft.exercises.add(fit.wearExerciseDraft(exercise));
      } else if (cached != null) {
        draft.exercises.add(
          SessionExercise(
            item,
            cached['name'] as String,
            cached['primary'] as String? ?? '',
            List.generate(3, (_) => SessionSet(10, 0, false)),
          ),
        );
      } else {
        return null;
      }
    }
  }
  if (draft == null ||
      draft.exercises.isEmpty ||
      draft.exercises.length > 40 ||
      draft.exercises.fold<int>(0, (count, ex) => count + ex.sets.length) > 200) {
    return null;
  }
  final now = DateTime.now().toUtc().toIso8601String();
  final config = data['training'] as Map? ?? const {};
  final normal = config['rest'] as int? ?? 90;
  return {
    'snapshotVersion': 1,
    'watchOrigin': true,
    'workoutId': id,
    'status': 'active',
    'name': draft.name ?? 'GymMane',
    'routineId': draft.routineId,
    'deload': draft.deload,
    'lightened': draft.lightened,
    'serverNow': now,
    'startedAt': now,
    'elapsedSec': 0,
    'currentIndex': 0,
    'effortMode': config['effort'],
    'restDefaults': {'normal': normal, 'mini': config['mini'] ?? 20, 'change': config['change'] ?? 0},
    'exercises': [
      for (final ex in draft.exercises)
        {
          'id': ex.id,
          'name': ex.name,
          'primary': ex.primary,
          'linkedNext': ex.linkedNext,
          if (ex.jumpNext) 'jumpNext': true,
          'slot': ?ex.slot,
          'weightUnit': config['units'],
          'weightStepKg': config['stepKg'],
          'distanceUnit': config['distance'],
          'sets': [
            for (final (index, set) in ex.sets.indexed)
              {
                'index': index,
                'setId': set.setId,
                'reps': set.reps,
                'weight': set.weight,
                'done': false,
                'kind': set.kind.name,
                'restAfterSec': normal,
                if (set.repsR != null) 'sideRestSec': config['side'] ?? 0,
                'repsRight': ?set.repsR,
                'sec': ?set.sec,
                'km': ?set.km,
                'restSec': ?set.rest,
                'goal': ?set.goal,
              },
          ],
        },
    ],
  };
}

Map<String, dynamic> wearHandoffPayload(Map<String, dynamic> snapshot) {
  final session = WorkoutSession(sessionId: snapshot['workoutId'] as String)
    ..routineId = snapshot['routineId'] as String?
    ..name = snapshot['name'] as String?
    ..deload = snapshot['deload'] == true
    ..lightened = snapshot['lightened'] == true
    ..loggedAt = DateTime.parse(snapshot['startedAt'] as String).toLocal()
    ..currentIndex = snapshot['currentIndex'] as int
    ..exercises = [
      for (final ex in (snapshot['exercises'] as List).cast<Map>())
        SessionExercise(ex['id'] as String, ex['name'] as String, ex['primary'] as String, [
          for (final set in (ex['sets'] as List).cast<Map>())
            SessionSet(
              set['reps'] as int,
              (set['weight'] as num).toDouble(),
              set['done'] == true,
              kind: SetKind.values.byName(set['kind'] as String),
              setId: set['setId'] as String,
              repsR: set['repsRight'] as int?,
              sec: set['sec'] as int?,
              km: (set['km'] as num?)?.toDouble(),
              rpe: (set['rpe'] as num?)?.toDouble(),
              rest: set['restSec'] as int?,
              goal: set['goal'] as String?,
              note: set['note'] as String? ?? '',
            )..half = set['half'] == true,
        ], linkedNext: ex['linkedNext'] == true, jumpNext: ex['jumpNext'] == true, slot: ex['slot'] as String?),
    ];
  final rest = snapshot['rest'] as Map?;
  session.restEndsAt = DateTime.tryParse(rest?['endsAt'] as String? ?? '');
  session.restFrozen = rest?['frozenSec'] as int?;
  session.restSwitch = rest?['switchSides'] == true;
  return {
    'session': session.toJson(),
    'status': snapshot['status'],
    'elapsed': snapshot['elapsedSec'],
    'anchor': snapshot['serverNow'],
    'restTotal': rest?['totalSec'] ?? 0,
  };
}

({WorkoutSession session, int elapsed, bool paused, bool save, int rest})? readWearHandoff(
  Map<String, dynamic> payload,
  String? id,
  DateTime now,
) {
  final raw = payload['session'];
  final status = payload['status'];
  final elapsed = payload['elapsed'];
  final anchor = payload['anchor'];
  final rest = payload['restTotal'];
  if (id == null ||
      !RegExp(r'^[a-f0-9]{24}$').hasMatch(id) ||
      raw is! Map ||
      raw['sid'] != id ||
      !const {'active', 'paused', 'complete'}.contains(status) ||
      elapsed is! int ||
      elapsed < 0 ||
      elapsed > 604800 ||
      anchor is! String ||
      rest is! int ||
      rest < 0 ||
      rest > 3600) {
    return null;
  }
  try {
    final date = DateTime.parse(anchor);
    final rows = raw['ex'];
    if (rows is! List || rows.isEmpty || rows.length > 40 || utf8.encode(jsonEncode(raw)).length > 35000) return null;
    final s = WorkoutSession.fromJson(Map<String, dynamic>.from(raw));
    final started = s.loggedAt;
    if (started == null ||
        started.isAfter(now.add(const Duration(minutes: 5))) ||
        s.complete ||
        s.manual ||
        s.currentIndex < 0 ||
        s.currentIndex >= s.exercises.length ||
        (s.restFrozen ?? 0) < 0 ||
        (s.restFrozen ?? 0) > 3600 ||
        (s.restEndsAt?.difference(now).inSeconds ?? 0) > 3900) {
      return null;
    }
    final setIds = <String>{};
    for (final ex in s.exercises) {
      if (ex.id.isEmpty || ex.id.length > 160 || ex.name.length > 256 || ex.primary.length > 80 || ex.sets.isEmpty) {
        return null;
      }
      for (final st in ex.sets) {
        if (!RegExp(r'^[a-f0-9]{32}$').hasMatch(st.setId) ||
            !setIds.add(st.setId) ||
            setIds.length > 200 ||
            st.reps < 0 ||
            st.reps > 999 ||
            (st.repsR ?? 0) < 0 ||
            (st.repsR ?? 0) > 999 ||
            !st.weight.isFinite ||
            st.weight < 0 ||
            st.weight > 1000 ||
            (st.sec ?? 0) < 0 ||
            (st.sec ?? 0) > 86400 ||
            !(st.km ?? 0).isFinite ||
            (st.km ?? 0) < 0 ||
            (st.km ?? 0) > 1000 ||
            !(st.rpe ?? 1).isFinite ||
            (st.rpe ?? 1) < 1 ||
            (st.rpe ?? 1) > 10 ||
            st.note.length > 1024) {
          return null;
        }
      }
    }
    final seconds = status == 'active' ? elapsed + now.difference(date).inSeconds.clamp(0, 604800) : elapsed;
    return (
      session: s,
      elapsed: seconds.clamp(0, 604800),
      paused: status == 'paused',
      save: status == 'complete',
      rest: rest,
    );
  } catch (_) {
    return null;
  }
}
