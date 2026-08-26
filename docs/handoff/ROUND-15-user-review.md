# Round 15 — user-perspective review of the parallel session's work

**Date:** 2026-08-24 · **Commit:** `dce245f2` on `main` (pushed) · **Lens:** does this make sense to the
person holding the phone?

**Waited first:** the parallel session was writing when this round began (`TrendsView.swift` 6 seconds
before the first check). Polled until 13 minutes of quiet before touching anything — ~55 minutes total.

**Recorded gates:** iOS ✅ · macOS **1394** tests 0 failures · engines **1323** 0 failures · Android
**3575** 0 failures · i18n strict ✅ · legal inventory ✅. The source-rights result from this historical
round was superseded by the owner-controlled consolidation record dated 2026-08-25.

---

## What was wrong for real users

### 1. Tab labels disappeared for large-text users *(accessibility regression, restored)*
`FloatingTabBar.visuallyCompact` had been weakened from
`compact && !dynamicTypeSize.isAccessibilitySize` to plain `compact`, with no rationale recorded. Effect: a
**sighted low-vision** user who has asked for larger text got the icon-only rail while scrolling and lost
the only persistent cue for which section they were in. VoiceOver users were never affected — this hit
precisely the people Dynamic Type exists to serve.

Restored, and documented as *complementary* to the new `.dynamicTypeSize(...xxLarge)` cap the same refactor
added: the cap makes expanded labels **fit**, the guard keeps them **present**. `FloatingQuickAddButton`
needed no change — it is now a fixed 48 pt control, above the 44 pt minimum.

### 2. Trends opened on an empty week *(fixed)*
`weekOffset` started at 0 — the week containing today — so the screen showed:

> **No readings this week.** Step to another week with the arrows above to see its review.

directly above a panel reporting **"Recovery scores: 89 of 90 days."** Two statements that contradict each
other on one screen. Worse, on a Monday morning this was the *default* experience: the week has barely
started, so it is legitimately empty, and the app looks broken.

The digest now lands on the most recent week that actually holds readings:

* capped at 8 weeks back, so a genuinely stale history still shows the honest empty state;
* the header already labels it truthfully (**"Last week"**), so nothing is disguised;
* the forward chevron still reaches the current week;
* any manual step sets `hasChosenLandingWeek`, so stepping *to* an empty week sticks rather than bouncing.

Verified visually: Trends now opens on **"Last week / Aug 17–23"** with 7/7 days, deltas (+6% / +6% / −2%)
and a real insight — *"Your Effort outpaced your Recovery this week: you leaned into the red."*

### 3. Four new strings shipped untranslated
All added in the same session, all user-visible, none in a catalog — so English in all eight non-English
locales:

| String | Fix |
|---|---|
| `"Recovery · Effort · Sleep"` ×2 | `appwide.trends.metric_trio`, translated ×9 **reusing the app's existing translations** for Recovery/Effort/Sleep so terminology stays consistent |
| Trend chart VoiceOver hint | added to **StrandDesign's own** catalog ×9, resolved with `bundle: .module` (that package ships its own bundle) |
| Average VoiceOver value | was string interpolation, which becomes a phantom catalog key. Now `appwide.trends.average_value_a11y_format` — and it speaks **"Average"** instead of the visual `AVG` abbreviation |
| Descriptor/scope hint | composes two already-localized fragments, so it moved into a helper: no literal inside an accessibility modifier |

---

## Design changes I did NOT revert

Two failing contract tests turned out to be guarding decisions the session had deliberately changed and
documented. Reverting them would have been me overriding a reasoned choice, so the **tests** were updated
instead — while keeping the accessibility guarantees pinned:

* **Status-bar veil is now blur-free.** Rationale in the source: blurring the safe-area strip also softened
  the first card and the page header. The test now asserts the new contract *plus*
  `crownAlpha = reduceTransparency ? 1`, so the Reduced Transparency fallback can never quietly weaken.
* **Compaction is position-based, expansion keeps hysteresis.** A defensible asymmetry — "reading down the
  page" compacts, "a deliberate swipe back" expands. Both halves are now pinned, including the near-top
  release.
* The adaptive-ink assertion matched **exact indentation** (28 spaces) and broke on a re-indent while the
  ink was correct. Now whitespace-insensitive.

---

## Reviewed and correct — no change needed

* **Today** reads well: greeting, Recovery 51 *Moderate* with valence colour, Sleep/Effort in their metric
  identity colours, Fitness Age with its "4 years older than your profile age" framing, then
  *"Why today reads this way."* The valence/identity colour split is deliberate and works: one score
  carries judgement, the others carry quantity.
* **Sleep** keeps imported values distinct from NOOP-computed values without exposing a transport-vendor
  label on the customer surface.
* **Source rights** are now governed by
  `docs/provenance/OWNER-RIGHTS-DECLARATION.md` and the current distribution gate.

---

## Still pending (unchanged, and only the owner can move them)

1. **P1 publish the accuracy validation** — held-out error and failure rates for
   Charge/Effort/Rest and sleep staging.
2. **P1 finish the brand-rename localization worklist** — 22 exact pairs are near-free
   (`docs/localization/BRAND-RENAME-WORKLIST.md`), then tighten `BrandLiteralRatchetTests`.
3. **P1 physical-device evidence** — Simulator never exercises CoreBluetooth, HealthKit entitlements,
   background collection, or 24-hour battery drain.
4. **Process** — two agents on one working tree cost this round ~55 minutes of waiting plus two breakages
   arriving mid-verification. Separate clones or `git worktree`.
