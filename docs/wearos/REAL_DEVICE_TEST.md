# GymMane Wear — real-device test guide (Windows)

> The current release builds support offline workout edits and a persistent
> nutrition queue. Update both test apps, sync once, then follow the offline
> checks below. Use `HANDOFF.md` for earlier diagnostic builds and trial results.

This guide installs **isolated test APKs** on an HONOR Magic8 Lite and a
Samsung Galaxy Watch4 Classic 46 mm. The test apps do not replace the official
GymMane app and do not share its private data.

The phone is an HONOR Magic8 Lite and the watch a Galaxy Watch4 Classic
SM-R890. ADB reported API 36 on both in the earlier diagnostic run. The
release test builds are non-debuggable and leave diagnostic logging off by
default. The device-specific checks below are still needed for each new build.

## 1. Test APKs and compatibility

| Device | APK | Application ID | APK minimum | BLE integration minimum |
| --- | --- | --- | --- | --- |
| HONOR phone | `build\app\outputs\flutter-apk\GymMane-test-phone.apk` | `com.gymmane.test.phone` | Android 7.0 / API 24 | Android 12 / API 31 |
| Galaxy Watch4 Classic | `build\app\outputs\flutter-apk\GymMane-test-watch.apk` | `com.gymmane.test.wear` | Android 12 / API 31, Wear hardware required | Android 12 / API 31 |

The phone app's ordinary GymMane screens support API 24+, but this companion
link intentionally reports unsupported below API 31. Check the installed OS
version on both devices rather than relying on the model name:

```powershell
adb -s <PHONE_SERIAL> shell getprop ro.build.version.sdk
adb -s <WATCH_IP_AND_DEBUG_PORT> shell getprop ro.build.version.sdk
```

Both results must be `31` or higher for this test. ADB reported API 36 on both
devices during the 2026-11-16 diagnostic run.

The watch APK is a real installable APK, not a Flutter asset bundle. It is built
from `lib/main_wear_companion.dart`, has a required Wear OS hardware feature and
BLE feature, and has a test-only minimum API of 31.

## 2. Safety and privacy

- Install **only** the two files whose names contain `test-`.
- Use the two named test APKs. The intermediate `app-release.apk` may be
  overwritten by another build variant.
- The phone and watch test IDs are distinct from each other and from the
  official app. Android gives each package a separate private data directory.
- Test APKs are signed with the same local Android debug certificate. This
  permits updating these test packages with `adb install -r`; it is not the
  upstream release signing key.
- The test phone build disables its production-package home-widget bridge,
  removes widget/Tile/complication registrations, and has a test-only app-link
  scheme. Plugin provider authorities are based on the test application ID.
- No `INTERNET`, Bluetooth scan or location permission is present in either
  test APK. The phone requests advertise + connect; the watch requests connect
  only. The watch also retains `VIBRATE` for its existing haptics.
- The link uses local Bluetooth GATT only. There is no Wear OS Data Layer relay,
  cloud sync, account, telemetry or HTTP/WebSocket transport.
- Keep the phone app open and in the foreground during the initial test. Both
  apps now declare an active-workout foreground service, but OEM process and
  battery policies can still interrupt BLE; verify this physically rather than
  treating it as guaranteed.
- The watch and phone must already be bonded in Android/Samsung system Bluetooth
  settings. The watch client refuses a non-bonded phone.
- Use only fictional workout values in the test app. Do not import an official
  GymMane backup into it.

## 3. Check versions and connect the HONOR phone to ADB

1. On the HONOR, open **Settings → About phone** and note Android/MagicOS
   version. It must be Android 12 / API 31 or newer for the link.
2. Enable Developer options by tapping **Build number** seven times in About
   phone. Depending on MagicOS version, the item may be under **Version
   information**.
3. Open **Settings → System & updates → Developer options** and enable **USB
   debugging**.
