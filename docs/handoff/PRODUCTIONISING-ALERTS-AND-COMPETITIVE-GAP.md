# Productionising NOOP: alerts, notifications, and the competitive gap

**Date:** 2026-08-24 · **Assessed against:** Garmin Connect, WHOOP, Oura, Apple Watch

---

## 0. The honest headline

The first audit correctly found strong foundations across all 13 notification
producers and the paging pipeline: authorization checks, stable identifiers,
leases, idempotency, retries, SMS-first voice fallback, receipts, DTMF,
capability-signed responder links, cancellation, expiry, and privacy-safe
monitoring, per-installation shared tenancy, credential rotation, full
installation erasure, bounded Safety retention, and restore-contract checks.

A subsequent concurrency and deployment review did find defects in the paging
boundary. They are now fixed: ambiguous provider outcomes remain `unknown`;
final failure is serialized; workers lease only a concurrency-sized wave;
database-backed submission permits make disable wait for started calls;
idempotent incident replay survives a pause; control writes are revisioned and
audited; external workers are heartbeat-gated; and API, migration, and worker
processes have least-privilege environment splits.

Apple and Android now also show unique-contact delivery receipts, give a direct
call path when every contact explicitly fails, and include bounded local
notification lifecycle evidence in diagnostics. What remains is **real-world
evidence**, **a delivery path that survives a sleeping app**, **consumer
identity and production infrastructure**.

---

## 1. What actually blocks a launch, in order

### P0 - Distribution and dependency gates must stay green

The 2026-08-25 owner-controlled consolidation record clears the prior
source-rights review. `python3 Tools/release-legal-gate.py distribution` must
still run for every release so NOOP's license and independent dependency
notices cannot drift.

### P0 — The safety page has never reached a real phone

This is the single most important gap in the feature the owner asked about. The pipeline is complete and
automation-verified, but the real-carrier test is **opt-in and has never run**:

```python
# server/tests/test_twilio_staging.py
pytestmark = pytest.mark.skipif(
    os.getenv("NOOP_RUN_TWILIO_STAGING") != "I_CONTROL_THIS_NUMBER",
    reason="real Twilio staging is explicitly opt-in",
)
```

**A safety feature with zero delivery evidence is a liability, not a feature.** If a contact is never
paged because of a carrier filter, a bad `from` number, or an unverified sender ID, the user finds out at
the worst possible moment. This is a procurement-and-testing task, not an engineering one:

1. Twilio account, a verified sending number per launch country, and A2P 10DLC / sender-ID registration
   where required (US 10DLC brand+campaign registration takes days to weeks — start now, it is the
   long-lead item).
2. Numbers you control in every launch country, on more than one carrier each.
3. Run the full matrix with `NOOP_RUN_TWILIO_STAGING=I_CONTROL_THIS_NUMBER`: invitation, accept, SMS
   arrival, voice fallback, DTMF acknowledge, responder link open, cancellation, expiry, retry after a
   provider 5xx, and **worker/API restart mid-incident** (the lease logic exists precisely for this — prove
   it).
4. Capture timestamps and provider SIDs for each. That evidence table is what `PRODUCTION_READINESS.md`
   already demands.
5. Measure and publish **median and p95 time-to-delivery**. WHOOP and Garmin are judged on this; you will
   be too.
6. Test the unhappy paths users will actually hit: contact blocked the number, phone off, DND/Focus,
   airplane mode, roaming, number changed, contact revoked consent.
7. **Implemented:** every explicit SMS and voice failure closes the incident as
   `failed`; the app says no contact delivery was confirmed and offers direct
   call actions.
   Ambiguous outcomes remain pending/unknown instead of becoming a false
   failure claim.
8. **Implemented:** Apple and Android show human responses individually and a
   deduplicated contact count backed by either a response or provider-confirmed
   delivery, with a localized timestamp, for example "Delivery or response
   confirmed for 2 of 2 contacts at 14:03."

### P0 for a 10,000-user shared launch — identity and infrastructure are not procured

The server now has a real shared authorization boundary. With
`NOOP_AUTH_MODE=shared`, the operator credential is administrative only;
versioned per-installation credentials own an exclusive device namespace and
cannot list, read, export, or delete another installation. Rotation, export,
hard deletion, Safety/Friends erasure, retention, migrations, and restore smoke
checks are implemented and exercised against PostgreSQL.

