# Release blockers and production readiness

**Assessed:** 2026-08-27; release-control status refreshed 2026-09-20

This older blocker summary remains useful historical context. The current
ordered execution plan, including the first-party NOOP Band, firmware/SDK,
terminology/data migration, manufacturing, certification, signing, stores, and
launch operations, is
[`../FIRST_PRODUCTION_RELEASE_PLAN.md`](../FIRST_PRODUCTION_RELEASE_PLAN.md).
The appendable ordered action list is
[`../FIRST_PRODUCTION_RELEASE_CHECKLIST.md`](../FIRST_PRODUCTION_RELEASE_CHECKLIST.md).
Use that plan and [`../PRODUCTION_READINESS.md`](../PRODUCTION_READINESS.md) for
current go/no-go status.

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

**Launch sequence: India first, then USA.** The first Safety transport is
app-to-app paging of accepted NOOP Safety contacts, with precise location off by
default and enabled only by explicit incident-scoped consent. SMS/voice is not
the first transport and remains disabled until country-specific carrier or DLT,
legal, physical-delivery, monitoring, failover, and staffed-operations gates
pass. India additionally requires the applicable hardware, privacy, store, and
consumer approvals described in
[`INDIA-FIRST-LAUNCH-PATH.md`](INDIA-FIRST-LAUNCH-PATH.md). The older
local-only-v1 recommendation is superseded: core health use remains local-first,
the ownership account is a narrow activation/control exception, and NOOP+
remains a separate explicit opt-in.

## P0 launch gates

1. **Stabilize and publish the implementation.** Review the complete working
   tree, run all Apple/Android/server/policy gates, commit intentional files,
   push a topic branch, open a pull request, pass all ten protected contexts on
   the exact head, and merge normally without bypass. Then verify the merged
   protected-main SHA has all ten successful contexts and the local checkout is
   clean and synchronized. Never push release work directly to `main`.
2. **Provision release identity.** Configure Apple Distribution/App Store
   profiles for the app, widgets, Watch targets, and App Group. Create and
   protect an Android upload key, Play App Signing identity, and production
   package registration. Validate in-place upgrades with existing local data.
3. **Complete store records.** Finish privacy labels, health-data disclosures,
   encryption/export answers, age rating, content rights, review credentials,
   descriptions, screenshots for every declared device class, support/privacy
   URLs, and native-speaker review for all shipped locales.
4. **Complete the ownership/account launch path.** Treat the current
   supplier-independent identity, terms, claim, installation, and onboarding
   foundation plus cooling-off deletion coordination as `PARTIAL`, not
   production-ready. Keep supplier-backed possession, provider identity
   erasure, approved band retirement/wipe, billing, recovery/release, legal
   approval, physical evidence, and production deployment/operations open.
5. **Deploy and operate the required server paths.** Choose production regions,
   tenancy and identity recovery, PostgreSQL/Timescale topology, secret
   management, TLS/domain/DNS, backups, restore drills, RPO/RTO, monitoring,
   incident response, retention, cost limits, and capacity. Prove the enabled
   ownership and Safety workloads under their launch budgets; complete the
   broader documented load, failover, and restore exercises before enabling
   NOOP+ data services.
6. **Prove app-to-app Safety paging.** On controlled Apple and Android phones,
   validate accepted-contact authorization, opaque APNs/FCM wake delivery,
   authenticated detail fetch, response/decline, cancellation, expiry,
   explicit incident-scoped location consent, latest-only replacement,
   terminal deletion, restart/relaunch, all-contact failure, monitoring, and
   operator response. Keep SMS/voice disabled unless its separate carrier or
   DLT, legal, physical-phone, failover, and staffed-operations gates pass.
7. **Finish managed portability before advertising round-trip NOOP+ export.**
   Resumable export, full archive prevalidation, and resumable idempotent import
   now exist for selected chunks and `day_ownership`, the only managed document
   kind in scope. Prove live expiry, large-account, cancellation/auth-refresh,
   cross-tenant, low-storage, and physical process-death behavior.
8. **Validate physical devices.** Exercise supported band generations,
   overnight history, reconnect, clock correlation, background restoration,
   haptics, charging state, low battery, alarms, HealthKit, Watch handoff,
   widgets/Live Activities, Android OEM restrictions, and upgrade/data
   retention on representative real hardware.
9. **Finish measurement evidence.** Run held-out studies for workout
   classification, sleep staging with wrist R-R/respiration plus PSG,
   temperature conversion, SpO2/VO2-derived presentation, and Charge/Effort/
   Rest calibration across representative participants and devices.
10. **Keep automatic emergency inference disabled.** The first-release path is
   manual app-confirmed paging only. Repeated-band gestures remain behind
   authenticated firmware and physical-device evidence. Automatic medical,
   Rhythm, anomaly, or fall paging remains blocked until a separately validated
   detector, staged hard-negative testing, human-factors review, physical
   firmware evidence, delivery evidence, and applicable regulatory review
   exist.

## Current engineering evidence

The current protected baseline is
`b688b3b725cd497e96a31b28540a219bf50446e1`. On 2026-09-18, live branch
protection was reverified as strict, administrator-enforced, linear-history
only, with force pushes and deletion disabled. That exact SHA has successful
GitHub Actions results for the ten contexts listed in
[`../RELEASE_CONTROLS.md`](../RELEASE_CONTROLS.md), including the exact-SHA
`trusted-release-controls` result.

The September 17-21 UI/cloud-readiness replacement candidate has completed its
applicable local Apple, Android, package, server, plan-only OpenTofu, and final
post-documentation policy verification. The consolidated commit and hosted
exact-SHA checks are still pending. Pull request `#16` currently points to
superseded head `3edddda180963444b8eb8caa48e5298623cd66f4`; it becomes
authoritative only after the replacement candidate is pushed and all ten
contexts pass on that exact SHA.

Protected source publication and hosted CI prove only the reviewed source
commit. They do not close the external gates below.
Simulator, emulator, and unit evidence does not close any physical-device,
carrier, signing, store, infrastructure, clinical, or regulatory gate above.

## Release rule

No production upload or public safety claim is complete until every applicable
P0 item has named evidence, an owner, a date, and a rollback path. A successful
build is necessary but is not release approval.
