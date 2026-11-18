# GymMane Wear OS companion — implementation status

> Offline-first workout continuity requested 2026-11-17 is implemented in the
> application code, including a confirmed watch-side finish/discard.
> The watch durably saves the full active workout and ordered
> local operations, remains usable without the phone, and automatically rebases
> and replays changes after reconnect. The phone persists mutations with their
> deduplication records before ACK. Both devices keep an active-workout
> foreground service. A phone with no workout stops the watch even if the watch
> still had unsynced edits; an interrupted link is reconciled on reconnect.
> Automated tests cover persistence, disconnect, reconnect,
> conflict refresh, replay and both stop paths; physical 20-minute validation is
> still required before release.

> Status as of 2026-11-15, including isolated real-device test APK preparation.
> See `ARCHITECTURE.md` for the design, `BLE_FEASIBILITY.md` for transport
> feasibility, `REAL_DEVICE_TEST.md` for Windows/ADB instructions, and
> `HANDOFF.md` for a resumable work log.

## Legend

- **Implemented** — code exists and is complete for the current scope.
- **Compiles** — verified by a compiler/build, not by runtime.
- **Unit-tested** — automated tests exist and pass.
- **Hardware-verified** — exercised on real phone + watch hardware.
- **Not started** — planned, no code yet.

**End-to-end workout synchronization is not hardware-verified.** A first test on
the HONOR Magic8 Lite and Galaxy Watch4 Classic confirmed GATT reconnect, service
discovery and MTU 517, but the watch continued to report no active workout.
Emulators cannot validate this BLE peripheral/client path.

## Summary

| Area | State |
| --- | --- |
| Architecture decision (Flutter companion vs native Wear app) | Implemented, documented |
| Shared Kotlin protocol (`packages/wear_protocol`) | Implemented, compiles, **unit-tested (36 tests)** |
| Dart remote-workout models | Implemented, compiles, unit-tested |
| Dart command executor + idempotency ledger | Implemented, compiles, **unit-tested (23 tests in the file)** |
| Dart snapshot builder | Implemented, compiles, unit-tested |
| Dart phone coordinator (`WearLinkServer`) | Implemented, compiles, serialized state pushes |
| Kotlin preferences / identity storage (`WearPrefs`) | Implemented, compiles |
| Kotlin GATT server (`WearGattServer`) | Implemented, compiles, **not hardware-verified** |
| Kotlin GATT client (`WearGattClient`) | Implemented, compiles, **not hardware-verified** |
| Kotlin MethodChannel bridge (`WearLinkBridge`) | Implemented, compiles |
| `MainActivity` bridge registration + permission forwarding | Implemented, compiles |
| Android manifest Bluetooth permissions / `INTERNET` removal | Implemented, verified in merged release manifest |
| Watch companion Dart client (`WearLinkClient`) | Implemented, compiles, unit-tested (including offline finish/discard) |
| Watch companion UI + `lib/main_wear_companion.dart` | Implemented, compiles |
| Settings UI (`wear` category, pairing code, status) | Implemented, compiles |
| ARB localisation for new strings (EN/IT) | Implemented; other locales fall back to English and are tracked in `test/pending_translation_keys.txt` |
| Dart tests for the new modules | Implemented, **72 Wear tests pass** |
| Isolated phone test APK | **Built and inspected** — `com.gymmane.test.phone`, API 24 minimum (BLE link requires API 31+) |
| Isolated Wear test APK | **Built and inspected** — `com.gymmane.test.wear`, API 31 minimum, required Wear + BLE features |
| Test APK permissions/signatures | **Verified** — no `INTERNET`, scan or location; role-specific Bluetooth permissions; same local debug certificate |
| Production release APK restoration | **Verified** — default build remains `com.gymmane.app` |
| Physical HONOR ↔ Watch4 transport smoke test | GATT reconnect, service discovery and MTU 517 observed; end-to-end workout state not delivered/displayed |
| Real BLE end-to-end validation | **Failing / under diagnosis** — no active snapshot displayed on watch |

