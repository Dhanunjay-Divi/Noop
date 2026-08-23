# Noop Band Fall Response Contract

Status: implementation contract only. Automatic fall response is not enabled in production.

## Product Boundary

Fall response is a critical-event workflow, not a wellness inference. Delayed history, heart rate,
readiness, sleep, stress, ECG, rhythm, or anomaly scores must never create a fall candidate.

The workflow may be enabled only after compatible firmware supplies fresh high-rate motion,
on-wrist evidence, and confirmed haptic delivery over an authenticated live connection:

1. Firmware emits a versioned fall candidate.
2. The phone validates freshness, motion coverage, worn state, and contract version.
3. The phone requests a strong band haptic and presents `I'm okay` and `Get help`.
4. The response countdown starts only after firmware confirms haptic delivery.
5. `I'm okay` cancels. `Get help` pages immediately.
6. After 45 seconds without a response, the phone pages accepted emergency contacts exactly once.

NOOP does not dispatch emergency services. A person should use the phone's built-in Emergency SOS
or contact local emergency services when danger is immediate.

## Version 1 Events

Every event is bound to one random `event_id`. Unknown versions or event types fail closed.

### `fall_candidate`

Firmware to phone:

```json
{
  "type": "fall_candidate",
  "contract_version": 1,
  "event_id": "uuid",
  "detected_at_unix": 1000,
  "motion_sample_rate_hz": 100,
  "motion_window_ms": 1500,
  "is_worn": true,
  "worn_evidence_age_ms": 200
}
```

The phone records its own `received_at_unix`; firmware cannot supply or override it. Version 1
requires at least 50 Hz motion over at least 1,000 ms, worn evidence no older than 2,000 ms, receipt
within 5 seconds, and no more than 2 seconds of forward clock skew.

The transport must additionally bind the event to an authenticated band identity, firmware build,
boot session, and monotonic event sequence. Those fields are transport metadata rather than detector
inputs. The phone durably rejects a repeated `event_id` or non-increasing sequence for the same boot.

### `fall_haptic_request`

Phone to firmware:

```json
{
  "type": "fall_haptic_request",
  "contract_version": 1,
  "event_id": "uuid",
  "pattern": "fall_response_strong_v1"
}
```

This command is idempotent by `event_id`. Repetition must not start overlapping patterns.

### `fall_haptic_confirmed`

Firmware to phone:

```json
{
  "type": "fall_haptic_confirmed",
  "contract_version": 1,
  "event_id": "uuid",
  "delivered": true
}
```

This confirms that the haptic pattern was delivered, not merely that a BLE write was accepted. It
must arrive within 5 seconds. Missing, negative, late, mismatched, or replayed confirmation ends the
automatic workflow without paging. The app shows that Fall Response was unavailable.

### User Responses

The band or phone may submit `fall_user_okay` or `fall_get_help`, each carrying the active
`event_id`, response source, and local timestamp. An explicit `fall_get_help` is user intent and may
page before haptic confirmation. Any stale or mismatched response is ignored.

## Durability and Idempotency

The active phase, event identity, boot identity, haptic-confirmed time, absolute response deadline,
and terminal outcome must be persisted atomically. A process restart resumes an already-confirmed
countdown from its original deadline; it never creates a new 45-second window.

Paging uses `event_id` as its idempotency key. A timeout can produce at most one incident even across
restarts, reconnects, or retries. Terminal event IDs remain in a bounded durable replay ledger.

The existing server accepts only `manual_sos`. Automatic fall response must use a distinct audited
trigger such as `validated_fall_no_response_v1` and must not be disguised as a manual SOS. That
server entry point remains blocked until detector validation, device attestation, abuse controls,
regulatory review, and staged delivery tests are complete.

## Production Gates

- Validated on-body detector performance across falls, daily activities, sports, transport, and
  off-wrist impacts, with predefined sensitivity and false-page thresholds.
- Confirmed behavior across supported firmware, phone OS background limits, disconnects, low battery,
  restarts, clock changes, and no-network recovery.
- Physical verification that haptic confirmation means the wearer was actually warned.
- At least two accepted emergency contacts, delivery capability available, and location behavior
  tested without making location a prerequisite for paging.
- Human-factors testing of the response prompt, accessibility, accidental cancellation, and explicit
  `Get help`.
- Privacy, legal, medical-device, and regional emergency-communications review.
- End-to-end staging with provider failures, retries, acknowledgement, cancellation, and exactly-once
  incident creation.

Until every gate passes, clients show readiness status without an enable switch.
