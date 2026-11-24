# geoloc

An offline-first location tracker built with Flutter. It records GPS fixes (real
or simulated), stores **every** fix in SQLite first, and uploads them to a mock
REST API whenever the network allows, without losing or duplicating data.

| Piece | Tech |
| --- | --- |
| App / state | Flutter, Riverpod |
| Location | `geolocator` (real GPS) + built-in simulator |
| Local storage | SQLite via `sqflite` |
| Connectivity | `connectivity_plus` |
| HTTP | `dio` |
| Mock backend | Node.js + Express (`server/`) |
| Tests | `flutter_test`, `mocktail`, `sqflite_common_ffi`, `node:test` |

## Running it

### 1. Start the mock API

```bash
cd server
npm install
npm start            # http://localhost:3000
```

### 2. Run the app

```bash
flutter pub get
flutter run          # Android emulator -> http://10.0.2.2:3000, iOS simulator -> http://localhost:3000
```

On a physical device use your computer's LAN IP:

```bash
flutter run --dart-define=API_BASE_URL=http://192.168.1.20:3000
```

On first launch the app asks for location access and stays on that screen until
it is granted (see [Location permission](#location-permission)). Then pick
**Phone GPS** or **Simulated** and press **Start recording**.

On an emulator the GPS has no position until you give it one: Android emulator
→ Extended controls (`...`) → Location → set a point; iOS simulator → Features →
Location. **Simulated** works without any of that.

### 3. Try the offline behaviour

```bash
# Make the server unavailable: uploads fail with 503, "Pending" grows in the app
curl -X PUT localhost:3000/admin/chaos -H 'content-type: application/json' -d '{"down":true}'

# Bring it back: pending records sync automatically (after their backoff)
curl -X PUT localhost:3000/admin/chaos -H 'content-type: application/json' -d '{"down":false}'

# See what the server received / reset it
curl localhost:3000/locations
curl -X DELETE localhost:3000/locations
```

You can also turn on airplane mode on the device/emulator. `FAIL_RATE=0.3 npm start`
makes 30% of uploads fail randomly.

## Architecture

```
lib/
  core/
    config.dart                         API base URL
    theme.dart                          colours, type, status colours
  feature/
    home.dart                           LocationGate + TrackingScreen
    location/
      data/
        location_record.dart            model, SyncStatus, counts
        location_store.dart             storage interface
        sqlite_location_store.dart      sqflite implementation
        location_api.dart               API interface + Dio implementation
      services/
        location_source.dart            GPS + simulated sources
        location_permission_service.dart  wraps Geolocator permission calls
        connectivity_service.dart
        sync_service.dart               batch upload, dedupe, backoff
        sync_coordinator.dart           decides WHEN to sync
      location_access_controller.dart   permission state for the gate
      tracking_controller.dart          start/stop, saves each fix
      providers.dart                    Riverpod wiring
      presentation/
        location_gate.dart              blocks the app until location is allowed
        tracking_screen.dart            main screen
server/                                 Express mock API (+ tests)
test/feature/location/                  Flutter tests
```

Data flow: `LocationSource -> TrackingController -> SQLite (pending) ->
SyncService -> Dio -> API -> SQLite (synced)`. The UI only reads SQLite
(`LocationStore.watch`), so counts and the list always reflect what is on disk.

### Reliability rules

- **Write first.** A fix is inserted into SQLite before anything else happens.
- **Acknowledge, then mark.** A record leaves `pending` only after the server
  lists its id as `accepted` or `duplicates`.
- **No duplicates.** Each record has a client-generated id (primary key locally,
  idempotency key on the server). If a response is lost and the record is sent
  again, the server answers `duplicates` and the client marks it synced.
  `SyncService` is also single-flight, so overlapping triggers cannot upload the
  same rows twice.
- **Failed attempts.** Network errors, timeouts, 5xx, 401/403, 408, 425 and 429
  keep the record `pending`, increase `attempts`, store `last_error` and delay
  the next try with exponential backoff (5s, 10s, 20s ... capped at 5 min).
  Records the server rejects as invalid (or a 4xx such as 400/422) become
  `failed`: they stay on the device, are shown in the UI and never block the
  queue. **Retry N rejected** puts them back to `pending`.
- **When sync runs** (`SyncCoordinator`): at start-up, when connectivity returns,
  2 s after new fixes are saved, when the earliest backoff expires, every
  minute as a safety net, and on **Upload now**. While the phone has no
  network it waits for connectivity to return instead of retrying on a timer.

### Location permission

The app can't do anything without location, so `LocationGate` sits in front of
the tracker:

1. On launch it checks the permission and, if the user hasn't answered yet,
   shows the system dialog immediately.
2. Until access is granted the user only sees a screen explaining why it's
   needed, with one button that fixes the current problem: *Allow location
   access* (dialog can still be shown), *Open Settings* (denied permanently) or
   *Turn on location* (GPS switched off).
3. It re-checks when the app comes back to the foreground and when the GPS
   toggle changes, so granting access in Settings unlocks the app, and revoking
   it mid-session stops recording and locks it again.

The GPS source only re-checks access before starting; it never prompts.

### Mock API

`POST /locations/batch`

```json
{ "locations": [
  { "id": "m1x2-abc", "latitude": 18.5204, "longitude": 73.8567,
    "accuracy": 8.2, "recordedAt": "2026-01-01T10:00:00.000Z" } ] }
```

Response: `{ "accepted": [...ids], "duplicates": [...ids], "rejected": [{ "id", "reason" }] }`

Other endpoints: `GET /health`, `GET /locations`, `DELETE /locations`,
`PUT /admin/chaos` (`failRate`, `latencyMs`, `down`).

## Tests

```bash
flutter test                  # storage + sync (needs the native sqlite3 library on the host)
cd server && npm test         # mock API
```

| File | Covers |
| --- | --- |
| `sync_coordinator_test.dart` | retries a due record while online, does not poll while offline, syncs as soon as the network returns (fake timers) |
| `sync_service_test.dart` | success, duplicates, failure + backoff + recovery, rejected records, non-retryable errors, partial acknowledgement, offline, overlapping calls, batching (mocked API, real in-memory SQLite) |
| `sqlite_location_store_test.dart` | persistence, duplicate inserts, ordering, backoff filtering, change stream |
| `location_api_test.dart` | request body, response parsing, which Dio errors and HTTP codes are retried |
| `location_access_controller_test.dart` | first-launch prompt, denied / blocked / GPS off, refresh while the dialog is open |
| `location_gate_test.dart` | the app stays locked until access is granted |

## Background location: how it works and its limits

The app asks the OS to keep delivering location updates while it is in the
background, saves each one to SQLite, and tries to upload opportunistically.
Anything not uploaded is simply kept and uploaded the next time the app runs.
No OS guarantees uninterrupted background tracking, so treat it as best effort.

### Android

How it is set up
- `geolocator` runs a **foreground service** with a persistent notification
  (`ForegroundNotificationConfig` in `location_source.dart`) and a partial wake
  lock. Updates are requested every 10 s with no distance filter.
- Manifest permissions:

  | Permission | Why |
  | --- | --- |
  | `ACCESS_FINE_LOCATION`, `ACCESS_COARSE_LOCATION` | GPS and network location; both are requested together as Android 12+ lets the user pick approximate |
  | `FOREGROUND_SERVICE`, `FOREGROUND_SERVICE_LOCATION` | run the location foreground service (Android 14+ needs the typed one) |
  | `WAKE_LOCK` | the service acquires a wake lock; without it starting tracking throws a `SecurityException` |
  | `POST_NOTIFICATIONS` | lets the service notification show on Android 13+ |
  | `INTERNET`, `ACCESS_NETWORK_STATE` | uploads and connectivity checks |

- Tracking must be **started while the app is visible**. With a foreground
  service the "While using the app" permission is enough; `ACCESS_BACKGROUND_LOCATION`
  is not requested.

Limitations
- Android 12+ blocks starting a foreground service from the background, and
  Android 14+ requires the location service type and permission shown above.
- Battery optimisation (Doze / App Standby) and aggressive OEM task killers
  (Xiaomi, Huawei, Oppo, Samsung and others) can still stop the service. Users
  may need to exempt the app from battery optimisation.
- If the user swipes the app away from recents, some devices kill the service.
  Points already saved are safe in SQLite; tracking resumes only when the user
  starts it again.
- The app doesn't ask for the notification permission. On Android 13+ the
  service still runs without it, but its notification only shows once the user
  allows notifications for Geoloc in Settings.
- Android resets permissions of unused apps, and "approximate location" gives
  coarse fixes.
- `usesCleartextTraffic` is enabled only so the demo can talk to `http://` mock
  servers. Remove it and use HTTPS in production.

### iOS

How it is set up
- `UIBackgroundModes: location` in `Info.plist` and `AppleSettings` with
  `allowBackgroundLocationUpdates: true`, `pauseLocationUpdatesAutomatically: false`
  and `showBackgroundLocationIndicator: true`.
- Usage descriptions for "When In Use" and "Always and When In Use".
- Tracking started in the foreground keeps receiving updates after the app is
  backgrounded, with the blue status-bar indicator shown.

Limitations
- If the user **force-quits** the app, iOS does not relaunch it for continuous
  updates. Restarting after termination would need the "Always" permission plus
  significant-location-change monitoring, which this app does not implement.
- Dart code (timers, Dio uploads) is not guaranteed to run in the background.
  The app gets CPU time when location updates arrive, so uploads often work, but
  reliable background uploads would need `BGTaskScheduler` or a background
  `URLSession`. Not implemented.
- Users can downgrade to "While Using", turn on approximate location, or enable
  Low Power Mode, all of which reduce frequency and accuracy.
- Apple requires a clear justification for background location during App Review.
- `NSAllowsLocalNetworking` is set so the demo can reach a local `http://`
  server; use HTTPS in production.

### Both platforms

- Points are time-based (about one every 10 s), so a device that isn't moving
  still records its position. On iOS, which can report every second, the GPS
  source drops fixes that arrive less than 5 s apart.
- The first fix can take from a few seconds to a minute, longer indoors. After
  20 s without one the screen says so instead of looking stuck.
- GPS accuracy drops indoors and in urban canyons.
- `connectivity_plus` only says a network interface exists. A captive portal or
  a down server still looks "online", which is why every upload failure goes
  through the retry/backoff path.
- Backoff timers only run while the process is alive. After a restart,
  `SyncCoordinator.start()` syncs immediately, so no pending record is forgotten.
- Synced records are never deleted locally. A real app would add retention.
