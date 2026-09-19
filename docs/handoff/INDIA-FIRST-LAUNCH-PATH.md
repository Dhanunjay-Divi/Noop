# India-first launch path

**Original assessment:** 2026-08-26 · **Guidance reconciled:** 2026-09-18 ·
**Sequence:** India, then USA

The 2026-08-26 inventory found no India-specific release coverage. That is
historical context, not the current plan: later release documents now identify
India-first hardware, privacy, store, ownership, and communications gates.
Documentation does not establish approved legal artifacts, carrier
registration, certification, locale quality, or launch evidence.

> **Current release direction:** the active local-only-v1 recommendation is
> superseded. Core collection, scoring, local history, export, and supported
> local controls remain local-first. A first-party band uses a narrow ownership
> account and one-time network claim; its supplier-independent foundation is
> only `PARTIAL`. Cooling-off deletion coordination exists, while
> supplier-backed possession, provider identity erasure, approved band
> retirement/wipe, billing, recovery/release, legal approval, physical
> evidence, and production operation remain open. NOOP+ health-data services
> remain a separate explicit opt-in.
>
> The first Safety transport is manual app-to-app paging of accepted NOOP
> Safety contacts. Precise location is off by default and requires explicit
> incident-scoped consent; only the latest location may be retained during the
> selected 8- or 12-hour window. SMS/voice remains disabled unless carrier or
> DLT registration, legal review, physical delivery, monitoring, failover, and
> staffed operations pass. Band-triggered and automatic paging remain separate
> later gates.

---

## The good news first: local-first is a structural advantage under DPDP

India's **Digital Personal Data Protection Act 2023** attaches its obligations to a *Data Fiduciary*: an
entity that determines the purpose and means of processing digital personal data. Notice and consent,
Data Principal rights (access, correction, erasure), grievance redressal, breach notification, and
penalties up to Rs 250 crore all follow from that status.

Keeping core health data on device reduces the server-side data surface and
preserves useful offline behavior. It does not erase NOOP's obligations for the
ownership records, accepted Safety contacts, incident state, consented
location, or any NOOP+ data the service actually processes. Public claims must
match the enabled production data flows and approved India privacy analysis.

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

### 2. TRAI DLT registration, only if SMS/voice fallback ships
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

The 2026-08-26 assessment had no controlled carrier-delivery evidence. Current
release status must come from the production-readiness record; source
automation alone cannot close DLT, carrier, legal, physical-phone, monitoring,
failover, or operations gates.

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

## Current sequencing: local-first core with narrow network services

The earlier recommendation to ship v1 with no account, server, or paging is no
longer active. The current release scope is narrower than a cloud-authoritative
product but is not local-only:

| Capability | India first-release direction | Gate |
|---|---|---|
| Core health experience | Keep collection, scoring, local history, export, and supported local controls on device and useful without NOOP+ or continuous network access | Physical band, data-integrity, performance, privacy, signing, and store evidence |
| Band ownership | Use the narrow ownership account and one-time claim; do not treat it as NOOP+ or health-data consent | Foundation is `PARTIAL`; cooling-off deletion, durable target progress, and restricted managed-data erasure coordination exist default-off, while supplier possession, provider/control-plane final erasure, physical retirement/wipe, billing, recovery/release, legal, physical, and production gates stay open |
| Safety primary transport | Manual app-to-app paging of accepted NOOP Safety contacts | Production APNs/FCM relay, accepted-contact authorization, explicit location-consent journey, latest-only retention/deletion, physical-phone/background delivery, monitoring, legal, and staffed operations |
| SMS/voice fallback | Keep disabled for the app-to-app launch path | Enable only after DLT entity/header/templates, carrier delivery, legal review, physical-phone tests, monitoring, failover, and staffed operations |
| NOOP+ | Keep a separate explicit opt-in; do not make it a prerequisite for core band use | Enable each managed-data feature only after its consent, identity, privacy, security, portability, deletion, load, recovery, and production gates pass |

App-to-app Safety and the ownership claim still require managed production
services. DLT does not gate an app-only push path, but it becomes mandatory
before enabling SMS/voice fallback in India.

---

## Architecture recommendation: preserve local-first core

Do not move core scoring or current local history behind a network dependency.
The production architecture may use managed services only for bounded,
explicit purposes:

1. **Ownership:** retain identity and control state needed to claim and recover
   a first-party band, with no health payload and no implication of NOOP+
   consent.
2. **Safety:** relay manual app-to-app pages only to accepted contacts. Keep
   push payloads opaque; require explicit incident-scoped consent before
   location sharing; retain only the latest location for the bounded incident;
   delete incident data at its terminal lifecycle point.
3. **NOOP+:** upload only the data classes selected through a separate opt-in
   disclosure and consent flow. Cancellation cannot deactivate a claimed band
   or remove core local capability.
4. **SMS/voice:** treat these as disabled fallback transports until India DLT,
   carrier, legal, physical-phone, monitoring, failover, and staffed-operations
   evidence exists.

This preserves offline usefulness and limits server data while acknowledging
that ownership, app-to-app Safety, and any enabled NOOP+ feature create real
privacy, security, availability, deletion, support, and incident-response
obligations.
