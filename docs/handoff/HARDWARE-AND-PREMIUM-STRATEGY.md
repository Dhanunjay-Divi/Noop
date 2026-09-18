# Noop Band + premium services: what this actually requires

**Assessed:** 2026-08-26 · **Model:** paid hardware + paid premium tier · **Markets:** India, then USA

> **2026-09-05 update:** the owner has confirmed an account-bound first-party
> band claim and a visible NOOP/NOOP+ choice before Home. The account is an
> activation and ownership boundary, not a subscription gate: an activated
> band and every core local metric continue without NOOP+ or payment. The
> current direction also removes user-facing v1 unpair, serves terms remotely,
> and leaves the 14- versus 30-day return window and condition deductions open.
> The detailed current contract and open legal/support exits are in
> [`../FIRST_PRODUCTION_RELEASE_PLAN.md`](../FIRST_PRODUCTION_RELEASE_PLAN.md).

---

## 1. Where you actually are, stated plainly

There is no Noop hardware in this repository, and the app does not yet know what one is.

```swift
// Packages/WhoopStore/Sources/WhoopStore/PairedDevice.swift:32
let isLegacyCompatibleBand = id == "my-whoop"
return isLegacyCompatibleBand ? "Compatible band" : name

// Strand/BLE/WhoopModel.swift
case whoop4   = "WHOOP 4.0"
case whoop5mg = "WHOOP 5.0 / MG"           // the only two device types that exist
```

- No `firmware/`, `device/` or `hardware/` directory.
- No NOOP-native device type, transport, or protocol.
- No StoreKit, no server billing, no entitlement model.

NOOP already contains a broad companion-app, storage, analytics, and provenance
foundation, but that source breadth is not physiological or population
validation. Claim-specific sensor, sleep, workout, and score evidence remains
open. The hardware program is close to entirely net-new, and it is a different
kind of undertaking from the app: certification and manufacturing have
calendars that no amount of engineering speed compresses.

I am telling you this bluntly because every plan below depends on the distinction between "we have an app
that reads WHOOP straps" and "we have a product that replaces WHOOP."

---

## 3. The tension you must resolve deliberately: local-first vs premium

You have two commitments that pull against each other:

- **Local-first core use without a continuous cloud or subscription
  dependency** is the durable differentiator. App exploration remains
  account-free; a first-party band has only the narrow ownership-claim
  exception documented in the release plan.
- **"Premium services"** implies accounts, servers, billing, and recurring revenue.

Resolved carelessly, you become a worse WHOOP: same cloud, same subscription, less brand. Resolved well,
you get a story stronger than anything in the market.

**The resolution: split on whether a feature physically requires a server.**

| Tier | Contents | Requires server? |
|---|---|---|
| **Core NOOP** | Available local metrics, records, coaching, and export, subject to source availability, missing-data rules, and claim-specific validation. App exploration is account-free; a first-party band has a narrow one-time ownership claim. | No continuous server dependency |
| **Managed capabilities** | Separately consented NOOP+ backup/sync and social features; separately authorized app-to-app Safety paging of accepted contacts. Safety is contact paging, not emergency dispatch, and is not made available merely by buying NOOP+. | Yes, where the feature requires rendezvous or relay |

Two reasons this specific split is the right one:

1. **It is honest.** Managed backup, cross-device social features, and
   app-to-app Safety relay require a server boundary. That does not guarantee
   delivery from a suspended or offline phone, and SMS/voice remains disabled
   behind separate release gates. Pricing should cover a real managed service,
   not withhold a number already computed locally.
2. **It preserves the product boundary.** After supported activation, core
   local capability does not depend on a NOOP+ subscription or continuous
   network access. That is an architecture commitment, not a claim about
   hardware lifetime, compatibility duration, or future support.

**The line to never cross:** no core metric ever moves behind the paywall, and no core metric ever requires
the network. The moment Recovery needs a subscription, you are WHOOP with worse distribution.

### One hard consequence for Friends

Recovery is personalized against each wearer's own baseline, so a raw score
must not be treated as a validated between-person ranking. Friends should use
non-competitive quantities such as streaks, consistency, adherence, or
within-person change unless a separately designed population study establishes
comparability.

---

## 4. The hardware program, which is the real work

Software estimates do not apply here. These are calendar items with external gatekeepers.

### Certification (start immediately; these gate revenue)

| Item | Market | Notes |
|---|---|---|
| **BIS** (CRS registration) | India | Mandatory for electronics. Weeks to months. |
| **WPC / ETA** | India | Mandatory radio approval for Bluetooth. |
| **FCC** (Part 15) | USA | Mandatory for any intentional radiator. |
| **Bluetooth SIG** membership + qualification | Both | Legally required to ship a BT product and use the marks. Budget membership plus per-design qualification. |
| **UN38.3 / IEC 62133** | Both | Lithium cell shipping and safety. Blocks air freight without it. |
| **CDSCO / FDA** | Both | **Avoidable, and stay avoiding it.** See below. |

**Stay out of medical-device regulation, deliberately.** Your existing not-a-medical-device posture, the
inert `FallResponse`, and the absence of ECG/AFib/BP claims keep you outside CDSCO and FDA. The moment
marketing says "detects" anything clinical, you enter a regime that costs years and a quality-management
system. WHOOP has FDA-cleared ECG because WHOOP has a regulatory department. **Your restraint here is a
competitive advantage, not a gap.**

### Firmware, which does not exist yet

The pieces you will need, roughly in dependency order:

1. **Sensor stack**: PPG front-end (HR, HRV, SpO2), accelerometer, skin temperature. R-R interval quality
   is the one that matters most for you specifically, because your Recovery weights HRV at 0.55 and your
   sleep staging needs R-R that the Walch dataset lacked. **Your own hardware is the chance to fix the
   3.7% REM recall by capturing R-R and respiration properly.**