4. Connect the phone to the Windows PC with a data-capable USB cable. Choose
   file transfer if prompted, then accept the **Allow USB debugging?** prompt
   on the phone.
5. Open PowerShell and define ADB:

   ```powershell
   $adb = "$env:LOCALAPPDATA\Android\Sdk\platform-tools\adb.exe"
   Test-Path $adb
   & $adb devices -l
   ```

   `Test-Path` should print `True`. The HONOR should appear with status
   `device`, not `unauthorized`. Record its serial as `$phone`.

6. Read its Android API level:

   ```powershell
   $phone = '<HONOR_SERIAL_FROM_adb_devices>'
   & $adb -s $phone shell getprop ro.build.version.sdk
   ```

## 4. Enable wireless ADB on the Galaxy Watch4 Classic

Wireless debugging uses Wi-Fi for the **PC-to-watch ADB session only**. It is
not used by the GymMane phone-watch link.

1. On the watch, open **Settings → About watch → Software information**. Tap
   **Software version** repeatedly (about seven times) until Developer options
   are enabled. Samsung menu wording can vary slightly with One UI Watch.
2. Return to **Settings → Developer options** and enable **Wireless debugging**.
   Accept any confirmation prompt.
3. Ensure the watch and PC are on the same trusted Wi-Fi network. In Wireless
   debugging, choose **Pair new device**. Keep that screen open and note the
   watch IP address, pairing port, pairing code and the separate connection
   port shown on the main Wireless debugging screen.
4. In PowerShell, use the pairing port first:

   ```powershell
   $watchIp = '<WATCH_IP>'
   & $adb pair "${watchIp}:<PAIRING_PORT>"
   ```

   Enter the pairing code when ADB prompts for it.

5. Connect using the connection port (which can differ from the pairing port):

   ```powershell
   & $adb connect "${watchIp}:<WIRELESS_DEBUGGING_PORT>"
   & $adb devices -l
   ```

   Set `$watch` to the exact `IP:PORT` serial shown with status `device`:

   ```powershell
   $watch = '<WATCH_IP_AND_DEBUG_PORT>'
   & $adb -s $watch shell getprop ro.build.version.sdk
   ```

   The watch API must be 31 or higher. Wireless debugging may disconnect if the
   watch changes Wi-Fi networks or sleeps; reconnect with the current port.

## 5. Confirm OS-level Bluetooth bonding

The Galaxy Watch4 and HONOR must first be paired in system settings, normally
through Samsung's Galaxy Wearable setup. Confirm that Bluetooth is on and each
device shows the other as paired/bonded in its Bluetooth settings. This is
separate from the GymMane six-digit authorization code.

Do not proceed with the companion pairing if the watch's GymMane device list
does not include the HONOR. The implementation deliberately does not scan for
unpaired devices.

## 6. Install the two test APKs

From the repository root in PowerShell:

```powershell
$repo = (Get-Location).Path
$phoneApk = Join-Path $repo 'build\app\outputs\flutter-apk\GymMane-test-phone.apk'
$watchApk = Join-Path $repo 'build\app\outputs\flutter-apk\GymMane-test-watch.apk'
Test-Path $phoneApk
Test-Path $watchApk
```

Both `Test-Path` results must be `True`. Check installed package names before
installing:

```powershell
& $adb -s $phone shell pm list packages | Select-String 'gymmane'
& $adb -s $watch shell pm list packages | Select-String 'gymmane'
```

Install without uninstalling or clearing anything:

```powershell
& $adb -s $phone install -r $phoneApk
& $adb -s $watch install -r $watchApk
```

Expected result for each is `Success`. The official app is
`com.gymmane.app`; the test packages are `com.gymmane.test.phone` and
`com.gymmane.test.wear`. **Do not run `adb uninstall`, `pm clear`, or any data
reset command.** If installation reports a signature mismatch for an already
installed test package, stop and report it rather than uninstalling it.

Verify packages and version:

