# Round: 2026-10-01 - Today metric catalog and Fitness Age

## Status

- State: `locally verified; protected integration pending`
- Owner: project team
- Branch: `codex/today-metric-catalog-fitness-age-20261001`
- Start commit: `5f0a798d3aada03ee2999ca6e18b2984aa184a5f`
- Record commit or PR: pending

## Objective

Make Today easier to personalize without turning it into an unbounded sensor
dashboard:

- expose every metric the Today screen can already render and route truthfully;
- keep the visible Key Metrics dashboard limited to three through six choices;
- make selection, ordering, and discovery clear on Apple and Android;
- restore Fitness Age as one compact weekly insight inside Daily Signal rather
  than consuming a Key Metrics card;
- preserve metric-first hierarchy, readable spacing, and cross-platform
  semantic and accessibility parity.

## Scope

### In scope

- The Apple and Android Key Metric registries and preference migration.
- A grouped, searchable editor with a distinct selected/reorder section.
- Today-ready Recovery, Effort, Sleep, HRV, resting heart rate, blood oxygen,
  respiratory rate, skin temperature, Steps, Weight, Calories, Stress,
  Vitality, and Hydration choices.
- Truthful missing, calibrating, unavailable, and disabled-hydration states.
- A compact Fitness Age row that opens its existing detail surface.
- Focused tests, simulator captures, visual review, localization, and
  operations evidence.

### Non-goals

- Exposing raw/internal samples or every Metric Catalog diagnostic as a Today
  card.
- Changing a health formula, score, source winner, baseline, provenance,
  persistence, account, network, notification, BLE, or band behavior.
- Claiming sensor accuracy, physical-device layout, battery, background, or
  band behavior from simulator evidence.

## Starting evidence

- The current editor exposes ten metrics even though Today already loads and
  renders additional user-facing signals.
- The six-card grid has appropriate glance density, but the editor is a flat
  list and does not scale cleanly to the full supported catalog.
- Fitness Age already has shared month-precise presentation, profile-state
  invalidation, and detail routing, but it is only available as a larger
  optional dashboard card.
- The existing Apple and Android registries share stable persisted identifiers,
  a three-card minimum, and a six-card maximum.

## Data, privacy, and medical truth

- Schema or migration impact: additive recognition of stable display-only
  metric identifiers; existing saved selections remain unchanged.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: Stress remains a non-diagnostic,
  personalized wellness estimate; missing or unqualified inputs remain visibly
  unavailable rather than inferred.

## Planned verification

- Apple preference, source-contract, accessibility, and screen-state tests.
- Android preference, source-contract, and UI tests.
- macOS, iPhone Simulator, and Android emulator builds.
- Paired Today and metric-editor captures at phone and desktop sizes.
- Localization, health-claims, operations-record, release-control, and diff
  hygiene gates appropriate to the changed surface.

## Physical device and deployment

- Install/update action: not run.
- Physical BLE/background/haptic/battery scenarios: out of scope.
- Release, signing, store, firmware, and production-traffic action: none.

## Open risks and honest limitations

- Simulator captures cannot prove physical-device font rendering or touch
  ergonomics.
- Hydration can be selected only when its existing opt-in is enabled; otherwise
  the editor must explain why it is unavailable.
- Metrics without two genuine observations must not receive a fabricated trend.

## Privacy check

- [x] No credentials, personal health values, device identifiers, signing
      material, or private supplier artifacts are present.

## Verification result

- Apple macOS dual-architecture app build: passed.
- Apple focused contracts: Key Metric preferences/progress, Daily Signal, and
  settings disclosure passed.
- Android Demo focused contracts: Key Metric preferences and Today metric
  catalog passed.
- Diff hygiene: passed.
- Visual review: the Today grid remains limited to the selected three through
  six cards; the editor exposes all 14 grouped choices with search, reorder,
  add, and remove controls; Fitness Age is a compact weekly lane below Daily
  Signal. No observed clipping or overlap in the reviewed phone and desktop
  captures.
- Physical-device behavior was not tested or claimed.
