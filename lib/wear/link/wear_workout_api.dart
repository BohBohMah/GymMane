import '../../models/live_session.dart';
import '../../models/workout.dart';

abstract class WearWorkoutApi {
  WorkoutSession? get session;
  bool get paused;
  bool get parked;
  bool get complete;
  int get elapsedSeconds;
  int get restTotal;

  /// Effective rest that would start if [setIndex] were completed now,
  /// including per-set, mini, change-exercise and per-exercise settings.
  int normalRestAfter(int exerciseIndex, int setIndex);

  /// Global rest durations the watch needs to resolve a rest without a phone.
  Map<String, int> get restDefaults;

  /// Adopts an already running rest at an absolute deadline, used when a
  /// watch completion is replayed after being offline.
  void adoptRest(DateTime endsAt, int totalSec, {bool switchSides = false});
  String get effortMode;
  String get workoutName;
  bool get hasData;

  void toggleSet(int exerciseIndex, int setIndex, {bool startRecovery = true});
  void setWeight(int exerciseIndex, int setIndex, double kg);
  void setReps(int exerciseIndex, int setIndex, int reps);
  void setRepsRight(int exerciseIndex, int setIndex, int reps);
  void setRpe(int exerciseIndex, int setIndex, double? rpe);
  void setKind(int exerciseIndex, int setIndex, SetKind kind);
  void setSeconds(int exerciseIndex, int setIndex, int seconds);
  void setKm(int exerciseIndex, int setIndex, double km);
  void nextExercise();
  void previousExercise();
  void goNextPending();
  void goToExercise(int index);
  void togglePause();
  void skipRest();
  void nudgeRest(int seconds);
  void setRest(int seconds);
  void finish({int? elapsedSeconds});
  void continueSession();
  void saveAndExit();
  void resumeSession();
}
