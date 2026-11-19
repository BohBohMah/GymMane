import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/wear/link/wear_link_diagnostics.dart';

void main() {
  test('snapshot diagnostic contains only state metadata', () {
    final summary = wearSnapshotSummary({
      'rev': 4,
      'status': 'active',
      'workoutId': 'live',
      'name': 'Private workout name',
      'exercises': [
        {
          'name': 'Private exercise name',
          'sets': [
            {'reps': 10, 'weight': 20},
          ],
        },
      ],
      'pairingCode': '123456',
    });

    expect(summary, 'rev=4 status=active hasWorkout=true exercises=1');
    expect(summary, isNot(contains('Private')));
    expect(summary, isNot(contains('123456')));
    expect(summary, isNot(contains('20')));
  });

  test('empty snapshot is reported as idle without exposing identifiers', () {
    expect(
      wearSnapshotSummary({'rev': 5, 'status': 'idle', 'workoutId': '', 'exercises': []}),
      'rev=5 status=idle hasWorkout=false exercises=0',
    );
  });
}
