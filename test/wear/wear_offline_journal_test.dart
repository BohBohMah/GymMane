import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/wear/link/wear_offline_journal.dart';
import 'package:gymmane/wear/link/wear_offline_journal_file.dart';

Map<String, dynamic> snapshot(int weight) => {
  'snapshotVersion': 1,
  'workoutId': 'fictional',
  'exercises': [
    {
      'id': 'exercise',
      'sets': [
        {'index': 0, 'setId': 'set-one', 'weight': weight, 'reps': 8, 'done': false},
      ],
    },
  ],
};

Map<String, dynamic> operation(String id) => {'id': id, 'workoutId': 'fictional', 'action': 'updateSet'};

Map<String, dynamic> restSnapshot({String status = 'active'}) => {
  'snapshotVersion': 1,
  'workoutId': 'fictional',
  'status': status,
  'elapsedSec': 0,
  'currentIndex': 0,
  'rest': null,
  'restDefaults': {'normal': 90, 'mini': 20, 'change': 0, 'side': 0},
  'exercises': [
    {
      'id': 'exercise',
      'sets': [
        {
          'index': 0,
          'setId': 'set-one',
          'weight': 20,
          'reps': 8,
          'done': false,
          'kind': 'normal',
          'restAfterSec': 120,
        },
        {
          'index': 1,
          'setId': 'set-two',
          'weight': 20,
          'reps': 8,
          'done': false,
          'kind': 'normal',
          'restAfterSec': 120,
        },
      ],
    },
  ],
};

Map<String, dynamic> completeOperation(String id, {int setIndex = 0}) => {
  'id': id,
  'workoutId': 'fictional',
  'action': 'completeSet',
  'args': {
    'exerciseIndex': 0,
    'exerciseId': 'exercise',
    'setIndex': setIndex,
    'setId': setIndex == 0 ? 'set-one' : 'set-two',
  },
};