```powershell
& $adb -s $phone shell pm path com.gymmane.test.phone
& $adb -s $watch shell pm path com.gymmane.test.wear
& $adb -s $phone shell dumpsys package com.gymmane.test.phone | Select-String 'versionName|versionCode'
& $adb -s $watch shell dumpsys package com.gymmane.test.wear | Select-String 'versionName|versionCode'
```

## 7. Launch both apps and grant Bluetooth access

```powershell
& $adb -s $phone shell monkey -p com.gymmane.test.phone 1
& $adb -s $watch shell monkey -p com.gymmane.test.wear 1
```

The phone opens the normal GymMane home screen. The watch test app opens directly
to the existing **Phone link** companion screen.

When prompted, allow **Nearby devices** on both devices. The phone needs
`BLUETOOTH_CONNECT` and `BLUETOOTH_ADVERTISE`; the watch needs
`BLUETOOTH_CONNECT`. Neither app requests Bluetooth scanning or location.

If the prompt was dismissed, use the OS app permission page:

- HONOR: **Settings → Apps → GymMane Test Phone → Permissions → Nearby devices**
- Watch: **Settings → Apps → GymMane Test Watch → Permissions → Nearby devices**

You can also grant the declared runtime permissions from the corresponding ADB
shell if needed:

```powershell
& $adb -s $phone shell pm grant com.gymmane.test.phone android.permission.BLUETOOTH_CONNECT
& $adb -s $phone shell pm grant com.gymmane.test.phone android.permission.BLUETOOTH_ADVERTISE
& $adb -s $watch shell pm grant com.gymmane.test.wear android.permission.BLUETOOTH_CONNECT
```

## 8. Enable GymMane on the phone and pair the watch

1. Keep GymMane Test Phone open. Tap the bottom **Profile** (person) destination
   to open Settings.
2. Open the **Smartwatch link** category.
3. Tap **Enable smartwatch link**. Accept the Nearby devices prompt if shown.
   The status should say **Waiting for a paired watch**.
4. Tap **PAIR A WATCH**. The phone shows a six-digit code and a two-minute
   expiry. Keep that screen visible; do not share or photograph the code.
5. On the watch, tap **CONNECT PHONE**. The app loads the Android bonded-device
   list. Select the HONOR phone by its displayed Bluetooth name, then enter the
   current six-digit code and tap **CONFIRM**.
6. Expected: the phone status changes to **Connected to …**. With no active
   workout, the watch opens its Home with routines, exercise selection and
   Nutrition when enabled on the phone.

The watch may show other bonded Bluetooth devices in the list. Choose only the
HONOR. If the code expires, tap **PAIR A WATCH** again on the phone and enter
the newly displayed code.

## 9. Create a fictional workout and test synchronization

The separate test package starts with its own app-private storage. Keep the
workout fictional; do not use or import personal GymMane data.

1. On the phone, return to **Home**. Tap the center play / **START WORKOUT**
   control. If the Start workout sheet appears, choose **Pick exercises**.
2. Choose one catalogue strength exercise that has repetitions and weight. Use
   the exercise search/list and select it. Tap the bottom **START 1 EXERCISE**
   (wording/count may reflect your selection).
3. Keep the phone app open on its live session. Confirm the watch displays the
   exercise, current set, repetitions and weight.
4. On the watch, use the `−` / `+` controls beside the repetitions and weight to
   change them to clearly fictional values (for example 8 reps and 20 kg). The
   values must update on the watch immediately, without waiting for the phone.
5. Confirm the phone's live session shows the changed reps and weight while the
   link is up.
6. On the watch tap **COMPLETE SET** once. Expected: the set completes on the
   watch immediately and the phone shows it completed once the edit is applied.
   The watch may briefly show a synchronization indicator; local success no
   longer depends on a round trip.

Do not finish or save a real workout from the production GymMane app as part of
this test.

## 10. Test the rest timer and duplicate protection

### 10a. Rest while connected

