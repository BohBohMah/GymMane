# GymMane Wear OS companion

The companion keeps one active workout in sync between an Android phone and a
Wear OS watch. It uses the existing Android Bluetooth bond and an authenticated
Bluetooth Low Energy connection. The phone keeps the workout history. The
watch can start a cached routine or a catalogue workout offline, persist edits
locally, and reconcile progress when the connection returns.

## Build and pair

Use Flutter with Dart 3.11.5 or later as required by `pubspec.yaml`, a JDK
compatible with Gradle 8.14 (the verified build used JDK 21), and Android SDK 36.
Set `JAVA_HOME` or the Gradle JDK in Android Studio and put `flutter` on `PATH`.
The phone test package supports Android API 24+, with the live link requiring
API 31+. The watch test package requires API 31+ (Wear OS 3+).

From the repository root in PowerShell:

```powershell
flutter pub get
if ($LASTEXITCODE -ne 0) { throw 'Could not resolve Flutter dependencies' }
flutter build apk --release -t lib/main.dart --android-project-arg=gymmaneTestVariant=phone --dart-define=GYMMANE_TEST_BUILD=true
if ($LASTEXITCODE -ne 0) { throw 'Phone build failed' }
Copy-Item build/app/outputs/flutter-apk/app-release.apk build/app/outputs/flutter-apk/GymMane-test-phone.apk -Force
flutter build apk --release -t lib/main_wear_companion.dart --android-project-arg=gymmaneTestVariant=wear --dart-define=GYMMANE_TEST_BUILD=true
if ($LASTEXITCODE -ne 0) { throw 'Watch build failed' }
Copy-Item build/app/outputs/flutter-apk/app-release.apk build/app/outputs/flutter-apk/GymMane-test-watch.apk -Force
```

Confirm the APK package IDs `com.gymmane.test.phone` and
`com.gymmane.test.wear` before installing on the corresponding devices. The
test builds use a local debug signing certificate. An in-place update requires
the same certificate as the installed APK.

Pair the devices in Android first. On the phone, open **Settings → Data &
backup → Wear OS watch**, enable the link, and grant Nearby devices access.
On the watch, select the already bonded phone during the enrollment window.
Current test builds enroll without typing an app PIN. The protocol retains the
legacy PIN path for compatibility.

## Verification for 2.5.0, build 18

- Static analysis passed. Flutter reported 1,390 passed and three skipped.
  The Kotlin protocol suite passed 40 tests. The sync and server modules
  passed 18 tests with locally available dependencies.
- Both signed release test APKs were installed in place on the HONOR phone and
  Galaxy Watch SM-R890. Both apps launched without fatal exceptions in Logcat.
- The watch showed the link go offline when phone Bluetooth was switched off
  and restored the authenticated connection after Bluetooth was switched back
  on. Both app processes stayed running. The observed recovery took about 15 seconds.
- A full physical workout replay with changes queued offline, rest timing,
  and a final history check remains a separate acceptance test.

See [the architecture](ARCHITECTURE.md) and the
[device test procedure](REAL_DEVICE_TEST.md). The
[handoff log](HANDOFF.md), [early status](IMPLEMENTATION_STATUS.md), and
[BLE feasibility record](BLE_FEASIBILITY.md) document earlier milestones.

Based on GymMane by InlitX.