void main() {
  test('pausing offline freezes elapsed time and the rest timer until resume', () async {
    var now = DateTime(2026, 11, 17, 12);
    final journal = WearOfflineJournal(write: (_) async {}, clock: () => now);
    await journal.initialize(restSnapshot()..['serverNow'] = now.toIso8601String());
    await journal.apply(completeOperation('set'));
    now = now.add(const Duration(seconds: 30));
    Future<void> action(String action) =>
        journal.apply({'id': action, 'workoutId': 'fictional', 'action': action, 'args': {}});
    await action('pause');
    expect(journal.snapshot!['elapsedSec'], 30);
    expect(journal.snapshot!['rest']['frozenSec'], 90);
    now = now.add(const Duration(minutes: 10));
    await action('resume');
    expect(journal.snapshot!['rest']['frozenSec'], isNull);
    expect(DateTime.parse(journal.snapshot!['rest']['endsAt']).difference(now).inSeconds, 90);
    now = now.add(const Duration(seconds: 15));
    await action('finish');
    expect(journal.snapshot!['summary']['durationSec'], 45);
    expect(journal.pendingOperations(10).last['args']['elapsedSec'], 45);
  });

  test('a removed set does not prevent local replay of the remaining operations', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(restSnapshot());
    await journal.apply(completeOperation('old'));
    await journal.apply(completeOperation('still-valid', setIndex: 1));
    final authority = restSnapshot();
    authority['exercises'][0]['sets'][0]['setId'] = 'replacement';
    await journal.rebase(authority);
    expect(journal.pendingOperations(10), hasLength(2));
    expect(journal.snapshot!['exercises'][0]['sets'][0]['done'], false);
    expect(journal.snapshot!['exercises'][0]['sets'][1]['done'], true);
  });

  test('private file restores local edit and pending operation', () async {
    final dir = await Directory.systemTemp.createTemp('wear_journal_test_');
    try {
      final journal = await WearOfflineJournalFile(dir).open();
      await journal.initialize(snapshot(20));
      await journal.apply({
        'id': 'offline',
        'workoutId': 'fictional',
        'action': 'adjustSet',
        'args': {
          'exerciseIndex': 0,
          'exerciseId': 'exercise',
          'setIndex': 0,
          'setId': 'set-one',
          'field': 'weight',
          'delta': 2.5,
        },
      });
      final reopened = await WearOfflineJournalFile(dir).open();
      final state = reopened.state!;
      final exercise = (state['snapshot']['exercises'] as List).first as Map;
      expect(((exercise['sets'] as List).first as Map)['weight'], 22.5);
      expect((state['pending'] as List).single['id'], 'offline');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('clearing a private journal does not restore the old workout', () async {
    final dir = await Directory.systemTemp.createTemp('wear_journal_clear_test_');
    try {
      final journal = await WearOfflineJournalFile(dir).open();
      await journal.initialize(snapshot(20));
      await journal.clear();
      expect((await WearOfflineJournalFile(dir).open()).state, isNull);
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('rapid local edits apply serially to the latest committed state', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(snapshot(20));
    Future<void> add(String id) => journal.apply({
      'id': id,
      'workoutId': 'fictional',
      'action': 'adjustSet',
      'args': {
        'exerciseIndex': 0,
        'exerciseId': 'exercise',
        'setIndex': 0,
        'setId': 'set-one',
        'field': 'weight',
        'delta': 2.5,
      },
    });
    await Future.wait([add('1'), add('2'), add('3')]);
    final state = journal.state!;
    final exercise = (state['snapshot']['exercises'] as List).first as Map;
    final set = (exercise['sets'] as List).first as Map;
    expect(set['weight'], 27.5);
    expect((state['pending'] as List).length, 3);
  });

  test('rejects missing or stale set identities without changing the journal', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(snapshot(20));
    for (final id in [null, 'another-set']) {
      await expectLater(
        journal.apply({
          'id': 'edit',
          'workoutId': 'fictional',
          'action': 'updateSet',
          'args': {'exerciseIndex': 0, 'exerciseId': 'exercise', 'setIndex': 0, 'setId': ?id, 'weight': 25},
        }),
        throwsFormatException,
      );
    }
    expect(journal.state!['snapshot'], snapshot(20));
    expect(journal.state!['pending'], isEmpty);
  });

  test('restores unacknowledged operations after recreation', () async {
    String? disk;
    final first = WearOfflineJournal(write: (value) async => disk = value);
    await first.initialize(snapshot(20));
    await first.commit(snapshot(25), operation('one'));
    final restored = WearOfflineJournal(write: (value) async => disk = value);
    await restored.restore(disk!);
    expect((restored.state!['pending'] as List).length, 1);
    expect(restored.state!['snapshot'], snapshot(25));
    await restored.acknowledge('one');
    final again = WearOfflineJournal(write: (value) async => disk = value);
    await again.restore(disk!);
    expect(again.state!['pending'], isEmpty);
  });

  test('failed write leaves previous state and pending journal unchanged', () async {
    var fail = false;
    final journal = WearOfflineJournal(
      write: (value) async {
        if (fail) throw StateError('storage failure');
      },
    );
    await journal.initialize(snapshot(20));
    fail = true;
    await expectLater(journal.commit(snapshot(25), operation('one')), throwsStateError);
    expect(journal.state!['snapshot'], snapshot(20));
    expect(journal.state!['pending'], isEmpty);
  });

  test('preserves ordering and rejects duplicate or out-of-order acknowledgements', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(snapshot(20));
    await Future.wait([
      journal.commit(snapshot(25), operation('one')),
      journal.commit(snapshot(30), operation('two')),
    ]);
    await expectLater(journal.commit(snapshot(35), operation('two')), throwsStateError);
    await expectLater(journal.acknowledge('two'), throwsStateError);
    expect((journal.state!['pending'] as List).length, 2);
    await journal.acknowledge('one');
    await journal.acknowledge('two');
    expect(journal.state!['pending'], isEmpty);
  });

  test('acknowledges a contiguous batch in one transaction', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(snapshot(20));
    await journal.commit(snapshot(25), operation('one'));
    await journal.commit(snapshot(30), operation('two'));
    await journal.commit(snapshot(35), operation('three'));
    await journal.acknowledgeMany(const ['one', 'two']);
    final pending = journal.state!['pending'] as List;
    expect(pending.length, 1);
    expect((pending.single as Map)['id'], 'three');
  });

  test('rejects operations for a different workout', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(snapshot(20));
    await expectLater(
      journal.commit(snapshot(25), {...operation('one'), 'workoutId': 'other'}),
      throwsFormatException,
    );
    expect(journal.state!['pending'], isEmpty);
  });

  test('completing a set offline starts the effective rest and stores its deadline', () async {
    var now = DateTime(2026, 11, 17, 12);
    final journal = WearOfflineJournal(write: (_) async {}, clock: () => now);
    await journal.initialize(restSnapshot());
    await journal.apply(completeOperation('rest-one'));

    final state = journal.state!;
    final rest = (state['snapshot'] as Map)['rest'] as Map;
    expect(rest['totalSec'], 120);
    expect(DateTime.parse(rest['endsAt'] as String), now.toUtc().add(const Duration(seconds: 120)));
    final stored = (state['pending'] as List).single as Map;
    expect((stored['args'] as Map)['restEndsAt'], rest['endsAt']);
    expect((stored['args'] as Map)['restTotalSec'], 120);
  });

  test('replaying after 90s keeps the 30s that are actually left', () async {
    var now = DateTime(2026, 11, 17, 12);
    final journal = WearOfflineJournal(write: (_) async {}, clock: () => now);
    await journal.initialize(restSnapshot());
    await journal.apply(completeOperation('rest-one'));

    now = now.add(const Duration(seconds: 90));
    final authority = restSnapshot();
    (authority['exercises'] as List)[0]['sets'] = [
      for (final set in ((authority['exercises'] as List)[0] as Map)['sets'] as List)
        {...set as Map, 'done': false},
    ];
    await journal.rebase(authority);

    final state = journal.state!;
    final rest = (state['snapshot'] as Map)['rest'] as Map;
    final endsAt = DateTime.parse(rest['endsAt'] as String);
    expect(endsAt.difference(now).inSeconds, 30);
    final stored = (state['pending'] as List).single as Map;
    expect((stored['args'] as Map)['restEndsAt'], rest['endsAt']);
  });

  test('an expired watch recovery does not reappear from an older phone snapshot', () async {
    var now = DateTime.utc(2026, 11, 22, 15);
    final journal = WearOfflineJournal(write: (_) async {}, clock: () => now);
    await journal.initialize(restSnapshot());
    await journal.apply(completeOperation('rest-one'));
    now = now.add(const Duration(minutes: 3));
    final phone = restSnapshot()..['rest'] = {
      'endsAt': now.add(const Duration(seconds: 70)).toIso8601String(),
      'totalSec': 120,
    };
    await journal.rebase(phone);
    expect(journal.snapshot!['rest'], isNull);
    expect((journal.pendingOperations(1).single['args'] as Map)['restTotalSec'], 120);
  });

  test('a matching completion already on the phone keeps the phone recovery', () async {
    final now = DateTime.utc(2026, 11, 22, 15);
    final journal = WearOfflineJournal(write: (_) async {}, clock: () => now);
    await journal.initialize(restSnapshot());
    await journal.apply(completeOperation('rest-one'));
    final phoneRest = {'endsAt': now.add(const Duration(seconds: 45)).toIso8601String(), 'totalSec': 120};
    final phone = restSnapshot()..['rest'] = phoneRest;
    (((phone['exercises'] as List)[0] as Map)['sets'] as List)[0]['done'] = true;
    await journal.rebase(phone);
    expect(journal.snapshot!['rest'], phoneRest);
  });

  test('uses explicit set rest, mini rest and change rest when present', () async {
    var now = DateTime(2026, 11, 17, 12);
    final journal = WearOfflineJournal(write: (_) async {}, clock: () => now);

    final explicit = restSnapshot();
    ((explicit['exercises'] as List)[0]['sets'] as List)[0]['restSec'] = 45;
    await journal.initialize(explicit);
    await journal.apply(completeOperation('explicit'));
    expect(((journal.state!['snapshot'] as Map)['rest'] as Map)['totalSec'], 45);
    await journal.acknowledge('explicit');

    final mini = restSnapshot();
    ((mini['exercises'] as List)[0]['sets'] as List)[1]['kind'] = 'restPause';
    await journal.rebase(mini);
    await journal.apply(completeOperation('mini'));
    expect(((journal.state!['snapshot'] as Map)['rest'] as Map)['totalSec'], 20);
    await journal.acknowledge('mini');

    final change = restSnapshot();
    (change['restDefaults'] as Map)['change'] = 150;
    change['exercises'] = [
      {
        'id': 'exercise',
        'sets': [
          {
            'index': 0,
            'setId': 'set-one',
            'weight': 20,
            'reps': 8,
            'done': true,
            'kind': 'normal',
            'restAfterSec': 120,
          },
          {
            'index': 1,
            'setId': 'set-two',
            'weight': 20,
            'reps': 8,
            'done': false,
            'kind': 'normal',
            'restAfterSec': 120,
          },
        ],
      },
      {
        'id': 'row',
        'sets': [
          {
            'index': 0,
            'setId': 'row-one',
            'weight': 40,
            'reps': 10,
            'done': false,
            'kind': 'normal',
            'restAfterSec': 90,
          },
        ],
      },
    ];
    await journal.rebase(change);
    await journal.apply({
      'id': 'change',
      'workoutId': 'fictional',
      'action': 'completeSet',
      'args': {'exerciseIndex': 0, 'exerciseId': 'exercise', 'setIndex': 1, 'setId': 'set-two'},
    });
    expect(((journal.state!['snapshot'] as Map)['rest'] as Map)['totalSec'], 150);
    expect((journal.state!['snapshot'] as Map)['currentIndex'], 1);
  });

  test('a completion while paused does not publish a running rest', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(restSnapshot(status: 'paused'));
    await journal.apply(completeOperation('paused'));
    expect((journal.state!['snapshot'] as Map)['rest'], isNull);
  });

  test('a local discard stays pending without erasing the workout', () async {
    final journal = WearOfflineJournal(write: (_) async {});
    await journal.initialize(restSnapshot());
    await journal.apply({
      'id': 'discard',
      'workoutId': 'fictional',
      'action': 'saveExit',
      'args': <String, dynamic>{},
    });
    final state = journal.state!;
    expect((state['snapshot'] as Map)['status'], 'active');
    expect((state['snapshot'] as Map)['exercises'], isNotEmpty);
    final pending = (state['pending'] as List).single as Map;
    expect(pending['action'], 'saveExit');
  });

  test('a discard intent survives an app restart', () async {
    final dir = await Directory.systemTemp.createTemp('wear_journal_discard_test_');
    try {
      final journal = await WearOfflineJournalFile(dir).open();
      await journal.initialize(restSnapshot());
      await journal.apply({
        'id': 'discard',
        'workoutId': 'fictional',
        'action': 'saveExit',
        'args': <String, dynamic>{},
      });
      final reopened = await WearOfflineJournalFile(dir).open();
      final state = reopened.state!;
      expect((state['snapshot'] as Map)['status'], 'active');
      expect(((state['pending'] as List).single as Map)['action'], 'saveExit');
    } finally {
      await dir.delete(recursive: true);
    }
  });
}