1. After completing the set, confirm the phone starts its normal rest timer and
   the watch shows the REST countdown.
2. Observe both countdowns for at least 10 seconds.
3. On the watch, test **−15**, **+15** and **SKIP** one at a time. Confirm the
   phone's rest timer changes or stops accordingly.
4. For a duplicate-tap check, tap **COMPLETE SET** twice quickly on a pending
   set. Expected result is one completed set, never two, on both devices. This
   checks the user-facing behavior; it does not inject a synthetic transport
   retry with the same operation ID.

### 10b. Rest while disconnected, with per-exercise durations

Use a workout where two exercises have different rest values (one through the
per-exercise setting or a per-set override, and a rest-pause/cluster set if
available).

1. Stop the phone app or walk out of Bluetooth range.
2. Complete the last set of exercise A. Expected: the watch starts the rest for
   that set immediately, with its own duration (not a fixed default) and the
   REST countdown keeps running while disconnected.
3. Let it finish and complete the next exercise's set. Expected: the watch uses
   that exercise's duration. If the next set is a rest-pause/cluster set, the
   mini rest must be used instead.
4. For change-exercise rest, complete the last pending set of an exercise and
   confirm the watch uses the change-exercise duration, not the normal one.

### 10c. Reconnect halfway through a rest

1. Reconnect in the middle of a 2:00 rest, about 1:30 after completing the set.
   Ensure the phone app is running before the link is restored.
2. Expected on the phone: the rest shows about **0:30** left and continues
   counting down from there; it must not restart at 2:00 or fire a second alarm.
3. Repeat with only a few seconds left and with the rest already expired during
   the separation. Expected: the phone either continues briefly or leaves the
   rest ended, never starts a fresh full rest.
4. Record the watch/phone clock times if the remaining time is off by more than
   a second or two; the watch sends remaining seconds precisely to tolerate
   clock skew, so a large error is a bug.

## 11. Disconnect and reconnect

1. On the watch tap **DISCONNECT**. This stops the watch client but does not
   erase its stored authorization key.
2. Tap **CONNECT PHONE**, select the bonded HONOR again, and wait for the
   connected status. A successful resume should not require a new PIN.
3. Verify the current workout snapshot arrives again and that the phone still
   shows the one completed set.
4. Leave the phone GymMane app open in the foreground for this initial test.
   Both apps now run an active-workout foreground service, but OEM background
   restrictions still differ by device; record what happens when the screen is
   off or the app is backgrounded instead of assuming either behavior.

## 11a. Stop the workout from either device

Use fictional values. Do not uninstall or clear the test packages between runs;
the journal must survive app restarts.

### Phone ends the workout while connected

1. Start a workout on the phone, make one or two watch edits, then end or
   discard the workout on the phone (back out of the live session).
2. Expected: within a snapshot the watch returns to Home.
   If the watch had unsynced workout edits, they
   are dropped; the phone is authoritative.

### Phone ends the workout while disconnected

1. Start a workout, then stop the phone app or walk out of range.
2. Complete a few sets and change a weight on the watch.
3. End the workout on the phone while the link is down, then reconnect.
4. Expected: the watch stops on the first authoritative idle snapshot and its
   queued edits do not resurrect the session. A stale idle frame from the same
   phone process must not stop a newer watch workout.

### Watch saves or discards a workout while connected

1. Complete several sets and tap **FINISH SESSION**. Confirm the completed
   sets appear once in the phone's history, even if the routine is incomplete.
2. Start another workout, choose **DISCARD**, and cancel the first confirmation.
   Confirm the workout is unchanged. Repeat and confirm that it leaves no entry
   in the phone's history.

### Watch finishes and discards, disconnected or killed

1. Disconnect the link (or stop the phone app). Make several unsynced edits,
   then confirm **DISCARD** on the watch.
2. Expected: the watch keeps the workout visible in a "waiting" state and
   refuses further edits instead of losing them.
