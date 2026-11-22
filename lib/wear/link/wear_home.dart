import 'dart:convert';

import '../../models/nutrition.dart';
import '../../state/fit_state.dart';
import 'wear_command.dart';

String wearDayKey(DateTime day) => day.toIso8601String().split('T').first;

const wearNutritionActions = {'water', 'undoWater', 'supplement', 'meal'};

/// The home snapshot includes only today's plan and the choices the watch can
/// act on. Nutrition history, photos and stock quantities stay on the phone.
class WearHomePhone {
  WearHomePhone(this.state, {DateTime Function()? clock}) : clock = clock ?? DateTime.now;

  final FitState state;
  final DateTime Function() clock;

  Map<String, Object?> snapshot() {
    final now = clock();
    final today = state.routineOn(now);
    final routines = [...state.routines]
      ..sort((a, b) => (a.id == today?.id ? 0 : 1).compareTo(b.id == today?.id ? 0 : 1));
    final available = routines
        .map((routine) => (routine, state.routineExercises(routine).length))
        .where((entry) => entry.$2 > 0)
        .take(40);
    var draftBudget = 16000;
    final routineRows = <Map<String, dynamic>>[];
    for (final (routine, count) in available) {
      final row = <String, dynamic>{'id': routine.id, 'name': _text(routine.name), 'count': count};
      if (draftBudget > 0 && count <= 40) {
        final draft = state.wearRoutineDraft(routine).toJson()..remove('sid');
        for (final exercise in draft['ex'] as List) {
          for (final set in (exercise as Map)['s'] as List) {
            (set as Map).remove('sid');
          }
        }
        final size = utf8.encode(jsonEncode(draft)).length;
        if (size <= draftBudget) {
          row['draft'] = draft;
          draftBudget -= size;
        }
      }
      routineRows.add(row);
    }
    final plan = state.nutritionBeta ? state.planOn(now) : null;
    final logged = state.nutritionBeta ? state.entriesOn(now).map((entry) => entry.meal).toSet() : <Meal>{};
    return {
      'day': wearDayKey(now),
      'language': state.language,
      'training': {
        'rest': state.restSeconds,
        'mini': state.miniRestSeconds,
        'change': state.changeRestSeconds,
        'side': state.sideRestSeconds,
        'effort': state.effortMode,
        'units': state.units,
        'distance': state.distanceUnit,
        'stepKg': state.fromDisplayWeight(state.weightStep),
      },
      'today': today != null && state.routineExercises(today).isNotEmpty
          ? {'id': today.id, 'name': _text(today.name)}
          : null,
      'routines': routineRows,
      'custom': [
        for (final exercise in state.customExercises.where((e) => !state.isArchived(e.id)).take(30))
          {'id': exercise.id, 'name': _text(exercise.name), 'primary': exercise.primary},
      ],
      'weekDone': state.daysDoneThisWeek,
      'weekGoal': state.weeklyTarget,
      'weekStartDay': state.weekStartDay,
      'streak': state.currentStreak,
      'nutrition': state.nutritionBeta,
      if (state.nutritionBeta) ...{
        'water': state.waterOn(now),
        'waterGoal': state.goalsFor(now).waterMl,
        'glass': state.goalsFor(now).glassMl,
        'watchWater': [
          for (final sip in state.waterSipsOn(now).where((sip) => sip.operationId != null).toList().reversed.take(40))
            {'id': sip.operationId, 'ml': sip.ml},
        ],
        'supplements': [
          for (final s in state.activeSupplements.take(24))
            {
              'id': s.id,
              'name': _text(s.name),
              'dose': _text(state.suppDoseLabel(s)),
              'done': state.takenOn(now).contains(s.id),
              'days': s.days,
              'every': s.every,
              if (s.from != null) 'from': wearDayKey(s.from!),
              if (s.until != null) 'until': wearDayKey(s.until!),
            },
        ],
        if (plan != null) ...{
          'plan': plan.id,
          'planName': _text(plan.name),
          'meals': [
            for (final slot in state.mealSlots.take(8))
              if (plan.itemsOf(slot.meal) case final items when items.isNotEmpty)
                {
                  'id': slot.meal.id,
                  'name': _text(slot.name),
                  'done': logged.contains(slot.meal),
                  'foods': items.take(8).map((entry) => _text(entry.name)).toList(),
                },
          ],
        },
      },
    };
  }

  WearExecution execute(WearCommand command) {
    if (command.workoutId != null) return WearExecution.invalid;
    final now = clock();
    final args = command.args;
    final id = args['id'];
    if (command.action == 'home/startRoutine' || command.action == 'home/startExercises') {
      if (state.session != null) return const WearExecution(ok: false, code: 'active_session');
      if (command.action == 'home/startRoutine') {
        final routine = id is String ? state.routineById(id) : null;
        if (routine == null || state.routineExercises(routine).isEmpty) return WearExecution.invalid;
        state.startRoutine(routine);
        return WearExecution.changedOk;
      }
      final ids = args['ids'];
      if (ids is! List || ids.length > 20 || ids.any((id) => id is! String)) return WearExecution.invalid;
      return state.startWearExercises(ids.cast<String>()) ? WearExecution.changedOk : WearExecution.invalid;
    }
    final rawDay = args['day'];
    final day = rawDay is String ? DateTime.tryParse(rawDay) : null;
    if (!state.nutritionBeta || day == null || wearDayKey(day) != rawDay || day.isAfter(now)) {
      return WearExecution.invalid;
    }
    switch (command.action) {
      case 'home/water':
        final ml = args['ml'];
        if (ml is! int || ml <= 0 || ml > 5000) return WearExecution.invalid;
        if (state.waterSipsOn(day).any((sip) => sip.operationId == command.id)) return WearExecution.unchanged;
        state.addWaterOn(day, ml: ml, operationId: command.id);
        return WearExecution.changedOk;
      case 'home/undoWater':
        if (id is! String) return WearExecution.invalid;
        final sip = state.waterSipsOn(day).where((sip) => sip.operationId == id).firstOrNull;
        if (sip == null) return WearExecution.unchanged;
        state.removeWaterSip(sip);
        return WearExecution.changedOk;
      case 'home/supplement':
        if (id is! String || !state.supplementsDueOn(day).any((s) => s.id == id)) return WearExecution.invalid;
        final taken = args['taken'];
        if (taken != null && taken is! bool) return WearExecution.invalid;
        return state.setSupplementTakenOn(day, id, taken != false)
            ? WearExecution.changedOk
            : WearExecution.unchanged;
      case 'home/meal':
        final plan = state.planOn(day);
        final slot = state.mealSlots.where((slot) => slot.meal.id == id).firstOrNull;
        if (plan == null || slot == null || args['plan'] != plan.id) return WearExecution.invalid;
        if (state.entriesOn(day).any((entry) => entry.meal == slot.meal)) return WearExecution.unchanged;
        return state.logPlanMeal(plan, slot.meal, day: day).isEmpty
            ? WearExecution.invalid
            : WearExecution.changedOk;
      default:
        return WearExecution.unsupported;
    }
  }

  static String _text(String value) => String.fromCharCodes(value.runes.take(80));
}
