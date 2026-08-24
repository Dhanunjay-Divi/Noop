# Agent handoff - Canonical repository and release constraints

**Status:** repository consolidation is complete; commercial distribution is
blocked.

## Read first

1. [`../ops/ACTIVE.md`](../ops/ACTIVE.md)
2. [`../ops/rounds/2026-08-24-overnight-calibration-effort-coach.md`](../ops/rounds/2026-08-24-overnight-calibration-effort-coach.md)
3. [`ROUND-17-overnight-calibration-effort-coach.md`](ROUND-17-overnight-calibration-effort-coach.md)
4. [`../ops/rounds/2026-08-24-cycle-tracking-metric-reconciliation.md`](../ops/rounds/2026-08-24-cycle-tracking-metric-reconciliation.md)
5. [`ROUND-16-cycle-tracking-and-metric-reconciliation.md`](ROUND-16-cycle-tracking-and-metric-reconciliation.md)
6. [`../ops/rounds/2026-08-23-explainable-trends-profile-rhythm.md`](../ops/rounds/2026-08-23-explainable-trends-profile-rhythm.md)
7. [`../ops/rounds/2026-08-23-today-metrics-recovery.md`](../ops/rounds/2026-08-23-today-metrics-recovery.md)
8. [`../ops/rounds/2026-08-23-repository-independence.md`](../ops/rounds/2026-08-23-repository-independence.md)
9. [`../REPOSITORY_INDEPENDENCE.md`](../REPOSITORY_INDEPENDENCE.md)
10. [`../provenance/rights-status.json`](../provenance/rights-status.json)
11. [`RELEASE-BLOCKERS.md`](RELEASE-BLOCKERS.md)

## Current repository truth

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Visibility: private at the final authenticated check.
- Default and only active remote branch: `main`.
- GitHub metadata: `isFork=false`, no parent repository.
- Local and remote `main` must resolve to the same commit after a fresh fetch.
- Current round baseline before its direct-to-main commit: `d1f238f8`.
- This source tree remains the auditable, noncommercial reference codebase.
  Standalone hosting does not make inherited source commercially independent.

Use `git log -1 --oneline` for the exact handoff commit. The round record and
this handoff are in that commit, avoiding a self-referential hard-coded hash.

## What landed

- All completed local application work was fast-forwarded to canonical `main`.
- The three merged feature branches were deleted after ancestry verification.
- Fork-era workflow filenames became `release.yml` and `testing-build.yml`.
- The shared Android debug keystore, obsolete LAN handoff, and stale fork-count
  artifact were removed.
- Terms are synchronized at version 2.3 on Apple, Android, and in source docs.
- Machine-readable rights state and fail-closed release enforcement are active.
- Current ops round, active handoff, and release blockers agree.
- Hosted CI migration debt is explicit: 247 Android and 166 Apple unique
  hardcoded or unextracted literals are baseline-tracked, and future additions
  fail the i18n gate.
- Profile measurements remain editable above the iOS software keyboard on both
  standard and compact layouts; the bottom action inset leaves the layout while
  editing and returns afterward.
- The DEBUG charging fixture now initializes live state before the first frame,
  removing a hosted UI-test race without changing Release behavior.
- Today now keeps the complete ten-metric catalog visible on Apple and Android;
  the saved three-to-five metrics are pins that lead the grid, not a visibility
  filter.
- Moderate Recovery gauges stay entirely yellow, and the Recovery hero and tile
  now agree on the same score-state color.
- Pattern cards now lead with plain `WHAT CHANGED` evidence and report recent
  Effort range/average rather than an internal monotony value.
- iPhone trends support hold-and-drag inspection; range cards name averages and
  score scales, including VoiceOver context.
- The profile display name defaults to Noop, is editable and grapheme-safe, and
  remains local to the UI rather than entering sync or shareable backups.
- Android Rhythm now has a real latest-night route behind its existing consent
  gate. Apple and Android refresh on new history, keep duplicate R-R sources
  separate, include active/canonical history after re-pairing, and rank readable
  resting coverage.
- Rhythm rejects non-dismissed recorded workouts, missing motion evidence, and
  elevated resting-window rates. It remains descriptive, non-diagnostic, and
  unable to alert.
- The Automations tap guide explains alarm, hydration, SOS, and fallback
  precedence. SOS wording reflects immediate SMS-first paging and location
  sharing when available, with voice remaining a delayed fallback.
- Paced breathing uses restrained phone haptics when no band is bonded.
- Sleep now shows one neutral `Imported` hero badge for imported scores instead
  of provider brand plus `PROVIDER SCORE`; detailed stored provenance remains.
