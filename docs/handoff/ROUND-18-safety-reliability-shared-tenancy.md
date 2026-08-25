# Round 18 handoff - Safety reliability and shared tenancy

## Current truth

- Automatic medical, anomaly, rhythm, fall, ECG, and AFib paging is unavailable.
- Manual SOS is the only accepted incident trigger.
- Provider state is not human receipt. Unknown delivery stays unknown.
- `NOOP_AUTH_MODE=shared` enforces per-installation biometric authorization;
  public signup, identity proof, and recovery are not implemented.
- Safety and installation credentials rotate through client-generated,
  versioned, retry-safe replacement tokens.
- Installation hard deletion covers biometric, Friends, Safety, and tenancy
  rows. Safety profile export/deletion and terminal/inactive retention exist.
- Paging starts fail-closed. Enabling it requires a configured provider, a
  healthy worker, the current control revision, and an identified operator.

## Read first

1. [`../ops/rounds/2026-08-24-safety-reliability-shared-tenancy.md`](../ops/rounds/2026-08-24-safety-reliability-shared-tenancy.md)
2. [`../../server/PRODUCTION_OPERATIONS.md`](../../server/PRODUCTION_OPERATIONS.md)
3. [`../../server/SAFETY.md`](../../server/SAFETY.md)
4. [`../PRODUCTION_READINESS.md`](../PRODUCTION_READINESS.md)
5. [`RELEASE-BLOCKERS.md`](RELEASE-BLOCKERS.md)
6. [`../provenance/rights-status.json`](../provenance/rights-status.json)

## Verification

- Server: 129 passed; nine database tests and one explicit live-Twilio test
  skip when their external environments are absent.
- Real PostgreSQL runtime integration: 9/9 passed after removing only the
  unavailable Timescale extension/hypertable calls from a disposable copy.
- Restore application SQL smoke and the 12-file migration manifest passed.
- Python Ruff check/format: passed.
- NoopRemoteSync: 42/42 passed.
- macOS app: 1,428 passed, one intentional skip.
- iOS simulator build: passed unsigned.
- Current iOS UI action: host-blocked before test launch by Xcode 26.6's
  debugger-version store on two simulators; no test failed.
- Android Full Debug: 3,646 tests, zero failures, six skips; APK,
  instrumentation source compilation, and lint passed.
- Strict localization, health-claims, legal inventory, private-data, and ops
  gates passed.
- Distribution remains blocked on the same three rights entries.

## Do not do

- Do not connect wellness scores, Rhythm, or Fall Response to paging.
- Do not describe queued, sent, or delivered provider state as a human seeing
  or accepting a page.
- Do not enable paging before real carrier staging and on-call ownership.
- Do not distribute the operator credential to shared clients.
- Do not claim 10,000-user readiness from unit tests or the Compose reference.
- Do not remove provenance or weaken the distribution gate.
- Do not mark Docker, Timescale, k6, carrier, cloud, physical-device, signing,
  store, or accuracy gates complete without their external evidence.

## Next work

1. Resolve source rights.
2. Start A2P 10DLC and launch-country sender procurement.
3. Choose identity/recovery, cloud/regions, RPO/RTO, monitoring/on-call, and
   budget.
4. Deploy a production-like staging topology and run the carrier, load,
   adversarial isolation, failover, and encrypted restore matrices.
5. Run the physical-device and participant evidence programs without resetting
   existing user data.
