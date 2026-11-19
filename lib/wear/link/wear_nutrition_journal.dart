import 'dart:convert';
import 'dart:math';

import '../../models/nutrition.dart';
import 'wear_command.dart';
import 'wear_home.dart';

/// Retains the last phone summary independently of the workout journal.
/// Commands carry the day they were entered and keep their identity on retry.
class WearNutritionJournal {
  WearNutritionJournal({required this.write});

  final Future<void> Function(String) write;
  Future<void> _tail = Future.value();
  Map<String, dynamic>? _base;
  List<WearCommand> _pending = [];
  String _peer = '';

  int get pendingCount => _pending.length;
  bool acceptsPeer(String peer) => _peer.isEmpty || _peer == peer;
  WearCommand? get first => _pending.firstOrNull;

  Future<void> restore(String encoded) async {
    final raw = jsonDecode(encoded);
    if (raw is! Map || raw['version'] != 1 || raw['pending'] is! List || raw['peer'] is! String) {
      throw const FormatException('invalid nutrition journal');
    }
    final pending = <WearCommand>[];
    for (final entry in raw['pending'] as List) {
      final command = entry is Map<String, dynamic> ? WearCommand.fromJson(entry) : null;
      if (command == null || !wearNutritionActions.any((action) => command.action == 'home/$action')) {
        throw const FormatException('invalid nutrition operation');
      }
      pending.add(command);
    }
    final base = raw['base'];
    if (base != null && base is! Map<String, dynamic>) {
      throw const FormatException('invalid nutrition summary');
    }
    _base = base as Map<String, dynamic>?;
    _peer = raw['peer'] as String;
    _pending = pending;
  }

  Future<void> rebase(Map<String, dynamic> incoming, String peer) => _transaction(() async {
    if (!acceptsPeer(peer) && _pending.isNotEmpty) return;
    final base = _copy(incoming);
    final ids = (base.remove('nutritionReceipts') as List?)?.whereType<String>().toSet() ?? {};
    final pending = _pending.where((entry) => !ids.contains(entry.id)).toList();
    if (peer == _peer && pending.length == _pending.length && jsonEncode(base) == jsonEncode(_base)) return;
    await _save(base, pending, peer);
  });

  Future<void> enqueue(WearCommand command) => _transaction(() async {
    if (_base?['nutrition'] != true) throw StateError('no nutrition summary');
    final ml = command.args['ml'];
    if (command.action == 'home/water' && (ml is! int || ml < 1 || ml > 5000)) {
      throw const FormatException('invalid water amount');
    }
    if (command.action != 'home/water' && command.args['id'] is! String) {
      throw const FormatException('operation has no target');
    }
    await _save(_base, [..._pending, command], _peer);
  });

  Future<void> settle(String id, {required bool accepted}) => _transaction(() async {
    final command = _pending.where((entry) => entry.id == id).firstOrNull;
    if (command == null) return;
    final base = _base == null ? null : _copy(_base!);
    if (accepted && base != null) _apply(base, command);
    await _save(base, _pending.where((entry) => entry.id != id).toList(), _peer);
  });

  Future<void> clear() => _transaction(() => _save(null, [], ''));

  Map<String, dynamic>? view(DateTime now) {
    final base = _base;
    if (base == null) return null;
    final view = _copy(base);
    final day = wearDayKey(now);
    final fresh = day == view['day'];
    view['day'] = day;
    if (!fresh) {
      view.remove('today');
      view.remove('plan');
      view.remove('planName');
      view.remove('meals');
      view['water'] = 0;
      view.remove('watchWater');
    }
    final supplements = view['supplements'];
    if (supplements is List) {
      view['supplements'] = [
        for (final row in supplements.whereType<Map>())
          if (_dueOn(row, now, fresh)) {...row, if (!fresh) 'done': false},
      ];
    }
    for (final command in _pending) {
      _apply(view, command);
    }
    return view;
  }

  static bool _dueOn(Map row, DateTime day, bool fresh) {
    if (row['days'] is! int) return fresh;
    return Supplement(
      id: '',
      name: '',
      days: row['days'] as int,
      every: row['every'] as int? ?? 1,
      from: DateTime.tryParse(row['from'] as String? ?? ''),
      until: DateTime.tryParse(row['until'] as String? ?? ''),
    ).dueOn(day);
  }

  static void _apply(Map<String, dynamic> data, WearCommand command) {
    final args = command.args;
    if (args['day'] != data['day']) return;
    if (command.action == 'home/water' || command.action == 'home/undoWater') {
      final entries = (data['watchWater'] as List?)?.whereType<Map>().toList() ?? <Map>[];
      final total = data['water'] as int? ?? 0;
      if (command.action == 'home/water') {
        final ml = args['ml'] as int;
        if (!entries.any((entry) => entry['id'] == command.id)) {
          entries.insert(0, {'id': command.id, 'ml': ml});
          data['water'] = total + ml;
        }
      } else {
        final index = entries.indexWhere((entry) => entry['id'] == args['id']);
        if (index >= 0) data['water'] = max(0, total - (entries.removeAt(index)['ml'] as int));
      }
      data['watchWater'] = entries;
    } else {
      final key = command.action == 'home/supplement' ? 'supplements' : 'meals';
      final entries = data[key] as List?;
      if (entries == null || (key == 'meals' && args['plan'] != data['plan'])) return;
      for (final entry in entries.whereType<Map>()) {
        if (entry['id'] == args['id']) entry['done'] = args['taken'] != false;
      }
    }
  }

  Future<void> _transaction(Future<void> Function() apply) {
    final next = _tail.then((_) => apply());
    _tail = next.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return next;
  }

  Future<void> _save(Map<String, dynamic>? base, List<WearCommand> pending, String peer) async {
    await write(jsonEncode({
      'version': 1,
      'peer': peer,
      'base': base,
      'pending': [for (final command in pending) command.toJson()],
    }));
    _base = base;
    _pending = pending;
    _peer = peer;
  }

  static Map<String, dynamic> _copy(Map<String, dynamic> data) =>
      jsonDecode(jsonEncode(data)) as Map<String, dynamic>;
}