- Menstrual-cycle setup sits directly below Sex in Profile and remains
  available from Health before the first wearable reading. The private tracker,
  conservative cadence/temperature model, and all presentation strings are
  mirrored across Apple and Android.
- Cycle forecasts widen with recent logged variability and fail closed on stale,
  out-of-range, or highly variable history. The UI makes no fertility,
  contraception, safe-day, exact ovulation, or diagnostic claim.
- Fitness Age and Vitality reconcile after relevant profile, birthday, and
  active-device changes. Failed reads, writes, or completion-marker persistence
  retain a retry path, and stale asynchronous reads cannot publish for a newer
  profile.
- Daily Signal keeps its identity, source, and state aligned at compact widths.
  Noop Band history sync uses an indeterminate reduced-motion-aware sweep and a
  brief completion confirmation rather than a fabricated percentage.
- Overnight calibration now fingerprints PPG-derived HR and every
  score-bearing history stream. A PPG-only persisted overnight fixture advances
  the canonical calibration count from `0/4` to `1/4`.
- Post-backfill scoring is durable and source-bound. Commits during a pass,
  device switches, cancellation, transient failures, and service recreation
  retain a coalesced retry path; the success watermark cannot advance after a
  failed pass.
- Daily Effort exposes a conservative 0-100 personal range only from current
  evidence and a same-day self-check. Its notification is explicit opt-in,
  current-local-day only, once daily, and never clearance or a stopping rule.
- Coach now receives a typed evidence envelope that separates unavailable,
  empty, observed, and missing states, bounds distinct-day coverage, sanitizes
  user text/dates, and prevents unsupported personalized nutrition claims.
- Android metric education now has specific localized guidance for heart-rate
  summaries, calories/macronutrients, mood, and body/basal-body temperature.
- The iPhone visual harness supports real iPhone SE dimensions and waits for
  the cold fixture state before recording the first frame.

## Verified gates

- Tool tests: 25/25 passed.
- Legal inventory: 152 runtime components and 3 container inputs verified.
- Distribution gate: blocked on exactly the three unresolved rights entries, as
  intended.
- Current health-claims scan: clear across 1,049 files.
- Android: 3,627 Full Debug unit tests executed with 0 failures and 6 skips;
  `assembleFullDebug` and instrumentation compilation passed, and managed Pixel
  API 35 instrumentation passed 4/4 tests.
- Apple: unsigned generic iOS simulator build passed; the production shell
  passed 21/21 UI tests, and 40/40 visual scenarios passed across iPhone SE and
  iPhone 14 Pro.
- Current macOS app suite: 1,410 passed, 1 intentional skip, 0 failures.
- All nine Swift packages: 2,596 tests, 0 failures, 2 intentional skips.
- StrandAnalytics: 1,360 tests passed; StrandDesign: 44 tests passed.
- Focused profile and brand-literal-ratchet macOS tests passed.
- i18n: focus-locale completeness and the no-new-literal regression gate pass.
- Shared app-wide localization has exact 278-key parity across nine locales;
  Daily Plan has 59-key parity, and canonical generator reruns are idempotent.
- Hosted GitHub Actions is externally blocked by the account Actions budget.
  Push run `32784344944` and manual health-claims run `32784502269` both ended
  in `startup_failure` before creating a job. Restore the Actions budget, then
  rerun the workflows for the current `main`.
- Server: pinned Ruff checks pass; local tests pass 59 with 4
  database-dependent skips.
- Round 14 iOS production shell: 17/17 tests passed locally, including the
  complete-catalog regression.
- Preceding full macOS app suite: 1,390 executed locally, with 1,389 passed,
  1 intentional skip, and 0 failures.
- Current StrandDesign package: 44/44 tests passed.
- Current Android Demo Debug unit suite passed, including the mirrored Recovery
  color and full-catalog ordering contracts.
- Simulator captures for the current Today pass are committed under
  `docs/assets/` and linked from the Round 14 handoff.
- Prior iOS production shell: 16/16 tests passed locally at `94661a17`.
- Profile keyboard regression: 5/5 passed on iPhone 17 Pro and 5/5 on compact
  iPhone 17e; both assert the lower measurement controls remain hittable.
- Charging fixture regression: 5/5 passed on a newly created simulator, and the
  focused `AppleDemoSeederTests` contract passed 2/2.
- Hosted app run `32670362286` passed at `94661a17`: the universal macOS build
  executed 1,390 tests with 1 skipped and 0 failures, while the iOS simulator
  build and 16/16 production-shell tests passed, including the charging
  assertion.
