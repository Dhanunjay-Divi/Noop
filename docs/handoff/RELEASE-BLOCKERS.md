# Release blockers and production readiness

**Assessed:** 2026-08-25
**Source-rights status:** **NOT cleared.** The owner declaration does not settle it. This repository's
root commit `ecaabdc0` is present under the same SHA in the public `ryanbr/noop`, whose origin
`muftiarfan/noop` carries **no licence at all** (76 stars, 1,046 forks, actively pushed). Absent a
licence, all rights are reserved, so no downstream licence choice can grant what upstream never did.
`Tools/provenance_ratchet.py` measures the residue: **38,829 lines across 212 files, 6.9% of the tree.**
See `docs/validation/AGENT-REVIEW-AND-COMPETITIVE-GAPS.md` finding 1c. **This is now P0 gate 0 and it
precedes every gate below.**
**Product verdict:** not yet production-ready

NOOP's project license and runtime dependency notices are internally
consistent. Both legal gate modes must remain green:

```bash
python3 Tools/release-legal-gate.py check
python3 Tools/release-legal-gate.py distribution
```

The PolyForm Noncommercial License 1.0.0, NOOP Required Notice, and independent
dependency notices remain mandatory. The legal gate does not replace review by
qualified counsel for store terms, trademarks, privacy disclosures, safety
claims, or a future commercial licensing posture.

**Launch sequence: India first, then USA.** Gates 4 and 5 below are written for US carriers and are
NOT the India path: India requires TRAI DLT entity, header and content-template registration rather than
A2P 10DLC, and the Noop Band additionally needs BIS and WPC/ETA approval. India coverage in this
repository is currently zero and no Indian locale ships. See
[`INDIA-FIRST-LAUNCH-PATH.md`](INDIA-FIRST-LAUNCH-PATH.md), which also recommends descoping v1 to
local-only so gates 4 and 5 leave the critical path entirely.

## P0 launch gates

1. **Stabilize and publish the implementation.** Review the complete working
   tree, run all Apple/Android/server/policy gates, commit intentional files,
   push `main`, and verify a clean `HEAD == origin/main`.
2. **Provision release identity.** Configure Apple Distribution/App Store
   profiles for the app, widgets, Watch targets, and App Group. Create and
   protect an Android upload key, Play App Signing identity, and production
   package registration. Validate in-place upgrades with existing local data.
3. **Complete store records.** Finish privacy labels, health-data disclosures,
   encryption/export answers, age rating, content rights, review credentials,
   descriptions, screenshots for every declared device class, support/privacy
   URLs, and native-speaker review for all shipped locales.
4. **Deploy and operate the server path.** Choose production regions, tenancy
   and identity recovery, PostgreSQL/Timescale topology, secret management,
   TLS/domain/DNS, backups, restore drills, RPO/RTO, monitoring, paging,
   incident response, retention, cost limits, and capacity. Run the documented
   10,000-user load, failover, and restore exercises.
5. **Prove Safety paging delivery.** Complete sender procurement and US A2P
   10DLC registration where applicable. Run controlled SMS, voice fallback,
   DTMF acknowledgement, responder-link, cancel, expiry, provider-5xx, worker
   restart, and all-contact-failure scenarios on real controlled phones.
   Record provider IDs and p95 delivery latency.
6. **Validate physical devices.** Exercise supported band generations,
   overnight history, reconnect, clock correlation, background restoration,
   haptics, charging state, low battery, alarms, HealthKit, Watch handoff,
   widgets/Live Activities, Android OEM restrictions, and upgrade/data
   retention on representative real hardware.
7. **Finish measurement evidence.** Run held-out studies for workout
   classification, sleep staging with wrist R-R/respiration plus PSG,
   temperature conversion, SpO2/VO2-derived presentation, and Charge/Effort/
   Rest calibration across representative participants and devices.
8. **Keep automatic emergency inference disabled.** Manual app SOS and repeated
   band SOS can use the acknowledged paging pipeline. Automatic medical,
   Rhythm, anomaly, or fall paging remains blocked until a separately validated
   detector, staged hard-negative testing, human-factors review, physical
   firmware evidence, carrier evidence, and applicable regulatory review exist.

## Current engineering evidence

Round 21 records the latest package, app, simulator, emulator, localization,
privacy, and migration results in
[`ROUND-21-validation-calibration-import-integrity.md`](ROUND-21-validation-calibration-import-integrity.md).
Simulator, emulator, and unit evidence does not close any physical-device,
carrier, signing, store, infrastructure, clinical, or regulatory gate above.

## Release rule

No production upload or public safety claim is complete until every applicable
P0 item has named evidence, an owner, a date, and a rollback path. A successful
build is necessary but is not release approval.
