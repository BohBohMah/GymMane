import '../../models/live_session.dart';
import '../../models/workout.dart';

abstract class WearWorkoutApi {
  WorkoutSession? get session;
  bool get paused;
  bool get parked;
  bool get complete;
  int get elapsedSeconds;
  int get restTotal;
  String get effortMode;
  String get workoutName;
  bool get hasData;

  void toggleSet(int exerciseIndex, int setIndex);
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
  void finish();
  void continueSession();
  void saveAndExit();
  void resumeSession();
}
