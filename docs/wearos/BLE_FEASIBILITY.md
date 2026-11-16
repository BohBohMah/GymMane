# GymMane local phone ↔ watch link — BLE feasibility

Status: **partial transport validation; end-to-end workout sync not verified.**
This document separates what the build and the unit tests prove from what still
needs a physical Android phone and a physical Wear OS watch.

## 1. Short verdict

The chosen transport is technically plausible and uses only standard Android
APIs:

- the phone is a **GATT server + BLE advertiser**;
- the watch is a **GATT client** that connects to a phone the user already
  bonded in system settings;
- **neither side scans**, so `BLUETOOTH_SCAN` and location permissions are not
  needed;
- both directions require an OS-bonded, encrypted, MITM-protected link, and the
  app adds its own PIN/PSK handshake and HMAC-protected session on top.

This is a supported Android pattern. A first physical test on the HONOR Magic8
Lite and Galaxy Watch4 Classic confirmed GATT connection, service discovery and
MTU 517 after reconnect. The watch still did not display the active workout,
so application-level snapshot delivery remains unverified and is currently
failing on that pair. An emulator cannot validate this BLE path.

## 2. What code validation proves

| Claim | Evidence |
| --- | --- |
| Framing, chunking and reassembly are correct | `WireTest` (12 tests) |
| HKDF, HMAC, PBKDF2, constant-time compare and base64 are correct | `SecureSessionTest`, `Base64Test` |
| PIN pairing, resume, wrong PIN, unauthorized device and replay are rejected | `HandshakeTest` (10 tests) |
| Replay, tamper, gap, reflection and session mismatch are rejected | `SecureSessionTest` (11 tests) |
| Commands are idempotent and stale revisions conflict | Dart `wear_command_executor_test` |
| The watch never reports success before the phone ack | Dart `wear_link_client_test` |
| The app compiles with the native GATT server/client/bridge | `:app:compileDebugKotlin` |
| The release APK has no `INTERNET`, no `BLUETOOTH_SCAN`, no location permission | merged release manifest + `aapt dump permissions` |
| The companion entry point compiles | `flutter build bundle -t lib/main_wear_companion.dart` |
| One HONOR/Watch4 BLE reconnect reaches GATT, discovers the service and negotiates MTU 517 | Physical ADB Bluetooth logs, 2026-11-15 |

The physical result proves GATT connection, service discovery and MTU negotiation
on this pair only. It does not prove that secure application state indications
are delivered, that workout snapshots are applied, or that reconnect remains
reliable. The observed snapshot test failed.

## 3. Android API feasibility

| Requirement | Minimum | Notes |
| --- | --- | --- |
| `BluetoothGattServer` + `BluetoothLeAdvertiser` | API 21 in general | The feature is gated to **API 31+** in native `supported` checks to match the permission model and the tested path. |
| `BLUETOOTH_CONNECT` / `BLUETOOTH_ADVERTISE` runtime permissions | API 31 | Requested only when the user enables the phone side or selects a phone on the watch. |
| `BluetoothDevice.createBond` / LE Secure Connections | API 19+ | Bonding is expected to be done in system settings. The app refuses non-bonded peers at the GATT layer and in the watch client. |
| `BluetoothGatt.requestMtu` | API 21 | Phone side cannot request MTU; the watch requests 517 and the phone reports the negotiated value. |
| `notifyCharacteristicChanged(..., confirm = true, ...)` | API 33 | API < 33 uses the deprecated overload. |
| `BluetoothGattCharacteristic.WRITE_TYPE_DEFAULT` | API 18 | Write-with-response, one chunk at a time. |

The protocol source avoids `java.util.Base64` (API 26+) with a small local
base64 implementation, so the compiled code has no hidden API-level trap.

## 4. Throughput and latency estimate

The snapshot is a compact JSON document. A realistic session (6 exercises × 4
sets plus rest and summary fields) is roughly 3–6 KB, and every frame is split
into MTU − 3 byte chunks:

