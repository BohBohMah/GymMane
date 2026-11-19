import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/catalog/exercise_catalog.dart';
import 'package:gymmane/models/nutrition.dart';
import 'package:gymmane/models/workout.dart';
import 'package:gymmane/services/local_store.dart';
import 'package:gymmane/state/fit_state.dart';
import 'package:gymmane/wear/link/wear_command.dart';
import 'package:gymmane/wear/link/wear_home.dart';
import 'package:gymmane/wear/link/wear_link_server.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final today = DateTime(2026, 11, 19, 12);
  late FitState state;
  late WearHomePhone home;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await Store.instance.init();
    state = FitState();
    home = WearHomePhone(state, clock: () => today);
  });
  tearDown(() => state.dispose());

  WearCommand command(String action, [Map<String, dynamic> args = const {}]) =>
      WearCommand(id: 'home-test', baseRev: 0, action: 'home/$action', args: args);

  test('water goes to today even if the phone is viewing another day', () {
    state.nutritionDay = today.subtract(const Duration(days: 1));
    final glass = state.goalsFor(today).glassMl;
    final tomorrow = today.add(const Duration(days: 1));
    expect(home.execute(command('water', {'day': wearDayKey(tomorrow), 'ml': glass})).ok, false);
    expect(home.execute(command('water', {'day': wearDayKey(today), 'ml': glass})).ok, true);
    expect(state.waterOn(today), glass);
    expect(state.waterOn(state.nutritionDay), 0);
    expect(home.snapshot()['water'], glass);
  });

  test('marking a scheduled supplement twice consumes stock once', () {
    state.supplements.add(const Supplement(id: 'creatine', name: 'Creatine', stock: 100, amount: 5));
    final request = command('supplement', {'day': wearDayKey(today), 'id': 'creatine'});
    expect(home.execute(request).changed, true);
    expect(home.execute(request).changed, false);
    expect(state.supplements.single.stock, 95);
    expect(state.takenOn(today), contains('creatine'));
    final undo = command('supplement', {'day': wearDayKey(today), 'id': 'creatine', 'taken': false});
    expect(home.execute(undo).changed, true);
    expect(home.execute(undo).changed, false);
    expect(state.supplements.single.stock, 100);
    expect(state.takenOn(today), isEmpty);
  });

  test('an offline glass can be undone later without removing a phone entry', () {
    final previous = today.subtract(const Duration(days: 1));
    state.addWaterOn(previous, ml: 250);
    expect(home.execute(command('water', {'day': wearDayKey(previous), 'ml': 250})).ok, true);
    expect(state.waterOn(previous), 500);
    final watchGlass = state.waterSipsOn(previous).last;
    final restored = WaterSip.fromJson(watchGlass.toJson());
    expect(restored.operationId, 'home-test');
    final undo = command('undoWater', {'day': wearDayKey(previous), 'id': restored.operationId});
    expect(home.execute(undo).changed, true);
    expect(home.execute(undo).changed, false);
    expect(state.waterSipsOn(previous).single.operationId, isNull);
    expect(state.waterOn(previous), 250);
  });

  test('a planned meal uses its real portions and never copies over a logged meal', () {
    state.mealPlans.add(MealPlan(id: 'plan', name: 'Today', items: [
      FoodEntry(id: 'food', at: today, meal: Meal.lunch, name: 'Rice', servings: 2, grams: 80),
    ]));
    state.mealWeek[today.weekday] = 'plan';
    final request = command('meal', {'day': wearDayKey(today), 'plan': 'plan', 'id': Meal.lunch.id});
    expect(home.snapshot()['planName'], 'Today');
    expect(home.execute(request).changed, true);
    expect(home.execute(request).changed, false);
    final logged = state.entriesOn(today).single;
    expect(logged.meal, Meal.lunch);
    expect(logged.totalGrams, 160);
  });

  test('starting a selected workout preserves the selection order and guards the active session', () {
    final selected = [kExercises[1].id, kExercises[0].id];
    expect(home.execute(command('startExercises', {'ids': selected})).ok, true);
    final sessionId = state.session!.sessionId;
    expect(state.session!.exercises.map((exercise) => exercise.id), selected);
    state.routines.add(Routine('routine', 'Other', [kExercises[2].id]));
    expect(home.execute(command('startRoutine', {'id': 'routine'})).code, 'active_session');
    expect(state.session!.sessionId, sessionId);
    state.saveAndExit();
  });

  test('repeating the same authenticated water command records one glass', () async {
    fit.waterLog.clear();
    fit.wearAppliedOperations.clear();
    final now = DateTime.now();
    final glass = fit.goalsFor(now).glassMl;
    final command = {
      'id': 'same-glass',
      'action': 'home/water',
      'args': {'day': wearDayKey(now), 'ml': glass},
    };
    final server = WearLinkServer.instance;
    try {
      expect((await server.debugCommand(command))['ok'], true);
      expect((await server.debugCommand(command))['ok'], true);
      expect(fit.waterLog.single.ml, glass);
    } finally {
      fit.waterLog.clear();
      fit.wearAppliedOperations.clear();
    }
  });
}
