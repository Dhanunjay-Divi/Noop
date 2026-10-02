# Round: 2026-10-01 - Today metric catalog and Fitness Age

## Status

- State: `locally verified after Android and Apple hosted-contract repair; protected integration pending`
- Owner: project team
- Branch: `codex/today-metric-catalog-fitness-age-20261001`
- Start commit: `5f0a798d3aada03ee2999ca6e18b2984aa184a5f`
- Record commit or PR: PR `#27`; final replacement commit pending

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
| Apple focused contracts | Pass: Key Metric preference/progress, Daily Signal, settings-disclosure, selected-row accessibility, and exact-date Trends scrub cases. The final macOS repair wall passes 5/5; the repaired iOS Key Metric boundary case and Recovery scrub case pass independently on the dedicated iPhone 17 Pro simulator. | Catalog membership, bounds, Fitness Age placement, accessible add/remove controls, selected-date chart state, and editor source contracts remain coherent | Every app regression or physical accessibility traversal |
| Android Demo focused contracts | Pass after the localization test correction: Key Metric preferences and Today metric catalog | Stable identifiers, ordering, bounds, hydration gate, routes, localized composed copy, and Fitness Age parity compile and pass in the Demo flavor | Full physical-device runtime behavior |
| Android Full unit wall after hosted contract repair | Pass: 5,262 tests, 7 skipped | The complete Full-flavor unit suite accepts the compact Fitness Age lane, scoped partial-locale additions, and Hydration's genuine goal progress | Android instrumentation on a physical phone |
| i18n and health-claims local gates | Pass: no new hardcoded or unextracted UI copy, complete focus-locale coverage, valid JSON/XML resources, and health-claims clear across 1,324 files | The new editor and accessibility copy is resource-backed without adding an unsafe health claim | Hosted execution on the replacement SHA or human translation review |
| Operations and terminology remediation | Pass: 111 operations records; 18,579 classified legacy occurrences across 1,641 groups; zero forbidden mappings; reviewed inventory SHA-256 `39c1ec2096ee0f4d88c2f3787b31a4c152e0ff5dd829a385513dcfc8b7a33942`; 54 terminology/required-CI tests | The round uses the complete required structure, and the generated terminology snapshot plus pinned digest match the rebased tree | Hosted-green release controls until the replacement head runs |
| Hosted PR `#27` head `30524ac09` | Every non-Apple required context passed, including the complete Android Full unit wall. Apple run `36899526468` then isolated three stale automation/source contracts: the old `FitnessAgeHeroLane` component name, removed Key Metric switches, and a whole-chart clearance assertion that did not model the movable edge lens. No product formula, metric source, or dashboard bound failed. | Hosted checks exercised the exact Android replacement and narrowed the remaining work to Apple test/accessibility contracts | A green final replacement SHA or protected integration |
| Final Apple hosted-contract repair | Pass locally: the Android source contract now names `FitnessAgeCompactLane`; the Key Metric editor exposes stable count, selected-row, add, and remove semantics while preserving the 3-6 boundary; and the Trends test scrolls the real container, verifies a lens-clear scrub path, reads the selected `Mon 7 Sep, 65` point, and confirms the scrub does not navigate. | The exact failures from Apple run `36899526468` are repaired and reproduced green in focused local result bundles | Full hosted Apple execution on the final replacement SHA |
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
- Rebased implementation commits:
  `2ccee6bd7` (metric catalog and Fitness Age) and
  `0592900f2` (localization), followed by `6980dc324` (release-gate repair)
  and `30524ac09` (complete Android contract repair); the next replacement
  commit carries the Apple hosted-contract repair and updated evidence.
- Branch and remote state: PR `#27` is open from
  `codex/today-metric-catalog-fitness-age-20261001`, rebased on protected-main
  closeout `08ad0f472a577e66fd612281550f549fa09c7703`; all non-Apple
  hosted contexts pass at `30524ac09`, the exact Apple failures are repaired
  and focused green locally, and one replacement push remains.
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

1. Push one replacement and require all protected contexts to pass.
2. Merge PR `#27` normally through protected `main`.
3. Re-run exact-main verification and retain signed-phone, physical-band,
   battery, background, haptic, and sensor-accuracy work as external gates.

## Privacy check

- [x] No credentials, personal health values, device identifiers, signing
      material, or private supplier artifacts are present.
