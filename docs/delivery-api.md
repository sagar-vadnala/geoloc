# Delivery partner API contract

What the app expects from the backend. `HttpDeliveryApi`
(`lib/feature/delivery/data/http_delivery_api.dart`) implements the client
side; `MockDeliveryApi` simulates it for development. Nothing here exists on a
server yet. This document is the request to the backend team.

## Conventions

| | |
| --- | --- |
| Base URL | `API_BASE_URL` (same host as the existing `POST /locations/batch`) |
| Format | JSON, UTF-8, timestamps in ISO 8601 UTC |
| Auth | `Authorization: Bearer <partner access token>` on every request |
| Idempotency | `Idempotency-Key: <opaque string>` on every `POST` and `PUT` |
| Coordinates | `{"lat": 19.0760, "lng": 72.8777}`, WGS84 |

### Authentication (not built yet)

The app has no sign-in flow. It needs:

- a partner login (phone + OTP is typical) returning a short-lived access
  token and a refresh token;
- `POST /auth/refresh` to renew the access token;
- `401` on any endpoint when the token is missing or expired. The app maps it
  to "Your session has ended" and must then sign the partner in again.

Tokens will be stored with the platform keystore (Keychain / Android Keystore,
for example via `flutter_secure_storage`), never in SQLite or plain prefs. For
development only, `--dart-define=DEV_PARTNER_TOKEN=...` is sent as the bearer
token. It is ignored in release builds.

### Idempotency

Every mutating request carries a key that the app reuses for all retries of
the same logical action (accepting delivery X, completing X with code Y). The
backend must:

- store the response (status code and body, including 4xx errors) per key and
  partner for at least 24 hours;
- return that stored response when the same key arrives again, without
  applying the change a second time;
- treat a different key for an already-applied transition as a new request
  (usually answered with `409 invalid_transition`).

This makes "the request went through but the response was lost" safe: the app
retries with the same key and gets the original result.

### Errors

```json
{ "error": { "code": "invalid_otp", "message": "Incorrect code", "attemptsRemaining": 2 } }
```

| HTTP | `code` | Meaning | App behaviour |
| --- | --- | --- | --- |
| 400/422 | `validation_failed` | Malformed request | Shows an error, no retry |
| 401 | | Not signed in | Session ended |
| 403/404 | | Not this partner's delivery | Drops it from the screen |
| 409 | `invalid_transition` | Status no longer allows the action | Reloads the delivery |
| 409/410 | `offer_unavailable` | Offer expired, cancelled or taken | Removes the offer |
| 422 | `too_far_from_stop` | Server-side geofence check failed | Asks to move closer |
| 422 | `invalid_otp` | Wrong code; include `attemptsRemaining` | Shows tries left |
| 423 | `otp_locked` | Too many wrong codes | Tells the partner to contact support |
| 408/429/5xx | | Temporary | Retried with the same key |

## Delivery status

`assigned` → `accepted` → `arrived_at_pickup` → `in_transit` →
`arrived_at_dropoff` → `completed`

Plus terminal `rejected` (by the partner), `expired` (offer timed out) and
`cancelled` (dispatch or customer, from any non-terminal status). The backend
is the source of truth and must reject anything out of order with
`409 invalid_transition`. The app validates against the same table
(`DeliveryTransitions`) so it never offers an impossible action.

## Objects

### Delivery

```json
{
  "id": "dlv_48213",
  "reference": "ORD-48213",
  "status": "accepted",
  "pickup": {
    "name": "Corner Bakehouse",
    "address": "3 Clock Tower Lane",
    "area": "Old Town",
    "location": { "lat": 19.0760, "lng": 72.8777 },
    "instructions": "Fragile. Keep the box upright.",
    "geofenceRadiusMeters": 75
  },
  "dropoff": {
    "name": "Asha",
    "address": "Flat 302, Tower B, Riverside Residency",
    "area": "Riverside",
    "location": { "lat": 19.0912, "lng": 72.8650 },
    "instructions": "Security desk will call up.",
    "geofenceRadiusMeters": 60
  },
  "parcel": { "description": "Small box", "itemCount": 1, "weightKg": 0.6 },
  "tripDistanceMeters": 4200,
  "estimatedMinutes": 18,
  "payout": { "amount": 85, "currency": "INR" },
  "verification": { "method": "otp", "otpLength": 4 },
  "acceptedAt": "2026-11-26T09:12:00Z",
  "pickedUpAt": null,
  "completedAt": null,
  "cancelReason": null
}
```

