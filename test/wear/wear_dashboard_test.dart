import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/catalog/exercise_catalog.dart';
import 'package:gymmane/l10n/l10n.dart';
import 'package:gymmane/models/exercise.dart';
import 'package:gymmane/theme/app_colors.dart';
import 'package:gymmane/theme/app_theme.dart';
import 'package:gymmane/wear/companion/wear_dashboard.dart';
import 'package:gymmane/wear/companion/wear_exercise_guide.dart';
import 'package:gymmane/wear/companion/wear_link_screen.dart';
import 'package:gymmane/wear/companion/wear_weight_picker.dart';
import 'package:gymmane/wear/link/wear_home.dart';
import 'package:gymmane/wear/wear_shell.dart';
import 'package:gymmane/widgets/exercise_art.dart';

void main() {
  testWidgets('supplement pills show taken state without an icon and can be toggled offline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(220, 240));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var taken = false;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: StatefulBuilder(
        builder: (context, setState) => WearDashboard(
          data: {
            'day': wearDayKey(DateTime.now()),
            'nutrition': true,
            'glass': 250,
            'water': 0,
            'waterGoal': 2000,
            'supplements': [{'id': 'creatine', 'name': 'Creatina', 'done': taken}],
          },
          section: WearSection.nutrition,
          connected: false,
          busy: false,
          workoutActive: false,
          setSection: (_) {},
          action: (action, args) {
            expect(action, 'supplement');
            expect(args['id'], 'creatine');
            setState(() => taken = args['taken'] as bool);
          },
          header: const Text('GymMane'),
          feedback: const SizedBox.shrink(),
          openWorkout: () {},
          openLink: () {},
        ),
      )),
    ));

    final pill = find.byWidgetPredicate((widget) => widget is WearButton && widget.label == 'Creatina');
    await tester.scrollUntilVisible(pill, 40);
    Color? background() {
      final box = tester.widget<Container>(find.descendant(of: pill, matching: find.byType(Container)));
      return (box.decoration as BoxDecoration).color;
    }
    expect(background(), GymColors.dark.bgRaised);
    expect(tester.widget<WearButton>(pill).selected, false);
    expect(find.descendant(of: pill, matching: find.byType(Icon)), findsNothing);

    await tester.tap(pill);
    await tester.pump();
    expect(background(), Colors.white);
    expect(tester.widget<WearButton>(pill).selected, true);
    expect(find.descendant(of: pill, matching: find.byType(Icon)), findsNothing);

    await tester.tap(pill);
    await tester.pump();
    expect(background(), GymColors.dark.bgRaised);
    expect(taken, false);
  });

  testWidgets('system back returns from nutrition to the app home', (tester) async {
    await tester.binding.setSurfaceSize(const Size(210, 210));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: const Scaffold(body: WearLinkScreen(embedded: false)),
    ));
    final nutrition = find.byWidgetPredicate((widget) => widget is WearButton && widget.label == t.nutrition);
    await tester.scrollUntilVisible(nutrition, 40);
    await tester.tap(nutrition);
    await tester.pumpAndSettle();
    expect(tester.widget<WearDashboard>(find.byType(WearDashboard)).section, WearSection.nutrition);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(tester.widget<WearDashboard>(find.byType(WearDashboard)).section, WearSection.home);
  });

  testWidgets('the weight picker accepts an exact decimal with a comma', (tester) async {
    await tester.binding.setSurfaceSize(const Size(210, 210));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    double? result;
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Builder(builder: (context) => Scaffold(body: TextButton(
        onPressed: () async {
          result = await Navigator.of(context).push<double>(MaterialPageRoute(
            builder: (_) => const WearWeightPicker(initial: '7.5', unit: 'kg', maximum: 1000),
          ));
        },
        child: const Text('Weight'),
      ))),
    ));
    await tester.tap(find.text('Weight'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '8,25');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(result, 8.25);
  });

  testWidgets('a guide opens under the workout UI with bundled art and instructions', (tester) async {
    await tester.binding.setSurfaceSize(const Size(200, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final exercise = kExercises.firstWhere((exercise) => exercise.art.isNotEmpty && exercise.steps.isNotEmpty);
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Builder(
        builder: (context) => Scaffold(body: TextButton(
          onPressed: () => showWearExerciseGuide(context, id: exercise.id, name: exercise.name),
          child: const Text('Guide'),
        )),
      ),
    ));
    await tester.tap(find.text('Guide'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 350));
    expect(find.byType(ExerciseArt), findsOneWidget);
    final art = tester.widget<ExerciseArt>(find.byType(ExerciseArt));
    expect(art.slug, exercise.art);
    expect(art.live, true);
    await tester.scrollUntilVisible(find.text('1. ${exerciseSteps(exercise).first}'), 45);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the watch can add a glass from the nutrition page while offline', (tester) async {
    await tester.binding.setSurfaceSize(const Size(200, 200));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    String? action;
    Map<String, dynamic>? args;
    final day = wearDayKey(DateTime.now());
    await tester.pumpWidget(MaterialApp(
      theme: AppTheme.dark,
      home: Scaffold(body: WearDashboard(
        data: {'day': day, 'nutrition': true, 'glass': 250, 'water': 500, 'waterGoal': 2000},
        section: WearSection.nutrition,
        connected: false,
        busy: false,
        workoutActive: false,
        setSection: (_) {},
        action: (next, arguments) {
          action = next;
          args = arguments;
        },
        header: const Text('GymMane'),
        feedback: const SizedBox.shrink(),
        openWorkout: () {},
        openLink: () {},
      )),
    ));
    expect(find.text(t.nutrition), findsOneWidget);
    final add = find.byWidgetPredicate((widget) => widget is WearButton && widget.label == '+250 ml');
    await tester.scrollUntilVisible(add, 35);
    await tester.ensureVisible(add);
    await tester.tap(add);
    expect(action, 'water');
    expect(args, {'day': day, 'ml': 250});
  });
}
