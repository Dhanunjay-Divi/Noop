# Round 19 - Safety escalation and validated-fall contract

**Date:** 2026-08-25
**Status:** implementation and local verification complete; external launch
gates remain

## Product contract

- App confirmation and the configured repeated Noop Band SOS gesture are the
  available incident origins.
- The server models a separate `validated_fall` origin, but new automatic fall
  incidents are hard-disabled because authenticated detector attestation is not
  implemented. The preparatory flag and allowlist cannot activate transport.
- Heart rate, rhythm, ECG, SpO2, temperature, stress, sleep, readiness, delayed
  history, and other wellness values cannot enter the paging request model.
- The default delivery plan has four SMS/voice rounds 15 minutes apart.
  Acknowledgement cancels all unsent rounds; cannot-respond cancels future jobs
  only for that contact.
- The owner chooses 8 or 12 hours. Only the latest location fix is retained and
  displayed through the signed responder link. No route history is stored.
- NOOP never contacts emergency services and cannot guarantee carrier delivery
  or human response.

## Implementation map

- `server/app/models.py`, `main.py`, `safety_repository.py`,
  `safety_worker.py`, and migration 013 implement origin validation,
  idempotency, evidence gates, rounds, responder context, and location duration.
- `NoopRemoteSync`, `SafetyPagingService`, `SafetySOSRuntime`, and
  `SafetyCenterView` implement Apple request/retry/location/UI behavior.
- Android `SafetyPaging`, `SafetySosGesture`,
  `SafetyLiveLocationSession`, `WhoopConnectionService`, and
  `SafetyCenterScreen` implement the corresponding behavior with atomic pending
  request persistence.
- `Tools/SafetyLocalization/safety_strings.json` is the source for all generated
  Apple and Android Safety copy.
- `server/SAFETY.md` is the operator contract. The dated ops record is
  `docs/ops/rounds/2026-08-25-safety-escalation-contract.md`.

## Do not weaken

- Do not connect Fall Response state machines to production transport until the
  firmware authentication, detector, physical-device, human-factors, carrier,
  legal, and regulatory gates pass.
- Do not treat the detector allowlist as evidence that a detector is validated.
- Do not add biometric values or raw coordinates to SMS or voice copy.
- Do not change provider delivered state into a claim that a person saw,
  understood, or accepted a page.
- Do not replace bounded rounds with unlimited carrier traffic.
- Do not contact emergency services on the user's behalf.

## Verification

The dated ops record contains the complete evidence and limitations. Final local
results are:

- Server: 142 passed and 11 explicit environment skips; migration 013 and the
  focused escalation contract passed on the disposable PostgreSQL 14 fixture.
- Apple: NoopRemoteSync 44/44; macOS 1,431 executed with 0 failures and 1
  intentional skip; regenerated unsigned iOS simulator build passed.
- Android: 3,649 tests with 0 failures and 6 skips; APK, lint, and
  instrumentation-source compilation passed; the final 221-key Safety
  localization contract passed.
- Policy: strict i18n, health claims, legal inventory, private-data, ops, Ruff,
  tool tests, and diff-whitespace checks passed. The source-rights review was
  later cleared by the 2026-08-25 owner-controlled consolidation declaration.

Carrier delivery, physical-device behavior, detector performance, production
infrastructure, signing, stores, source-rights clearance, and regulatory review
remain external work. Do not infer any of them from local test results.
