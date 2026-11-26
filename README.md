# geoloc

A delivery-partner app (MVP) built in Flutter on top of an offline-first
location core. Partners go online, receive delivery requests with a countdown,
accept or reject them, navigate to the pickup and drop-off, have arrival
detected from GPS, and complete the delivery with the recipient's one-time
code. Every position recorded during a delivery is stored on the phone first
and uploaded when the network allows.

There is no backend yet. The app runs against an in-app mock backend by
default (clearly labelled "Demo data") and switches to the real API with one
build flag. The contract the backend has to implement is in
[`docs/delivery-api.md`](docs/delivery-api.md).

| Piece | Tech |
| --- | --- |
| App / state | Flutter, Riverpod |
| Location | `geolocator` (real GPS) + simulators for demos |
| Map | `flutter_map` with raster tiles (OpenStreetMap by default) |
| Navigation | hand-off to Google Maps / Apple Maps via `url_launcher` |
| Local storage | SQLite via `sqflite` |
| Connectivity | `connectivity_plus` |
| HTTP | `dio` |
| Mock backends | in-app `MockDeliveryApi`; Node.js + Express for location uploads (`server/`) |
| Tests | `flutter_test`, `mocktail`, `fake_async`, `sqflite_common_ffi`, `node:test` |

## Delivery partner app

### Running it

```bash
flutter pub get
flutter run                        # mock backend, nothing else needed
```

On first launch the app asks for location access and stays locked until it is
granted. Then:

1. **Go online.** A request appears within a few seconds, near your position.
2. **Accept** it before the timer runs out (or **Reject** it).
3. On the delivery screen, tap **Navigate** to open Google Maps, or turn on
   **Simulate driving** (mock mode only) to drive the courier to the stop on
   an emulator. Arrival is detected automatically; **I've arrived** is the
   manual fallback.
4. **Confirm pickup**, drive to the drop-off, then **Enter delivery code**. In
   mock mode the code is shown under the input, as the recipient would read it
   from their phone.
5. The delivery appears in **History** and in today's count.

Against a real backend:

```bash
flutter run \
  --dart-define=DELIVERY_API_MODE=http \
  --dart-define=API_BASE_URL=https://api.example.com \
  --dart-define=DEV_PARTNER_TOKEN=<token from your dev backend>
```

### Configuration

All service settings are `--dart-define` values read by `DeliveryConfig`
(`lib/feature/delivery/delivery_config.dart`). Nothing service-specific is
hardcoded.

| Define | Default | |
| --- | --- | --- |
| `DELIVERY_API_MODE` | `mock` | `mock` or `http` |
| `API_BASE_URL` | emulator host, port 3000 | delivery API and location uploads |
| `DEV_PARTNER_TOKEN` | empty | bearer token for a dev backend; ignored in release builds |
| `GEOFENCE_RADIUS_M` | `75` | arrival radius when the backend sends none per stop |
| `ARRIVAL_MAX_ACCURACY_M` | `50` | fixes less accurate than this are ignored |
| `ARRIVAL_FIXES` / `ARRIVAL_DWELL_S` | `3` / `5` | consecutive fixes and seconds inside the fence |
| `OFFER_POLL_S` | `5` | request polling interval while online |
| `MAP_TILE_URL` / `MAP_TILE_ATTRIBUTION` | OpenStreetMap | raster tile source |
| `ROUTING_URL` | empty | OSRM-compatible routing server; empty draws a dashed straight line |
| `MOCK_FAILURE_RATE` | `0` | e.g. `0.3` makes 30% of mock calls fail, half after applying the change |

### How a delivery moves

```
assigned ──accept──▶ accepted ──arrive──▶ arrived_at_pickup ──confirm pickup──▶ in_transit
   │                                                                              │
   ├─reject──▶ rejected                                                         arrive
   └─timeout─▶ expired                                                            ▼
                                     completed ◀──valid OTP── arrived_at_dropoff
     any active status ──dispatch/customer──▶ cancelled
```

- The backend is the source of truth. The app sends a request for each step
  and shows whatever status comes back. `DeliveryTransitions` holds the same
  table, so the UI only shows the action that fits the current status, and a
  stale screen can't send an out-of-order request.
- Pickup is its own stage: nothing can be completed before the parcel is
  collected, and reaching the drop-off never completes a delivery.
- Duplicate taps are blocked while a request is in flight. Every mutation has
  an idempotency key that is reused for retries, so a request whose response
  was lost can be sent again without being applied twice. Transient failures
  are retried twice with backoff, then shown with a retry button.
