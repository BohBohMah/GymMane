import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/wear/link/wear_command.dart';
import 'package:gymmane/wear/link/wear_nutrition_journal.dart';
import 'package:gymmane/wear/link/wear_offline_journal_file.dart';

void main() {
  final today = DateTime(2026, 11, 19, 12);
  const day = '2026-11-19';
  const summary = {
    'day': day,
    'nutrition': true,
    'water': 500,
    'glass': 250,
    'supplements': [
      {'id': 'creatine', 'name': 'Creatina', 'done': false, 'days': 0},
    ],
  };
  WearCommand command(String id, String action, Map<String, dynamic> args) =>
      WearCommand(id: id, baseRev: 0, action: 'home/$action', args: {'day': day, ...args});

  test('nutrition data, pending commands and exact undo survive app closure', () async {
    final dir = await Directory.systemTemp.createTemp('wear-nutrition-test');
    addTearDown(() => dir.delete(recursive: true));
    final file = WearJournalFile(dir, 'nutrition.json');
    var journal = WearNutritionJournal(write: file.write);
    await journal.rebase(summary, 'phone-a');
    await journal.enqueue(command('glass', 'water', {'ml': 250}));
    await journal.enqueue(command('creatine', 'supplement', {'id': 'creatine', 'taken': true}));
    expect(journal.view(today)!['water'], 750);
    expect(journal.view(today)!['watchWater'][0]['id'], 'glass');

    journal = WearNutritionJournal(write: file.write);
    await file.restore(journal.restore);
    expect(journal.view(today)!['supplements'][0]['done'], true);
    expect(journal.pendingCount, 2);
    expect(journal.first!.id, 'glass');
    await journal.enqueue(command('undo', 'undoWater', {'id': 'glass'}));
    expect(journal.view(today)!['water'], 500);

    await journal.rebase({...summary, 'water': 750, 'watchWater': [{'id': 'glass', 'ml': 250}],
      'nutritionReceipts': ['glass'],
    }, 'phone-a');
    expect(journal.first!.id, 'creatine');
    expect(journal.view(today)!['water'], 500);
    expect(journal.view(today.add(const Duration(days: 1)))!['supplements'][0]['done'], false);
    await journal.rebase({...summary, 'water': 100}, 'phone-b');
    expect(journal.acceptsPeer('phone-b'), false);
    expect(journal.pendingCount, 2);
  });
}