- Hosted i18n run `32670362251` and health-claims run `32670362291` passed at
  `94661a17`.
- Workflow YAML parsing, ops records, private-data filename guard, JSON parsing,
  and diff whitespace checks passed.
- GitHub authentication and standalone repository metadata were verified.
- Independent source review found and then confirmed fixes for translated SOS
  semantics, Unicode graphemes, sparse/noisy R-R selection, dismissed workouts,
  canonical re-pair history, half-open tie-breaking, and gravity-source parity.
- Current independent reconciliation review found one Android completion-marker
  durability issue. Checked background persistence and failed-write retry
  coverage resolved it; follow-up review found no additional concrete issue.

These checks do not establish store readiness, physical-device behavior,
medical accuracy, clinical safety, or commercial source rights.
The i18n result also does not mean the 413 baseline entries are translated or
that machine-translated reproductive-health copy has native-speaker approval.

## Do not do

- Do not delete `LICENSE`, `NOTICE`, `ATTRIBUTION.md`, upstream references, or
  contributor history to make the repository look new.
- Do not mark a blocker resolved without every structured evidence field
  required by `Tools/release-legal-gate.py`.
- Do not change `distributionStatus` to `cleared` while any blocker is
  unresolved.
- Do not trigger artifact publishing by bypassing or weakening the distribution
  gate.
- Do not push this inherited tree into an empty history and call it clean-room
  work.
- Do not add signing keys, credentials, raw health exports, or personal device
  identifiers to Git.
- Do not claim medical, anomaly-SOS, fall, ECG, AFib, or accuracy readiness
  without the separate validation and regulatory evidence.
- Do not turn experimental Rhythm into an alert path or relax its resting,
  workout, consent, and source-separation gates without a new validation round.
- Do not add the local display name to Friends, sync, or backups without an
  explicit privacy/product decision and migration review.
- Do not present cycle awareness as fertility, contraception, safe-day,
  ovulation-date, pregnancy, diagnosis, or medical guidance.
- Do not advance an age-metric completion watermark when any required read,
  write, or marker-persistence step failed.
- Do not replace source-bound post-backfill revisions with one process-local
  boolean, clear durable pending work after failure, or advance its fingerprint
  watermark before the pass reaches success.
- Do not notify from a historical Effort row, a withheld range, or a disabled
  preference. Effort remains a planning cue, not training clearance.
- Do not render a failed Coach data read as an empty log or turn missing
  evidence into zero, a trend, or personalized diet advice.

## Ordered next work

1. Resolve each entry in `docs/provenance/rights-status.json` through a
   rights-holder license, independently implemented replacement, or removal.
2. Keep behavior-only specifications and clean-room implementation roles
   separate; record the affected-source manifest and independent review.
3. Run `python3 Tools/release-legal-gate.py check` and then
   `python3 Tools/release-legal-gate.py distribution`.
4. Migrate the 247 Android and 166 Apple baseline entries into reviewed
   localization resources; never expand the baseline for new work.
5. Obtain native-speaker approval for reproductive-health copy in every
   supported locale.
6. When both legal gates pass, resume signing, store metadata, physical-device
   matrices, accuracy studies, safety-provider staging, and regulatory review
   in `RELEASE-BLOCKERS.md`.
7. Validate tap precedence, phone/band haptics, re-paired canonical history,
   overnight Rhythm refresh, and workout overlap on representative physical
   devices without resetting local data.
8. Obtain native-speaker review for the 47 new app-wide cycle/source/sync keys,
   then validate cycle, age-metric, and Noop Band sync behavior on
   representative physical devices without resetting local data.
9. Start a new dated ops round for any material source, device, release, or
   repository change and update `docs/ops/ACTIVE.md` before handing off.
10. Validate the source-bound overnight scoring queue, Daily Effort nudge, and
    Coach evidence states on representative physical devices and real user
    histories without resetting local data.

## Fast verification

```bash
git fetch origin --prune
git status --short --branch
git branch -r
git rev-parse HEAD
git rev-parse origin/main
gh repo view Dhanunjay-Divi/Noop \
  --json visibility,isFork,parent,defaultBranchRef
gh run view 32670362286
python3 Tools/release-legal-gate.py check
python3 Tools/release-legal-gate.py distribution
python3 Tools/i18n_audit.py --ci origin/main
python3 Tools/validate-ops-rounds.py --all .
python3 Tools/check-private-data.py
```

The distribution command must currently fail with the recorded blocker IDs. A
passing result is valid only after reviewed rights evidence is committed.