## What works today

- The existing app is functionally untouched. The feature is opt-in and off by
  default (`SettingsState.wearLink == false`).
- With the setting off, nothing native starts: `WearLinkServer.attach()` only
  registers a channel handler and a listener, and the BLE server never runs.
- With the setting on, the phone advertises a GATT service and the watch can
  connect to an already bonded phone, pair with a six-digit code and mirror the
  live workout.
- The phone remains the final history store. The watch durably queues one
  operation at a time and continues locally while offline. A conflict triggers
  a fresh snapshot, rebase and automatic retry.
- Revisions are phone-owned. Rest ticks and clock fields do not bump `rev`;
  rest is sent as a wall-clock `endsAt`. Duplicate command ids are served from a
  ledger persisted with the live workout.
- The snapshot also exposes `restDefaults` and an effective `restAfterSec` per
  set, so the watch starts the correct rest (set override, mini, change,
  routine/exercise/default) while offline. A replayed completion carries
  `restRemainingSec`; the phone prefers it over the absolute deadline and
  continues the rest instead of restarting it.
- When the phone ends or discards the workout, its idle snapshot stops the watch
  even if the watch still holds unsynced edits; a stale same-boot idle frame is
  ignored. This is what makes a phone-side interruption authoritative.
- The watch offers **finish and discard** with a confirmation page. The intent
  is committed to the journal behind every pending edit and sent FIFO, so the
  phone receives all weights, reps, sets and exercises before the discard. The
  workout is only removed after a positive ACK, a `no_session` ACK or an idle
  phone snapshot; otherwise it stays durable and retries on reconnect, even
  across a full watch app restart. Further edits are refused with `finishing`
  until the discard completes.
- The enabled preference survives app restarts. Closing the watch app stops the
  radio through `shutdown()` without forgetting the link, while an explicit
  Disconnect clears it; the phone restores its server from `fit.wearLink` on
  launch.
- The shared protocol is a standalone JVM Gradle project compiled into the app
  module. It covers framing/chunking, HKDF/PBKDF2/HMAC, PIN pairing and resume,
  wrong PIN, unauthorized devices, replay, tamper, gap, reflection, session
  mismatch, and strict per-direction sequence numbers.
- Both roles require an OS-bonded, encrypted, MITM-protected peer. A non-bonded
  device is rejected by the phone before the handshake and by the watch client
  before connecting.
- The phone does not trust the first device: the watch must prove knowledge of
  the PIN (first pairing) or the stored 256-bit PSK (resume), and the user picks
  the phone explicitly from the bonded-device list.

## Security and privacy properties

- No `android.permission.INTERNET` in the merged **release** manifest and in the
  APK (`aapt dump permissions`). The debug manifest still contains the
  Flutter-tooling `INTERNET` permission; that is expected and does not affect the
  release artifact.
- No `BLUETOOTH_SCAN`, no location permissions. The phone only advertises and the
  watch only connects to an explicit bonded address.
- No Wear OS Data Layer API, Play Services relay, HTTP, WebSocket or IP sync.
- App-level crypto uses standard primitives only: OS LE Secure Connections +
  bonding, six-digit PIN, PBKDF2-HMAC-SHA256 (120k), random 256-bit PSK,
  HMAC-SHA256 tags, HKDF-SHA256 session keys. No custom cipher.
- Known limitation: the PSK is stored in app-private `SharedPreferences`, not in a
  Keystore-wrapped store. See `BLE_FEASIBILITY.md` §5.

## Test and build evidence

