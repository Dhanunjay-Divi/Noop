# Competitive metric gap analysis

**Date:** 2026-08-26 · **Researched:** WHOOP 5.0/MG, Oura Gen4, Garmin, Apple watchOS 26, Samsung One UI 8, Fitbit/Google,
Polar, Coros, Suunto, Ultrahuman, RingConn, Amazfit/Zepp, Withings

---

## Competitive gap analysis

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
