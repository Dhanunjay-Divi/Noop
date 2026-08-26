# Round: 2026-08-23 - Repository independence and mainline consolidation

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `236f3b73`
- End implementation commit: `94661a17`
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Move the active checkout and all completed application work to the canonical
`Dhanunjay-Divi/Noop` GitHub repository, remove obsolete hosting artifacts,
leave a clean single-branch handoff, and prevent a hosting migration from being
misrepresented as commercial source clearance.

Success requires a clean local and remote `main`, no obsolete shared signing
key or LAN handoff, current round and agent documentation, passing engineering
checks, and a release gate that remains closed until every recorded rights issue
has reviewable evidence.

## Scope

### In scope

- Verify the canonical GitHub repository, authentication, visibility, default
  branch, and fork relationship.
- Consolidate completed local history on `main` and remove merged remote
  feature branches.
- Rename retired hosting workflow paths and remove stale hosting/stat artifacts.
- Remove the tracked shared Android debug key and document per-machine debug
  signing.
- Add machine-readable rights status, terms-version parity, provenance
  retention checks, and a fail-closed distribution gate.
- Bring Terms 2.3, notices, repository documentation, the active ops record,
  and the agent handoff into agreement.

### Non-goals

- Claim that changing remotes or GitHub metadata transfers source rights.
- Remove required license, notice, attribution, contributor, or upstream
  provenance records while affected source remains.
- Rewrite inherited implementation or establish clean-room independence.
- Publish a commercial binary, sign store artifacts, or validate physical
  wearable behavior.

## Starting evidence

- The canonical GitHub repository was private with `main` as its default branch.
- Authenticated GitHub inspection reported `isFork=false` and no parent.
- Local `main` contained 45 completed commits not yet present on
  `origin/main`; the remote had no divergent commit.
- Three remaining remote feature branches were all ancestors of local `main`.
- The tree still had retired hosting workflow filenames, a tracked shared debug
  keystore, a stale fork-count artifact, and an obsolete LAN agent handoff.
- The current NOOP owner declaration was recorded on 2026-08-25.

## Delivered

- Added `docs/REPOSITORY_INDEPENDENCE.md` and
  `docs/provenance/rights-status.json` as the human and machine-readable
  repository-rights source of truth.
- Expanded `Tools/release-legal-gate.py` so dependency inventory, required
  provenance markers, required blockers, structured resolution evidence, and
  Apple/Android Terms versions fail closed.
- Updated Apple, Android, and source Terms acknowledgment to version 2.3 and
  restored consistent noncommercial wording for this reference tree.
- Renamed the release workflows to `release.yml` and `testing-build.yml`.
- Removed the tracked shared Android debug key, stale fork-count badge data,
  obsolete LAN handoff, and their active references.
- Regenerated all distributed NOTICE copies from the reviewed preamble.
- Corrected the source-classification ceiling to 49,168 lines across 154 files,
  while retaining the 15,980-line Apple package core as the known minimum.
- Replaced the stale active ops handoff and added a current agent handoff.
- Consolidated all completed work on `main` and removed the three merged remote
  feature branches.
- Used the repository's explicit migration baseline to capture the previously
  unpushed localization debt exposed by hosted CI: 247 unique Android literals
  and 166 unique Apple literals. The no-new-literal gate remains strict.
- Restored focus-locale catalog completeness and applied the pinned Ruff format
  to two server files that hosted CI identified.
- Stabilized profile measurement editing so the bottom action inset is removed
  while the software keyboard is open, the measurement fields are revealed
  after `keyboardDidShow`, and clear/retype controls remain reachable on both
  standard and compact iPhone layouts.
- Moved the DEBUG charging fixture to synchronous live-state setup before the
  first frame. This removed a hosted-only race between the Today masthead and
  the asynchronous database seed without changing production behavior.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none. No app install, uninstall, database
  operation, device reset, or user-data mutation occurred.
- Source/provenance or formula impact: provenance controls changed; health,
  scoring, detection, and calibration formulas did not.
- Terms impact: version 2.3 causes a fresh acknowledgment where the app's
  existing terms gate requires one.
- Localization impact: focus-locale coverage is structurally complete, but the
  tracked literal baseline is not translated UI and reproductive-health copy
  still requires native-speaker review.
- Permissions/network disclosure impact: none in app runtime behavior.
- Health/medical claim impact and limitations: the health-claims gate remains
  clear; no build or unit test establishes medical accuracy or safety.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `python3 -m unittest discover -s Tools/tests -p 'test_*.py' -v` | 25/25 passed | Legal, release-workflow, health-copy, screenshot, and upstream-watch tool contracts pass | Platform runtime behavior |