2. **Power management**: WHOOP ships 14+ days. This is the hardest single constraint and it dictates
   sampling rates, which dictates metric quality. Decide the tradeoff explicitly and early.
3. **BLE protocol**: your own framing, commands, historical backfill, clock sync. Design for the failure
   modes the app already learned the hard way: gap-aware backfill, clock drift, partial sessions.
4. **OTA update path.** Non-negotiable. You will ship firmware bugs; without OTA every bug is an RMA.
5. **Secure boot + device identity/attestation.** Each unit needs a provisioned identity, both for pairing
   security and so premium entitlements can bind to hardware.
6. **Manufacturing test fixtures**, calibration per unit, yield tracking.

### Operations, which is what a hardware company actually is
RMA and warranty policy, spares, packaging and regulatory inserts per market, customs and import,
support staffing, and a firmware rollback plan. Budget for the fact that a 2% RMA rate on a physical
product is an ongoing operational cost with no software equivalent.

---

## 5. Premium infrastructure, since you are willing to spend

**Spend on the boring reliable things, not on scale you do not have.**

### Do
- **Managed Postgres with PITR** (Timescale for the series data). Not self-managed on a droplet: a lost
  backup is worse than a large bill. `server/` already targets Postgres/Timescale.
- **Two regions, aligned to market**: India (Mumbai) and US. Latency matters less than data locality for
  DPDP comfort and user trust.
- **Restore drills, quarterly, written down.** A backup you have never restored is a hypothesis. Your own
  `RELEASE-BLOCKERS.md` gate 4 already demands this.
- **Paging worker on redundant infrastructure.** `server/app/safety_worker.py` exists; if the SOS path has
  a single point of failure you have a safety feature that fails silently.
- **Provider redundancy only if SMS/voice is later enabled.** Do not enable that
  fallback until carrier or DLT, legal, physical-delivery, monitoring, failover,
  and staffed-operations gates pass.
- **Secrets in a real manager**, not env files on a box.
- **Monitoring with actual on-call**, at minimum for the paging worker.

### Do not
- Do not put scoring on the server. It costs money, adds latency, breaks offline, and forfeits the moat.
- Do not build your own auth. Use platform identity; every rolled-your-own auth is a future incident.
- Do not over-provision for imagined scale. Your gate-4 target is 10,000 users; that is one well-configured
  managed Postgres, not a Kubernetes estate.

### Billing, where both markets have specific traps

**India, and this one surprises people:**
- **RBI e-mandate rules govern recurring card payments.** Auto-debit requires registration, an additional
  factor of authentication, a pre-debit notification to the user, and per-transaction limits above which
  explicit approval is needed. **A naive Stripe subscription does not work in India.** Use Razorpay or a
  provider with native e-mandate/UPI-AutoPay support, and expect UPI AutoPay to be the dominant rail.
- **In-app digital subscriptions must use Apple/Google IAP**, which handles Indian rails but takes 15-30%.
- **Hardware sales are a separate flow** and must not go through IAP. Keep the storefront and the
  subscription completely separate, because mixing them is a store-rejection risk.
- GST registration and e-invoicing for the hardware business.

**USA:**
- **Washington's My Health My Data Act is the trap.** It defines consumer health data broadly, requires
  specific consent, and carries a **private right of action**, meaning individuals can sue directly. Any
  US health app collecting server-side data needs this analysed before launch, not after. Nevada has a
  similar law.
- HIPAA most likely does **not** apply, since you are not a covered entity or business associate. Do not
  claim HIPAA compliance as marketing; it is both wrong and a red flag to anyone who knows.
- CCPA/CPRA if you reach California thresholds.
- FTC Health Breach Notification Rule now explicitly reaches health apps.

**The structural point:** premium services turn you into a Data Fiduciary under DPDP and a regulated
health-data holder in several US states. **That liability is the actual cost of the premium tier**, larger
than the hosting bill. Which is another argument for keeping the free tier fully local: the cheapest data
to protect is the data you never receive.

---

## 6. Sequencing

**Now, in parallel, before writing more code**
1. Trademark "NOOP" and "Noop Band" in India (CGPDTM) and the US (USPTO).
2. Open BIS, WPC/ETA, FCC and Bluetooth SIG processes. Longest lead, start first.
3. Decide the free/premium line and write it down as a product invariant.

**Then: v1 app, local-first**
Ship the bounded first-release scope from `INDIA-FIRST-LAUNCH-PATH.md`: core collection, scoring,
history, and export stay local-first; the narrow ownership account and manual app-to-app paging of
accepted Safety contacts remain gated network services. NOOP+ health-data storage and SMS/voice
fallback stay disabled until their separate production gates pass.

**Then: hardware bring-up**
Firmware, own protocol, R-R and respiration capture done properly, OTA, provisioning, manufacturing test.
Use this to retire the WHOOP protocol dependency and the licensing residue at the same time.

**Then: premium, one feature at a time**
Enable NOOP+ features only after their consent, encryption, restore, deletion, and operations gates
pass. SMS/voice Safety fallback remains last because it needs DLT or carrier registration, legal
review, provider failover, staffed operations, and the full physical-phone matrix.

---

## 7. The two things most likely to kill this

1. **A safety feature that fails silently.** Paging that Focus mode suppresses, or a single-provider SMS
   path, or a worker with no on-call. The reputational damage from one failed SOS exceeds every other risk
   here, which is why paging should ship last and with redundancy.
2. **Diluting the free tier.** The moment a core metric needs a subscription or the network, the only
   story competitors cannot copy is gone, and you are a small WHOOP.