3. Fully close the watch app from recents and reopen it. Expected: the same
   workout and the pending finish are still there.
4. Reconnect. Expected: the phone first receives every pending weight, rep,
   set and exercise change, then the discard; only then does the watch clear.
5. If the phone already had no workout, the watch may also clear on the
   explicit no-workout reply.

## 12. Bluetooth-only / no-network check

Before disabling Bluetooth, sync Nutrition once. Then turn Bluetooth off,
add one glass, mark a supplement, and close and reopen the watch app. Confirm
the pending entries and selection are restored. Tap a taken supplement to
unmark it, or undo the last glass logged on the watch. Restore Bluetooth and
check the phone diary and supplement inventory for duplicates. If Wear OS
terminated the watch app, reopen it to resume syncing.

On the watch face add **GymMane · Workout** and **GymMane · Water**. Check each
tile opens the matching app screen. During a workout, check the ongoing
activity shows the GymMane runner and opens the session when tapped.

Do this after installation, ADB setup and the initial pairing:

1. Turn off Wi-Fi and mobile data on the HONOR using Quick Settings. Keep
   Bluetooth enabled.
2. If desired, turn off watch Wi-Fi too; keep watch Bluetooth enabled. This will
   disconnect wireless ADB, which uses Wi-Fi, but should not affect the
   phone-watch BLE link.
3. Reconnect from the watch if needed and repeat a reps/weight edit and a set
   completion.
4. Expected: local pairing, snapshots, edits and acknowledgements continue to
   work with Wi-Fi/mobile data off.
5. Re-enable Wi-Fi to resume wireless ADB and collect watch logs. Do not use
   airplane mode unless you verify Bluetooth stays enabled.

## 13. Collect useful logs safely

The diagnostic test APKs emit lines tagged `GymManeWearLink` and
`[GymManeWearLink]`. They report only connection stages, snapshot status/revision,
whether a workout exists, exercise count, GATT result codes and command names.
They do not log workout/exercise names, set values, pairing codes, addresses or
snapshot contents. The tracing flag is enabled only for the isolated test
variants and is disabled in the normal production build.

After both updated test APKs are installed and the symptom is reproduced, read
only the tagged lines (this does not clear the device log):

```powershell
$logDir = Join-Path $env:TEMP 'gymmane-wear-test'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$pattern = 'GymManeWearLink'

& $adb -s $phone logcat -d -v time |
    Select-String -Pattern $pattern |
    Set-Content (Join-Path $logDir 'phone-wear-link.log')
& $adb -s $watch logcat -d -v time |
    Select-String -Pattern $pattern |
    Set-Content (Join-Path $logDir 'watch-wear-link.log')
```

Share only those two filtered files or their relevant excerpts. Do not share
unrestricted `logcat`, a full bug report, device serials, Bluetooth addresses,
pairing codes, account names or real workout details.

For a bounded app-process log:

```powershell
$logDir = Join-Path $env:TEMP 'gymmane-wear-test'
New-Item -ItemType Directory -Force -Path $logDir | Out-Null
$phonePid = (& $adb -s $phone shell pidof -s com.gymmane.test.phone).Trim()
$watchPid = (& $adb -s $watch shell pidof -s com.gymmane.test.wear).Trim()
if ($phonePid) {
    & $adb -s $phone logcat -d "--pid=$phonePid" -v time |
        Set-Content (Join-Path $logDir 'phone-app.log')
}
if ($watchPid) {
    & $adb -s $watch logcat -d "--pid=$watchPid" -v time |
        Set-Content (Join-Path $logDir 'watch-app.log')
}
```

Before sharing, review each file locally and redact device names, addresses,
serials, account identifiers and any personal content. Prefer sharing the
on-screen error code and the relevant few redacted lines, not entire system
logs.

Record this minimal report:

