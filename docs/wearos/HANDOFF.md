# GymMane Wear OS companion — handoff

## 1. Session date and state

- Date: 2026-11-15.
- Branch: `feature/wear-os-offline`.
- The companion implementation is **code-complete for the agreed scope**.
  Isolated phone and Wear test APKs have now been built and statically verified.
  A physical phone + Wear OS watch pair was exercised, but end-to-end workout
  snapshot delivery remains **unverified and currently failing**.
- Nothing was pushed. Commits are small and local only.

## 1a. Real-device test preparation (2026-11-15)

The interrupted build-preparation edits were recovered, completed and checked.
Files added/changed for this preparation:

- `android/app/build.gradle.kts`: opt-in `gymmaneTestVariant=phone|wear`,
  distinct application IDs, watch API 31 minimum, test-only release manifest
  overlays and local debug signing. With the property unset, the production
  application ID/signing behavior remains unchanged.
- `android/app/src/phoneTest/` and `android/app/src/wearTest/`: role-specific
  manifest overlays and static-shortcut targets.
- `android/app/src/main/AndroidManifest.xml`: test label/scheme placeholders;
  normal production values remain GymMane and `gymmane`.
- `lib/services/home_widget_bridge.dart`: test builds do not invoke production
  home-widget calls.
- `docs/wearos/REAL_DEVICE_TEST.md`: beginner-friendly Windows/ADB install and
  test procedure.

Artifacts:

| APK | Application ID | Minimum | Notes |
| --- | --- | --- | --- |
| `build/app/outputs/flutter-apk/GymMane-test-phone.apk` | `com.gymmane.test.phone` | API 24; companion BLE link requires API 31+ | `lib/main.dart`; BLE advertise + connect |
| `build/app/outputs/flutter-apk/GymMane-test-watch.apk` | `com.gymmane.test.wear` | API 31 | `lib/main_wear_companion.dart`; required Wear + BLE features; connect + vibrate |

Both test APKs are builds signed with the local Android debug key
(SHA-256 `b731e5b0dfeee1046596c49dafdf0496300817dab65ad3db7acb225d8c259e52`).
Neither requests `INTERNET`, `BLUETOOTH_SCAN`, or location permissions. Test
provider authorities and static shortcut package targets use test IDs. The
default production `app-release.apk` was rebuilt after the test builds and
verified as `com.gymmane.app`.

Validation: Flutter analyze clean; 30 Wear Dart tests pass; Kotlin protocol
tests 36 pass; full Flutter suite 1171 pass / 3 skipped / 1 known localization
failure (`test/i18n_test.dart`). The test APKs passed package/min-SDK,
permission, watch/BLE feature and signing inspection. At this preparation stage
no devices were attached and no APK was installed by the build environment.
See §1b for subsequent owner-run physical evidence.

## 1b. First physical test and diagnostic build (2026-11-15)

The owner installed the test APKs and exercised the HONOR Magic8 Lite and
Galaxy Watch4 Classic (SM-R890, Wear OS 6.0; API 36 on both devices). Phone app
reported `Connected to
…`; the test phone showed a live session, but the watch remained on “No workout
running on the phone,” including after Refresh and a set change.

ADB/logcat evidence after reopening the watch app:

- Watch GATT client reconnected with status 0.
- MTU negotiation completed with MTU 517 and status 0.
- GATT service discovery completed with status 0.
- No relevant app crash was found. A later watch log showed that its app task had
  been removed and Android killed that process; reopening it caused the GATT
  reconnect. This explains that disconnect, but does not explain the missing
  active workout snapshot.
- The screen’s no-workout message cannot distinguish an idle snapshot from no
  snapshot received. That is the remaining diagnostic question.

Added gated, metadata-only tracing to:

- `lib/wear/link/wear_link_diagnostics.dart`,
  `wear_link_server.dart`, `wear_link_client.dart`;
- `android/app/src/main/kotlin/com/gymmane/app/wear/WearLinkDiagnostics.kt`,
  `WearGattServer.kt`, `WearGattClient.kt`;
- `android/app/build.gradle.kts` and
  `test/wear/wear_link_diagnostics_test.dart`.

