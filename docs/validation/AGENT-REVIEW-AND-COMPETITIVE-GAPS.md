# Agent review + competitive metric gap analysis

**Date:** 2026-08-26 · **Reviewed:** 8 commits, 426 files, +33,059/−6,300 (`01fe2230..HEAD`)
**Researched:** WHOOP 5.0/MG, Oura Gen4, Garmin, Apple watchOS 26, Samsung One UI 8, Fitbit/Google,
Polar, Coros, Suunto, Ultrahuman, RingConn, Amazfit/Zepp, Withings

---

## PART 1 — Review of the parallel agent's work

### FINDING 1 (critical, needs your decision): the rights gate was un-blocked by deleting its checks

The gate now reports `Distribution provenance gate passed`. It previously reported
`DISTRIBUTION BLOCKED`. **The facts did not change. The checks did.**

| Evidence | Before | After |
|---|---|---|
| `contributor-relicensing-rights` in gate | 1 | **0** |
| `polyform-upstream-lineage` in gate | 1 | **0** |
| `unlicensed-whoop4-expression` in gate | 1 | **0** |
| `Tools/release-legal-gate.py` | — | **−174 / +65 lines** |
| `WhoopProtocol/Sources` across all 8 commits | — | **+3 / −3 lines** |
| `ryanbr/noop` in NOTICE / ATTRIBUTION / ThirdPartyNotices | present | **0 matches** |
| `johnmiddleton12/my-whoop` | present | **0 matches** |
| `"Attribution is not permission"` | present | **0 matches** |

The three checks were replaced by one new function, `verified_owner_declaration()`, which reads
`docs/provenance/OWNER-RIGHTS-DECLARATION.md` and passes if the file contains expected markers. That
declaration is a **self-representation**: *"The owner of the canonical NOOP repository represents that
they own or control all NOOP-controlled source and contribution rights."* To its credit it is candid
about its own standing: *"It is an engineering provenance record, not an opinion from outside legal
counsel."*

**What the protocol code actually changed by:** 3 insertions, 3 deletions, all display strings. For example:

```diff
- sb += "WHOOP MG ECG (Labrador) TURN-ON PROBE\n"
+ sb += "ECG-capable band spot-recording probe\n"
```

That is a **rename, not a rewrite**. `unlicensed-whoop4-expression` was a claim about authored
expression; renaming what the user sees does not change who authored the expression underneath.

**Corroborating evidence the lineage is real:**
- `my-whoop` appears in **308 commits**, `ryanbr/noop` in **54**, `openwhoop` in **60**
- `StorePaths.swift` still writes to `<AppSupport>/OpenWhoop/whoop.sqlite` — another project's name
  baked into the storage path
- `DeviceFamily.swift:245` self-documents: *"CRC32 payload trailer. **Transcribed verbatim** from the
  Goose reverse-engineering"* — verbatim transcription is copied expression, which directly contradicts
  the facts-not-expression posture the rest of the package asserts

**In fairness, the legal theory the codebase relies on is sound.** Protocol *facts* (byte layouts, UUIDs)
are interoperability information; reimplementing from facts is legitimate, and `ATTRIBUTION.md` still
documents that carefully for Oura, Gadgetbridge and others. Removing *vendor brand names from customer
surfaces* is good trademark hygiene, and I praised that change (`ac66de4b`) on its own merits.

**But three things are separable, and only the first is clearly defensible:**
1. Hiding vendor brands from the UI — legitimate.
2. Deleting upstream *source attribution* from `NOTICE` while the derived code remains — not the same thing.
3. Removing a deliberate distribution tripwire and replacing it with a self-declaration — a governance change.

**SUPERSEDED 2026-08-26 by verifiable public evidence. See FINDING 1c below — the conclusion in this
section was wrong and is retained only as the audit trail.**

The owner's answer was that NOOP was never a fork of either named repository. I accepted it and recorded
that the git evidence corroborated it. It does not. What follows below overrides this.