- negotiated MTU 517 → ~6–12 chunks per snapshot, usually under a second on a
  normal connection interval;
- MTU stuck at 23 → ~150–300 chunks, with one confirmation per indication.
  It still works, but the first snapshot and every post-command refresh can take
  several seconds. This is a **real risk on OEMs that reject MTU negotiation or
  on very busy links** and must be measured on hardware.

Commands are tiny and are acknowledged with a matching small ack, so they are
not affected by snapshot size.

## 5. Known limitations and risks

1. **No foreground service.** The link lives only while the phone app process is
   alive. That is acceptable while a workout is on screen, but Android may kill
   the process in the background; the watch then shows offline and reconnects
   when the app returns.
2. **Bonding is a prerequisite.** If the phone and watch are not bonded in
   system settings, the link cannot start. The UI explains this but cannot bond
   the devices silently without `createBond`/system UI.
3. **OEM variability.** Some phones restrict BLE advertising or GATT server
   operation when the screen is off or the app is backgrounded. This must be
   tested on the actual target devices.
4. **PSK storage.** The per-watch PSK is stored in app-private
   `SharedPreferences`, protected by Android app sandboxing but not by a
   hardware-backed keystore wrapper. Moving it to `EncryptedSharedPreferences`
   or a Keystore-wrapped key is a possible hardening step, not a current claim.
5. **MTU fallback.** Correctness is maintained at MTU 23, but latency may be
   poor. This is covered in §4.
6. **No iOS support.** The feature is Android/Wear OS only.
7. **No emulator proof.** The Android emulator does not emulate a real BLE
   peripheral/central pair, so it cannot validate this feature.
8. **Rest timer is wall-clock based.** A large clock difference between phone and
   watch changes the displayed countdown. The phone remains authoritative.

## 6. Real-hardware test procedure

This procedure is the missing validation. Record the result for every step.

### 6.1 Prerequisites

- One Android phone, API 31 or newer, with BLE.
- One Wear OS watch, Android API 31 or newer, with BLE.
- Both devices paired (bonded) in system Bluetooth settings.
- Use the isolated test APKs and the Windows/ADB walkthrough in
  [`REAL_DEVICE_TEST.md`](REAL_DEVICE_TEST.md). Do not use the production
  `app-release.apk` for this test.
- Phone test ID: `com.gymmane.test.phone`; watch test ID:
  `com.gymmane.test.wear`. They install alongside production
  `com.gymmane.app`.
- Bluetooth on, Wi-Fi and mobile data can be off for the privacy test.

### 6.2 Pairing

1. Install and open GymMane Test Phone on the phone.
2. Settings → **Smartwatch link** → enable.
3. Tap **PAIR A WATCH**; a six-digit code and a two-minute countdown appear.
4. On the watch: Settings → **Phone link** → **CONNECT PHONE**; grant the
   Bluetooth permission; pick the bonded phone.
5. Enter the code on the watch.
6. Expected: the phone shows “Connected to …”; the watch leaves the PIN page and
   shows either the live workout or “No workout running on the phone”.

Record: pairing time, any system pairing dialog, any error code shown.

### 6.3 Snapshot and commands

1. Start a workout on the phone.
2. Expected: the watch shows the workout name, exercise, set, reps and weight.
3. Complete a set on the watch.
4. Expected: the phone shows the set done, and only then the watch flashes
   “Saved on phone”.
5. Change reps and weight on the watch; verify the phone updates.
6. Set an RPE, tap pause/resume, next/previous exercise, skip rest, −15 s and
   +15 s.
7. Expected: every control is reflected on the phone; the rest countdown matches.

### 6.4 Duplicates, conflicts and reconnects

1. Tap complete twice quickly on the watch.
   Expected: one set completion, no duplicate log entry.
