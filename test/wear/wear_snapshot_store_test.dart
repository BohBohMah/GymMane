import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/wear/link/wear_snapshot_store.dart';

Map<String, dynamic> snapshot(int rev) => {
  'snapshotVersion': 1,
  'workoutId': 'session',
  'status': 'active',
  'rev': rev,
  'exercises': [
    {
      'id': 'example',
      'name': 'Example',
      'sets': [
        {'index': 0, 'reps': 8, 'weight': 20.0, 'done': false},
      ],
    },
  ],
};

void main() {
  late Directory directory;

  setUp(() async => directory = await Directory.systemTemp.createTemp('wear_snapshot_test_'));
  tearDown(() async => directory.delete(recursive: true));

  test('restores complete snapshot in a new store instance', () async {
    await WearSnapshotStore(directory).save(snapshot(1));
    final restored = await WearSnapshotStore(directory).load();
    expect(restored, snapshot(1));
  });

  test('rejects invalid update without overwriting existing snapshot', () async {
    final store = WearSnapshotStore(directory);
    await store.save(snapshot(1));
    expect(() => store.save({...snapshot(2), 'snapshotVersion': 99}), throwsFormatException);
    expect(await store.load(), snapshot(1));
  });

  test('serializes writes in order', () async {
    final store = WearSnapshotStore(directory);
    await Future.wait([store.save(snapshot(1)), store.save(snapshot(2))]);
    expect((await store.load())!['rev'], 2);
  });
}