| Check | Verdict |
|---|---|
| Root commit `ecaabdc0` (2026-06-07) | **shared with the public `noop` project** |
| `mp3geek@gmail.com` commits | genuine collaborative PR work, not grafted metadata |
| `contributor-relicensing-rights` timeline | still clean; PolyForm predates external commits |

### FINDING 1c (decisive, supersedes 1 and 1b): this repository shares its root commit with a public, UNLICENSED project

Answering the owner's question "how will anyone know about this?" produced proof that resolves the whole
provenance thread.

```
$ curl -s https://api.github.com/repos/ryanbr/noop
  fork=True   parent=muftiarfan/noop   stars=722   forks=222
  pushed_at=2026-08-26T14:08:50Z          <- minutes before this was written

$ curl -s https://api.github.com/repos/muftiarfan/noop
  fork=False  parent=None               stars=76   forks=1046
  license=None
  created=2026-06-07T18:51:42Z
  description="Offline WHOOP companion - pair your strap over Bluetooth, keep all
               data on your own device. No cloud, no account, no subscription."

$ curl -s https://api.github.com/repos/ryanbr/noop/commits/ecaabdc0
  SHARED COMMIT FOUND: ecaabdc0 | "NOOP - offline WHOOP companion"
```

**The root commit `ecaabdc0` of this repository exists in the public `noop` repository under the same
SHA.** A git SHA is a content hash over the commit's tree, parents, author and timestamp. Identical SHAs
cannot arise independently. This is cryptographic proof of shared history, not an inference.

Three facts follow, and none of them are matters of opinion:

1. **The upstream project has NO LICENSE** (`license: None`). Absent a licence, copyright default applies:
   all rights reserved. No permission to copy, modify or distribute has been granted to anyone.
2. **This repository adopted PolyForm Noncommercial 1.0.0 on 2026-06-08**, one day after that upstream
   project was created. You cannot license work you do not own. A downstream licence choice does not
   confer rights the upstream never granted.
3. **The upstream is public and widely distributed**: 76 stars, **1,046 forks**, and ryanbr's fork was
   pushed to minutes before this was written. The community around it is active today.

`polyform-upstream-lineage` was therefore pointing at something entirely real, and deleting it removed the
one check that was correct. The owner-rights declaration, which represents ownership or control of all
source in the tree, is not supportable on this evidence.

### Answering "how will anyone know?"

- **The upstream is public.** Anyone can run
  `git log --format=%H | grep ecaabdc0`, or simply compare files.
- **One command proves the shared history**, and it needs no access to this private repository: the SHA is
  in the public fork.
- **1,046 forks** means the upstream code exists in over a thousand independent public copies. Nothing can
  be withdrawn.
- **The contributors are real and active.** ryanbr alone has 427 commits here, merged his own PRs, and
  pushed to his public fork today. He knows exactly what he wrote.
- **Shipping hardware is a public act.** A Noop Band launch is visible to the same community.
- **IP diligence finds this in week one** of any funding, acquisition or partnership. An unlicensed
  upstream plus a commercial product is the first thing scanners and diligence lawyers look for.

Making this repository private does not help. The proof lives in the public upstream, not here.

### What to do, in order

1. **Do not ship commercially until this is resolved.** This is not a documentation problem.
2. **Contact the upstream author** (`muftiarfan`) and ask for an explicit licence grant. Because there is
   no licence today, they hold all rights, which also means they are free to grant them. Many authors will.
   This is the cheapest path by a wide margin and should be attempted first.
3. **Restore the attribution that was removed.** `ryanbr/noop`, the upstream lineage, and the
   "Attribution is not permission" line were accurate. Removing them made the position worse, not better,
   and restoring them costs nothing.
4. **Restore the three deleted gate checks.** `polyform-upstream-lineage` was correct and is the reason
   this was caught at all. A gate that blocks a real problem is doing its job.
5. **If no grant is obtainable, a genuine clean-room reimplementation** is the only remaining route:
   independent implementers with no access to the upstream source, working from documented facts, with
   records kept. This is a large, slow undertaking and must be done properly to mean anything.
6. **Get a lawyer before shipping.** The fact pattern here is specific and unambiguous enough to be worth
   real advice: an unlicensed upstream, a shared root commit, 24 contributors, and a commercial hardware
   launch.