| Command | Result |
| --- | --- |
| `android\gradlew.bat -p packages/wear_protocol test` | **BUILD SUCCESSFUL**, 36 tests, 0 failures |
| `flutter test test/wear/` | **72 tests pass** |
| `flutter analyze` (Flutter 3.41.9) | **No issues found!** |
| `flutter test` (full suite) | **1171 pass / 3 skip / 1 failure** — the only failure is the pre-existing `test/i18n_test.dart` missing-ARB-keys case (52 keys unrelated to Wear, present in `HEAD`) |
| `flutter build bundle -t lib/main_wear_companion.dart` | exit 0 (companion entry point compiles) |
| `:app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| `flutter build apk --release` | **SUCCESS** — `build\app\outputs\flutter-apk\app-release.apk`, production ID `com.gymmane.app` |
| merged release manifest | 0 `INTERNET`, 0 `BLUETOOTH_SCAN`, 0 location; `BLUETOOTH_ADVERTISE` + `BLUETOOTH_CONNECT` + legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` (maxSdk 30) |
| Phone test APK | **SUCCESS**, `build\app\outputs\flutter-apk\GymMane-test-phone.apk`; application ID `com.gymmane.test.phone`, min SDK 24, target 36; required advertise + connect permissions |
| Wear test APK | **SUCCESS**, `build\app\outputs\flutter-apk\GymMane-test-watch.apk`; application ID `com.gymmane.test.wear`, min SDK 31, target 36; required Wear + BLE features, connect + vibrate only |
| Offline-first delivery build (2026-11-17) | **SUCCESS** after 62 Wear tests passed, Flutter 3.41.9 / Gradle 8.14 / Temurin 21, release test variants: phone 114,473,829 B SHA-256 `8E584E27C37E0DEEBF10314F0D48BCD9C4D9F6C94707CE9D313C3B5D825F8307`, watch 68,639,421 B SHA-256 `6864B746FA1AFCD1E63A5B98EAA75149B5813601B3A6CDC23E8B6489218F9A40`. Includes offline per-exercise rest and mid-rest reconnect. Zero `INTERNET`/`BLUETOOTH_SCAN`/location permissions; debug cert `b731e5b0…`; `WearWorkoutService` (`connectedDevice`) in both; watch non-debuggable. Not installed. Details and exact commands in `HANDOFF.md`. |
| Test APK signing | `apksigner verify` succeeded; both use local debug cert SHA-256 `b731e5b0dfeee1046596c49dafdf0496300817dab65ad3db7acb225d8c259e52` |
| APK package/permission inspection | Android `apkanalyzer`/`aapt` inspection: neither test APK has `INTERNET`, `BLUETOOTH_SCAN`, or location permissions; authorities and shortcuts resolve to test IDs |
| Preparation-session devices / installs | No ADB devices were attached during APK preparation; no installation was performed by the build environment |
| First owner-run physical test | Both test apps were installed by the owner on API 36 HONOR and API 36 SM-R890. The watch remained on “No workout running on the phone” with an active phone session. ADB showed successful GATT connection/service discovery and MTU 517 after reopening the watch app. |

The pre-existing i18n failure is unchanged in kind: the 40 new `wearLink*` keys
are listed in `test/pending_translation_keys.txt`, the project's existing
mechanism for keys not yet translated into all 20 non-EN/IT languages. EN and IT
are complete. No existing test was weakened or deleted.

## What is not done / not proven

- **Partial BLE hardware validation only.** GATT reconnect, service discovery
  and MTU 517 were observed on one pair. Snapshot delivery/update is currently
  failing or not being applied; it remains unverified pending diagnosis.
- The foreground service and 20-minute offline behavior still require physical
  validation against OEM power management on the target phone and watch.
- The production app still uses its original application ID. Real-device tests
  use separate test APK IDs so they can coexist with production and each other.
  Test builds are debug-signed and are not for distribution.
- HONOR Magic8 Lite advertiser/GATT capability, pairing-code handshake, secure
  indications, snapshot delivery, workout
  commands and background behavior are not fully verified. See
  `REAL_DEVICE_TEST.md`.
- **OEM/MTU behaviour unmeasured.** MTU 517 is requested; a fallback to 23 works
  but may be slow (see `BLE_FEASIBILITY.md` §4).
- **No iOS support.**