2. Change the same set on the phone, then immediately use a stale watch screen.
   Expected: the watch reports “Not saved on phone”, requests a fresh state and
   shows the phone value.
3. Walk out of range, then return.
   Expected: the watch reconnects with backoff and resyncs; no stale set is shown
   as saved.
4. Close and reopen the phone app with the link enabled.
   Expected: the phone re-advertises, the watch reconnects, or the watch can
   reconnect from **CONNECT PHONE**.
5. Restart one device without re-pairing.
   Expected: resume works from the stored PSK; if the watch PSK was forgotten,
   pair again with a new code.

### 6.5 Security checks

1. Enter a wrong six-digit code.
   Expected: rejection; no session; the watch shows an error and does not show
   the workout.
2. Try to connect from a different/non-bonded device.
   Expected: the phone rejects the connection at the GATT layer and logs
   `not_bonded`; no handshake data is accepted.
3. Replay an old secured frame (with a test harness).
   Expected: rejected by the sequence/MAC check.
4. Verify the watch cannot see data before the phone confirms a command.
   Expected: “Saved on phone” only after the ack.

### 6.6 Privacy checks

1. Inspect both test APKs (or installed packages
   `com.gymmane.test.phone` and `com.gymmane.test.wear`). Neither may have
   `android.permission.INTERNET`, `BLUETOOTH_SCAN` or location permissions.
2. The phone APK requires `BLUETOOTH_ADVERTISE` and `BLUETOOTH_CONNECT`; the
   watch APK requires only `BLUETOOTH_CONNECT` (plus `VIBRATE`).
3. Turn off Wi-Fi and mobile data (or use airplane mode with Bluetooth on).
   Expected: pairing, snapshots and commands still work.
4. Inspect logcat for HTTP/WebSocket/Data Layer calls.
   Expected: none. `gymmane/wearlink` MethodChannel and BLE/GATT logs only.

### 6.7 Device matrix

Run at least:

| Phone | Watch | Result |
| --- | --- | --- |
| HONOR Magic8 Lite | Samsung Galaxy Watch4 Classic 46 mm / Wear OS 6.0 | GATT reconnect + service discovery + MTU 517 observed; workout snapshot not displayed; investigating |
| Pixel (stock Android 12+) | Pixel Watch / Galaxy Watch | pending |
| Samsung (One UI) | Galaxy Watch | pending |
| Xiaomi/Redmi | any Wear OS watch | pending |

## 7. Pass/fail criteria

The feature is **hardware-verified** only when all of the following hold on at
least two real pairs:

- pairing succeeds with the correct code and fails with a wrong one;
- the watch mirrors a live workout and every command is confirmed by the phone;
- duplicates are idempotent and stale commands resync;
- reconnect after range loss and after app restart works;
- the release APK works with Wi-Fi/mobile data disabled and has no `INTERNET`
  permission;
- no crash or ANR in logcat during a 15-minute session.

The installable test APKs have been built and statically inspected. A first
physical transport smoke test is recorded above, but end-to-end workout sync
failed. Follow `REAL_DEVICE_TEST.md`; do not call the feature end-to-end
hardware-verified until the full criteria above pass.

## 8. How to run the automated evidence

```powershell
$env:JAVA_HOME='C:\Users\Claudio\.jdks\temurin-21.0.12.1'
$env:GRADLE_OPTS='-Dorg.gradle.java.home=C:\Users\Claudio\.jdks\temurin-21.0.12.1'
$FLUTTER='C:\Users\Claudio\AppData\Local\Temp\opencode\flutter-3.41\bin\flutter.bat'

.\android\gradlew.bat -p packages\wear_protocol test --console=plain
& $FLUTTER analyze
& $FLUTTER test test\wear\
& $FLUTTER build apk --release
Select-String -Path build\app\intermediates\merged_manifests\release\processReleaseManifest\AndroidManifest.xml -Pattern 'INTERNET|BLUETOOTH_SCAN|LOCATION'
```
