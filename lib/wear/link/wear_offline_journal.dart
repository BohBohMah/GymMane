import 'dart:async';
import 'dart:convert';

/// A serialized, write-before-publish transaction coordinator.
///
/// The caller supplies a durable atomic [write] implementation. This class is
/// deliberately not connected to BLE until the phone has durable idempotency.
class WearOfflineJournal {
  WearOfflineJournal({required this.write, DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  final Future<void> Function(String encoded) write;
  final DateTime Function() clock;
  Future<void> _tail = Future.value();
  Map<String, dynamic>? _state;
  List<Map<String, dynamic>> _completed = [];

  Map<String, dynamic>? get state => _state == null ? null : _copy(_state!);

  bool get hasPending => (_state?['pending'] as List?)?.isNotEmpty ?? false;
  bool get hasLocalDraft => (_state?['snapshot'] as Map?)?['watchOrigin'] == true;
  Map<String, dynamic>? get firstCompleted => _completed.isEmpty ? null : _copy(_completed.first);
  bool get hasCompleted => _completed.isNotEmpty;
  bool hasAction(String action) =>
      (_state?['pending'] as List?)?.any((entry) => (entry as Map)['action'] == action) ?? false;
  Map<String, dynamic>? get snapshot {
    final value = _state?['snapshot'];
    return value is Map<String, dynamic> ? _copy(value) : null;
  }

  List<Map<String, dynamic>> pendingOperations(int limit) => [
    for (final entry in (_state?['pending'] as List? ?? const []).take(limit))
      _copy(entry as Map<String, dynamic>),
  ];

  Future<void> clear() => _transaction(() async {
    await _write(null);
    _state = null;
  });

  Future<void> restore(String encoded) => _transaction(() async {
    final value = jsonDecode(encoded);
    if (value is! Map<String, dynamic>) throw const FormatException('invalid journal');
    final completed = value.remove('completed');
    if (completed != null && (completed is! List || completed.length > 40 ||
        completed.any((row) => row is! Map<String, dynamic> || row['action'] != 'uploadCompletedWorkout'))) {
      throw const FormatException('invalid completed workouts');
    }
    final archive = (completed as List?)?.cast<Map<String, dynamic>>() ?? <Map<String, dynamic>>[];
    if (value['schema'] == 1 && value['cleared'] == true && value.length == 2) {
      _state = null;
      _completed = archive;
      return;
    }
    _validate(value);
    _state = _copy(value);
    _completed = archive;
  });

  Future<void> initialize(Map<String, dynamic> snapshot) => _transaction(() async {
    if (_state != null) throw StateError('journal already initialized');
    final candidate = <String, dynamic>{
      'schema': 1,
      'snapshot': _copy(snapshot),
      'nextSequence': 1,
      'pending': <dynamic>[],
    };
    _validate(candidate);
    await _write(candidate);
    _state = candidate;
  });

  // Freeze a single checkpoint for retries. Edits that arrive while it is in
  // flight append after it and are replayed against the phone's accepted state.
  Future<void> prepareAdoption(Map<String, dynamic> Function(Map<String, dynamic>) makeCommand) =>
      _transaction(() async {
    final current = _state;
    if (current == null || !hasLocalDraft || hasAction('adoptWorkout')) return;
    final candidate = _copy(current);
    final sequence = candidate['nextSequence'] as int;
    final snapshot = candidate['snapshot'] as Map<String, dynamic>;
    candidate['pending'] = [
      {...makeCommand(_copy(snapshot)), 'sequence': sequence},
    ];
    candidate['nextSequence'] = sequence + 1;
    _validate(candidate);
    await _write(candidate);
    _state = candidate;
  });

  Future<void> reopenAdoption(String id) => _transaction(() async {
    final current = _state;
    if (current == null || !hasLocalDraft) return;
    final candidate = _copy(current);
    final pending = candidate['pending'] as List;
    if (pending.isEmpty || (pending.first as Map)['id'] != id) return;
    pending.removeAt(0);
    await _write(candidate);
    _state = candidate;
  });

  Future<bool> discardUnsentDraft() async {
    var discarded = false;
    await _transaction(() async {
      if (!hasLocalDraft || hasAction('adoptWorkout')) return;
      await _write(null);
      _state = null;
      discarded = true;
    });
    return discarded;
  }

  Future<bool> archiveUnsentDraft(Map<String, dynamic> Function(Map<String, dynamic>) makeCommand) async {
    var saved = false;
    await _transaction(() async {
      if (!hasLocalDraft || hasAction('adoptWorkout')) return;
      if (_completed.length >= 40) throw StateError('completed workout queue is full');
      final snapshot = _copy(_state!['snapshot'] as Map<String, dynamic>);
      _reduce(snapshot, {'action': 'finish', 'args': <String, dynamic>{}});
      final archive = [..._completed, makeCommand(snapshot)];
      await _write(null, completed: archive);
      _completed = archive;
      _state = null;
      saved = true;
    });
    return saved;
  }

  Future<void> acknowledgeCompleted(String id) => _transaction(() async {
    final archive = _completed.where((command) => command['id'] != id).toList();
    if (archive.length == _completed.length) return;
    await _write(_state, completed: archive);
    _completed = archive;
  });

  Future<void> _write(Map<String, dynamic>? state, {List<Map<String, dynamic>>? completed}) {
    final archive = completed ?? _completed;
    return write(jsonEncode({
      ...state ?? const {'schema': 1, 'cleared': true},
      if (archive.isNotEmpty) 'completed': archive,
    }));
  }

  /// Replaces the authoritative base and reapplies every unacknowledged local
  /// operation. This is used after reconnect so phone changes and watch edits
  /// are merged by stable exercise/set identities.
  Future<void> rebase(Map<String, dynamic> snapshot, {List<String> acknowledge = const []}) =>
      _transaction(() async {
    final current = _state;
    if (current == null || current['snapshot'] is! Map) {
      final candidate = <String, dynamic>{
        'schema': 1,
        'snapshot': _copy(snapshot),
        'nextSequence': 1,
        'pending': <dynamic>[],
      };
      _validate(candidate);
      await _write(candidate);
      _state = candidate;
      return;
    }
    final oldSnapshot = current['snapshot'] as Map;
    if (oldSnapshot['workoutId'] != snapshot['workoutId']) {
      final candidate = <String, dynamic>{
        'schema': 1,
        'snapshot': _copy(snapshot),
        'nextSequence': 1,
        'pending': <dynamic>[],
      };
      _validate(candidate);
      await _write(candidate);
      _state = candidate;
      return;
    }
    final pending = [
      for (final item in current['pending'] as List) _copy(Map<String, dynamic>.from(item as Map)),
    ];
    _removeConfirmedPrefix(pending, acknowledge);
    final applied = snapshot['appliedOperationIds'];
    if (applied is List) {
      final ids = applied.whereType<String>().toSet();
      pending.removeWhere((operation) => ids.contains(operation['id']));
    }
    final candidate = <String, dynamic>{
      'schema': 1,
      'snapshot': _copy(snapshot),
      'nextSequence': current['nextSequence'],
      'pending': <dynamic>[],
    };
    for (final operation in pending) {
      try {
        final derived = _reduce(candidate['snapshot'] as Map<String, dynamic>, operation);
        // Older journals may still contain a relative operation that the
        // phone has seen. Keep its original identity and arguments on retry.
        if (operation['action'] == 'adjustSet') derived.remove('weight');
        if (derived.isNotEmpty) {
          operation['args'] = {...(operation['args'] as Map).cast<String, dynamic>(), ...derived};
        }
      } on FormatException {
        // The phone may have removed a set or ended a rest while offline.
        // Keep the operation for the phone to confirm or reject explicitly.
      }
      (candidate['pending'] as List).add(operation);
    }
    _validate(candidate);
    await _write(candidate);
    _state = candidate;
  });

  /// Applies a local edit against the latest committed snapshot, rather than
  /// against a value captured by an earlier UI frame.
  Future<void> apply(Map<String, dynamic> operation) => applyAll([operation]);

  Future<void> applyAll(List<Map<String, dynamic>> operations) => _transaction(() async {
    final current = _state;
    if (current == null) throw StateError('journal not initialized');
    final candidate = _copy(current);
    final snapshot = candidate['snapshot'] as Map<String, dynamic>;
    final pending = candidate['pending'] as List;
    final ids = {for (final entry in pending) (entry as Map)['id']};
    if (pending.any((entry) => (entry as Map)['action'] == 'saveExit')) {
      throw StateError('workout already closing');
    }
    var sequence = candidate['nextSequence'] as int;
    for (final operation in operations) {
      final id = operation['id'];
      if (id is! String || id.isEmpty || operation['workoutId'] != snapshot['workoutId']) {
        throw const FormatException('invalid operation identity');
      }
      if (!ids.add(id)) throw StateError('duplicate operation');
      final derived = _reduce(snapshot, operation);
      final stored = _copy(operation);
      if (stored['action'] == 'adjustSet' && derived.containsKey('weight')) {
        // The stepper reads the last committed local value (including rapid
        // taps). The phone receives the resulting weight, never an increment.
        stored['action'] = 'updateSet';
        final args = (stored['args'] as Map).cast<String, dynamic>()
          ..remove('field')
          ..remove('delta');
        stored['args'] = {...args, 'weight': derived['weight']};
      } else if (derived.isNotEmpty) {
        stored['args'] = {...(stored['args'] as Map).cast<String, dynamic>(), ...derived};
      }
      pending.add({...stored, 'sequence': sequence++});
    }
    candidate['nextSequence'] = sequence;
    _validate(candidate);
    await _write(candidate);
    _state = candidate;
  });

  /// Applies one local operation to [snapshot] and returns any arguments that
  /// must be persisted with the operation for later replay (the absolute rest
  /// deadline of a completed set).
  Map<String, dynamic> _reduce(Map<String, dynamic> snapshot, Map<String, dynamic> operation) {
    final derived = <String, dynamic>{};
    final action = operation['action'];
    final args = operation['args'];
    if (args is! Map) throw const FormatException('invalid arguments');
    final exercises = snapshot['exercises'] as List;
    if (action == 'goToExercise') {
      final index = args['index'];
      if (index is! int || index < 0 || index >= exercises.length) {
        throw const FormatException('invalid exercise');
      }
      snapshot['currentIndex'] = index;
    } else if (action == 'nextExercise' || action == 'prevExercise' || action == 'goNextPending') {
      if (exercises.isEmpty) throw const FormatException('invalid exercise');
      final current = ((snapshot['currentIndex'] as num?)?.toInt() ?? 0).clamp(0, exercises.length - 1);
      if (action == 'nextExercise') {
        snapshot['currentIndex'] = (current + 1).clamp(0, exercises.length - 1);
      } else if (action == 'prevExercise') {
        snapshot['currentIndex'] = (current - 1).clamp(0, exercises.length - 1);
      } else {
        var target = current;
        for (var offset = 1; offset <= exercises.length; offset++) {
          final candidate = (current + offset) % exercises.length;
          final sets = (exercises[candidate] as Map)['sets'] as List;
          if (sets.any((set) => (set as Map)['done'] != true)) {
            target = candidate;
            break;
          }
        }
        snapshot['currentIndex'] = target;
      }
    } else if (action == 'updateSet' ||
        action == 'adjustSet' ||
        action == 'completeSet' ||
        action == 'uncompleteSet') {
      final exerciseIndex = args['exerciseIndex'];
      final setIndex = args['setIndex'];
      if (exerciseIndex is! int || exerciseIndex < 0 || exerciseIndex >= exercises.length) {
        throw const FormatException('invalid exercise');
      }
      final exercise = exercises[exerciseIndex];
      if (exercise is! Map || exercise['id'] != args['exerciseId'] || exercise['sets'] is! List) {
        throw const FormatException('exercise changed');
      }
      final sets = exercise['sets'] as List;
      if (setIndex is! int || setIndex < 0 || setIndex >= sets.length || sets[setIndex] is! Map) {
        throw const FormatException('invalid set');
      }
      final set = sets[setIndex] as Map;
      final setId = args['setId'];
      if (set['index'] != setIndex || setId is! String || setId.isEmpty || set['setId'] != setId) {
        throw const FormatException('set changed');
      }
      if (action == 'completeSet' || action == 'uncompleteSet') {
        final complete = action == 'completeSet';
        final sideSeconds = (set['sideRestSec'] as num?)?.toInt() ?? 0;
        if (complete && (set['done'] == true || (args['firstSide'] == true && set['half'] == true))) {
          // Already completed on the phone. Keep its recovery deadline.
          return derived;
        }
        final switchSides = complete && set['half'] != true && sideSeconds > 0;
        if (switchSides && !args.containsKey('firstSide')) derived['firstSide'] = true;
        final done = complete && !switchSides;
        set['done'] = done;
        if (switchSides) {
          set['half'] = true;
        } else {
          set.remove('half');
        }
        if (complete && args['keepRest'] != true) {
          final storedEndsAt = args['restEndsAt'];
          final originalDeadline = storedEndsAt is String ? DateTime.tryParse(storedEndsAt) : null;
          final now = _now();
          if (originalDeadline == null && snapshot['status'] == 'paused') {
            derived['keepRest'] = true;
          } else {
            final seconds = originalDeadline != null
                ? (args['restTotalSec'] as num?)?.toInt() ?? 0
                : switchSides ? sideSeconds : _restSeconds(snapshot, exerciseIndex, setIndex, exercise, set);
            final endsAt = originalDeadline ?? now.add(Duration(seconds: seconds));
            if (originalDeadline == null) {
              derived['restEndsAt'] = endsAt.toUtc().toIso8601String();
              derived['restTotalSec'] = seconds;
            }
            if (snapshot['status'] != 'paused') {
              snapshot['rest'] = seconds > 0 && endsAt.isAfter(now) ? {
                'endsAt': endsAt.toUtc().toIso8601String(),
                'totalSec': seconds.clamp(0, 3600),
                'switchSides': switchSides,
              } : null;
            }
          }
        }
        _refreshSummary(snapshot);
        if (done && exerciseIndex == snapshot['currentIndex'] && sets.every((item) => (item as Map)['done'] == true)) {
          for (var offset = 1; offset < exercises.length; offset++) {
            final next = (exerciseIndex + offset) % exercises.length;
            final nextSets = (exercises[next] as Map)['sets'] as List;
            if (nextSets.any((item) => (item as Map)['done'] != true)) {
              snapshot['currentIndex'] = next;
              break;
            }
          }
        }
      } else if (action == 'adjustSet') {
        final key = args['field'];
        final delta = args['delta'];
        const limits = <String, num>{'weight': 1000, 'reps': 999, 'repsRight': 999, 'sec': 86400, 'km': 1000};
        if (!limits.containsKey(key) || delta is! num || !delta.isFinite || set[key] is! num) {
          throw const FormatException('invalid adjustment');
        }
        final result = ((set[key] as num) + delta).clamp(0, limits[key]!);
        final integer = key == 'reps' || key == 'repsRight' || key == 'sec';
        if (!result.isFinite || (integer && result != result.round())) {
          throw const FormatException('adjustment out of range');
        }
        set[key] = integer ? result.toInt() : result.toDouble();
        if (key == 'weight') derived['weight'] = set[key];
      } else {
        var changed = false;
        for (final key in const ['reps', 'repsRight', 'weight', 'rpe', 'sec', 'km', 'kind']) {
          if (!args.containsKey(key)) continue;
          final value = args[key];
          if (key == 'reps' && (value is! int || value < 0 || value > 999)) {
            throw const FormatException('invalid reps');
          }
          if (key == 'weight' && (value is! num || !value.isFinite || value < 0 || value > 1000)) {
            throw const FormatException('invalid weight');
          }
          if ((key == 'sec' || key == 'repsRight') && (value is! int || value < 0 || value > 86400)) {
            throw const FormatException('invalid integer');
          }
          if (key == 'km' && (value is! num || !value.isFinite || value < 0 || value > 1000)) {
            throw const FormatException('invalid distance');
          }
          if (key == 'kind' && value is! String) throw const FormatException('invalid kind');
          if (key == 'rpe' &&
              value != null &&
              (value is! num || !value.isFinite || value < 1 || value > 10)) {
            throw const FormatException('invalid rpe');
          }
          set[key] = value;
          changed = true;
        }
        if (!changed) throw const FormatException('empty edit');
      }
    } else if (action == 'pause' || action == 'resume') {
      final now = _now();
      final rest = snapshot['rest'];
      if (action == 'pause' && snapshot['status'] == 'active') {
        _freezeElapsed(snapshot, now);
        snapshot['status'] = 'paused';
        snapshot['pausedAt'] = now.toIso8601String();
        if (rest is Map) {
          final left = _restLeft(rest, now);
          if (left > 0) {
            rest['frozenSec'] = left;
          } else {
            snapshot['rest'] = null;
          }
        }
      } else if (action == 'resume' && snapshot['status'] != 'active') {
        snapshot['status'] = 'active';
        snapshot['serverNow'] = now.toIso8601String();
        snapshot.remove('pausedAt');
        if (rest is Map && rest['frozenSec'] is int) {
          final left = rest.remove('frozenSec') as int;
          rest['endsAt'] = now.add(Duration(seconds: left)).toIso8601String();
        }
      }
    } else if (action == 'skipRest') {
      snapshot['rest'] = null;
    } else if (action == 'nudgeRest') {
      final rest = snapshot['rest'];
      final seconds = args['seconds'];
      if (rest is! Map || seconds is! int || seconds == 0) throw const FormatException('invalid rest');
      final frozen = rest['frozenSec'];
      if (frozen is int) {
        rest['frozenSec'] = (frozen + seconds).clamp(0, 3600);
      } else {
        final end = DateTime.tryParse(rest['endsAt'] as String? ?? '');
        if (end == null) throw const FormatException('invalid rest');
        rest['endsAt'] = end.add(Duration(seconds: seconds)).toIso8601String();
      }
      rest['totalSec'] = (((rest['totalSec'] as num?)?.toInt() ?? 0) + seconds).clamp(0, 3600);
    } else if (action == 'setRest') {
      final seconds = args['seconds'];
      if (seconds is! int || seconds < 0 || seconds > 3600) throw const FormatException('invalid rest');
      snapshot['rest'] = seconds == 0
          ? null
          : {
              'endsAt': _now().add(Duration(seconds: seconds)).toIso8601String(),
              'totalSec': seconds,
              'switchSides': false,
            };
    } else if (action == 'saveExit') {
      // Terminal intent. The local workout stays readable and durable until the
      // phone confirms that it discarded the session; clearing here would lose
      // unsynced sets if the watch is closed or the connection drops.
    } else if (action == 'finish') {
      _freezeElapsed(snapshot, _now());
      final elapsed = args['elapsedSec'] ?? snapshot['elapsedSec'];
      if (elapsed is int) {
        snapshot['elapsedSec'] = elapsed;
        derived['elapsedSec'] = elapsed;
      }
      snapshot['status'] = 'complete';
      snapshot['rest'] = null;
      _refreshSummary(snapshot);
    } else {
      throw const FormatException('unsupported local operation');
    }
    return derived;
  }

  DateTime _now() => clock();

  void _freezeElapsed(Map<String, dynamic> snapshot, DateTime now) {
    if (snapshot['status'] == 'active') {
      final base = DateTime.tryParse(snapshot['serverNow'] as String? ?? '');
      final elapsed = (snapshot['elapsedSec'] as num?)?.toInt() ?? 0;
      snapshot['elapsedSec'] = elapsed + (base == null ? 0 : now.difference(base).inSeconds.clamp(0, 604800));
    }
    snapshot['serverNow'] = now.toIso8601String();
  }

  int _restLeft(Map rest, DateTime now) {
    final end = DateTime.tryParse(rest['endsAt'] as String? ?? '');
    return end == null ? 0 : (end.difference(now).inMilliseconds / 1000).ceil().clamp(0, 3600);
  }

  /// Resolves the rest that the phone would start for this set, using the
  /// explicit per-set value, the mini rest before a rest-pause/cluster set,
  /// the change-exercise rest, and the effective per-exercise/default rest.
  int _restSeconds(Map<String, dynamic> snapshot, int exerciseIndex, int setIndex, Map exercise, Map set) {
    if (set.containsKey('restSec')) {
      return ((set['restSec'] as num?)?.toInt() ?? 0).clamp(0, 3600);
    }
    final defaults = snapshot['restDefaults'];
    final mini = defaults is Map ? ((defaults['mini'] as num?)?.toInt() ?? 0) : 0;
    final change = defaults is Map ? ((defaults['change'] as num?)?.toInt() ?? 0) : 0;
    final sets = exercise['sets'] as List;
    if (setIndex + 1 < sets.length) {
      final next = sets[setIndex + 1];
      final kind = next is Map ? next['kind'] : null;
      if ((kind == 'restPause' || kind == 'cluster') && mini > 0) return mini;
    }
    if (change > 0 && _closesExercise(sets, setIndex) && _hasPendingElsewhere(snapshot, exerciseIndex)) {
      return change;
    }
    return ((set['restAfterSec'] as num?)?.toInt() ?? 0).clamp(0, 3600);
  }

  bool _closesExercise(List sets, int setIndex) {
    for (var i = 0; i < sets.length; i++) {
      if (i == setIndex) continue;
      final value = sets[i];
      if (value is! Map || value['done'] != true) return false;
    }
    return true;
  }

  bool _hasPendingElsewhere(Map<String, dynamic> snapshot, int exerciseIndex) {
    final exercises = snapshot['exercises'] as List;
    for (var i = 0; i < exercises.length; i++) {
      if (i == exerciseIndex) continue;
      final sets = (exercises[i] as Map)['sets'];
      if (sets is! List) continue;
      if (sets.any((set) => set is Map && set['done'] != true)) return true;
    }
    return false;
  }

  static void _refreshSummary(Map<String, dynamic> snapshot) {
    var sets = 0;
    var volume = 0.0;
    for (final exercise in snapshot['exercises'] as List) {
      for (final set in (exercise as Map)['sets'] as List) {
        final value = set as Map;
        if (value['done'] == true) {
          sets++;
          volume += ((value['weight'] as num?) ?? 0) * ((value['reps'] as num?) ?? 0);
        }
      }
    }
    snapshot['summary'] = {
      'volumeKg': volume.round(),
      'sets': sets,
      'durationSec': (snapshot['elapsedSec'] as num?)?.toInt() ?? 0,
    };
  }

  /// Persists a new complete local snapshot and its operation in one commit.
  /// [operation] must contain a unique ID and the same workout ID.
  Future<void> commit(Map<String, dynamic> snapshot, Map<String, dynamic> operation) =>
      _transaction(() async {
        final current = _state;
        if (current == null) throw StateError('journal not initialized');
        final candidate = _copy(current);
        final previous = candidate['snapshot'] as Map<String, dynamic>;
        final id = operation['id'];
        if (id is! String ||
            id.isEmpty ||
            operation['workoutId'] != previous['workoutId'] ||
            snapshot['workoutId'] != previous['workoutId']) {
          throw const FormatException('invalid operation identity');
        }
        final pending = candidate['pending'] as List;
        if (pending.any((entry) => entry is Map && entry['id'] == id)) {
          throw StateError('duplicate operation');
        }
        final sequence = candidate['nextSequence'] as int;
        pending.add({..._copy(operation), 'sequence': sequence});
        candidate['nextSequence'] = sequence + 1;
        candidate['snapshot'] = _copy(snapshot);
        _validate(candidate);
        await _write(candidate);
        _state = candidate;
      });

  /// Removes only the oldest confirmed operation. Out-of-order acknowledgements
  /// are rejected instead of silently losing earlier pending work.
  Future<void> acknowledge(String operationId) => acknowledgeMany([operationId]);

  /// Removes a contiguous batch confirmed by the phone in one durable write.
  Future<void> acknowledgeMany(List<String> operationIds) => _transaction(() async {
    if (operationIds.isEmpty) return;
    final current = _state;
    if (current == null) throw StateError('journal not initialized');
    final candidate = _copy(current);
    final pending = candidate['pending'] as List;
    if (pending.isNotEmpty && (pending.first as Map)['action'] == 'adoptWorkout' &&
        (pending.first as Map)['id'] == operationIds.first) {
      (candidate['snapshot'] as Map).remove('watchOrigin');
    }
    _removeConfirmedPrefix(pending, operationIds);
    await _write(candidate);
    _state = candidate;
  });

  static void _removeConfirmedPrefix(List pending, List<String> operationIds) {
    if (pending.length < operationIds.length) {
      throw StateError('acknowledgement exceeds pending operations');
    }
    for (var index = 0; index < operationIds.length; index++) {
      if ((pending[index] as Map)['id'] != operationIds[index]) {
        throw StateError('batch acknowledgement is out of order');
      }
    }
    pending.removeRange(0, operationIds.length);
  }

  Future<void> _transaction(Future<void> Function() run) {
    final next = _tail.then((_) => run());
    _tail = next.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return next;
  }

  static void _validate(Map<String, dynamic> state) {
    final snapshot = state['snapshot'];
    final pending = state['pending'];
    if (state['schema'] != 1 ||
        snapshot is! Map ||
        snapshot['snapshotVersion'] != 1 ||
        snapshot['workoutId'] is! String ||
        (snapshot['workoutId'] as String).isEmpty ||
        snapshot['exercises'] is! List ||
        state['nextSequence'] is! int ||
        (state['nextSequence'] as int) < 1 ||
        pending is! List) {
      throw const FormatException('invalid or unsupported journal');
    }
    final ids = <String>{};
    var last = 0;
    for (final item in pending) {
      if (item is! Map ||
          item['id'] is! String ||
          (item['id'] as String).isEmpty ||
          item['workoutId'] != snapshot['workoutId'] ||
          item['sequence'] is! int ||
          (item['sequence'] as int) <= last ||
          !ids.add(item['id'] as String)) {
        throw const FormatException('invalid pending operation');
      }
      last = item['sequence'] as int;
    }
    if (last >= (state['nextSequence'] as int)) throw const FormatException('invalid next sequence');
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> value) =>
      (jsonDecode(jsonEncode(value)) as Map).cast<String, dynamic>();
}
