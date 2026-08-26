# India-first launch path

**Assessed:** 2026-08-26 · **Sequence:** India, then USA
**Current India coverage in this repository: none.** Zero references to DPDP, TRAI/DLT, BIS, WPC/ETA,
CDSCO, or India in any doc or server file. No Indian locale ships. Every compliance artefact built so far
(A2P 10DLC, 11 references) targets the **second** market.

---

## The good news first: local-first is a structural advantage under DPDP

India's **Digital Personal Data Protection Act 2023** attaches its obligations to a *Data Fiduciary*: an
entity that determines the purpose and means of processing digital personal data. Notice and consent,
Data Principal rights (access, correction, erasure), grievance redressal, breach notification, and
penalties up to Rs 250 crore all follow from that status.

**If health data never leaves the device, NOOP is not processing it as a fiduciary.** That is not a
loophole; it is the architecture doing real work. NOOP's account-free, local-first design is the single
most defensible privacy position of any wearable app in this market, and it should be stated plainly in
store copy because it is a genuine differentiator, not marketing.

**The moment a server holds another person's data, that changes.** Friends profiles and paging contacts on
a hosted droplet make NOOP a Data Fiduciary for those records, with the full obligation set attached. That
is the real cost of the server path, and it is a governance cost, not a hosting cost.

---

## P0 India gates, in dependency order

### 1. Hindi locale (missing, and cheap)
Shipped locales are `de, en, es, fr, it, pt-PT, ru, zh-Hans, zh-Hant`. **There is no `hi`.** The app ships
Russian and European Portuguese but not the majority language of its first market.

English-only is arguably viable for the initial urban early-adopter segment, and that is a legitimate
scoping decision. But it should be a decision, not an oversight. Note the existing 8 `needs_review` cycle
translations remain open regardless.

### 2. TRAI DLT registration, if paging ships (long lead, blocks nothing else)
India does **not** use A2P 10DLC. Commercial SMS requires registration on a telecom operator's
**Distributed Ledger Technology** platform, and it is a three-part process, each part a separate approval:

1. **Entity registration** — the legal entity, on a DLT portal (Jio, Airtel, Vi, BSNL).
2. **Header registration** — the 6-character sender ID.
3. **Content template registration** — **every message template must be pre-approved before it can send.**

Two consequences specific to NOOP:

- **Template pre-approval collides with localisation and with dynamic copy.** Safety messages cannot be
  assembled freely at runtime; the template must match what was registered, with variables in registered
  positions. `SafetyPagingService` copy needs auditing against this constraint before registration, not
  after.
- **DND scrubbing and category matter.** Safety paging should qualify as transactional or service-implicit
  rather than promotional, which exempts it from the 9pm-9am promotional window. Getting the category
  wrong means safety messages are silently dropped at night, which is precisely when they matter. This
  must be verified with the operator, not assumed.

`NOOP_RUN_TWILIO_STAGING` has still never been run, so **paging delivery has never been proven on any
carrier in any country.**

### 3. CDSCO: stay out of it deliberately
Software as a Medical Device is regulated under India's Medical Devices Rules 2017 via **CDSCO**. NOOP's
existing "not a medical device" posture, its inert-by-design `FallResponse`, and the absence of any
ECG/AFib/BP claim keep it outside that regime. **This is worth protecting as a product decision.** The
same restraint that makes NOOP honest also keeps it out of a licensing lane that would take a solo
founder years.

Corollary: the disclaimer wording should be reviewed for India, and no store copy should imply diagnosis,
screening, or treatment.

### 4. Hardware: BIS and WPC/ETA (the longest lead of all)
For the Noop Band itself, not the app:
- **BIS registration** under the Compulsory Registration Scheme for electronics.
- **WPC / ETA** equipment type approval for the Bluetooth radio.

Both are mandatory to sell or import, and both are measured in weeks-to-months. **If the band ships in
India, start these now**, because they gate revenue and nothing in software can compress them.

### 5. Store records
Play Store and App Store India declarations, health-data disclosures, and data-safety forms. If NOOP
charges anything, Apple and Google IAP handle Indian payment rails, which avoids direct RBI exposure.

---

## Recommended sequencing: descope v1 to remove the two longest gates

The current `RELEASE-BLOCKERS.md` has eight P0 gates. **Two of them, server operations (4) and paging
delivery (5), account for most of the calendar time**, and both are avoidable in a first release.

**Ship v1 as local-only: no server, no Friends, no paging.**

| Gate | v1 local-only | Full scope |
|---|---|---|
| 0. Source rights | **required** | required |
| 1. Stabilise and publish | required | required |
| 2. Release identity | required | required |
| 3. Store records | required | required |
| 4. Server operations | **removed** | Postgres/Timescale, TLS/DNS, backups, restore drills, RPO/RTO, 10k load |
| 5. Paging delivery | **removed** | DLT entity + header + templates, controlled real-phone matrix |
| 6. Physical devices | required | required |
| 7. Measurement evidence | required | required |
| 8. Automatic inference stays off | required (free) | required |

That removes DLT registration, droplet operations, and the entire safety-delivery evidence matrix from the
critical path, and it removes NOOP's exposure as a DPDP Data Fiduciary at launch. What remains is a
coherent, honest product: local-first biometrics with cited metrics and no cloud.

Then Friends in v1.1 and paging in v1.2, with DLT registration running in parallel from now, since it
takes longer than the code will.

---

## Architecture recommendation: keep computation local, permanently

The server should stay what it already is: **optional, off by default, self-hosted, no telemetry.** Do not
move scoring to a droplet. Reasons, in order of weight:

1. **It is the product.** "No cloud, no account, no subscription" is the only claim no competitor can copy
   without abandoning their business model.
2. **DPDP.** Local computation keeps NOOP out of Data Fiduciary status for the health data itself.
3. **Offline is a feature.** Scores currently work on a plane, in a tunnel, with no signal. Server-side
   scoring trades that away for nothing the user asked for.
4. **Cost and blast radius.** A solo founder running health data for others inherits uptime, backup,
   breach-notification and incident duties permanently.

**The one genuine exception is paging**, and it is unavoidable: you cannot send an SMS from a phone whose
battery is dead, which is exactly the scenario the feature exists for. So paging needs a server-side
escalation worker, which `server/app/paging.py` and `safety_worker.py` already implement. Keep that
component **as thin a relay as possible** and store nothing on it that is not strictly required to
escalate.
