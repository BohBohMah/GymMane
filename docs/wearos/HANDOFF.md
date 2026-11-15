# GymMane Wear OS companion — handoff

## 1. Session date and state

- Date: 2026-11-15.
- Branch: `feature/wear-os-offline`.
- The implementation is **code-complete for the agreed scope** and
  **hardware-unverified**. All automated checks that can run in this
  environment were run; real BLE behaviour was not, because no physical phone +
  Wear OS watch pair was available and an emulator cannot validate it.
- Nothing was pushed. Commits are small and local only.

## 2. Commits in this feature

The work is split into small local commits on `feature/wear-os-offline`; see
`git log --oneline` for the exact hashes. The intended grouping is:

1. shared Kotlin protocol package and its tests;
2. Dart link layer (models, executor, snapshot, phone coordinator) and tests;
3. Android native transport (GATT server/client, bridge, manifest, permissions);
4. watch companion UI, phone settings UI, entry point and localisation;
5. documentation (`ARCHITECTURE.md`, `IMPLEMENTATION_STATUS.md`,
   `BLE_FEASIBILITY.md`, this file).

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

## 7. Tests and builds actually run

| What | Command | Result |
| --- | --- | --- |
| Protocol unit tests | `.\android\gradlew.bat -p packages\wear_protocol test` | **BUILD SUCCESSFUL**, 36 tests, 0 failures |
| Dart Wear tests | `& $FLUTTER test test\wear\` | **28 tests pass** |
| Static analysis | `& $FLUTTER analyze` | **No issues found!** |
| Full Flutter suite | `& $FLUTTER test` | **1169 pass / 3 skip / 1 failure** |
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

Run the real-device procedure in `docs/wearos/BLE_FEASIBILITY.md` §6 on at least
two phone/watch pairs, starting with:

1. bond the phone and watch in system settings;
2. enable Settings → **Smartwatch link** on the phone and tap **PAIR A WATCH**;
3. open Settings → **Phone link** on the watch, select the bonded phone and
   enter the code;
4. start a workout, complete a set from the watch, and verify “Saved on phone”
   appears only after the phone shows the set done;
5. record pairing time, MTU, reconnect behaviour, duplicate/stale handling and
   any logcat errors;
6. repeat with Wi-Fi and mobile data off, then inspect the installed package for
   `INTERNET`/`BLUETOOTH_SCAN`/location permissions.

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
