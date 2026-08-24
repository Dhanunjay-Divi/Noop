# Productionising NOOP: alerts, notifications, and the competitive gap

**Date:** 2026-08-24 · **Assessed against:** Garmin Connect, WHOOP, Oura, Apple Watch

---

## 0. The honest headline

The alert and notification code is in **better shape than expected**. I audited all 13 notification
producers and the 3,669-line paging pipeline and found **no defects** in the notification layer:

* every scheduler checks authorization before scheduling, so nothing fails silently;
* every request uses a **stable identifier**, so `add()` replaces rather than duplicates;
* `removePendingNotificationRequests` is used where re-scheduling needs it;
* the paging pipeline already implements leases (60 references), idempotency (36), retries (31),
  SMS-first with voice fallback, provider receipts, DTMF acknowledgement, signed responder links,
  cancellation, expiry, and privacy-safe monitoring.

What is missing is **not code**. It is three things: **evidence**, **a delivery path that survives a
sleeping app**, and **the rights to ship at all**.

---

## 1. What actually blocks a launch, in order

### P0 — Distribution is blocked, and no amount of feature work changes that

```
$ python3 Tools/release-legal-gate.py distribution
ERROR: DISTRIBUTION BLOCKED: repository independence is not established
(contributor-relicensing-rights, polyform-upstream-lineage, unlicensed-whoop4-expression).
```

Productionising alerts for an app that cannot legally ship is motion without progress. See
`docs/handoff/RELEASE-BLOCKERS.md`. Everything below assumes this is being worked in parallel.

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
7. Decide and document behaviour when **all** contacts fail. Silence is unacceptable; the user must be told
   the page did not land.
8. Add a **user-visible delivery receipt** in the app ("Reached 2 of 2 contacts at 14:03"). Garmin and Apple
   both surface this; without it the user has no idea whether the feature worked.

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
* **(b) Optional push via the user's own self-hosted server.** NOOP already has one, with sync. Let a user
  who runs it opt into server-side scheduling and push. This is the strategically best answer: it keeps
  "no NOOP-operated cloud" intact while giving power users cloud-grade reliability. Cost: APNs/FCM
  credentials handling in a self-hosted context, which is fiddly but solved.
* **(c) A NOOP-operated push relay.** Matches competitors' reliability, breaks the core promise. Only worth
  it if reliability data shows (a) and (b) are insufficient.

Recommendation: **(a) now with honest copy, (b) as the differentiated answer.** Do not do (c) without a
deliberate strategy change.

### P1 — You are flying blind on delivery and crashes

Local-first with no telemetry means a notification that never fires is invisible to you. Competitors run
crash reporting, staged rollout, remote config, and a kill switch as table stakes.

Minimum viable, without betraying the privacy stance:
* an **opt-in**, on-device diagnostics log for the notification and paging path, exportable as a bundle in
  one tap (the log export already exists — make the path from "it's wrong" to a reproducible bundle short);
* a **local delivery ledger** the user can inspect: what was scheduled, what fired, what was suppressed and
  why. This doubles as your support tool and as the transparency feature nobody else has;
* a **remote kill switch for paging** — if a carrier or provider misbehaves you need to disable outbound
  paging without shipping a build. This one genuinely needs a server flag.

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
| **Delivery receipts for alerts** | Garmin/Apple surface send status | Not surfaced to the user | Small, high-trust win — do it |

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

**Next (makes alerts real)**
3. Run the full carrier matrix and publish the evidence table + p95 delivery latency.
4. Add the user-visible delivery receipt and the all-contacts-failed path.
5. Ship the local delivery ledger (support tool + transparency feature in one).
6. Add the paging kill switch.

**Then (closes the reliability gap)**
7. Physical-device background-sync evidence: reboot, process death, DST, airplane mode, OEM battery
   killers, plus 24-hour battery drain — the number buyers compare.
8. Decide local-only vs self-hosted push (§1 P1), and make the copy match whichever you choose.

**Then (closes the competitive gap)**
9. Activity-scoped incident detection per §3, with published false-positive rates.
10. Third-party import (Strava/Garmin/Fitbit) so switchers keep their history.
11. Publish the accuracy validation. This is the moat, and it compounds: every competitor asks for trust,
    only you would be showing your work.
