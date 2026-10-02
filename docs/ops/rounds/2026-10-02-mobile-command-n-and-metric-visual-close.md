# Round: 2026-10-02 - Mobile command N and metric visual close

## Status

- State: `verified locally; protected integration pending`
- Owner: project team
- Branch: `codex/mobile-command-n-visual-close-20261002`
- Start commit: `e840874872f5e7eb7f38afcecd7aaa826b12288e`
- End implementation commit: commit containing this record
- Record commit or PR: pending protected pull request

## Objective

Close the remaining mobile presentation evidence without overstating hardware
behavior:

- make the movable action control read as the requested NOOP `N` on iPhone and
  Android rather than as a generic activity ring;
- preserve its drag, edge snap, persistence, launcher, and accessibility
  behavior;
- visually verify the current Android Daily Signal and complete 18-choice
  Today metric editor;
- retain the existing source boundaries for Steps, Apple Health, Health
  Connect, WHOOP, supplier-native data, and NOOP-derived insights.

## Scope

### In scope

- The tiny iPhone and Android command-lens glyph and focused source contracts.
- Current iPhone Simulator and Android API 35 emulator captures.
- Follow-up evidence for the Daily Signal and direct/derived metric rounds.
- Operations records and protected-main integration.

### Non-goals

- Metric formulas, source arbitration, storage, accounts, network behavior,
  BLE, firmware, background collection, notifications, or release distribution.
- Claiming physical Apple Watch, WHOOP, supplier-band, HealthKit, Health
  Connect, battery, accuracy, haptics, or assistive-technology behavior.

## Starting evidence

- Current protected-main source drew an 80-percent circular arc with a center
  dot inside the movable lens. At phone density it read as an `O` or activity
  ring, despite the earlier mobile-brand round recording the requested `N`.
- The direct/derived metric round still listed Android visual review as
  pending.
- A clean-wipe Android API 35 emulator was already running the exact
  protected-main-equivalent tree with synthetic, non-health demo state.
- Existing protected evidence already covered the fresh Terms -> band ->
  account -> ownership -> profile -> plan flow and exact-date Trends
  interaction; this presentation-only repair does not alter either path.

## Delivered

- Replaced the arc/dot glyph with one matched geometric `N` on Apple and
  Android. Both implementations use the same bottom-left -> top-left ->
  bottom-right -> top-right path, rounded 2.5-point stroke, and
  cyan/teal/charge gradient.
- Preserved the `48x52` interaction target, `18x38` visible lens, bounded drag,
  nearest-edge snap, stored edge/height, nine-action launcher, and non-drag
  accessibility movement actions.
- Kept the existing spoken labels: iPhone `NOOP action center`; Android
  localized `Quick actions`. No health value or drag coordinate is logged.
- Reviewed the current Android Today surface at `1080x2424`: no observed
  clipping or overlap in Daily Signal, Fitness Age, self-check, Key Metrics,
  bottom navigation, or the edge N.
- Reviewed the Android metric editor in upper and lower states. It exposes all
  18 Today-ready choices and clearly separates measured/imported,
  source-dependent, and NOOP-insight rows.
- Confirmed Steps remains in the selected fresh-install six as
  `Activity - Measured`. Primary Steps still excludes motion-derived and
  calibrated estimates; WHOOP Steps remains unavailable without validated
  source data.
- Reviewed the current iPhone Today surface at `1206x2622`: the N is legible,
  edge-attached, and clear of the self-check, metric cards, and navigation.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none. Simulator values are
  synthetic and do not establish sensor delivery or accuracy.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: focused source
  contracts, bounded build status files, exact screenshot/XML hashes, launch
  status, and process cleanup.
- Why existing evidence is sufficient, or why new evidence is required: the
  changed boundary is deterministic local drawing only. Geometry and visual
  evidence diagnose it more directly than a runtime event.
- Existing evidence reused: command-lens position tests, accessibility
  identifiers/actions, protected onboarding evidence, and protected Trends
  interaction evidence.
- New bounded events or operation spans: none. Render- or drag-frame logging
  would be high frequency and would not improve diagnosis.
- Redaction, retention, and high-frequency controls: synthetic screenshots
  only; no user health values, identifiers, raw BLE data, or coordinates enter
  diagnostics or repository evidence.
- Cross-platform/backend correlation: matched Apple/Android path contracts and
  paired screenshots; backend is not applicable.
- Remaining blind spots: physical drag comfort, VoiceOver/TalkBack traversal,
  OLED rendering, and frame pacing.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Android focused compile and unit contract | Initial run compiled production but failed on a new test-fixture reference; corrected rerun passed `PrimaryNavigationContractTest` with `BUILD SUCCESSFUL` in 18 seconds | The production glyph compiles, the test names the geometric N, and existing movement/persistence contracts remain green | OEM or physical TalkBack behavior |
