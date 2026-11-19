import '../../models/live_session.dart';
import '../../models/workout.dart';

enum RemoteStatus { idle, active, paused, parked, complete }

class RemoteSet {
  const RemoteSet({
    required this.index,
    required this.setId,
    required this.reps,
    required this.weight,
    required this.done,
    required this.kind,
    this.half = false,
    this.repsRight,
    this.rpe,
    this.sec,
    this.km,
    this.note = '',
    this.restSeconds,
  });

  final int index;
  final String setId;
  final int reps;
  final int? repsRight;
  final double weight;
  final bool done;
  final bool half;
  final SetKind kind;
  final double? rpe;
  final int? sec;
  final double? km;
  final String note;
  final int? restSeconds;

  int get weakReps => repsRight == null || repsRight! > reps ? reps : repsRight!;
}

class RemoteExercise {
  const RemoteExercise({
    required this.id,
    required this.name,
    required this.primary,
    required this.sets,
    required this.linkedNext,
    this.weightUnit,
    this.weightStepKg,
    this.distanceUnit,
    this.guide = const [],
  });

  final String id;
  final String name;
  final String primary;
  final List<RemoteSet> sets;
  final bool linkedNext;
  final String? weightUnit;
  final double? weightStepKg;
  final String? distanceUnit;
  final List<String> guide;

  int get pendingIndex => sets.indexWhere((s) => !s.done);

  bool get complete => sets.isNotEmpty && sets.every((s) => s.done);
}

class RemoteRest {
  const RemoteRest({
    required this.endsAt,
    required this.totalSeconds,
    required this.switchSides,
    this.frozenSeconds,
  });

  final DateTime endsAt;
  final int totalSeconds;
  final bool switchSides;
  final int? frozenSeconds;

  Duration remaining([DateTime? now]) {
    final frozen = frozenSeconds;
    if (frozen != null) return Duration(seconds: frozen);
    final left = endsAt.difference(now ?? DateTime.now());
    return left.isNegative ? Duration.zero : left;
  }

  bool get running => frozenSeconds == null && remaining() > Duration.zero;
}

class RemoteSummary {
  const RemoteSummary({this.volumeKg = 0, this.sets = 0, this.durationSeconds = 0});

  final int volumeKg;
  final int sets;
  final int durationSeconds;
}

class RemoteWorkout {
  const RemoteWorkout({
    required this.rev,
    required this.bootId,
    required this.workoutId,
    required this.status,
    required this.name,
    required this.elapsedSeconds,
    required this.currentIndex,
    required this.exercises,
    required this.serverNow,
    this.startedAt,
    this.rest,
    this.summary,
    this.pausedAt,
    this.effortMode = '',
  });

  final int rev;
  final String bootId;
  final String? workoutId;
  final RemoteStatus status;
  final String name;
  final DateTime? startedAt;
  final int elapsedSeconds;
  final int currentIndex;
  final List<RemoteExercise> exercises;
  final RemoteRest? rest;
  final RemoteSummary? summary;
  final DateTime serverNow;
  final DateTime? pausedAt;
  final String effortMode;

  bool get hasWorkout => workoutId != null && status != RemoteStatus.idle;
  bool get finished => status == RemoteStatus.complete;

  RemoteExercise? get currentExercise {
    if (exercises.isEmpty) return null;
    final index = currentIndex.clamp(0, exercises.length - 1);
    return exercises[index];
  }

  int get doneSets => exercises.fold(0, (sum, e) => sum + e.sets.where((s) => s.done).length);
  int get totalSets => exercises.fold(0, (sum, e) => sum + e.sets.length);

  int get liveElapsedSeconds {
    if (status != RemoteStatus.active) return elapsedSeconds;
    final live = elapsedSeconds + DateTime.now().difference(serverNow).inSeconds;
    return live < 0 ? 0 : live;
  }

