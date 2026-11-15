import 'package:flutter/material.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'services/local_store.dart';
import 'state/fit_state.dart';
import 'wear/companion/wear_companion_app.dart';

/// Standalone entry point for the watch companion, useful with
/// `flutter run -t lib/main_wear_companion.dart` on a Wear OS emulator.
/// The normal app launches the same screen from the watch settings.
Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  await initializeDateFormatting();
  await Store.instance.init();
  fit.loadFromStore();
  runApp(const WearCompanionApp());
}