Tracing reports only state/revision/exercise counts, command action names and
transport stages/result codes. It never records workout/exercise names, set
values, PINs, Bluetooth addresses or payloads. Native tracing is compiled on
only for test APK variants; Dart tracing also needs
`--dart-define=GYMMANE_WEAR_DIAGNOSTICS=true`.

Updated test APKs were built and statically verified at the same paths and IDs:
`GymMane-test-phone.apk` (`com.gymmane.test.phone`) and
`GymMane-test-watch.apk` (`com.gymmane.test.wear`). Both use the existing test
debug certificate and contain the diagnostic tracing. The production
`app-release.apk` was restored to `com.gymmane.app`; its generated
`GYMMANE_WEAR_DIAGNOSTICS` flag is false. **The updated APKs were not installed**:
at the time of this entry, the owner had not yet authorized device updates. On
2026-11-16, the owner explicitly authorized installation; both test APKs were
updated with `adb install -r` on their respective devices. Installation
succeeded and preserved each package ID/version. The official
`com.gymmane.app` was not touched.

## 1c. Diagnostic reproduction and captured logs (2026-11-16)

The owner connected the two test apps, started/completed sets, stopped that
workout, started another and tapped Refresh several times. The complete
logcat buffers were captured from both devices and stored locally under
`%TEMP%\gymmane-wear-test`; only relevant lines were reviewed.

Watch-side evidence:

- First GATT connection attempt returned status 0 at connection, but a later
  characteristic-write callback returned status 133. The client retried.
- The retry connected, negotiated MTU 517, discovered the service, enabled
  indications and completed the stored-key handshake.
- The watch requested state and received two snapshots, both `idle`,
  `hasWorkout=false`, `exercises=0` (revisions 1 and 2). The following command
  acknowledgement was successful.
- Eight later Refresh requests were logged as sent/write-started, but no
  subsequent state or acknowledgement appeared in the watch log.
- No fatal crash from the GymMane watch process was found. An unrelated
  `GlanceAppWidget` NPE was present.

Phone-side evidence:

- The test phone process was running in the foreground and the installed package
  was `com.gymmane.test.phone` version 2.3.0 (versionCode 14).
- No `GymManeWearLink` lines, Flutter diagnostic lines, or app-process lines
  appeared in any captured logcat buffer. Thus this capture cannot establish
  whether the phone prepared an active snapshot, received the later Refresh
  writes, or emitted responses.

Conclusion: the watch's GATT/handshake path works intermittently, but the
captured state was idle and later Refresh responses are absent. The phone-side
silence leaves the precise failing stage unresolved; do not claim a functional
fix yet. The full raw logs remain local and should not be committed or shared
without filtering.

## 1d. Persistent trace build (2026-11-16)

The preceding logcat capture had no phone-side app output. Added an app-private,
bounded (`128 KiB`) metadata trace at `files/wearlink-diagnostics.log`. Dart
events are forwarded over the existing local MethodChannel to the native
logger; Kotlin transport events append to the same file. It retains only the
last 128 KiB, records state/revision/counts and transport outcomes, and never
stores workout names, set values, PINs, addresses or payloads. The file can be
read from a test build using:

```powershell
adb -s $phone shell run-as com.gymmane.test.phone cat files/wearlink-diagnostics.log
adb -s $watch shell run-as com.gymmane.test.wear cat files/wearlink-diagnostics.log
```

An initial attempt to make a Flutter **release** APK debuggable failed at
runtime (`Precompiled runtime requires a precompiled snapshot`). Corrected by
building the test packages as genuine `--debug` variants and applying the
role-specific manifest/resource overlays to both debug and release build types.
The debug test manifests still remove `INTERNET`; only the test packages are
debuggable. Both debug APKs were installed in-place with `adb install -r`,
preserving app data and package IDs. No production APK was installed.

The phone process initialized the persistent logger after the update. Both app
tasks are currently sleeping/locked, so Dart initialization has not yet emitted
the phone attach event and no fresh session trace is available. A physical
screen unlock/wake is required before the next capture. Do not diagnose sync
from the pre-update trace or claim a functional fix yet.

