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

**What only you can answer:** was NOOP ever a fork or derivative of `ryanbr/noop` or
`johnmiddleton12/my-whoop`? If yes, that lineage survives the removal of the line naming it. If those
were only facts-only references and the expression is genuinely NOOP's, the removal is defensible and
the declaration is the right mechanism.

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