| `python3 Tools/release-legal-gate.py check` | Passed; 152 runtime components and 3 container inputs | The exact dependency notices, owner record, and Terms versions are internally consistent | Signing, store, or physical-device readiness |
| `python3 Tools/release-legal-gate.py distribution` | Passes under the 2026-08-25 NOOP owner declaration | The current owner record, NOOP license, and dependency notices are coherent | Signing, store, or physical-device readiness |
| `python3 Tools/health_claims_gate.py` | Clear; 1,039 files scanned | Checked user-facing source avoids unsupported affirmative health claims | Clinical validity |
| Android compile and unit tests | `BUILD SUCCESSFUL`; `compileFullDebugKotlin` and `testFullDebugUnitTest` passed | The Android source and unit-test graph compile after Terms and signing changes | Physical OEM, BLE, background, haptic, or store behavior |
| Unsigned macOS Debug app build | Passed | The macOS app graph compiles after the synchronized Terms change | Signing, notarization, runtime behavior, or physical BLE behavior |
| Unsigned iOS Debug simulator build | Passed | The iOS app graph compiles after the synchronized Terms change | Signing, App Store acceptance, physical BLE, background, haptic, or battery behavior |
| Workflow YAML parse and release-workflow tests | Passed | Renamed workflow files are syntactically readable and retain tested promotion/rollback contracts | A hosted release run or signing-secret availability |
| First hosted `main` run | i18n and server Ruff-format jobs failed | Canonical CI caught debt hidden while 46 commits were local-only | Product or release readiness |
| `python3 Tools/i18n_audit.py --ci origin/main` after migration | Passed; 247 Android and 166 Apple unique literals baseline-tracked | Focus locales are structurally complete and future literal additions fail CI | Translation of baseline entries or native-speaker approval |
| Ruff 0.12.2 and local server tests | `ruff check` and format check passed; 59 tests passed, 4 database-dependent tests skipped | Python style and non-database server behavior are green | TimescaleDB, containers, backup restore, or production deployment |
| Profile measurement UI regression | 5/5 passed on iPhone 17 Pro and 5/5 on compact iPhone 17e | Weight and height can be cleared and retyped while the height field and clear action remain hittable above the software keyboard | Physical-device keyboards, accessibility review, or every Dynamic Type size |
| Full local iOS production-shell suite at `94661a17` | 16/16 passed on iPhone 17 Pro | The production navigation, metrics, reminders, profile, sleep, terms, charging, and calendar UI contracts pass together | Physical BLE, HealthKit, background, haptic, battery, or medical behavior |
| Clean charging fixture regression | 5/5 UI iterations passed on a newly created simulator; `AppleDemoSeederTests` passed 2/2 | Charging live state is present before the first frame and remains inert without `--demo-seed` | Real band charging telemetry |
| Hosted app run `32668839522` | macOS passed; iOS failed only `testBandBatteryShowsChargingStateFromLiveFixture` before `94661a17` | The failure was isolated to first-frame DEBUG fixture timing and was retained rather than rewritten as a pass | The subsequent remediation result |
| Final hosted app run `32670362286` at `94661a17` | Passed: universal macOS build plus 1,390 tests with 1 skipped; iOS simulator build plus 16/16 production-shell tests, including charging | The first-frame remediation passes on clean hosted runners across both Apple jobs | Signing, physical hardware, or store readiness |
| Hosted i18n run `32670362251` and health-claims run `32670362291` at `94661a17` | Passed | The final implementation checkpoint preserves both hosted policy gates | App compilation or runtime behavior |
| Ops validator, private-data guard, JSON parse, and `git diff --check` | Passed | Documentation structure, filename privacy guard, structured state, and whitespace are clean | A full secret-history audit |
| Authenticated GitHub inspection | Private; default `main`; `isFork=false`; parent absent | The canonical hosting repository is standalone in GitHub metadata | Source ownership, which was recorded separately on 2026-08-25 |
| Git ancestry checks | All three legacy branches and `origin/main` were ancestors of local `main` | Mainline push and branch deletion do not discard unique branch commits | Correctness of every historical commit |

## Physical device and deployment

- Install/update action: not run.
- Simulator evidence: iPhone 17 Pro and compact iPhone 17e on iOS 26.5.
- Generalized physical device and OS class: not applicable to this repository
  round.
- Data-preservation result: no device or application data was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: the complete iOS, Android OEM, Watch, WHOOP 5/MG,
  overnight, reconnect, haptic, battery, and background validation matrix.

## Git and release state

- Changed paths: legal/provenance tooling and tests, terms, notices, workflow
  names, repository/ops documentation, and obsolete artifact removals.
- Commits: one repository-independence commit on top of the 45 completed local
  commits, followed by bounded hosted-CI, profile-keyboard, and demo-fixture
  remediation commits through `94661a17`.
- Branch and remote state: local `main` matches `origin/main`; merged remote
  feature branches are removed; `origin/HEAD` resolves to `origin/main`.
- Repository visibility verified: private.
- Version/build impact: no application marketing or build-number change.
- Release or distribution impact: no artifact was published. The later owner
  declaration cleared the source-rights gate.

## Decisions

- Standalone hosting and source-rights evidence are separate facts.
- NOOP source ownership is recorded by the owner declaration; independent
  runtime dependencies retain their own license texts.
- Decision-log entries: D-008 updated; D-011 added.

## Open risks and honest limitations

- The current NOOP owner declaration governs source rights.
- This round does not provide legal advice or replace review by qualified
  counsel.
- No store signing, notarization, release-secret, physical-device, accuracy,
  clinical, or regulatory gate was completed.
- The i18n baseline tracks 413 unique hardcoded or unextracted literals. Passing
  the regression gate does not mean those surfaces are translated.
- The reproductive-health locale values remain machine translations pending
  native-speaker sign-off in every supported locale.
- Existing commit history was retained; the current release gate validates the
  owner-rights record and does not rely on a history rewrite.

## Next round

Remaining launch work is store signing and metadata, production infrastructure,
carrier paging evidence, physical-device validation, held-out accuracy studies,
and native-speaker localization review.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