## 1e. Offline code review and fixes (2026-11-16)

At the owner's request, no further device testing or installation was performed.
The watch PIN screen now has its own numeric keypad instead of depending on a
system IME. The watch command queue only advances on its own acknowledgement,
recovers from a timeout, fails outstanding commands on disconnect, and assigns
the latest revision when dispatching queued commands. The phone schedules a
follow-up snapshot for changes occurring while a command is being applied.
The GATT server waits for service registration before advertising, rejects a
second peer, disconnects after failed indications, and avoids replying to a
command on a replacement session. Missing snapshots are distinguished from
explicit idle state, and the watch elapsed timer no longer freezes for sessions
without a start timestamp.

Automated evidence: 33 Wear Dart tests pass, `flutter analyze` reports no
issues, the 36 Kotlin protocol tests pass, and both release test APKs compile.
The release test artifacts in `build/app/outputs/flutter-apk/` have the expected
test IDs, are non-debuggable, and do not request `INTERNET`, network state,
Bluetooth scanning, or location. They were **not installed** during this review;
the devices still have the prior debug diagnostic builds. The root cause of the
physical idle symptom is not proven and none of these changes has been validated
on hardware.

## 1f. Physical crash identified (2026-11-16)

After the owner paired successfully, Android's `data_app_crash` report on the
HONOR showed `IllegalArgumentException: notification should not be longer than
max length of an attribute value` from `BluetoothGattServer.notifyCharacteristicChanged`,
while sending an active workout snapshot. With negotiated MTU 517 the previous
code split frames at 514 bytes (`MTU - 3`), exceeding Android's 512-byte GATT
attribute value limit. The watch logs showed successful handshake followed by
write errors matching the phone crash times.

Both client and server now compute chunk size as `min(max(MTU,23)-3,512)`.
Server indication invocation exceptions are handled as transport failures rather
than uncaught process crashes. The protocol regression test checks MTUs 23, 247,
517, large values, and reassembles a frame exceeding 512 bytes. Kotlin protocol
tests, 33 Wear Dart tests, `flutter analyze` and both test APK builds passed.
Manifest inspection confirms neither APK requests `INTERNET`, network state,
scan or location permissions. Updated APKs were built but not installed or
verified on physical devices; the owner had requested no device testing.

## 1g. Watch rest and text rendering (2026-11-16)

The owner subsequently reported the link appeared to work, but rest was not
shown and all watch text had yellow underlines. Code review identified that
the standalone companion lacked a Material `Scaffold`, and nested rest/summary
maps from `StandardMethodCodec` were incorrectly cast to
`Map<String, dynamic>`. The companion now has a `Scaffold` and parses nested
maps without assuming their generic key type. A channel-level Dart test checks
that nested rest and summary data survive the actual method codec.

34 Wear tests and `flutter analyze` pass. A new non-debuggable watch test APK
was built and checked for the correct test ID and absence of `INTERNET`, network
state, scan and location permissions. It was not installed or tested on the
watch by the assistant. The owner-observed link success and the two fixes still
require physical confirmation.

## 1h. Scroll fade and effort mode

The top fade in `WearPage` now occupies a smaller fraction of the screen.
The phone snapshot carries `effortMode` (`rpe`, `rir`, or empty), included in
the semantic fingerprint so preference changes propagate. The watch hides
effort controls when the mode is empty, displays RPE or RIR otherwise, and
converts RIR to the phone's canonical RPE (`10 - RIR`). Older snapshots without
the field default to no effort controls. Updating both test APKs is required.
35 Wear Dart tests pass, Flutter analysis is clean, and both test release APKs
were rebuilt with no Internet, network state, scan or location permissions.
They were not installed or tested on hardware.

## 1i. Ongoing workout on Wear OS

The watch now starts a `connectedDevice` foreground service and posts an
AndroidX Wear Ongoing Activity when an active, paused or parked workout state
arrives. The notification has a tap intent back to the app. While that service
is active, engine teardown does not shut down the existing GATT client; reopening
an already-connected client requests a fresh snapshot. An idle/complete
snapshot, explicit disconnect or forget stops the service. Notification
permission is requested when needed. The service does not automatically restart
after process death, and Android can still end it or restrict background starts.
The phone remains authoritative.