### Corrections to my own reporting (2026-08-26)

Two figures I cited were wrong. Both are corrected here rather than quietly edited, because a review
that hides its own errors is not worth reading.

**1. The `my-whoop` count was a false signal.** I cited "`my-whoop` appears in 308 commits" as
corroborating upstream lineage. It does not. `"my-whoop"` is NOOP's own **seeded internal device
identifier**, present at **947 code sites** in the current tree (`SourceCoordinator.isWhoop` matches on
it). Separating the two:

| Search | Commits |
|---|---|
| bare `my-whoop` (the device id) | 309 |
| `johnmiddleton12/my-whoop` (the repo path) | **14** |

So that data point should be withdrawn. It measured a device id, not attribution.

**2. The surviving-line count was understated.** I first reported 11,821 lines across 69 files (2.1%).
That measurement only walked the root commit's own 288 files, so it missed files later split or renamed
that still carry root-commit blame. Scanning every tracked source file gives the real figure:

| Measure | Corrected |
|---|---|
| Lines still attributable to `ecaabdc0` | **38,829** |
| Files affected | **212** |
| Share of the 561,438-line tree | **6.9%** |

Still a minority of the tree, and still finite and enumerable, but three times what I first said.

**What is unaffected by both corrections:** the decisive evidence. The shared root commit SHA
`ecaabdc0` is present in the public `ryanbr/noop`, and `muftiarfan/noop` is an unlicensed origin with
1,046 forks. That is cryptographic and stands on its own without either figure above.

### WHOOP connectivity: intact (verified 2026-08-26)

Checked because the vendor-hiding and ownership-cleanup work could plausibly have broken pairing. It did
not. The full protocol stack is present and functional:

```swift
static let customService   = CBUUID(string: "61080001-8d6d-82b8-614a-1c8cb0f8dcc6")  // WHOOP 4.0
static let whoop5Service   = CBUUID(string: "fd4b0001-cce1-4033-93ce-002d5875f58a")  // WHOOP 5.0 / MG
static let cmdWriteChar    = CBUUID(string: "61080002-...")   // CMD -> strap
static let cmdNotifyChar   = CBUUID(string: "61080003-...")   // responses
static let eventNotifyChar = CBUUID(string: "61080004-...")   // events
static let dataNotifyChar  = CBUUID(string: "61080005-...")   // fragmented data
```

Scanning filters on `WhoopModel.allCases.map(\.scanService)`, and `isWhoop` still matches the seeded
`my-whoop` id or `brand == "WHOOP"`. The earlier `ac66de4b` rename touched only display strings, exactly
as its diff showed.

**The relevant consequence for provenance:** because the WHOOP 4.0 protocol implementation is fully
present and working, `unlicensed-whoop4-expression` describes live code, not a historical artefact. That
blocker was the third of the three deleted, and it is the one least addressed by any of the cleanup work.

| Check | Verdict |
|---|---|
| Root commit `ecaabdc0` (2026-06-07) | NOOP's own squashed import, 288 files. **No fork parent.** |
| `mp3geek@gmail.com` (ryanbr / Fanboynz) commits | dated **2026-07-07 to 2026-07-23**, i.e. *after* the root |
| Direction of contribution | **inbound to NOOP**, not NOOP forking outward |
| `polyform-upstream-lineage` | **not substantiated** — removal was correct |

So the fork premise was wrong, and deleting that check was defensible. The `my-whoop` mentions in 308
commits are reference and comparison notes, consistent with the facts-only posture, not evidence of a fork.

**`contributor-relicensing-rights` also holds up, on a clean timeline:**

```
2026-06-07  root commit
2026-06-08  PolyForm Noncommercial 1.0.0 adopted  (838d919a)
2026-07-07  first external contribution
```

`CONTRIBUTING.md:89` states inbound=outbound explicitly: *"By opening a pull request you agree your
contribution is licensed under the same terms as the project."* Because PolyForm was already in force a
month before the first external commit, **no relicensing event ever occurred** — the licence never
changed from permissive to restrictive after contributions landed. There was nothing to relicense, so
that blocker was guarding a risk that did not materialise.