- While active, the delivery is re-read every 30 s and when the app returns to
  the foreground, so a cancellation by dispatch shows up with its reason.
- After an app restart, the active delivery is restored from
  `GET /partner/deliveries/active` and tracking resumes.

### Verification: OTP rather than a photo

The delivery is completed with a one-time code that the recipient receives and
reads out; the backend checks it.

- **Security.** A code proves the recipient was present. A photo proves only
  that a parcel was near a door, and it can be staged or reused. The OTP is
  checked server-side with an attempt limit; the app never knows the answer.
- **Reliability.** A few bytes go through on a weak connection, and the
  idempotent request can be retried safely. Photo upload is large and slow
  exactly where couriers often are (basements, stairwells).
- **Privacy.** No images of people, homes or doors are collected, stored or
  retained, and no camera permission is needed.
- **Practicality.** Typing four digits is faster than framing a photo. The
  downside is recipients who are absent or can't find the code, which needs a
  support override on the backend.
- **Backend needs.** Code generation and delivery to the recipient (SMS or
  push), hashed storage, attempt limits and lockout, expiry. See
  [OTP requirements](docs/delivery-api.md#otp-requirements-for-the-backend).

`verification.method` in the API is `otp` today, with `photo` reserved in the
model and contract, so "leave at door" photo proof can be added later without
reworking the flow.

### Maps and location

- **Map.** `flutter_map` draws the courier (with an accuracy circle), both
  stops (the current one with its geofence), and the route. It follows the
  courier until they pan, then offers a recenter button. Tiles come from
  OpenStreetMap by default. Its [tile policy](https://operations.osmfoundation.org/policies/tiles/)
  does not allow heavy production use, so set `MAP_TILE_URL` to a commercial
  provider (MapTiler, Stadia, Thunderforest, Mapbox raster) before launch.
- **Route.** With `ROUTING_URL` set to an OSRM-compatible server the road route
  is drawn; otherwise, or if routing fails, a dashed straight line. The route
  is fetched once per stage, not on every fix.
- **Navigation.** **Navigate** opens turn-by-turn directions in Google Maps
  (Android), Google Maps or Apple Maps (iOS), or the Google Maps website.
- **Arrival detection** (`ArrivalDetector`). A single reading never counts.
  Arrival needs 3 consecutive fixes inside the geofence over at least 5 s
  while the courier has essentially stopped (under about 11 km/h averaged
  over that window, so driving past doesn't count). Fixes with accuracy worse
  than 50 m are ignored and shown as a weak-signal warning, implausible jumps
  are discarded, and a 25 m exit margin stops jitter at the edge from
  resetting progress. The radius comes from the backend per stop, or from
  `GEOFENCE_RADIUS_M`. The backend repeats the distance check.
- **Battery.** Two GPS profiles: while online and waiting, coarse updates
  (about 100 m accuracy, every 30 s or 50 m); during a delivery, GPS accuracy
  every 5 s. Nothing runs while offline.
- **Lifecycle.** Tracking belongs to the delivery, not to a screen: it starts
  when a delivery becomes active, continues while the partner is in another
  screen or in Google Maps, and stops as soon as the delivery is finished.
- **Problems handled.** Permission removed or GPS switched off (banner with a
  Settings button; tracking retries every 10 s), no fix for 20 s, and weak
  signal. The location gate keeps the app locked without permission.
- **Breadcrumbs.** Positions during a delivery (every 15 s or 30 m) go into the
  existing SQLite queue with the delivery id and are uploaded by the existing
  sync engine, so nothing is lost offline.

Background behaviour and its platform limits are described in
[Background location](#background-location-how-it-works-and-its-limits) below.

### Security and privacy

- Before acceptance the partner sees only the drop-off area. History holds
  areas and first names only, in memory. The only delivery data stored on the
  phone is the breadcrumb points in the location queue (see limitations).
- The OTP is never logged or stored; the input is cleared when the screen
  closes. `OtpProof.toString()` masks it.
- No secrets ship in the app. The dev token define is ignored in release
  builds, and real tokens belong in the platform keystore.
- Needs backend support: authentication and token refresh, OTP generation and
  delivery, number masking for calls, server-side geofence checks, idempotency
  storage, and retention rules for location data.

### Structure

```
lib/feature/delivery/
  delivery_config.dart          --dart-define settings
  delivery_providers.dart       Riverpod wiring (plain Dart)
  delivery_bootstrap.dart       platform overrides: GPS, Dio, routing, breadcrumbs
  domain/                       models, state machine, arrival detector, geo maths
  data/
    delivery_api.dart           API interface, errors, proof types
    http_delivery_api.dart      Dio implementation of docs/delivery-api.md
    delivery_repository.dart    idempotency keys and retries
    mock/mock_delivery_api.dart simulated backend (mock mode only)
    route_service.dart          OSRM routing with straight-line fallback
    breadcrumb_sink.dart        delivery positions into the existing location queue
  services/                     navigation hand-off, demo route simulator
  application/                  controllers: availability, offers, active delivery, history
  presentation/                 dashboard, offer card, map, delivery code, history
```

Everything outside `presentation/`, `delivery_bootstrap.dart` and
`navigation_launcher.dart` is plain Dart without Flutter or plugin imports,
which keeps the logic testable on the Dart VM.

### Limitations

- No real backend, sign-in, push notifications or number masking. These are
  integration boundaries with documented contracts, not built features.
- Requests are polled every 5 s while online; production should use push.
- OpenStreetMap tiles and the public OSRM demo are not for production traffic.
- The old location log screen (menu, top right) can record at the same time as
  a delivery; both would then share one GPS stream.
- Uploaded location points, breadcrumbs included, are never deleted from the
  phone. A retention rule is still to be added.
- On iOS, tracking stops if the partner force-quits the app during a delivery.
  The delivery itself is restored from the backend on the next launch.

## Location core

The location recorder from the first version is still there: it is the
offline-first queue the delivery breadcrumbs go through, and its screen is
under the menu as "Location log and uploads".

### Running the location upload server

#### 1. Start the mock API

```bash
cd server
npm install
npm start            # http://localhost:3000
```

#### 2. Run the app

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

#### 3. Try the offline behaviour

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
    home.dart                           LocationGate + DashboardScreen
    delivery/                           delivery partner feature (see above)
    location/
      domain/
        location_fix.dart               LocationFix / LocationSource (plain Dart)
      data/
        location_record.dart            model, SyncStatus, counts, deliveryId
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
        tracking_screen.dart            location log screen
server/                                 Express mock API (+ tests)
test/feature/location/                  location tests
test/feature/delivery/                  delivery tests
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
  queue. **Retry failed records** puts them back to `pending`.
- **When sync runs** (`SyncCoordinator`): at start-up, when connectivity returns,
  2 s after new fixes are saved, when the earliest backoff expires, every
  minute as a safety net, and on **Sync now**.

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
flutter test                  # everything (SQLite tests need the native sqlite3 library on the host)
cd server && npm test         # mock API
```

The delivery logic tests use plain Dart only (domain, data, controllers), so
they would also run on the Dart VM without the Flutter engine.

| File | Covers |
| --- | --- |
| `sync_service_test.dart` | success, duplicates, failure + backoff + recovery, rejected records, non-retryable errors, partial acknowledgement, offline, overlapping calls, batching (mocked API, real in-memory SQLite) |
| `sqlite_location_store_test.dart` | persistence, duplicate inserts, ordering, backoff filtering, change stream |
| `location_api_test.dart` | request body, response parsing, which Dio errors and HTTP codes are retried |
| `location_access_controller_test.dart` | first-launch prompt, denied / blocked / GPS off, refresh while the dialog is open |
| `location_gate_test.dart` | the app stays locked until access is granted |
| `sqlite_location_store_test.dart` (new cases) | delivery id round-trip, v1 to v2 migration keeps existing points |
| `delivery_status_test.dart` | allowed and forbidden transitions, no completing before drop-off, terminal states, wire values |
| `arrival_detector_test.dart` | single fix not enough, dwell, inaccurate fixes, outlier jumps, hysteresis, drive-past, configurable radius |
| `mock_delivery_api_test.dart` | drop-off hidden before acceptance, expiry, idempotent replay, lost response, out-of-order steps, OTP attempts and lockout, history paging |
| `http_delivery_api_test.dart` | paths, idempotency header, payloads, 204, cursors, error-code mapping, unreadable responses |
| `delivery_repository_test.dart` | same key across retries, lost response not applied twice, new key per code, retry limits |
| `offers_controller_test.dart` | polls only online and idle, window not extended, expiry, double-tap accept, withdrawn offers, reject |
| `active_delivery_controller_test.dart` | resume after restart, arrival needs several fixes, weak signal, double tap, invalid actions, drop-off doesn't complete, OTP, retry after failure, cancellation by dispatch, GPS off, no fix, breadcrumbs, simulated drive |
| `history_controller_test.dart` | paging to the end, no duplicate loads, error then retry |
| `delivery_screens_test.dart` | dashboard online flow, wrong-code message |

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
