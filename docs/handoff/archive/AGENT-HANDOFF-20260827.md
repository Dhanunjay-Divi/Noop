# Agent handoff - 2026-08-27

## Authority

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Work directly from canonical `main`.
- Preserve NOOP's PolyForm Noncommercial License 1.0.0, Required Notice, and
  exact independent dependency notices.
- Customer-rendered product wording uses NOOP or neutral compatible-wearable
  language. Protocol-family names remain available internally and in technical
  documentation.

## Device support boundary

- WHOOP 4 is the stable direct BLE transport.
- WHOOP 5/MG discovery, CLIENT_HELLO correlation, live HR, family-correct
  battery routing, and experimental history are implemented. Representative
  physical-device validation remains open.
- Do not infer support for a future WHOOP family from a shared service or frame.
- Oura Gen 3 is the only direct Oura path exercised on physical hardware.
  Gen 4/5 are generation-aware software paths and remain experimental.
- Garmin support is local export import plus standard Bluetooth HR broadcast
  when exposed. Proprietary history, Body Battery recreation, cloud sync, and
  universal device control are not implemented.

## Round 23 device transport work

The complete implementation and evidence are in
[`../../ops/rounds/2026-08-27-device-transport-durability.md`](../../ops/rounds/2026-08-27-device-transport-durability.md).

Preserve these invariants:

- Device family comes from advertisement or discovered-service evidence, never
  a stale selected model.
- A WHOOP 5/MG bond transition requires the exact pending CLIENT_HELLO
  confirmed-write callback.
- Android battery reads wait for family establishment. WHOOP 4 uses its custom
  command; WHOOP 5/MG uses the standard characteristic.
- Oura no-response commands are serialized. Stop drains disable and unsubscribe
  with a bounded deadline.
- Oura history TLVs remain history even after the driver returns to streaming.
  They may persist but cannot mutate live HR, R-R, or wear state.
- Oura cursor movement waits for every associated store write. Failure,
  timeout, disconnect, stale generation, unanchored teardown, or explicit stop
  leaves the cursor behind for an idempotent retry.
- Unanchored history never receives wall-clock sync-arrival time. Only a
  genuinely live push may use its captured arrival time.
- Banked IBI-derived HR is history-only, median-based, range-gated, anchored,
  and transactionally tied to the original R-R rows.
- Delayed Apple source callbacks are gated by coordinator ownership. Android
  scan replay executes inline on the main owner, and explicit stop invalidates
  its history barrier before late Room completion.

## Archived initial snapshot audit

- The snapshot supplied by the owner contains the same core WHOOP, Oura,
  Garmin import, generic HR, and protocol foundations.
- Additional Oura motion/raw/real-step dumps and older WHOOP capture scripts
  are diagnostics. Do not restore them into production merely to increase file
  count.
- Current production support should be extended from validated behavior, not by
  copying experimental probes wholesale.

## Verified local evidence

- OuraProtocol: 143 tests, 0 failures.
- WhoopStore: 399 tests, 0 failures.
- macOS app: 1,508 tests, 1 skipped, 0 failures.
- Universal macOS app: exact CI build passed for `x86_64 arm64`; keep the
  timestamp collection in `Backfiller` split into typed appends so clean Swift
  builds do not regress into a type-checker timeout.
- NOOPiOS unsigned simulator build and 25 production-shell UI tests: passed on
  iPhone 17 Pro. Pull-to-sync assertions intentionally accept active feedback
  or an explicit terminal outcome because completion may outrun UI automation.
- Android Full plus Demo: 7,652 tests, 14 skipped, 0 failures/errors.
- Android Full plus Demo debug APK assembly: passed.
- Final policy, privacy, localization, legal, and ops gates are recorded in the
  round commit.

## External gates

- No new physical wearable run was performed in this round.
- WHOOP 5/MG, Oura Gen 4/5, Android OEM, overnight, reconnect, haptic, battery,
  background, and in-place upgrade matrices remain external release evidence.
- Signing, store review, production infrastructure, carrier delivery,
  prospective accuracy studies, native-speaker review, and regulatory work
  remain separate in `RELEASE-BLOCKERS.md`.
