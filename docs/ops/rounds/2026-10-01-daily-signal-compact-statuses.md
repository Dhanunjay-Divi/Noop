# Round: 2026-10-01 - Daily Signal compact statuses

## Status

- State: `integrated and exact-main verified; signed-device review pending`
- Owner: project team
- Branch: `codex/today-metric-catalog-fitness-age-20261001`
- Start commit: `232f746e045d2755947579c3408efc5c3b84ff69`
- End implementation commit: `f57d2de9373d0656a36052674e50a55007ea1c5e`
- Record commit or PR: PR `#27`; squash merge
  `5a287b50423b921d408833392b6dfdeadf14a8ae`

## Objective

Give every scored Daily Signal metric one short, useful status without adding
paragraph copy to the number-first summary.

## Scope

### In scope

- Short status labels for Recovery, Sleep, and Effort on Apple and Android.
- Shared boundaries, localization, accessibility, focused tests, app builds,
  and visual review.

### Non-goals

- Formula, source, storage, account, network, BLE, notification, or hardware
  changes.
- Diagnostic or treatment claims.

## Starting evidence

- Recovery already had compact calibrated and score-band states.
- Sleep and Effort showed numbers without equally concise plain-language
  context.
- The requested number-first layout did not have room for paragraph education
  under each score.

## Delivered

- Recovery keeps the existing score-aware `Low`, `Steady`, and `Strong`
  presentation plus its established calibration, carry, and missing-data
  states.
- Sleep now uses `Need more rest`, `Steady`, or `Well rested`.
- Effort now uses `Light`, `Moderate`, or `High`.
- Apple and Android use the same sleep boundaries of 60 and 80 and the same
  canonical 100-point Effort boundaries of 30 and 70.
- Effort status is derived before optional display conversion to the 21-point
  compatibility scale, so changing display units cannot change its meaning.
- Missing values remain `No data`; Android low-confidence sleep keeps
  `Estimate` ahead of a score-band label.
- All six new labels are generated for every supported app-wide locale and are
  included in accessibility output.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple focused test wall | 50/50 passed: 2 compact-status boundary cases plus 48 Today explainability regressions | Status boundaries, non-finite handling, existing Daily Signal semantics, and localization contracts compile and pass together | Physical-phone rendering or sensor accuracy |
| Android Full debug unit/compile wall | `BUILD SUCCESSFUL`; 29 tasks, including Full Kotlin/resource compilation and `testFullDebugUnitTest` | Android implementation, resources, accessibility composition, and status boundary tests compile and pass | Android visual appearance because no emulator was attached |
| iPhone Simulator build | `NOOPiOS` build succeeded with app, Watch, complications, and widgets | Current Apple app graph compiles with the status implementation | Signed installation or physical-device behavior |
| iPhone Simulator visual review | Reviewed a 1206x2622 current-state capture showing Recovery 43 `Steady`, Sleep 85 `Well rested`, and Effort 45 `Moderate`; no observed clipping, overlap, or sentence wrapping | The requested compact presentation fits the current phone layout | Other Dynamic Type sizes or every locale on physical hardware |
| Android API 35 follow-up visual review | Reviewed current 1080x2424 Today capture SHA-256 `f165091139b669623be80dd7dc29eef6a736c447458409bbd0d7c30a0c95ee8a`; no observed clipping or overlap in the Daily Signal, Fitness Age, self-check, or navigation | The matched compact hierarchy renders coherently on the reviewed Android emulator | Physical TalkBack, every locale/font size, or sensor accuracy |

## Data, privacy, and medical truth

- No score formula, source, persistence, network, account, or device behavior
  changed.
- These are compact score-band descriptions, not diagnoses or measured stress,
  fatigue, hydration, or readiness claims.
- Sleep status describes the existing sleep score. Effort status describes the
  existing canonical Effort score.
- No personal, raw health, device, or credential data was added to diagnostics
  or repository evidence.

## Open risks and honest limitations

- Android emulator visual review is complete; signed physical-phone review
  remains pending.
- Large-text, all-locale, and signed physical-phone review remain release
  evidence gates.
- Physical-band, BLE, background, battery, haptic, notification, and sensor
  accuracy behavior was not exercised or claimed.

## Physical device and deployment

- Install/update action: unsigned iPhone Simulator candidate only.
- Android follow-up launch: exact Full debug APK installed on an API 35
  emulator with synthetic fixture state.
- BLE/background/haptic/battery scenarios exercised: none.
- No deployment, store upload, signed candidate, firmware action, or production
  traffic was dispatched.

## Git and release state

- Final PR `#27` head
  `f57d2de9373d0656a36052674e50a55007ea1c5e` passed all ten required
  contexts and merged normally through protected `main` as
  `5a287b50423b921d408833392b6dfdeadf14a8ae`.
- The exact main commit completed 38 checks with 33 successes, five
  intentional skips, and zero failures; strict required-CI verification passed
  10/10.

## Decisions

- Keep Recovery's established status contract.
- Use `Need more rest / Steady / Well rested` for Sleep and
  `Light / Moderate / High` for canonical 100-point Effort.
- Derive Effort status before optional display conversion to the 21-point
  compatibility scale.
- Preserve `No data`, calibration, carry, and low-confidence states.

## Next round

1. Run signed physical-phone accessibility review.
2. Keep physical sensor, background, battery, and notification behavior behind
   their existing device evidence gates.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
