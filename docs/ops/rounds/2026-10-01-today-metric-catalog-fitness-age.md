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

## Delivered

- Apple and Android expose the same 14 Today-ready metric choices: Recovery,
  Sleep, Effort, HRV, resting heart rate, blood oxygen, respiratory rate, skin
  temperature, Steps, Calories, Weight, Hydration, Stress, and Vitality.
- The editor is selected-first, searchable, and grouped by Daily Signal,
  Vitals, Activity, and Wellbeing. Selected metrics can be reordered or removed;
  available metrics can be added without losing the existing three-card minimum
  or six-card maximum.
- Hydration remains visible in the catalog but can be newly selected only after
  the existing explicit hydration-tracking opt-in. An already selected
  Hydration tile remains visible and removable.
- Fitness Age is a compact, today-only weekly lane under Daily Signal on Apple
  and Android. It uses the existing month-precise presentation, calibration
  state, and detail route rather than becoming another large score card.
- Stress, Vitality, skin temperature, and Hydration reuse their existing
  sources, missing-state behavior, and detail destinations. Skin temperature
  does not fabricate a trend when the source may represent either an absolute
  reading or a deviation.
- Existing stored metric selections decode unchanged. Empty or invalid storage
  retains the existing six-metric fresh-install default.

## Data, privacy, and medical truth

- Schema or migration impact: additive recognition of stable display-only
  metric identifiers; existing saved selections remain unchanged.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: Stress remains a non-diagnostic,
  personalized wellness estimate; missing or unqualified inputs remain visibly
  unavailable rather than inferred.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple macOS dual-architecture app build | Pass | The shared Apple Today surface and editor compile for both macOS architectures | Signed iPhone behavior or physical touch ergonomics |
| Apple focused contracts | Pass: Key Metric preference/progress, Daily Signal, and settings-disclosure cases | Catalog membership, bounds, Fitness Age placement, and editor source contracts remain coherent | Every app regression or physical accessibility traversal |
| Android Demo focused contracts | Pass: Key Metric preferences and Today metric catalog | Stable identifiers, ordering, bounds, hydration gate, routes, and Fitness Age parity compile and pass in the Demo flavor | Full physical-device runtime behavior |
| i18n and health-claims local gates | Health-claims pass; final exact i18n remediation in progress after hosted audit identified newly authored literals | No new unsafe health claim; the exact remaining localization scope is known | Hosted-green localization until the replacement head runs |
| Initial hosted PR `#27` policy checks | Operations record, terminology snapshot, and i18n failed narrowly; applicability, health claims, runtime licenses, server, Swift packages, and trusted release controls passed; Apple and Android app jobs continued | The remote candidate reached exact-head verification and isolated evidence/localization defects rather than a hidden gate bypass | A green replacement SHA or protected integration |
| Visual review | Reviewed phone and desktop Today/editor captures without observed clipping or overlap | The selected grid remains glanceable, the full catalog is discoverable, and Fitness Age is visually subordinate to daily scores | Every viewport, locale, Dynamic Type size, or physical display |
| Diff hygiene | Pass | No whitespace or merge-marker defect in the current change | Runtime correctness beyond the listed gates |

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

## Git and release state

- Changed paths: Apple and Android Key Metric registries, Today rendering,
  metric editors, focused tests, localization resources, terminology inventory,
  and operations records.
- Implementation commit: `82e71db8b0de23fafe3e365a7aac416eb8467ce0`.
- Branch and remote state: PR `#27` is open from
  `codex/today-metric-catalog-fitness-age-20261001`; initial hosted policy
  failures are being corrected on the same branch.
- Repository visibility verified: unchanged.
- Version/build impact: none planned.
- Release or distribution impact: source integration only after all protected
  checks pass; no store release or production-traffic action.

## Decisions

- Keep Today bounded to three through six selected cards instead of rendering
  every sensor reading on the primary scroll.
- Make the editor the complete Today-ready catalog, not a raw Metric Catalog
  browser containing internal or diagnostic series.
- Keep Fitness Age fixed in Daily Signal because it updates weekly and should
  not compete with the daily Recovery, Sleep, and Effort scores.
- Preserve Hydration's existing explicit opt-in and avoid implying that an
  unconfigured target is a meaningful progress axis.
- Preserve existing formula, source, persistence, account, network,
  notification, and BLE behavior.

## Next round

1. Complete localization and terminology remediation, push one replacement,
   and require all protected contexts to pass.
2. Rebase after the protected PR `#26` documentation closeout if it merges
   first, then merge PR `#27` normally through protected `main`.
3. Re-run exact-main verification and retain signed-phone, physical-band,
   battery, background, haptic, and sensor-accuracy work as external gates.

## Privacy check

- [x] No credentials, personal health values, device identifiers, signing
      material, or private supplier artifacts are present.
