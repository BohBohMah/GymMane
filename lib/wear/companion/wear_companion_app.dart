import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';

import '../../l10n/l10n.dart';
import '../../services/local_store.dart';
import '../../theme/app_theme.dart';
import '../link/wear_link_client.dart';
import '../wear_shell.dart';
import 'wear_companion_settings.dart';
import 'wear_link_screen.dart';
import 'wear_motion.dart';

String wearLanguage(String code) => code.toLowerCase().split(RegExp('[-_]')).first == 'it' ? 'it' : 'en';

/// Minimal app wrapper used by the companion entry point and by previews.
class WearCompanionApp extends StatefulWidget {
  const WearCompanionApp({super.key});

  @override
  State<WearCompanionApp> createState() => _WearCompanionAppState();
}

class _WearCompanionAppState extends State<WearCompanionApp> {
  final _preferences = WearCompanionPreferences();
  final _home = WearLinkClient.instance.home;
  static const _languageKey = 'wear_phone_language';
  late String _language;
  static final _motionTheme = _theme(false);
  static final _reducedTheme = _theme(true);

  static ThemeData _theme(bool reduced) => AppTheme.dark.copyWith(
    pageTransitionsTheme: PageTransitionsTheme(
      builders: {for (final platform in TargetPlatform.values) platform: WearPageTransitions(reduced: reduced)},
    ),
    splashFactory: reduced ? NoSplash.splashFactory : null,
  );

  @override
  void initState() {
    super.initState();
    WearRotary.init();
    final code = _home.value?['language'];
    _language = wearLanguage(
      code is String
          ? code
          : Store.instance.note(_languageKey) ?? WidgetsBinding.instance.platformDispatcher.locale.languageCode,
    );
    setAppLanguage(_language);
    _home.addListener(_syncLanguage);
  }

  void _syncLanguage() {
    final code = _home.value?['language'];
    if (code is! String) return;
    final next = wearLanguage(code);
    if (Store.instance.note(_languageKey) != next) Store.instance.setNote(_languageKey, next);
    if (next == _language) return;
    setAppLanguage(next);
    setState(() => _language = next);
  }

  @override
  void dispose() {
    _preferences.dispose();
    _home.removeListener(_syncLanguage);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'GymMane',
      debugShowCheckedModeBanner: false,
      theme: AppTheme.dark,
      darkTheme: AppTheme.dark,
      themeMode: ThemeMode.dark,
      locale: Locale(_language),
      supportedLocales: const [Locale('en'), Locale('it')],
      localizationsDelegates: const [
        AppLocalizations.delegate,
        GlobalMaterialLocalizations.delegate,
        GlobalWidgetsLocalizations.delegate,
        GlobalCupertinoLocalizations.delegate,
      ],
      builder: (context, child) {
        final media = MediaQuery.of(context);
        return ListenableBuilder(
          listenable: _preferences,
          child: child,
          builder: (context, child) {
            final reduced = media.disableAnimations || _preferences.reduceMotion;
            return MediaQuery(
              data: media.copyWith(disableAnimations: reduced),
              child: Theme(data: reduced ? _reducedTheme : _motionTheme, child: child!),
            );
          },
        );
      },
      home: Scaffold(body: WearLinkScreen(embedded: false, preferences: _preferences)),
    );
  }
}