That does not create a consumer account system or a production deployment.
Installation enrollment is still an administrator action. A public service
needs a selected identity provider, signup proof, recovery and lost-device
policy, support-access controls, abuse prevention, managed secrets and keys,
WAF/rate limits, multi-zone database, object-locked backups, monitoring/on-call,
DNS/TLS, and a deployment pipeline. It also needs an independent isolation
review and production-like mixed-workload evidence. The exact topology and
acceptance gate are in `server/PRODUCTION_OPERATIONS.md`.

### P1 — Local-first means local notifications, and that is a real reliability ceiling

This is the deepest architectural difference from every competitor, and it is a **consequence of the
product's best idea**, not a bug.

| | NOOP today | WHOOP / Garmin / Oura |
|---|---|---|
| Where notifications originate | scheduled **on-device** from data the app has already computed | **pushed from cloud** after server-side analysis |
| If the band has not synced | no notification — there is nothing to schedule from | notification still arrives |
| If the app was killed / iOS deferred background work | nudge can be missed or stale | unaffected |
| If the phone was off overnight | schedule may be stale on wake | server retries |

Consequence: NOOP's morning "your recovery is X" style nudges are only as reliable as background BLE sync
and iOS/Android background execution — the least reliable part of any wearable stack, and the part
`PRODUCTION_READINESS.md` correctly marks as needing physical-device evidence.

**Three honest options:**

* **(a) Accept and disclose.** Keep everything local; state plainly that reminders depend on the app having
  synced. Cheapest, fully consistent with the privacy promise, and weakest on reliability.
* **(b) User-operated push for independently signed builds.** A user who builds
  NOOP with their own Apple/Google application identity can supply their own
  provider credentials. This is not a general App Store or Play solution.
  Distributing NOOP's APNs signing key, certificate, or FCM server credential
  to self-hosters would compromise every installation. Android UnifiedPush can
  be an expert-only alternative, but it does not provide ordinary iPhone
  delivery or a competitive default experience.
* **(c) An optional NOOP-operated push relay.** This is the practical route to
  cloud-grade delivery for the signed store apps. Keep it minimal: explicit
  opt-in, separate device-registration credentials, short-lived opaque or
  end-to-end-encrypted payloads, no wellness values in provider-visible text,
  no advertising identity, bounded logs, deletion and key-rotation support,
  and an independent privacy/security review. It changes the "no
  NOOP-operated cloud" posture even if biometric computation and storage remain
  local.

Recommendation: **(a) for the first honest release.** Choose (c) deliberately
if measured background reliability is insufficient. Do not present (b) as a
general solution for the signed store builds and do not distribute provider
credentials.

### P1 — Delivery evidence exists locally; fleet visibility still does not

Local-first with no telemetry means a notification that never fires is invisible to you. Competitors run
crash reporting, staged rollout, remote config, and a kill switch as table stakes.

The minimum privacy-preserving code is now present:

* Apple and Android keep a bounded local lifecycle ledger containing only
  stable identifiers, category, state, and time. Scheduled means the OS accepted
  the request; presented means an app callback was observed. It never claims an
  unobserved banner or vibration happened.
* Diagnostics exports include that ledger without notification copy, health
  values, routes, or credentials.
* The paging kill switch is database-backed, revisioned, audited, and waits for
  already-started provider submissions before returning.

This still does not provide fleet crash telemetry, synthetic checks, or alert
delivery for a NOOP-operated service. Those require an explicit opt-in telemetry
and hosting decision.

---

## 2. What competitors have that NOOP does not

Grounded in Garmin's own documentation and each product's shipping feature set.

| Capability | Them | NOOP | Verdict |
|---|---|---|---|
| **Incident detection** (auto-alert on a crash) | Garmin: during **certain outdoor activities only**, sends automated message + LiveTrack link + GPS to emergency contacts. Their manual: *"supplemental… should not be relied on as a primary method… does not contact emergency services on your behalf."* | `FallResponse` exists but is **inert by design**; no validated detector | **The real gap, and legitimately closable — see §3** |
| **Fall / crash detection** | Apple Watch, 24/7 fall detection + vehicle crash detection | Not available, deliberately | Needs a validated detector; Apple has bespoke hardware + years of data |
| **Live location sharing** | Garmin LiveTrack / GroupTrack — friends follow in real time | Live location exists only for an **active SOS page** (migration 007) | Moderate gap; the plumbing is already there |
| **Emergency services dispatch** | Apple SOS (incl. satellite) | Never — explicitly out of scope | Correct call. Do not chase this |
| **Cloud push reliability** | All of them | Local only | See §1 P1 |
| **3rd-party sync** (Strava, Garmin, Fitbit) | Standard | Listed as a gate, not built | Real adoption blocker: people will not abandon their history |
| **Teams / social** | WHOOP teams, Garmin challenges | Private Friends only (invitation-only, 6-field, no directory) | Deliberate; the privacy stance is the differentiator |
| **Coaching content** | WHOOP Coach, Garmin training plans | AI Coach with user's own API key | Different model, arguably better (no vendor lock) |
| **Delivery receipts for alerts** | Garmin/Apple surface send status | Unique contacts reached and last-reached time are surfaced | Implemented; real-carrier evidence remains |