- `dropoff.name` is the recipient's first name only. No phone number: calls
  should go through a number-masking service (not part of this MVP).
- `geofenceRadiusMeters` is optional per stop; the app falls back to
  `GEOFENCE_RADIUS_M` (default 75).
- `verification.method` is `otp` today. `photo` is reserved so proof-of-delivery
  photos can be added later without changing the app's data model.

### Offer

```json
{
  "id": "dlv_48213",
  "reference": "ORD-48213",
  "pickup": { "name": "...", "address": "...", "area": "...", "location": { "lat": 0, "lng": 0 } },
  "dropoffArea": "Riverside",
  "distanceToPickupMeters": 1200,
  "tripDistanceMeters": 4200,
  "estimatedMinutes": 18,
  "payout": { "amount": 85, "currency": "INR" },
  "parcel": { "description": "Small box", "itemCount": 1 },
  "expiresInSeconds": 40
}
```

The drop-off is reduced to `dropoffArea` until the offer is accepted.
`expiresInSeconds` is relative so a wrong phone clock cannot change the window.
The backend enforces expiry; the app only displays it.

## Endpoints

| Method | Path | Body | Response |
| --- | --- | --- | --- |
| `PUT` | `/partner/availability` | `{"online": true, "location": {...}?}` | `204` |
| `GET` | `/partner/offers?lat=&lng=` | | `{"offers": [Offer], "pollAfterSeconds": 5}` |
| `POST` | `/deliveries/{id}/accept` | | `Delivery` (drop-off now complete) |
| `POST` | `/deliveries/{id}/reject` | `{"reason": "..."}`? | `204` |
| `GET` | `/partner/deliveries/active` | | `Delivery`, or `204` if none |
| `GET` | `/deliveries/{id}` | | `Delivery` in its current state |
| `POST` | `/deliveries/{id}/arrive` | `Arrival` | `Delivery` |
| `POST` | `/deliveries/{id}/pickup` | | `Delivery` (`in_transit`) |
| `POST` | `/deliveries/{id}/complete` | `Proof` | `Delivery` (`completed`) |
| `GET` | `/partner/deliveries?status=completed,cancelled&cursor=&limit=20` | | `{"items": [Delivery], "nextCursor": "..." \| null}` |
| `GET` | `/partner/summary` | | `{"completedToday": 3, "completedThisWeek": 14}` |
| `POST` | `/locations/batch` | existing, see the main README | existing |

Notes:

- **Offers.** The poll doubles as a location heartbeat. A partner with an active
  delivery should get no offers, and an offer must be exclusive to one partner
  while it is open. Production should push offers (FCM/APNs) instead of
  polling; the app's controller keeps the same shape either way.
- **Accept.** Must be atomic: exactly one partner can accept, and only before
  expiry. A second accept with a different key gets `409`.
- **Arrival** body:
  `{"stop": "pickup" | "dropoff", "detection": "auto" | "manual", "location": {"lat", "lng", "accuracy", "recordedAt"}?}`.
  The backend should run its own distance check (`too_far_from_stop`) and keep
  manual arrivals for review. Arriving never completes a delivery.
- **Complete** body: `{"method": "otp", "otp": "4821", "location": {...}?}`.
  The backend validates the code. The app never receives it.
- **History** returns only what a partner needs later: no exact drop-off
  address or coordinates, recipient first name only.
- **Locations.** While a delivery is active the app queues the courier's
  position every 15 s or 30 m and uploads through the existing
  `POST /locations/batch`, now with `"deliveryId"` on each point. Points are
  deduplicated by their `id` as before.

## OTP requirements for the backend

The app's part is small: collect the code and send it once per attempt. The
security lives on the server:

1. Generate a random code per delivery when the order is placed (4–6 digits,
   from a CSPRNG). Store only a hash.
2. Send it to the recipient (SMS, push or the customer app), never to the
   partner app.
3. Compare in constant time. Limit attempts (the mock allows 5) and lock with
   `423 otp_locked`. Rate-limit per partner as well.
4. Expire the code when the delivery completes or is cancelled.
5. Record who completed the delivery, when and where (`location` in the
   request), for disputes.
6. Provide a support override for recipients who can't produce a code.