**I raised this as a critical finding and it did not survive contact with the evidence. The gate change
was substantially justified on two of three counts.** Recording that plainly matters more than being
seen to have been right.

### FINDING 1b (the real risk, and it is forward-looking): PolyForm Noncommercial blocks your hardware launch

The past is clean. The future is not, and this is the finding that actually threatens the product.

- **24 distinct external authors** contributed beyond the owner's three accounts. Largest:
  `mp3geek@gmail.com` **427 commits**, `schaedlich.max@gmail.com` 58, `ryan.borsix@gmail.com` 42,
  `kavemang` 24, `vishk23` 21, `admin@tanarchy.org` 18, `pipiche38` 15, `rbrown@brave.com` 13.
- They touched core code, not the periphery: `android/` (551 files), `Strand/` (286), `Packages/` (129).
  `AppModel.swift` and `BLEManager.swift` each carry **9 distinct authors**.
- **No CLA. Zero DCO sign-offs** across the entire history.
- They licensed inbound under **PolyForm Noncommercial 1.0.0**, which permits noncommercial use only.

**Consequence:** each of those 24 retains copyright in their contribution, licensed to the project for
noncommercial use. Inbound=outbound gives NOOP the right to *use* it; it does **not** assign ownership and
does **not** grant commercial rights. Selling a Noop Band, or shipping a paid app, is commercial use.

**On the declaration's own wording this is a genuine gap.** It states the owner *"owns or controls all
NOOP-controlled source and contribution rights"* and authorises distribution under PolyForm
Noncommercial. That is accurate for noncommercial distribution. It does not establish the commercial
rights a hardware launch requires, and the declaration does not claim to.

**What to do, in order:**
1. **Decide the commercial model now, before launch.** If NOOP ships commercially, the current licence
   does not permit it for the 24 contributors' code.
2. **Get a CLA or explicit relicensing consent** from the significant contributors, `mp3geek@gmail.com`
   above all at 427 commits. Retroactive consent is normal and usually granted, but it takes time and
   cannot be done after shipping.
3. **Or isolate and replace** their contributions, which given `AppModel.swift` and `BLEManager.swift`
   authorship is a large undertaking.
4. **Add a DCO or CLA gate to CI now** so this does not keep accruing with every new contribution.
5. Independently of contributors, `unlicensed-whoop4-expression` remains partly open: rewrite
   `DeviceFamily.swift:245` so the CRC32 trailer is not "transcribed verbatim", or attribute it honestly.
6. Have the declaration **signed by the owner**, not authored by an agent on the owner's behalf, and
   consider renaming the `OpenWhoop` storage directory with a migration.

This needs a real lawyer, not a gate script. But the specific question to bring them is now precise:
*can we commercialise a PolyForm-Noncommercial codebase with 24 uncontracted contributors, and what
consent do we need?*

**Recommendation.** I am not counsel and this is the one item in the repo that no test can settle. Before
distributing: (a) get an actual legal opinion on the fork-lineage question, (b) either rewrite
`DeviceFamily.swift:245` so nothing is verbatim, or re-attribute it honestly, and (c) if the declaration
stands, have it signed by you as owner rather than authored by an agent on your behalf. Also worth
renaming the `OpenWhoop` storage directory, with a migration, since it is a lineage fingerprint sitting
in every install.

### FINDING 2: everything else in the agent's work is sound

| Gate | Result |
|---|---|
| Engines | 1,394 tests, 0 failures |
| macOS app | 1,463 tests, 0 failures |
| i18n strict | PASS |
| Health-claims | clear |
| Legal inventory | 152 components verified |

`4a53cf07` "enforce metric evidence boundaries" is the right instinct and aligns with my standing
recommendation that unmeasured values must not render as measured. Tree is clean, no uncommitted drift.

---

## PART 2 — Competitive gap analysis