  static RemoteWorkout fromJson(Map<String, dynamic> json) {
    final status = switch (json['status'] as String? ?? 'idle') {
      'active' => RemoteStatus.active,
      'paused' => RemoteStatus.paused,
      'parked' => RemoteStatus.parked,
      'complete' => RemoteStatus.complete,
      _ => RemoteStatus.idle,
    };
    final restJson = json['rest'] as Map?;
    final summaryJson = json['summary'] as Map?;
    return RemoteWorkout(
      rev: (json['rev'] as num?)?.toInt() ?? 0,
      bootId: json['bootId'] as String? ?? '',
      workoutId: json['workoutId'] as String?,
      status: status,
      effortMode: switch (json['effortMode']) {
        'rpe' => 'rpe',
        'rir' => 'rir',
        _ => '',
      },
      name: json['name'] as String? ?? 'GymMane',
      startedAt: DateTime.tryParse(json['startedAt'] as String? ?? ''),
      elapsedSeconds: (json['elapsedSec'] as num?)?.toInt() ?? 0,
      currentIndex: (json['currentIndex'] as num?)?.toInt() ?? 0,
      serverNow: DateTime.tryParse(json['serverNow'] as String? ?? '') ?? DateTime.now(),
      pausedAt: DateTime.tryParse(json['pausedAt'] as String? ?? ''),
      rest: restJson == null
          ? null
          : RemoteRest(
              endsAt: DateTime.tryParse(restJson['endsAt'] as String? ?? '') ?? DateTime.now(),
              totalSeconds: (restJson['totalSec'] as num?)?.toInt() ?? 0,
              switchSides: restJson['switchSides'] as bool? ?? false,
              frozenSeconds: (restJson['frozenSec'] as num?)?.toInt(),
            ),
      summary: summaryJson == null
          ? null
          : RemoteSummary(
              volumeKg: (summaryJson['volumeKg'] as num?)?.toInt() ?? 0,
              sets: (summaryJson['sets'] as num?)?.toInt() ?? 0,
              durationSeconds: (summaryJson['durationSec'] as num?)?.toInt() ?? 0,
            ),
      exercises: [
        for (final raw in (json['exercises'] as List?) ?? const [])
          RemoteExercise(
            id: (raw as Map)['id'] as String? ?? '',
            name: raw['name'] as String? ?? '',
            primary: raw['primary'] as String? ?? '',
            linkedNext: raw['linkedNext'] as bool? ?? false,
            weightUnit: switch (raw['weightUnit']) {
              'kg' => 'kg',
              'lb' => 'lb',
              _ => null,
            },
            weightStepKg: (raw['weightStepKg'] as num?)?.toDouble(),
            guide: (raw['guide'] as List?)?.whereType<String>().toList() ?? const [],
            distanceUnit: switch (raw['distanceUnit']) {
              'km' => 'km',
              'mi' => 'mi',
              _ => null,
            },
            sets: [
              for (final set in (raw['sets'] as List?) ?? const [])
                RemoteSet(
                  index: ((set as Map)['index'] as num?)?.toInt() ?? 0,
                  setId: set['setId'] as String? ?? '',
                  reps: (set['reps'] as num?)?.toInt() ?? 0,
                  repsRight: (set['repsRight'] as num?)?.toInt(),
                  weight: (set['weight'] as num?)?.toDouble() ?? 0,
                  done: set['done'] as bool? ?? false,
                  half: set['half'] as bool? ?? false,
                  kind: _kindFromJson(set['kind']),
                  rpe: (set['rpe'] as num?)?.toDouble(),
                  sec: (set['sec'] as num?)?.toInt(),
                  km: (set['km'] as num?)?.toDouble(),
                  note: set['note'] as String? ?? '',
                  restSeconds: (set['restSec'] as num?)?.toInt(),
                ),
            ],
          ),
      ],
    );
  }

  SessionSet? sessionSet(int exerciseIndex, int setIndex) {
    if (exerciseIndex < 0 || exerciseIndex >= exercises.length) return null;
    final sets = exercises[exerciseIndex].sets;
    if (setIndex < 0 || setIndex >= sets.length) return null;
    return SessionSet(
      sets[setIndex].reps,
      sets[setIndex].weight,
      sets[setIndex].done,
      kind: sets[setIndex].kind,
      rpe: sets[setIndex].rpe,
      sec: sets[setIndex].sec,
      km: sets[setIndex].km,
      note: sets[setIndex].note,
      repsR: sets[setIndex].repsRight,
    );
  }

  static SetKind _kindFromJson(Object? raw) {
    if (raw is String) {
      return switch (raw) {
        'warmup' => SetKind.warmup,
        'drop' => SetKind.drop,
        'failure' => SetKind.failure,
        'restpause' || 'restPause' => SetKind.restPause,
        'cluster' => SetKind.cluster,
        _ => SetKind.normal,
      };
    }
    return setKindFrom(raw);
  }
}
