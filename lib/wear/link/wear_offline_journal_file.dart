import 'dart:io';

import 'wear_offline_journal.dart';

/// Private-file adapter. A single journal instance must own this directory.
class WearOfflineJournalFile {
  WearOfflineJournalFile(this.directory);

  final Directory directory;
  static const _name = 'wear_workout_journal_v1.json';

  Future<WearOfflineJournal> open() async {
    final file = WearJournalFile(directory, _name);
    final journal = WearOfflineJournal(write: file.write);
    await file.restore(journal.restore);
    return journal;
  }
}

class WearJournalFile {
  WearJournalFile(this.directory, this.name);

  final Directory directory;
  final String name;
  File get _target => File('${directory.path}/$name');

  Future<void> restore(Future<void> Function(String) load) async {
    await directory.create(recursive: true);
    final target = _target;
    if (!await target.exists()) return;
    try {
      await load(await target.readAsString());
    } on FormatException {
      await target.rename('${target.path}.damaged-${DateTime.now().microsecondsSinceEpoch}');
    }
  }

  Future<void> write(String data) async {
    final target = _target;
    final temp = File('${target.path}.tmp');
    final handle = await temp.open(mode: FileMode.write);
    try {
      await handle.writeString(data);
      await handle.flush();
    } finally {
      await handle.close();
    }
    await temp.rename(target.path);
  }
}