36 Wear Dart tests and Flutter analysis pass; both test APKs compile, and their
manifests have no INTERNET, network state, scan or location permission. The
watch now requests notification and connected-device foreground-service
permissions. Icon visibility, background starts, standby, process termination
and reconnection are **not hardware-verified**. The updated APKs were not
installed by the assistant.

## 2. Commits in this feature

The work is split into small local commits on `feature/wear-os-offline`:

1. `02b19d3` — shared Kotlin protocol package and its tests;
2. `c8c944e` — Dart link layer (models, executor, snapshot, phone coordinator)
   and tests;
3. `e628a0f` — Android native transport (GATT server/client, bridge, manifest,
   permissions);
4. `3a2af70` — watch companion UI, phone settings UI, entry point and
   localisation;
5. `12eadc9` — documentation (`ARCHITECTURE.md`, `IMPLEMENTATION_STATUS.md`,
   `BLE_FEASIBILITY.md`, this file);
6. `7946af0` — keep the watch link preference across engine teardown (a user
   Disconnect still clears it).

`analysis_options.yaml` was already modified before this work (two analyzer
excludes added by an earlier `flutter pub get`). It is **not** part of the
feature and was left untouched.

`.opencode/` is local harness tooling. It is untracked and must not be committed.

## 3. Overall objective

Add a privacy-first, opt-in Wear OS companion to GymMane:

- the phone stays the single authoritative store of workout state;
- the watch shows the live workout and sends small, idempotent commands;
- communication is local Bluetooth only: no accounts, cloud, analytics,
  telemetry, HTTP/WebSocket/IP sync and no Wear OS Data Layer;
- `android.permission.INTERNET` must be absent from the final release APK;
- the original app and the existing standalone watch mode keep working
  unchanged when the feature is off (the default).

All of these are implemented. The only unproven part is the physical BLE link.

## 4. Chosen architecture

Full rationale: `docs/wearos/ARCHITECTURE.md`. Short version:

- The repository already ships a complete Flutter Wear OS UI (`lib/wear/`) and
  builds Flutter on Wear. Rather than a second native Kotlin/Compose app, the
  companion is a **second Flutter entry point** in the same Android module
  (`lib/main_wear_companion.dart`) that reuses `WearPage`, `WearButton`,
  `WearIconButton`, `WearClock`, `WearRotary`, `AppTheme`, `GymColors` and the
  ARB strings.
- The normal watch app reaches the same screen from Settings → **Phone link**
  (`fit.pushRoute('link')`), so no second APK is required in production.
- The companion owns **no** workout database; it mirrors phone snapshots.
- Transport is direct BLE GATT: phone = GATT server + advertiser, watch = GATT
  client connecting to an already OS-bonded phone. Neither scans, so
  `BLUETOOTH_SCAN` and location permissions are avoided.
- Security: OS LE Secure Connections + bonding, characteristics requiring
  encrypted MITM peers, plus an app-level six-digit PIN, random 256-bit PSK,
  PBKDF2-HMAC-SHA256 (120k), HMAC-SHA256 tags, HKDF-SHA256 session keys and
  strict per-direction sequence numbers. No custom cipher.

## 5. Implemented components

### Shared Kotlin protocol — `packages/wear_protocol/`

Standalone JVM Gradle project compiled into the app module.

- `Wire.kt` — 5-byte framing (`kind` + big-endian length, max 65536),
  `FrameReader`, `Chunker`.
- `Security.kt` — `WearCrypto`: SHA-256, HMAC-SHA256, HKDF-SHA256,
  PBKDF2-HMAC-SHA256, constant-time compare and a local base64 implementation
  (no `java.util.Base64`, so no API 26 trap).
- `Messages.kt` — `WearJson` helpers and `Map`/`JsonElement` conversions used by
  the MethodChannel bridge.
