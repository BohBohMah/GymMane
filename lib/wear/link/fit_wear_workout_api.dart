import '../../models/live_session.dart';
import '../../models/workout.dart';
import '../../state/fit_state.dart';
import 'wear_workout_api.dart';

class FitWearWorkoutApi implements WearWorkoutApi {
  @override
  WorkoutSession? get session => fit.session;

  @override
  bool get paused => fit.sessionPaused;

  @override
  bool get parked => fit.route != 'session';

  @override
  bool get complete => fit.session?.complete ?? false;

  @override
  int get elapsedSeconds => fit.sessionElapsed;

  @override
  int get restTotal => fit.restTotal;

  @override
  String get effortMode => fit.effortMode;

  @override
  String get workoutName {
    final name = fit.session?.name?.trim();
    return name == null || name.isEmpty ? 'GymMane' : name;
  }

  @override
  bool get hasData => fit.hasData;

  @override
  void toggleSet(int exerciseIndex, int setIndex) => fit.toggleSet(exerciseIndex, setIndex);

  @override
  void setWeight(int exerciseIndex, int setIndex, double kg) =>
      fit.setSessionWeight(exerciseIndex, setIndex, kg);

  @override
  void setReps(int exerciseIndex, int setIndex, int reps) =>
      fit.setSessionReps(exerciseIndex, setIndex, reps);

  @override
  void setRepsRight(int exerciseIndex, int setIndex, int reps) =>
      fit.setSessionRepsRight(exerciseIndex, setIndex, reps);

  @override
  void setRpe(int exerciseIndex, int setIndex, double? rpe) =>
      fit.setSessionRpe(exerciseIndex, setIndex, rpe);

  @override
  void setKind(int exerciseIndex, int setIndex, SetKind kind) =>
      fit.setSetKind(exerciseIndex, setIndex, kind);

  @override
  void setSeconds(int exerciseIndex, int setIndex, int seconds) =>
      fit.setSessionSeconds(exerciseIndex, setIndex, seconds);

  @override
  void setKm(int exerciseIndex, int setIndex, double km) => fit.setSessionKm(exerciseIndex, setIndex, km);

  @override
  void nextExercise() => fit.nextExercise();

  @override
  void previousExercise() => fit.prevExercise();

  @override
  void goNextPending() => fit.goNextPending();

  @override
  void goToExercise(int index) => fit.goToExercise(index);

  @override
  void togglePause() => fit.toggleSessionPause();

  @override
  void skipRest() => fit.skipRest();

  @override
  void nudgeRest(int seconds) => fit.nudgeRest(seconds);

  @override
  void setRest(int seconds) => fit.setRest(seconds);

  @override
  void finish() => fit.finishSession();

  @override
  void continueSession() => fit.continueSession();

  @override
  void saveAndExit() => fit.saveAndExit();

  @override
  void resumeSession() => fit.resumeSession();
}