```text
Phone model / Android version / API:
Watch model / Wear OS version / Android API:
Phone APK application ID and version:
Watch APK application ID and version:
OS-level Bluetooth bond confirmed on both: yes/no
Nearby devices permission granted on both: yes/no
Pairing result and elapsed time:
Snapshot and set acknowledgement result:
Rest timer while connected:
Offline rest with per-exercise/set duration:
Mid-rest reconnect remaining time (expected ~0:30 of 2:00):
Reconnect result:
Phone-ended workout stops the watch (connected / disconnected):
Watch finish+discard confirmed and queued edits delivered before discard:
Watch discard survives an app restart:
Wi-Fi/mobile-data-off result:
Visible error code (do not include the PIN):
Redacted log file names, if any:
```

## 14. Common failures

| Symptom | Checks |
| --- | --- |
| `INSTALL_FAILED_OLDER_SDK` on watch | Read the watch API with `getprop`; the Wear test APK requires API 31+. Update the watch OS if an update is available. |
| Watch app cannot be installed / incompatible device | Confirm the watch is a Wear OS device, API 31+, and that the watch APK (not phone APK) was installed. Its manifest requires watch hardware and BLE. |
| Watch shows no paired phones | Confirm phone-watch OS Bluetooth bonding, grant Nearby devices on the watch, then tap **REFRESH**. This app intentionally does not scan. |
| `not_bonded` | Re-establish the OS bond through Samsung/Galaxy Wearable or system Bluetooth settings. Do not try an unbonded phone. |
| Phone reports unsupported or enable fails | BLE integration requires API 31+, Bluetooth enabled, and Nearby devices permission. The phone must expose BLE peripheral advertising and a GATT server. |
| Phone waits forever; watch cannot connect | Keep the phone app open/foreground, check the phone still shows pairing mode, verify the code has not expired, and confirm Bluetooth is on. HONOR advertising/GATT support must be measured on the handset; the build cannot prove it. |
| Wrong PIN / pairing times out | Tap **PAIR A WATCH** again and enter the current six-digit code within two minutes. |
| Watch says `Phone not connected` | Check the phone status, bonded phone choice, Bluetooth permissions and that the phone app process is still alive. Reopen the phone app to restart advertising. |
| Link drops when backgrounded or screen is off | Both apps declare an active-workout foreground service, but Android/OEM may still restrict background work. Reconnect and record the behavior instead of changing system settings during the first test. |
| ADB watch disappears after Wi-Fi is disabled | Expected for wireless ADB. The Bluetooth app link can remain active. Re-enable Wi-Fi and reconnect ADB to retrieve logs. |
| `INSTALL_FAILED_UPDATE_INCOMPATIBLE` | The same test package was previously signed by a different key. Stop and report it; do not uninstall or clear app data. |
| `advertise_<number>` or `start_failed` | Record the code and phone model/API. This requires handset/Bluetooth-stack diagnosis; do not infer success from compilation. |

## 15. Hardware checks that remain

The implementation checks API 31+, a Bluetooth adapter and the BLE hardware
feature. On the tested HONOR/SM-R890 pair, GATT reconnect, service discovery and
MTU 517 were observed. An earlier pair of builds did not deliver the active
workout snapshot to the watch; later fixes (including the 512-byte GATT chunk
limit) were confirmed working by the owner at a basic level, but the current
offline-first pair has not been exercised on hardware at all. The watch client
requires an already-bonded phone. No BLE scan or location permission is used.

Both apps now declare `WearWorkoutService` with foreground service type
`connectedDevice`; this grants a visible ongoing notification during a workout
but does not guarantee that every OEM keeps BLE alive. Background execution,
screen-off advertising, OEM battery policies, reconnection reliability and
indication delivery still need observation on the real HONOR/Galaxy pair.
Specifically unverified for this build: a 20-minute separation, offline edits,
watch-app restart with the journal intact, automatic replay on reconnect,
conflict refresh, durability across a real power loss, the phone-ended-workout
stop while disconnected, and a confirmed watch finish/discard whose full queue
reaches the phone before the session is removed.