- `HandshakeCrypto.kt` — handshake transcripts and proof constructors.
- `Handshake.kt` — `PhoneHandshake` / `WatchHandshake` state machines
  (pair / resume / reject).
- `Session.kt` — `SecureSession` sealing/opening with sequence and MAC checks.
- Tests: `WireTest.kt` (12), `SecureSessionTest.kt` (11), `HandshakeTest.kt`
  (10), `Base64Test.kt` (3) — **36 tests, 0 failures**.

### Dart link layer — `lib/wear/link/`

- `remote_workout.dart` — snapshot models (status, exercise, set, rest,
  summary) and JSON parsing.
- `wear_workout_api.dart` / `fit_wear_workout_api.dart` — abstraction and
  adapter onto the real `fit` singleton. It delegates to the existing
  authoritative methods.
- `wear_command.dart` — command / ack / execution result models.
- `wear_command_executor.dart` — validates and executes commands; enforces
  `baseRev` conflicts; a bounded `WearCommandLedger` makes duplicate ids
  idempotent. Explicit but invalid set indices are rejected, not silently
  redirected to the pending set.
- `wear_snapshot.dart` — authoritative state JSON and a semantic fingerprint.
  Rest ticks and clock fields are excluded from the fingerprint so they do not
  bump `rev`; rest is sent as a wall-clock `endsAt`.
- `wear_link_status.dart` — connection/pairing status model.
- `wear_link_server.dart` — phone coordinator: commands → executor → ack,
  state push on `fit` changes, and **serialized pushes** so a snapshot built
  before a command cannot overwrite the command result.
- `wear_link_client.dart` — watch client: ack-gated command queue, conflict
  resync, bounded pending map, reconnect support and test hooks.

### Android native transport — `android/app/src/main/kotlin/com/gymmane/app/wear/`

- `WearPrefs.kt` — `WearUuids` and preferences: phone server flag, pairing
  window + PIN, per-watch PSK map, watch identity, phone address/name, client
  flag.
- `WearGattServer.kt` — phone peripheral: advertises the service, exposes RX
  (write) and TX (indicate/read) with encrypted-MITM permissions, rejects
  non-bonded peers, runs `PhoneHandshake`/`SecureSession`, chunks to `MTU - 3`
  and indicates sequentially.
- `WearGattClient.kt` — watch central: refuses non-bonded phones, requests MTU
  517, discovers the service, enables indications, runs `WatchHandshake`,
  submits the PIN, sends one write at a time and dispatches state/ack.
- `WearLinkBridge.kt` — `gymmane/wearlink` MethodChannel for both roles,
  including deferred permission results and the bonded-device list. The bonded
  list itself requests/awaits `BLUETOOTH_CONNECT` before returning.
- `MainActivity.kt` — registers the bridge, forwards
  `onRequestPermissionsResult` and detaches on engine cleanup.

### UI and integration

- `lib/wear/companion/wear_link_screen.dart` — watch companion: device picker,
  PIN entry, overview, set steppers, RPE, rest timer + haptics, navigation,
  pause/resume, disconnect/forget, flash messages. It only shows “Saved on
  phone” after the ack.
- `lib/wear/companion/wear_link_settings.dart` — phone settings card: opt-in
  toggle, pairing code with countdown, status, forget.
- `lib/wear/companion/wear_companion_app.dart` and
  `lib/main_wear_companion.dart` — development/preview entry point.
- `lib/screens/settings_screen.dart` — new `wear` category.
- `lib/wear/wear_shell.dart` — watch Settings → **Phone link** and the `link`
  route.
- `lib/state/settings_state.dart` / `lib/state/fit_state.dart` — persisted
  `wearLink` flag, default **false**, reset on data wipe.
- `lib/main.dart` — attaches the phone server or the watch client according to
  `DeviceKind.isWatch()`.

### Build and manifest

- `android/app/build.gradle.kts` — compiles the protocol sources and depends on
  `kotlinx-serialization-json:1.7.3`.
