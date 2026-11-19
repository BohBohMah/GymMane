import 'package:flutter/material.dart';
import 'package:phosphoricons_flutter/phosphoricons_flutter.dart';

import '../../l10n/l10n.dart';
import '../../models/exercise.dart';
import '../../state/fit_state.dart';
import '../../theme/app_colors.dart';
import '../../theme/app_theme.dart';
import '../../widgets/exercise_art.dart';
import '../wear_shell.dart';

Future<void> showWearExerciseGuide(
  BuildContext context, {
  required String id,
  required String name,
  List<String> customSteps = const [],
}) => Navigator.of(context).push<void>(
  MaterialPageRoute(
    builder: (context) {
      final exercise = fit.exerciseById(id);
      final steps = exercise == null ? customSteps : exerciseSteps(exercise);
      final art = exercise?.art ?? '';
      final gc = context.gc;
      return Scaffold(
        body: WearPage(
          scaleEdges: false,
          children: [
            Text(
              t.catalogName(id, name),
              textAlign: TextAlign.center,
              style: AppTheme.f(17, weight: FontWeight.w800, color: gc.text),
            ),
            if (art.isNotEmpty) ...[
              const SizedBox(height: 8),
              ExerciseArt(
                slug: art,
                height: 112,
                live: !MediaQuery.disableAnimationsOf(context),
                loops: 3,
                icon: sportIcon(id),
              ),
            ],
            const SizedBox(height: 8),
            if (steps.isEmpty) Text(t.noStepsYet, textAlign: TextAlign.center),
            for (final (index, step) in steps.indexed)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: DecoratedBox(
                  decoration: BoxDecoration(color: gc.bgRaised, borderRadius: BorderRadius.circular(16)),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Text('${index + 1}. $step', style: AppTheme.f(13, color: gc.text, height: 1.35)),
                  ),
                ),
              ),
            WearButton(label: t.back, icon: PhosphorIconsBold.caretLeft, onTap: () => Navigator.pop(context)),
          ],
        ),
      );
    },
  ),
);
