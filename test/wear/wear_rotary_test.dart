import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:gymmane/theme/app_theme.dart';
import 'package:gymmane/wear/wear_shell.dart';

void main() {
  testWidgets('small workout pages keep the primary action reachable with reduced motion', (tester) async {
    await tester.binding.setSurfaceSize(const Size(180, 180));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var completed = false;
    await tester.pumpWidget(
      MaterialApp(
        theme: AppTheme.dark,
        home: MediaQuery(
          data: const MediaQueryData(size: Size(180, 180), disableAnimations: true),
          child: Scaffold(
            body: WearPage(
              scaleEdges: false,
              children: [
                const SizedBox(height: 190),
                WearButton(
                  label: 'Completa la serie in corso',
                  filled: true,
                  onTap: () => completed = true,
                ),
              ],
            ),
          ),
        ),
      ),
    );
    final action = find.byType(WearButton);
    await tester.scrollUntilVisible(action, 65);
    await tester.pumpAndSettle();
    expect(tester.getSize(action).height, 48);
    await tester.tap(action);
    expect(completed, true);
    expect(tester.takeException(), isNull);
  });

  testWidgets('native rotary events scroll the active Wear controller', (tester) async {
    WearRotary.init();
    final controller = ScrollController();
    WearRotary.attach(controller);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: ListView(controller: controller, children: List.generate(40, (i) => SizedBox(height: 48))),
        ),
      ),
    );
    ServicesBinding.instance.channelBuffers.push(
      'gymmane/rotary',
      const StandardMethodCodec().encodeMethodCall(const MethodCall('scroll', 80.0)),
      (_) {},
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 160));
    expect(controller.offset, 28);
    controller.jumpTo(110);
    WearRotary.turn(80);
    await tester.pumpAndSettle();
    expect(controller.offset, 138);
    WearRotary.detach(controller);
    await tester.pumpWidget(const SizedBox());
    controller.dispose();
  });
}
