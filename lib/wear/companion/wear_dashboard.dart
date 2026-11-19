import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../models/exercise.dart';
import '../../state/fit_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../link/wear_home.dart';
import '../wear_shell.dart';
import 'wear_exercise_guide.dart';

enum WearSection { home, routines, exercises, nutrition }

class WearDashboard extends StatefulWidget {
  const WearDashboard({
    super.key,
    required this.data,
    required this.section,
    required this.connected,
    required this.busy,
    required this.workoutActive,
    required this.setSection,
    required this.action,
    required this.header,
    required this.feedback,
    required this.openWorkout,
    required this.openLink,
    this.pendingNutrition = 0,
  });

  final Map<String, dynamic>? data;
  final WearSection section;
  final bool connected;
  final bool busy;
  final bool workoutActive;
  final ValueChanged<WearSection> setSection;
  final void Function(String action, Map<String, dynamic> args) action;
  final Widget header;
  final Widget feedback;
  final VoidCallback openWorkout;
  final VoidCallback openLink;
  final int pendingNutrition;

  @override
  State<WearDashboard> createState() => _WearDashboardState();
}

class _WearDashboardState extends State<WearDashboard> {
  final _selected = <String>{};
  String _query = '';
  int _limit = 12;

  Map<String, dynamic> get _data => widget.data ?? const {};
  bool get _canSend => widget.connected && !widget.busy && widget.data != null;
  String get _today => wearDayKey(DateTime.now());
  bool get _isToday => _data['day'] == _today;

  List<Map> _list(String key) => (_data[key] as List?)?.whereType<Map>().toList() ?? const [];

  @override
  Widget build(BuildContext context) {
    final children = switch (widget.section) {
      WearSection.home => _home(),
      WearSection.routines => _routines(),
      WearSection.exercises => _exercises(),
      WearSection.nutrition => _nutrition(),
    };
    return WearPage(
      key: ValueKey(widget.section),
      scaleEdges: false,
      children: [
        Center(child: widget.header),
        const SizedBox(height: 8),
        widget.feedback,
        ...children,
        if (widget.section != WearSection.home)
          _button(t.back, PhosphorIconsBold.caretLeft, () => widget.setSection(WearSection.home)),
      ],
    );
  }

  List<Widget> _home() {
    final routine = _isToday ? _data['today'] as Map? : null;
    return [
      if (widget.workoutActive)
        _button(t.continueWorkout, PhosphorIconsFill.play, widget.openWorkout, primary: true)
      else if (routine != null) ...[
        _caption(routine['name'] as String),
        _button(t.startWorkout, PhosphorIconsFill.play, _canSend ? () => _startRoutine(routine) : null, primary: true),
      ],
      _button(t.routines, PhosphorIconsRegular.barbell, () => widget.setSection(WearSection.routines)),
      _button(t.exercises, PhosphorIconsRegular.listChecks, () => widget.setSection(WearSection.exercises)),
      if (_data['nutrition'] != false)
        _button(t.nutrition, PhosphorIconsRegular.drop, () => widget.setSection(WearSection.nutrition)),
      if (!widget.connected) _button(t.wearLinkConnect, PhosphorIconsRegular.linkSimple, widget.openLink),
    ];
  }

  void _startRoutine(Map routine) => widget.action('startRoutine', {'id': routine['id']});

  List<Widget> _routines() {
    final routines = _list('routines');
    return [
      _heading(t.routines),
      if (routines.isEmpty) _caption(widget.connected && widget.data != null ? t.noRoutines : t.wearLinkOffline),
      for (final routine in routines)
        _button(
          routine['name'] as String,
          PhosphorIconsRegular.barbell,
          _canSend && !widget.workoutActive ? () => _startRoutine(routine) : null,
        ),
    ];
  }

