# GymMane Wear OS companion architecture

Status: implemented and code-validated; **not verified on real BLE hardware**.
See `IMPLEMENTATION_STATUS.md` for the current state, `BLE_FEASIBILITY.md` for
the transport risks and the real-device procedure, and `HANDOFF.md` for a
resumable work log.

## Goal

Let a Wear OS watch show and drive the workout that is running on the phone.
The phone remains the final history store, while the watch owns a durable
working copy and ordered journal for the active workout. The watch reads full
snapshots and sends small, idempotent operations. Everything stays on the
local Bluetooth link:
no account, no server, no Data Layer, no HTTP or WebSocket, and no
`android.permission.INTERNET` in the release APKs.

The feature is opt-in and off by default. When it is off, GymMane behaves
exactly as it did before, including the existing standalone Wear experience.

## Reuse decision: Flutter companion, not a second native app

The repository already contains a complete Flutter Wear OS UI:

- `lib/wear/wear_shell.dart`: circular screens, large controls, rotary input,
  dimming, rest ring, localization.
- `lib/wear/wear_app.dart` and `DeviceKind.isWatch()`: the current standalone
  watch entry point, which runs the whole GymMane database on the watch.
- `lib/theme`, `lib/l10n`, `lib/widgets`: shared visual identity and strings.
- `WearSurfaces.kt`: existing Tile/complication bridge inside the same APK.

The alternatives were:

| Option | Reuse | Watch performance | Maintenance | Verdict |
| --- | --- | --- | --- | --- |
| New Kotlin/Compose Wear app | Low: duplicates theme, localization, navigation and protocol glue | Best | Two UI stacks, two build systems, two release paths | Rejected |
| Second Flutter project | Medium | Good enough; the project already ships Flutter on Wear | Two pubspecs, two Android projects | Rejected |
| Second Flutter entry point in this project | High: same theme, l10n, widgets, models and Gradle module | Good enough; same engine already used on Wear | One codebase, one test suite | **Chosen** |

The companion is a separate Flutter entry point,
`lib/main_wear_companion.dart`, built from the same Android module. In normal
use the existing watch build already reaches the same screen from Settings →
**Phone link** (`fit.pushRoute('link')`), so **no second APK is required in
production**. The extra entry point is a development/preview convenience:

```bash
flutter run -t lib/main_wear_companion.dart -d <wear-device>
```

This keeps the official Flutter build untouched: the normal `flutter build apk`
still produces the phone app, and the existing watch-mode branch in
`lib/main.dart` still produces the standalone Wear app. The companion stores
only the current snapshot and pending-operation journal; it does not duplicate
the phone's workout library or history database.

The companion reuses `WearPage`, `WearButton`, `WearIconButton`, `WearClock`,
`WearRotary`, `AppTheme`, `GymColors` and the ARB strings. It does not reuse the
standalone `WearShell` screens directly because those read the local `fit`
singleton; the companion reads a remote snapshot instead.

## Topology

```
+-----------------------------+        BLE GATT (bonded, encrypted)        +---------------------+
| GymMane phone               |  phone = GATT server + advertiser           | GymMane watch       |
| Flutter UI + authoritative  |  RX  write (watch -> phone)                 | Flutter companion   |
| FitState + session engine   |  TX  indicate (phone -> watch)              | no local database   |
|                             | <-----------------------------------------> | GATT client         |
| WearLinkServer (Dart)       |                                             | WearLinkClient      |
| WearLinkBridge (Kotlin)     |                                             | (Dart + Kotlin)     |
+-----------------------------+                                             +---------------------+
```

The phone never scans. The watch never scans. The watch lists its
already-bonded devices and connects to the phone's address. This avoids
`BLUETOOTH_SCAN` and location permissions entirely. The user pairs the watch
and phone once in the operating system, then authorizes the GymMane apps with
a six-digit code shown on the phone.

If a Wear OS build does not expose the phone in `bondedDevices`, the documented
fallback is to pair from system settings again; a scan-based fallback is
deliberately not included because it would add permissions and a location
surface.

## Permissions

Phone manifest:

- `BLUETOOTH_ADVERTISE` (`neverForLocation`)
- `BLUETOOTH_CONNECT`
- legacy `BLUETOOTH` / `BLUETOOTH_ADMIN` with `maxSdkVersion="30"`
- `INTERNET` and `ACCESS_NETWORK_STATE` explicitly removed with
  `tools:node="remove"` as defence in depth