- `android/app/src/main/AndroidManifest.xml` — `BLUETOOTH_ADVERTISE`
  (`neverForLocation`), `BLUETOOTH_CONNECT`, legacy `BLUETOOTH`/`BLUETOOTH_ADMIN`
  with `maxSdkVersion="30"`, explicit `INTERNET` removal via
  `tools:node="remove"` and `bluetooth_le` as `required=false`.
- `test/pending_translation_keys.txt` — the 40 new `wearLink*` keys are listed
  here, using the project's existing mechanism for keys translated only into EN
  and IT so far. Other languages fall back to English.

## 6. Protocol and consistency rules

- The phone owns `rev`. Rest ticks and clock fields never bump it.
- Commands carry `baseRev`; a stale command returns `conflict` and the watch
  requests a fresh state. `requestState` is always accepted.
- The phone acknowledges after executing and pushing the resulting state.
- Duplicate command ids are served from a bounded ledger, so a retried tap is
  idempotent.
- The watch never marks a set complete locally: it shows the pending set until
  the phone ack and snapshot arrive.
- Reconnect: the watch client uses exponential backoff (max 30 s) and stops
  auto-retry after an authentication rejection; the user can reconnect from the
  UI. The phone re-advertises when the link is enabled.
- Lifecycle: closing the watch app calls `WearGattClient.shutdown()`, which
  stops the radio but keeps `clientEnabled` true, so the next launch resumes the
  saved phone. An explicit **Disconnect** calls `stop()` and clears it. On the
  phone, engine teardown calls `WearGattServer.stop()` without clearing
  `serverEnabled`, so relaunching the app restores the enabled link from
  `fit.wearLink`.

## 7. Tests and builds actually run

| What | Command | Result |
| --- | --- | --- |
| Protocol unit tests | `.\android\gradlew.bat -p packages\wear_protocol test` | **BUILD SUCCESSFUL**, 36 tests, 0 failures |
| Dart Wear tests | `& $FLUTTER test test\wear\` | **30 tests pass** |
| Static analysis | `& $FLUTTER analyze` | **No issues found!** |
| Full Flutter suite | `& $FLUTTER test` | **1171 pass / 3 skip / 1 failure** |
| Companion entry bundle | `& $FLUTTER build bundle -t lib\main_wear_companion.dart` | exit 0 |
| Kotlin app compile | `.\gradlew.bat :app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| Release APK | `& $FLUTTER build apk --release` | **SUCCESS**, 114,563,030 bytes |
| Merged release manifest | `Select-String ... release\processReleaseManifest\AndroidManifest.xml` | 0 `INTERNET`, 0 `BLUETOOTH_SCAN`, 0 location |
| Release APK permissions | `aapt dump permissions app-release.apk` | no `INTERNET`; `BLUETOOTH_ADVERTISE`, `BLUETOOTH_CONNECT`, legacy BT (maxSdk 30) |

The single full-suite failure is **pre-existing and unrelated**: `test/i18n_test.dart`
reports 52 missing ARB keys (`help*`, `pairSetting*`, `keepCounting*`,
`holdOvertime`, `alsoWorksMuscles`). The same 52 keys are missing in `HEAD`; the
feature's own keys are tracked in `test/pending_translation_keys.txt`. No existing
test was modified to hide anything.

## 8. What is still unverified / not done

- **No real BLE hardware validation.** Follow `BLE_FEASIBILITY.md` §6. Until then
  do not claim the link works on hardware.
- **No foreground service.** The link lives while the phone app process is alive.
  If Android kills the process, the watch shows offline and reconnects when the
  app returns.
- **PSK storage hardening.** The PSK is in app-private `SharedPreferences`, not
  Keystore-wrapped. A possible follow-up is `EncryptedSharedPreferences` or a
  Keystore-wrapped key.
- **OEM/MTU behaviour.** MTU 517 is requested; the MTU-23 fallback works but can
  be slow for large snapshots (see `BLE_FEASIBILITY.md` §4).
- **No iOS support.**

## 9. First precise task on resume

Use `docs/wearos/REAL_DEVICE_TEST.md` for exact Windows/ADB commands and the
HONOR Magic8 Lite + Galaxy Watch4 Classic sequence. Check the OS API level on
both devices first (31+ required for the link), bond them in system Bluetooth
settings, and install only the two `GymMane-test-*.apk` files. Never uninstall,
clear, overwrite or update `com.gymmane.app`.

