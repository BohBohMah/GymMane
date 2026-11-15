# GymMane Wear OS companion — implementation status

> Current state after the completed implementation session.
> See `ARCHITECTURE.md` for the design, `BLE_FEASIBILITY.md` for the transport
> feasibility and the real-device procedure, and `HANDOFF.md` for a resumable log.

## Legend

- **Implemented** — code exists and is complete for the current scope.
- **Compiles** — verified by a compiler/build, not by runtime.
- **Unit-tested** — automated tests exist and pass.
- **Hardware-verified** — exercised on real phone + watch hardware.
- **Not started** — planned, no code yet.

**Nothing in this feature has been verified on real BLE hardware.** Unit tests and
builds validate code only. No emulator was available, and an emulator cannot
validate real BLE peripheral communication regardless.

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
| Watch companion Dart client (`WearLinkClient`) | Implemented, compiles, **unit-tested (5 tests)** |
| Watch companion UI + `lib/main_wear_companion.dart` | Implemented, compiles |
| Settings UI (`wear` category, pairing code, status) | Implemented, compiles |
| ARB localisation for new strings (EN/IT) | Implemented; other locales fall back to English and are tracked in `test/pending_translation_keys.txt` |
| Dart tests for the new modules | Implemented, **28 tests pass** |
| Release APK build + merged manifest inspection | **Verified** — no `INTERNET`, no scan/location |
| Real BLE end-to-end validation | **Not possible in this environment** |

## What works today

- The existing app is functionally untouched. The feature is opt-in and off by
  default (`SettingsState.wearLink == false`).
- With the setting off, nothing native starts: `WearLinkServer.attach()` only
  registers a channel handler and a listener, and the BLE server never runs.
- With the setting on, the phone advertises a GATT service and the watch can
  connect to an already bonded phone, pair with a six-digit code and mirror the
  live workout.
- The phone remains the only authoritative store. The watch queues one command
  at a time, waits for the phone ack and only then reports success. A conflict
  triggers a fresh snapshot request.
- Revisions are phone-owned. Rest ticks and clock fields do not bump `rev`;
  rest is sent as a wall-clock `endsAt`. Duplicate command ids are served from a
  bounded ledger.
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
| `flutter test test/wear/` | **28 tests pass** |
| `flutter analyze` (Flutter 3.41.9) | **No issues found!** |
| `flutter test` (full suite) | **1171 pass / 3 skip / 1 failure** — the only failure is the pre-existing `test/i18n_test.dart` missing-ARB-keys case (52 keys unrelated to Wear, present in `HEAD`) |
| `flutter build bundle -t lib/main_wear_companion.dart` | exit 0 (companion entry point compiles) |
| `:app:compileDebugKotlin` | **BUILD SUCCESSFUL** |
| `flutter build apk --release` | **SUCCESS** — `build\app\outputs\flutter-apk\app-release.apk`, 114,563,030 bytes |
| merged release manifest | 0 `INTERNET`, 0 `BLUETOOTH_SCAN`, 0 location; `BLUETOOTH_ADVERTISE` + `BLUETOOTH_CONNECT` + legacy `BLUETOOTH`/`BLUETOOTH_ADMIN` (maxSdk 30) |

The pre-existing i18n failure is unchanged in kind: the 40 new `wearLink*` keys
are listed in `test/pending_translation_keys.txt`, the project's existing
mechanism for keys not yet translated into all 20 non-EN/IT languages. EN and IT
are complete. No existing test was weakened or deleted.

## What is not done / not proven

- **No real BLE hardware validation.** The complete procedure is in
  `BLE_FEASIBILITY.md` §6. Until it is run, treat BLE behaviour as unverified.
- **No foreground service.** The link lives while the phone app process lives;
  the watch shows offline and reconnects when the phone app returns.
- **No separate companion APK/applicationId.** The companion is a second Flutter
  entry point in the same app, so one applicationId is correct. The release APK
  is the same artifact for phone and watch.
- **OEM/MTU behaviour unmeasured.** MTU 517 is requested; a fallback to 23 works
  but may be slow (see `BLE_FEASIBILITY.md` §4).
- **No iOS support.**