Watch companion uses the same APK and manifest. It needs `BLUETOOTH_CONNECT`
(and the legacy permissions on API 30). It does not use
`BLUETOOTH_SCAN`, `ACCESS_FINE_LOCATION` or `ACCESS_COARSE_LOCATION`.

The feature is gated to Android 12 / API 31 and above, where the runtime
`BLUETOOTH_CONNECT` and `BLUETOOTH_ADVERTISE` model is available. On older
devices the setting is shown as unavailable and the rest of the app is
unchanged.

## Security model

No custom cipher is invented. The design uses the operating system's BLE
security plus standard primitives:

1. The phone and watch are bonded in the operating system. LE Secure
   Connections provides an encrypted, MITM-protected link.
2. The GATT server marks its characteristics as requiring an encrypted,
   MITM-protected link (`PERMISSION_WRITE_ENCRYPTED_MITM` and
   `PERMISSION_READ_ENCRYPTED_MITM`). The Android Bluetooth stack refuses
   access from a non-bonded or unencrypted peer.
3. The app adds an authorization layer above GATT:
   - The phone shows a random six-digit code while pairing mode is open for a
     short window.
   - The watch proves knowledge of the code with PBKDF2-HMAC-SHA256
     (120,000 iterations, per-session salt) and HMAC-SHA256.
   - The phone then generates a random 256-bit pre-shared key and sends it
     inside the encrypted link, authenticated with the code-derived key.
   - Both sides store the pre-shared key. Reconnects use an HMAC challenge
     over fresh nonces; no key is sent again.
4. Every application message carries an HMAC-SHA256 tag and a strictly
   increasing per-direction sequence number. The tag covers a domain string,
   the session id, the sequence, the direction, the message type and the exact
   payload string. Replays, gaps, reflection between directions, tampering and
   messages from another session are rejected.
5. A first connection while pairing mode is closed is rejected. The phone never
   trusts the first device that connects, and never accepts a device without
   either the stored key or the current pairing code.

The pre-shared key is stored in the app's private `SharedPreferences` on each
side. `Forget` removes it. There is no cloud escrow and no export.

The app-layer key is defense in depth: the OS link already provides
confidentiality and integrity. If a link key were compromised, the HMAC tags
still prevent another bonded device from forging commands without the
GymMane key.

## Wire transport

Application frames:

```
byte 0      kind (1 = handshake JSON, 2 = secure JSON)
bytes 1..4  payload length, big endian, max 65536
bytes 5..   payload
```

GATT writes are chunked to `MTU - 3` bytes and reassembled by `FrameReader`.
The phone uses indications for the TX characteristic so the stack acknowledges
each chunk; the watch uses write-with-response for RX. Both sides keep one
frame in flight, which keeps ordering simple.

Handshake frames are plaintext JSON inside the encrypted BLE link. Secure
frames are JSON envelopes:

```json
{
  "sid": "base64 session id",
  "seq": 12,
  "t": "command",
  "d": "{...payload as a JSON string...}",
  "mac": "base64 HMAC-SHA256"
}
```

The payload is carried as a string so the MAC is computed over exactly the
bytes that are verified, without depending on JSON key ordering.

## Messages

Phone to watch:

- `state`: authoritative snapshot. Fields include revision, boot id, workout
  id, status (`idle`, `active`, `paused`, `complete`, `parked`), name, elapsed
  seconds, current exercise index, exercises and sets, rest end timestamp,
  rest total, `restDefaults` (normal/mini/change/side), an effective
  `restAfterSec` per set, summary and server time.
- `ack`: result of a command (`id`, `ok`, `rev`, `code`, optional `message`).

Watch to phone:

- `command`: `id` (UUID), `baseRev`, `action`, `args`.
- `requestState` is a command action and never mutates the workout.
- `bye`: clean disconnect.

Supported actions:

`completeSet`, `uncompleteSet`, `updateSet`, `nextExercise`, `prevExercise`,
`goNextPending`, `goToExercise`, `pause`, `resume`, `skipRest`, `nudgeRest`,
`setRest`, `finish`, `continueSession`, `saveExit`, `resumeSession`,
`requestState`.