  List<Widget> _exercises() {
    final catalog = {
      for (final exercise in fit.allExercises.where((e) => !fit.isArchived(e.id)))
        exercise.id: exerciseName(exercise),
      for (final exercise in _list('custom')) exercise['id'] as String: exercise['name'] as String,
    };
    final exercises = catalog.entries.where((exercise) => exercise.value.toLowerCase().contains(_query)).toList();
    return [
      _heading(t.exercises),
      _button(
        '${t.startWorkout} (${_selected.length})',
        PhosphorIconsFill.play,
        _canSend && !widget.workoutActive && _selected.isNotEmpty
            ? () => widget.action('startExercises', {'ids': _selected.toList()})
            : null,
        primary: true,
      ),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: TextField(
          textInputAction: TextInputAction.search,
          style: const TextStyle(fontSize: 13),
          decoration: InputDecoration(hintText: t.searchExercises, isDense: true),
          onChanged: (value) => setState(() {
            _query = value.trim().toLowerCase();
            _limit = 12;
          }),
        ),
      ),
      for (final exercise in exercises.take(_limit))
        Row(
          children: [
            Expanded(
              child: _button(
                exercise.value,
                _selected.contains(exercise.key) ? PhosphorIconsBold.check : PhosphorIconsBold.plus,
                () => setState(() {
                  if (!_selected.remove(exercise.key) && _selected.length < 20) _selected.add(exercise.key);
                }),
              ),
            ),
            const SizedBox(width: 4),
            SizedBox(
              width: 48,
              child: WearIconButton(
                icon: PhosphorIconsRegular.info,
                label: '${t.howTo} · ${exercise.value}',
                onTap: fit.exerciseById(exercise.key) == null
                    ? null
                    : () => showWearExerciseGuide(context, id: exercise.key, name: exercise.value),
              ),
            ),
          ],
        ),
      if (exercises.length > _limit)
        _button(t.next, PhosphorIconsBold.caretDown, () => setState(() => _limit += 12)),
      if (!widget.connected) _caption(t.wearLinkOffline),
    ];
  }

  List<Widget> _nutrition() {
    final valid = _isToday && _data['nutrition'] == true;
    final glass = _data['glass'] as int? ?? 0;
    final plan = valid ? _data['plan'] as String? : null;
    final lastGlass = _list('watchWater').firstOrNull;
    final canLog = valid && !widget.busy;
    return [
      _heading(t.nutrition),
      if (!valid) _caption(t.wearLinkOffline),
      if (widget.pendingNutrition > 0)
        _caption('${t.wearLinkWaiting} · ${widget.pendingNutrition}'),
      if (valid) ...[
        _heading(t.waterLabel),
        _caption('${_data['water']} / ${_data['waterGoal']} ml'),
        _button(
          '+$glass ml',
          PhosphorIconsFill.drop,
          canLog && glass > 0 ? () => widget.action('water', {'day': _today, 'ml': glass}) : null,
          primary: true,
        ),
        if (lastGlass != null)
          _button(
            '${t.undo} · ${lastGlass['ml']} ml',
            PhosphorIconsRegular.arrowCounterClockwise,
            canLog ? () => widget.action('undoWater', {'day': _today, 'id': lastGlass['id']}) : null,
          ),
        if (_list('supplements').isNotEmpty) _heading(t.supplementsLabel),
        for (final item in _list('supplements')) ..._supplement(item, canLog),
        if (plan != null) ...[
          _heading(_data['planName'] as String? ?? t.mealPlansTitle),
          for (final meal in _list('meals')) ...[
            _heading(_mealName(meal)),
            _caption((meal['foods'] as List).join(' · ')),
            _button(
              meal['done'] == true ? t.done : t.logPlan,
              meal['done'] == true ? PhosphorIconsBold.check : PhosphorIconsRegular.forkKnife,
              canLog && meal['done'] != true
                  ? () => widget.action('meal', {'day': _today, 'plan': plan, 'id': meal['id']})
                  : null,
            ),
          ],
        ],
      ],
    ];
  }

  List<Widget> _supplement(Map item, bool canLog) {
    final taken = item['done'] == true;
    final dose = item['dose'] as String? ?? '';
    return [
      if (dose.isNotEmpty) _caption(dose),
      Padding(
        padding: const EdgeInsets.only(bottom: 6),
        child: WearButton(
          label: item['name'] as String,
          filled: taken,
          color: Colors.white,
          selected: taken,
          onTap: canLog
              ? () => widget.action('supplement', {
                  'day': _today,
                  'id': item['id'],
                  'taken': !taken,
                })
              : null,
        ),
      ),
    ];
  }

  String _mealName(Map meal) {
    final custom = meal['name'] as String? ?? '';
    if (custom.isNotEmpty) return custom;
    return switch (meal['id']) {
      'breakfast' => t.mealBreakfast,
      'lunch' => t.mealLunch,
      'dinner' => t.mealDinner,
      'snacks' => t.mealSnacks,
      _ => t.mealOther,
    };
  }

  Widget _heading(String label) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 5),
    child: Text(
      label,
      textAlign: TextAlign.center,
      style: AppTheme.f(15, weight: FontWeight.w800, color: context.gc.text),
    ),
  );

  Widget _caption(String label) => Padding(
    padding: const EdgeInsets.only(bottom: 5),
    child: Text(label, textAlign: TextAlign.center, style: AppTheme.f(12, color: context.gc.textSecondary)),
  );

  Widget _button(String label, IconData icon, VoidCallback? onTap, {bool primary = false}) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: WearButton(label: label, icon: icon, onTap: onTap, filled: primary),
  );
}
