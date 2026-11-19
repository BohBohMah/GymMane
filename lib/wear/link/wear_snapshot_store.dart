import 'dart:convert';
import 'dart:io';

/// Stores one complete, validated snapshot in app-private storage.
///
/// This is not yet an offline workout journal and must not be used to replay
/// commands. Writes are serialized and replace the previous file atomically.
class WearSnapshotStore {
  WearSnapshotStore(this.directory);

  final Directory directory;
  Future<void> _tail = Future.value();
  static const _fileName = 'wear_snapshot_v1.json';

  Future<void> save(Map<String, dynamic> snapshot) {
    final encoded = jsonEncode(_validated(snapshot));
    final next = _tail.then((_) => _write(encoded));
    _tail = next.then<void>((_) {}, onError: (Object error, StackTrace stack) {});
    return next;
  }

  Future<void> _write(String encoded) async {
    await directory.create(recursive: true);
    final temporary = File('${directory.path}/$_fileName.tmp');
    final destination = File('${directory.path}/$_fileName');
    final handle = await temporary.open(mode: FileMode.write);
    try {
      await handle.writeString(encoded);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temporary.rename(destination.path);
  }

  Future<Map<String, dynamic>?> load() async {
    await _tail;
    final file = File('${directory.path}/$_fileName');
    if (!await file.exists()) return null;
    final decoded = jsonDecode(await file.readAsString());
    if (decoded is! Map<String, dynamic>) throw const FormatException('snapshot must be an object');
    return _validated(decoded);
  }

  static Map<String, dynamic> _validated(Map<String, dynamic> data) {
    final version = data['snapshotVersion'];
    final id = data['workoutId'];
    final status = data['status'];
    final exercises = data['exercises'];
    if (version != 1 ||
        id is! String ||
        id.isEmpty ||
        !const {'active', 'paused', 'parked', 'complete'}.contains(status) ||
        data['rev'] is! int ||
        exercises is! List) {
      throw const FormatException('invalid or unsupported workout snapshot');
    }
    for (final exercise in exercises) {
      if (exercise is! Map || exercise['id'] is! String || exercise['sets'] is! List) {
        throw const FormatException('invalid exercise');
      }
      for (final set in exercise['sets'] as List) {
        if (set is! Map ||
            set['index'] is! int ||
            set['reps'] is! int ||
            set['weight'] is! num ||
            set['done'] is! bool) {
          throw const FormatException('invalid set');
        }
      }
    }
    // Deep-copy and reject non-JSON values before any replacement takes place.
    return (jsonDecode(jsonEncode(data)) as Map).cast<String, dynamic>();
  }
}