## State authority and conflicts

The phone builds snapshots from the real `fit` state. It does not reimplement
workout rules. In particular, completing a set calls the existing
`fit.toggleSet`, which owns rest arming, superset advance, side switches and
auto-advance. Weight, reps, RPE/RIR, set kind, rest and navigation call the
existing `fit` methods.

A snapshot revision increases only when the semantic state changes. Rest
countdown ticks and clock fields do not bump it; rest is transmitted as a
wall-clock `endsAt` timestamp and the watch renders the countdown locally.
Rest start, nudge, skip and pause do change the snapshot.

Because the watch must start rests with no phone, `restDefaults` and each
set's effective `restAfterSec` are part of the snapshot. The offline journal
resolves a completed set's rest from the per-set override, mini rest, change
rest and effective default, then stores `restEndsAt`/`restTotalSec` with the
pending operation. Replaying that completion sends the deadline plus
`restRemainingSec`; the phone prefers the remaining seconds (no clock-skew
error) and adopts the original total instead of restarting the rest.

Operations carry `baseRev` plus stable workout, exercise and set identities. If
the revision changed, the phone returns `conflict` without mutating anything.
The watch rebases its ordered pending operations over the fresh phone snapshot
and retries automatically with the original IDs. Successful IDs are persisted
with the phone workout state, so reconnect retries cannot log a set twice.

While connected, confirmation means the phone has durably acknowledged the
change. While disconnected, the watch first commits the updated snapshot and
operation to its private journal, then updates the UI and labels it offline. A
transport timeout leaves the operation queued instead of losing it.

### Ending a workout on either device

The phone is authoritative when it has no workout. A snapshot with `status:
idle` and an empty `workoutId` stops the watch even if the watch still has
queued edits: the journal is cleared and the live workout disappears. Without
this rule a phone-side interruption left the watch running forever. A same-boot
idle snapshot whose `rev` predates the revision the watch already holds is
treated as stale and ignored, because it could be a delayed frame; a changed
`bootId` is accepted because the phone process may have restarted with a lower
revision.

A snapshot that changes the workout identity (a new workout or idle) also
releases any command still waiting for an ACK, because that ACK can no longer
belong to the current session; otherwise the send pump could wait forever and
block the next workout's queue.

The watch also offers a confirmed *finish and discard* action
(`WearLinkClient.finishAndDiscard`). It records a `saveExit` operation in the
journal, behind every pending edit (weights, reps, sets, exercises), and never
clears the local snapshot when it is recorded. The queue is sent strictly in
order, so the phone receives all unsynced work before the discard. The local
workout is removed only on a positive `saveExit` ACK, a `no_session` ACK (the
phone already has nothing), or an authoritative idle snapshot. Any other
failure keeps the intent durable and retries on the next connection. While the
intent is pending, further watch edits are refused with code `finishing`. If
the watch app is killed, the journal restores both the workout and the pending
`saveExit`, so a finished workout can never be lost.

## Reconnect and lifecycle

On every connection the handshake produces fresh nonces and a fresh session
id. The phone sends a full snapshot immediately after the handshake. The watch
rebases pending local operations and replays them strictly in order. Both
devices keep a user-visible connected-device foreground service during an
active, paused or parked workout so Android can preserve the BLE endpoint and
automatic reconnect during a prolonged separation. The service stops when the
workout ends or the link is explicitly disabled.

## Files

- `lib/wear/link/`: Dart protocol models, snapshot builder, command executor,
  phone coordinator and watch client.
- `lib/wear/companion/`: companion screens and shell.
- `lib/main_wear_companion.dart`: companion entry point.
- `android/app/src/main/kotlin/com/gymmane/app/wear/`: GATT server/client and
  MethodChannel bridge.
- `packages/wear_protocol/`: pure Kotlin protocol, crypto helpers and JVM
  tests, compiled into the app module.
- `docs/wearos/`: this document, status, handoff and BLE feasibility notes.

## Non-goals

- Wear OS Data Layer API, Play Services, cloud relay, Wi-Fi sync.
- Remote accounts, analytics, telemetry, crash reporting.
- Starting or editing the plan from the watch; the phone owns planning.
- Replacing the existing standalone watch build. It remains available for
  users who want a fully independent watch app.