On the available target pair, start with:

1. bond the phone and watch in system settings;
2. enable Settings → **Smartwatch link** on the phone and tap **PAIR A WATCH**;
3. open Settings → **Phone link** on the watch, select the bonded phone and
   enter the code;
4. start a workout, complete a set from the watch, and verify “Saved on phone”
   appears only after the phone shows the set done;
5. record pairing time, MTU, reconnect behaviour, duplicate/stale handling and
   any logcat errors;
6. repeat with Wi-Fi and mobile data off, then record results without exposing
   personal workout or device data.

If hardware is still unavailable, the honest next step is to keep the code
frozen and update `IMPLEMENTATION_STATUS.md` only with new evidence.

## 10. Useful commands

```powershell
# Environment (Windows, this machine)
$env:JAVA_HOME='C:\Users\Claudio\.jdks\temurin-21.0.12.1'
$env:GRADLE_OPTS='-Dorg.gradle.java.home=C:\Users\Claudio\.jdks\temurin-21.0.12.1'
$FLUTTER='C:\Users\Claudio\AppData\Local\Temp\opencode\flutter-3.41\bin\flutter.bat'

# Protocol unit tests (fast)
.\android\gradlew.bat -p packages\wear_protocol test --console=plain

# Dart Wear tests
& $FLUTTER test test\wear\

# Static analysis
& $FLUTTER analyze

# Full app tests (long; one known pre-existing i18n failure)
& $FLUTTER test

# Companion entry point compile check
& $FLUTTER build bundle -t lib\main_wear_companion.dart

# Isolated debuggable test APKs (copy Gradle's output after each build)
& $FLUTTER build apk --debug -t lib\main.dart `
  --android-project-arg=gymmaneTestVariant=phone `
  --dart-define=GYMMANE_TEST_BUILD=true `
  --dart-define=GYMMANE_WEAR_DIAGNOSTICS=true
Copy-Item build\app\outputs\apk\debug\app-debug.apk `
  build\app\outputs\flutter-apk\GymMane-test-phone.apk
& $FLUTTER build apk --debug -t lib\main_wear_companion.dart `
  --android-project-arg=gymmaneTestVariant=wear `
  --dart-define=GYMMANE_TEST_BUILD=true `
  --dart-define=GYMMANE_WEAR_DIAGNOSTICS=true
Copy-Item build\app\outputs\apk\debug\app-debug.apk `
  build\app\outputs\flutter-apk\GymMane-test-watch.apk

# Release APK
& $FLUTTER build apk --release

# Inspect the release manifest and APK permissions
Select-String -Path build\app\intermediates\merged_manifests\release\processReleaseManifest\AndroidManifest.xml -Pattern 'INTERNET|BLUETOOTH_SCAN|LOCATION'
$aapt = Get-ChildItem "$env:LOCALAPPDATA\Android\Sdk\build-tools" -Directory | Sort-Object Name -Descending | Select-Object -First 1
& (Join-Path $aapt.FullName 'aapt.exe') dump permissions build\app\outputs\flutter-apk\app-release.apk
```

## 11. Permanent privacy and compatibility constraints

These must not be violated by any future change:

1. **No `android.permission.INTERNET`** in the final release APK. Verify the
   *merged* manifest and the APK, not the source manifest.
2. No `ACCESS_NETWORK_STATE`, analytics, telemetry, crash reporting, ads,
   accounts, logins, cloud sync or remote user data.
3. No Wear OS Data Layer API / Play Services relay / Wi-Fi sync. Bluetooth only.
4. No `BLUETOOTH_SCAN`, no location permissions; do not trust the first device
   that connects.
5. The feature stays opt-in and off by default; the app and the existing
   standalone watch mode must work unchanged when off.
6. Keep `Based on GymMane by InlitX` attribution, GPL-3.0 and CC BY-SA 4.0 art
   notices intact.
7. Do not modify existing tests to hide failures; distinguish pre-existing
   failures from new ones.