| Android Full debug APK | `assembleFullDebug` passed through the bounded runner | The exact changed production candidate packages successfully | Signed installation or physical-band behavior |
| Android API 35 visual review | `1080x2424` Today capture SHA-256 `3dd114ad0b5922c859b0cff38463c3a97a1b2a8d1ddbbeec0750d4a39fcbbd9`; semantics XML SHA-256 `085d8b1ef971a85be92b08f51ed545a60289e77c390c1af3b20078321a154b34` with content description `Quick actions` | The N is visually distinct and the current Today layout has no observed clipping or overlap | Physical display, touch comfort, or TalkBack focus order |
| Android metric-editor visual review | Upper capture SHA-256 `bd10cd4af6338562ecff7e78c556c44dfe43bf6ab47ba9e0fe41453d40419c86`; lower capture SHA-256 `586ca6c0db7f47e4ea66478d5c59216754deb73a1b17962ab7b188137791b973` | All 18 choices, selected Steps, measured/source-dependent/NOOP grouping, and stable layout are visible | Physical Health Connect or wearable delivery |
| Apple focused shell contract | 1/1 passed with `TEST SUCCEEDED` | The iPhone shell uses the geometric N and retains the launcher/accessibility contract | Physical VoiceOver or drag ergonomics |
| Complete iPhone Simulator graph | `NOOPiOS` build succeeded for iPhone 17 Pro Simulator, including Watch and app extensions | The changed iPhone source compiles in the real mobile graph | Signed phone, Watch sensor, BLE, or background behavior |
| iPhone visual review | `1206x2622` Today capture SHA-256 `935ae33b49a1731665f82d92634f6109c6206593ccd6af8430b221cc5127dcc4` | The N is legible and clear of Today content and navigation at the reviewed density | Every locale, Dynamic Type size, or physical display |
| Terminology inventory review | 18,605 classified occurrences across 1,647 path/category groups; zero forbidden mappings; regenerated inventory reviewed and release-gate pin updated | New operations evidence and shifted line numbers are classified without adding a customer-facing vendor-to-NOOP mapping | Removal of pre-existing compatibility terminology |
| Repository controls | Full all-platform i18n passed; 115 operations records valid; required-CI structure verified all ten contexts; terminology/required-CI suites passed 54 tests; health-claims/release-control/trusted-control suites passed 36 tests; health-claims clear across 1,324 files; nine release controls, legal inventory of 230 runtime components and three container inputs, and private-data filename guard passed | The implementation, evidence, generated inventory, and protected workflow contracts are coherent without a new unsafe claim or private filename | Hosted exact-head execution, release approval, or physical behavior |
| Diff hygiene | `git diff --check` passed before documentation closeout | No whitespace-error regression in the implementation patch | Runtime correctness outside the listed gates |

## Physical device and deployment

- Install/update action: unsigned Android Full debug APK installed on an API 35
  emulator; unsigned `NOOPiOS` app installed on an iPhone 17 Pro Simulator.
- Generalized device and OS class: Android API 35 emulator at `1080x2424` and
  iOS 26.5 iPhone 17 Pro Simulator at `1206x2622`.
- Data-preservation result: synthetic fixture state only; no product data path
  changed.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: signed physical phones, Apple Watch, WHOOP,
  supplier-band, HealthKit, Health Connect, BLE, battery, accuracy, background,
  haptics, VoiceOver, and TalkBack.

## Git and release state

- Changed paths: iPhone and Android shell glyphs, focused shell contracts, and
  operations records.
- Commits: pending local implementation commit.
- Branch and remote state: local branch from exact protected
  `main` `e840874872f5e7eb7f38afcecd7aaa826b12288e`; protected pull request
  and exact-main verification pending.
- Repository visibility verified: unchanged; public-source exclusions remain in
  force.
- Version/build impact: none planned.
- Release or distribution impact: source integration only; no store upload,
  signed release, firmware action, or production traffic.

## Decisions

- Durable decision added or changed: the movable action lens must use a
  recognizable geometric NOOP `N`; an arc/dot activity-ring glyph is not an
  acceptable substitute.
- Decision-log entry: not required. This restores the existing mobile-brand
  decision without changing product or data authority.

## Open risks and honest limitations

- Simulator/emulator evidence cannot establish physical drag ergonomics,
  assistive-technology focus order, physical frame pacing, BLE, source
  availability, battery, haptics, or sensor accuracy.
- WHOOP Steps remains intentionally unavailable until a validated direct or
  export value exists.
- Apple Health aggregates remain labelled Apple Health because the current
  flattened import does not retain enough device identity to claim Apple Watch.

## Next round

1. Complete protected checks, normal merge, and exact-main verification.
2. Run the signed physical-source matrix from
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
