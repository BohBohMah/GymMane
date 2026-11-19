import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../l10n/l10n.dart';
import '../../state/fit_state.dart';
import '../../theme/app_theme.dart';
import '../wear_shell.dart';
import 'wear_link_screen.dart';

/// Minimal app wrapper used by the companion entry point and by previews.
class WearCompanionApp extends StatefulWidget {
  const WearCompanionApp({super.key});

  @override
  State<WearCompanionApp> createState() => _WearCompanionAppState();
}

class _WearCompanionAppState extends State<WearCompanionApp> {
  @override
  void initState() {
    super.initState();
    WearRotary.init();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GymMane',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      locale: fit.locale,
      supportedLocales: AppLocalizations.supportedLocales,
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      home: const Scaffold(body: WearLinkScreen(embedded: false)),
    );
  }
}