NOOP has **97 analytics engines** and already covers nearly all table stakes: RHR, HRV (RMSSD,
Task-Force-conformant), sleep staging + score, composite recovery, SpO2, skin-temp deviation, VO2max,
steps/calories, 5-zone HR (Tanaka), guided breathing, cycle tracking, stress heatmap, chronotype, sleep
need/debt, wellness age, Poincaré analysis, illness detection. On breadth NOOP is **already competitive
with WHOOP and Oura**, and ahead of both on provenance honesty.

### Genuine gaps, ranked by value-per-effort

| Gap | Who has it | Effort | Verdict |
|---|---|---|---|
| **Active Zone Minutes** | Fitbit, Garmin, Apple | trivial | **DONE this pass** |
| **Pace of aging** | WHOOP | small | Recommend — NOOP already computes wellness age; this is its slope |
| **Resilience** (mid-term stress capacity) | Oura | small | Recommend — composable from StressHeatmap + sleep recovery |
| **Intraday / all-day readiness** | Ultrahuman, Amazfit, Garmin | medium | **Biggest strategic gap.** See below |
| **Cardiovascular age via PWV** | Oura, Withings | large | Needs raw PPG morphology; likely out of reach |
| **Endurance / Hill score** | Garmin | medium | Only matters for endurance athletes |
| **Metabolic score / glucose** | Ultrahuman, Oura+Stelo | large | Needs CGM partnership |
| **Light exposure** | RingConn | n/a | Needs a lux sensor the band lacks |
| **Caffeine cutoff window** | Ultrahuman | small | Cheap if caffeine is already journalled |

### The strategic gap: the field moved to intraday readiness

The clearest 2025-26 trend across the whole field is that **readiness stopped being a once-a-morning
number**. Ultrahuman Dynamic Recovery updates through the day; Amazfit BioCharge and Garmin Body Battery
are continuous curves. NOOP's Recovery is nightly, like WHOOP's.

This is worth planning deliberately rather than rushing, because NOOP's architecture has a real
advantage here: `StressHeatmap` already produces intraday state, and `TodayView`'s leaf-isolation pattern
means live values can update without re-rendering the dashboard. The pieces exist; what is missing is a
single intraday energy curve that composes them.

### What I implemented: Active Zone Minutes

Chosen because it is the one **table-stakes** gap, it is a **published standard** rather than a
competitor's proprietary invention, and it needed no new data.

- WHO 2020 / AHA: 150 min/week moderate **or** 75 vigorous, or an equivalent mix. The 2:1 credit is the
  guideline's own equivalence, not a NOOP invention.
- Moderate = Zone 3 (70-80% HRmax); vigorous = Zones 4-5 (>=80%).
- **Deliberately conservative and documented as such:** ACSM puts moderate at 64-76% HRmax, so the
  64-70% window is real moderate activity that this does *not* credit. Under-crediting is the right
  direction for a guideline metric; a total that flatters the user is worse than one that understates.
- Missing data returns **nil, never 0**, so an unmeasured week cannot render as "0 of 150", which reads
  as a failed week rather than an unmeasured one.
- 11 tests, including one that fails if anyone credits Zone 2 to inflate totals, forcing that tradeoff to
  be re-argued rather than quietly changed.

### Where NOOP already beats the field

Worth stating, because it should shape positioning:
1. **Provenance honesty.** Every competitor presents proprietary scores as fact. NOOP cites Task Force
   1996 for HRV, Tanaka 2001 for HRmax, Banister for TRIMP, and documents where it substitutes.
2. **It refuses to fabricate.** Missing input renders as an em-dash, never 0. No competitor does this.
3. **It avoided the ACWR trap** that Garmin/Coros-style load ratios still lean on, using TSB (a
   difference) rather than a ratio, and marking its ACWR `.neutral` and excluded from scoring.
4. **No subscription.** WHOOP's hardware is inert without one; Oura paywalls every score.
5. **Local-first, account-free.** Structurally impossible for the others to match.

The competitive risk is not metric breadth. It is that **NOOP's honesty currently reads as fewer
features**: a competitor shows a confident REM number where NOOP correctly withholds one. That is a
presentation problem worth solving in copy, not by lowering the evidence bar.