## 3. The one feature worth building, and how to do it honestly

**Activity-scoped incident detection.** Garmin's framing is the unlock: it fires only during *recorded
outdoor activities*, it is documented as *supplemental*, and it does **not** call emergency services. That
is a **safety** feature, not a medical-device claim — and it sits inside NOOP's existing boundary rather
than violating it.

Why this is tractable where 24/7 medical anomaly detection is not:
* the user has **started an activity**, so context is known and false positives are cheap to tolerate;
* a crash/fall during cycling or running has a **motion signature**, not a physiological one — no
  diagnostic claim required;
* there is a **cancellation window**, so a false positive costs an annoyance, not a false alarm to contacts;
* NOOP's paging pipeline (leases, retries, ack, cancel) is **already built** for exactly this.

What it still needs, and none of it is optional:
1. Motion streaming from the band at a documented rate — `FallResponsePolicy` already requires ≥50 Hz over a
   ≥1 s window with worn-state evidence ≤2 s old. Honour that contract.
2. A detector validated on **staged events and hard negatives** (dropping the phone, setting the band on a
   table, a bumpy descent). Publish precision/recall and false-positive-per-day.
3. Confirmed haptic delivery before the countdown starts — already in the contract.
4. A cancellation window that is reachable **without unlocking**, and accessible.
5. Copy that mirrors Garmin's caution verbatim in spirit: supplemental, not a primary means of summoning
   help, does not contact emergency services.

Until 1–2 exist, keep it inert. The gate is right.

## 4. Where NOOP already beats all of them

Worth protecting, because these are the reasons to choose it:

* **No account, local-first.** Nobody else offers this. It is the whole pitch.
* **Multi-device.** WHOOP + Oura + Xiaomi + Apple Health in one app; every competitor is single-ecosystem.
* **Glass-box scoring.** Provenance chips, cited constants, and a hard no-fabrication rule — verified this
  week against real arrhythmia data and hostile inputs (`docs/validation/RHYTHM-REAL-DATA-FINDINGS.md`).
  No competitor will tell you *why* your recovery is 51 or admit when it cannot say.
* **Resonance HRV biofeedback with strap haptics** — genuinely ahead of WHOOP.
* **Data portability**: encrypted export, integrity manifests, no lock-in.
* **Nine locales** already at parity for generated copy.
* **Price.**

## 5. Ordered plan

**Now (unblocks everything)**
1. Rights: clean-room the 15,980 lines, contributor consent, pick a posture.
2. Twilio procurement + A2P/10DLC registration — long lead, start before you need it.
3. Choose cloud/regions, identity and recovery provider, launch countries,
   RPO/RTO, on-call/monitoring vendor, and infrastructure budget.

**Next (makes alerts real)**
4. Run the full carrier matrix and publish the evidence table + p95 delivery latency.
5. **Done in code:** user-visible receipt and all-contacts-failed recovery.
6. **Done in code:** bounded local notification lifecycle ledger in diagnostics.
7. **Done in code:** revisioned, audited paging kill switch with submission permits.
8. **Done in code:** shared installation isolation, credential lifecycle,
   installation-wide erasure, Safety retention, and restore contracts.

**Then (closes the reliability gap)**
9. Physical-device background-sync evidence: reboot, process death, DST, airplane mode, OEM battery
   killers, plus 24-hour battery drain — the number buyers compare.
10. Decide local-only vs an optional minimal push relay (§1 P1), and make the
    architecture, privacy disclosure, and copy match that choice.

**Then (closes the competitive gap)**
11. Activity-scoped incident detection per §3, with published false-positive rates.
12. Third-party import (Strava/Garmin/Fitbit) so switchers keep their history.
13. Publish the accuracy validation. This is the moat, and it compounds: every competitor asks for trust,
    only you would be showing your work.
