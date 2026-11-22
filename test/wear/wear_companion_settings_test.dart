import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/l10n/l10n.dart';
import 'package:gymmane/services/local_store.dart';
import 'package:gymmane/wear/companion/wear_companion_app.dart';
import 'package:gymmane/wear/companion/wear_companion_settings.dart';
import 'package:gymmane/wear/companion/wear_motion.dart';
import 'package:gymmane/wear/link/remote_workout.dart';
import 'package:gymmane/wear/link/wear_link_client.dart';
import 'package:gymmane/wear/wear_shell.dart';
import 'package:gymmane/widgets/rolling_text.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    SharedPreferences.setMockInitialValues({});
    await Store.instance.init();
  });

  testWidgets('watch follows the phone language and falls back to English', (tester) async {
    final home = WearLinkClient.instance.home;
    home.value = {'language': 'it'};
    addTearDown(() {
      home.value = null;
      Store.instance.setNote('wear_phone_language', 'en');
      setAppLanguage('en');
    });
    await tester.pumpWidget(const WearCompanionApp());
    expect(t.wearLinkConnect, 'COLLEGA TELEFONO');
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).locale, const Locale('it'));
    home.value = {'language': 'fr'};
    await tester.pumpAndSettle();
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).locale, const Locale('en'));
    home.value = null;
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const WearCompanionApp());
    expect(tester.widget<MaterialApp>(find.byType(MaterialApp)).locale, const Locale('en'));
  });

  testWidgets('watch settings open on a small display and persist after relaunch', (tester) async {
    await tester.binding.setSurfaceSize(const Size(180, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    Future<void> openSettings() async {
      final settings = find.byWidgetPredicate((widget) => widget is WearButton && widget.label == t.settings);
      await tester.scrollUntilVisible(settings, 55);
      await Scrollable.ensureVisible(tester.element(settings), alignment: 0.6);
      await tester.pump();
      await tester.tap(settings);
      await tester.pumpAndSettle();
      expect(find.byType(WearCompanionSettings), findsOneWidget);
    }

    await tester.pumpWidget(const WearCompanionApp());
    expect(find.byType(RollingText), findsOneWidget);
    await openSettings();
    final reduceMotion = find.text(t.calmMotionSetting);
    await tester.tap(reduceMotion);
    await tester.pumpAndSettle();
    final keepScreen = find.text(t.keepScreenOn);
    await tester.scrollUntilVisible(keepScreen, 30);
    await Scrollable.ensureVisible(tester.element(keepScreen), alignment: 0.6);
    await tester.pump();
    await tester.tap(keepScreen);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(WearCompanionSettings), findsNothing);
    expect(find.byType(RollingText), findsNothing);

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(const WearCompanionApp());
    expect(find.byType(RollingText), findsNothing);
    await openSettings();
    final preferences = tester.widget<WearCompanionSettings>(find.byType(WearCompanionSettings)).preferences;
    expect(preferences.reduceMotion, isTrue);
    expect(preferences.keepScreenOn, isTrue);

    tester.binding.platformDispatcher.accessibilityFeaturesTestValue = const FakeAccessibilityFeatures(
      disableAnimations: true,
    );
    addTearDown(tester.binding.platformDispatcher.clearAccessibilityFeaturesTestValue);
    preferences.setReduceMotion(false);
    preferences.setKeepScreenOn(false);
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(find.byType(RollingText), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('screen stays awake only while the visible workout is active', (tester) async {
    const channel = MethodChannel('gymmane/screen');
    final calls = <bool>[];
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      expect(call.method, 'keepOn');
      calls.add((call.arguments as Map)['on'] as bool);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(channel, null));
    final workout = WearLinkClient.instance.workout;
    addTearDown(() => workout.value = null);
    final prefs = WearCompanionPreferences()..setKeepScreenOn(true);
    addTearDown(() {
      prefs.setKeepScreenOn(false);
      prefs.dispose();
    });
    RemoteWorkout session(RemoteStatus status) => RemoteWorkout(
      rev: 1,
      bootId: 'boot',
      workoutId: 'workout',
      status: status,
      name: 'Prova',
      elapsedSeconds: 12,
      currentIndex: 0,
      exercises: const [],
      serverNow: DateTime.now(),
    );

    await tester.pumpWidget(const WearCompanionApp());
    workout.value = session(RemoteStatus.active);
    await tester.pump();
    expect(calls, [true]);
    workout.value = session(RemoteStatus.paused);
    await tester.pump();
    expect(calls, [true, false]);
    workout.value = session(RemoteStatus.active);
    await tester.pump();
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    expect(calls, [true, false, true, false]);
  });

  testWidgets('navigation animates the latest content and respects reduced motion', (tester) async {
    Widget screen(int page, {bool reduce = false}) => MaterialApp(
      home: MediaQuery(
        data: MediaQueryData(disableAnimations: reduce),
        child: WearEnter(
          identity: page,
          child: WearRollingDigits('$page:02', style: const TextStyle(fontSize: 16)),
        ),
      ),
    );
    await tester.pumpWidget(screen(1));
    await tester.pumpWidget(screen(2));
    final transition = find.ancestor(of: find.byType(RollingText), matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(transition).opacity.value, lessThan(1));
    expect(tester.widget<RollingText>(find.byType(RollingText)).text, '2:02');
    await tester.pumpWidget(screen(3, reduce: true));
    expect(find.byType(RollingText), findsNothing);
    final label = find.text('3:02');
    expect(label, findsOneWidget);
    final reduced = find.ancestor(of: label, matching: find.byType(FadeTransition)).first;
    expect(tester.widget<FadeTransition>(reduced).opacity.value, 1);
  });
}
