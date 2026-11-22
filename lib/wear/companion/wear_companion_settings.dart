import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../services/local_store.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../wear_shell.dart';

class WearCompanionPreferences extends ChangeNotifier {
  static const _motionKey = 'wear_reduce_motion';
  static const _screenKey = 'wear_keep_screen_on';

  final _store = Store.instance;
  late bool _reduceMotion = _store.note(_motionKey) == 'true';
  late bool _keepScreenOn = _store.note(_screenKey) == 'true';

  bool get reduceMotion => _reduceMotion;
  bool get keepScreenOn => _keepScreenOn;

  void setReduceMotion(bool enabled) {
    if (enabled == _reduceMotion) return;
    _reduceMotion = enabled;
    _store.setNote(_motionKey, '$enabled');
    notifyListeners();
  }

  void setKeepScreenOn(bool enabled) {
    if (enabled == _keepScreenOn) return;
    _keepScreenOn = enabled;
    _store.setNote(_screenKey, '$enabled');
    notifyListeners();
  }
}

class WearCompanionSettings extends StatelessWidget {
  const WearCompanionSettings({super.key, required this.preferences});

  final WearCompanionPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    return Scaffold(
      body: ListenableBuilder(
        listenable: preferences,
        builder: (context, _) {
          Localizations.localeOf(context);
          return WearPage(
            scaleEdges: false,
            children: [
              Text(
                t.settings,
                textAlign: TextAlign.center,
                style: AppTheme.f(16, weight: FontWeight.w800, color: gc.text),
              ),
              const SizedBox(height: 10),
              _PreferenceTile(
                label: t.calmMotionSetting,
                value: preferences.reduceMotion,
                onChanged: preferences.setReduceMotion,
              ),
              const SizedBox(height: 6),
              _PreferenceTile(
                label: t.keepScreenOn,
                value: preferences.keepScreenOn,
                onChanged: preferences.setKeepScreenOn,
              ),
              const SizedBox(height: 8),
              WearButton(label: t.back, icon: PhosphorIconsBold.caretLeft, onTap: () => Navigator.pop(context)),
              const SizedBox(height: 8),
              Text(
                'Based on GymMane by InlitX',
                textAlign: TextAlign.center,
                style: AppTheme.f(10, color: gc.textSecondary),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _PreferenceTile extends StatelessWidget {
  const _PreferenceTile({required this.label, required this.value, required this.onChanged});

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) {
    final gc = context.gc;
    final shape = RoundedRectangleBorder(borderRadius: BorderRadius.circular(22));
    void toggle() => onChanged(!value);
    return Semantics(
      label: label,
      toggled: value,
      onTap: toggle,
      excludeSemantics: true,
      child: Material(
        color: gc.bgRaised,
        shape: shape,
        child: InkWell(
          customBorder: shape,
          onTap: toggle,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      label,
                      style: AppTheme.f(13, weight: FontWeight.w700, color: gc.text, height: 1.2),
                    ),
                  ),
                  const SizedBox(width: 8),
                  WearSwitchIndicator(on: value),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
