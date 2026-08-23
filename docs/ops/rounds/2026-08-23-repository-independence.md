# Round: 2026-08-23 - Repository independence and mainline consolidation

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `236f3b73`
- End implementation commit: the commit containing this record
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
- Rename fork-era workflow paths and remove stale hosting/stat artifacts.
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
- The tree still had fork-era workflow filenames, a tracked shared debug
  keystore, a stale fork-count artifact, and an obsolete LAN agent handoff.
- The inherited source, PolyForm Noncommercial terms, unlicensed WHOOP 4
  expression, and multi-author history still prevented an honest commercial
  clearance claim.

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
| `python3 Tools/release-legal-gate.py check` | Passed; 152 runtime components and 3 container inputs | The exact dependency notices, provenance markers, rights state, and Terms versions are internally consistent | Commercial distribution rights |
| `python3 Tools/release-legal-gate.py distribution` | Rejected with the three recorded blockers, as designed | Artifact publishing remains fail closed | Resolution of any blocker |
| `python3 Tools/health_claims_gate.py` | Clear; 1,039 files scanned | Checked user-facing source avoids unsupported affirmative health claims | Clinical validity |
| Android compile and unit tests | `BUILD SUCCESSFUL`; `compileFullDebugKotlin` and `testFullDebugUnitTest` passed | The Android source and unit-test graph compile after Terms and signing changes | Physical OEM, BLE, background, haptic, or store behavior |
| Unsigned macOS Debug app build | Passed | The macOS app graph compiles after the synchronized Terms change | Signing, notarization, runtime behavior, or physical BLE behavior |
| Unsigned iOS Debug simulator build | Passed | The iOS app graph compiles after the synchronized Terms change | Signing, App Store acceptance, physical BLE, background, haptic, or battery behavior |
| Workflow YAML parse and release-workflow tests | Passed | Renamed workflow files are syntactically readable and retain tested promotion/rollback contracts | A hosted release run or signing-secret availability |
| First hosted `main` run | i18n and server Ruff-format jobs failed | Canonical CI caught debt hidden while 46 commits were local-only | Product or release readiness |
| `python3 Tools/i18n_audit.py --ci origin/main` after migration | Passed; 247 Android and 166 Apple unique literals baseline-tracked | Focus locales are structurally complete and future literal additions fail CI | Translation of baseline entries or native-speaker approval |
| Ruff 0.12.2 and local server tests | `ruff check` and format check passed; 59 tests passed, 4 database-dependent tests skipped | Python style and non-database server behavior are green | TimescaleDB, containers, backup restore, or production deployment |
| Ops validator, private-data guard, JSON parse, and `git diff --check` | Passed | Documentation structure, filename privacy guard, structured state, and whitespace are clean | A full secret-history audit |
| Authenticated GitHub inspection | Private; default `main`; `isFork=false`; parent absent | The canonical hosting repository is standalone in GitHub metadata | Ownership of inherited source |
| Git ancestry checks | All three legacy branches and `origin/main` were ancestors of local `main` | Mainline push and branch deletion do not discard unique branch commits | Correctness of every historical commit |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not applicable to this repository round.
- Data-preservation result: no device or application data was mutated.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: the complete iOS, Android OEM, Watch, WHOOP 5/MG,
  overnight, reconnect, haptic, battery, and background validation matrix.

## Git and release state

- Changed paths: legal/provenance tooling and tests, terms, notices, workflow
  names, repository/ops documentation, and obsolete artifact removals.
- Commits: one repository-independence commit on top of the 45 completed local
  commits, followed by a bounded hosted-CI remediation commit.
- Branch and remote state: local `main` matches `origin/main`; merged remote
  feature branches are removed; `origin/HEAD` resolves to `origin/main`.
- Repository visibility verified: private.
- Version/build impact: no application marketing or build-number change.
- Release or distribution impact: no artifact was published. Distribution
  remains blocked by `docs/provenance/rights-status.json`.

## Decisions

- Standalone hosting and source-rights independence are separate facts.
- Attribution and provenance are removed only after affected source is licensed,
  independently replaced, or removed with reviewed evidence.
- Decision-log entries: D-008 updated; D-011 added.

## Open risks and honest limitations

- Three commercial-rights blockers remain unresolved: PolyForm upstream
  lineage, unlicensed WHOOP 4 expression, and contributor relicensing rights.
- This round does not provide legal advice or replace review by qualified
  counsel.
- No store signing, notarization, release-secret, physical-device, accuracy,
  clinical, or regulatory gate was completed.
- The i18n baseline tracks 413 unique hardcoded or unextracted literals. Passing
  the regression gate does not mean those surfaces are translated.
- The reproductive-health locale values remain machine translations pending
  native-speaker sign-off in every supported locale.
- A new GitHub repository containing this inherited history is not a clean-room
  commercial implementation.

## Next round

1. Choose and execute a documented resolution route for each rights blocker:
   rights-holder license, independent replacement, or removal.
2. Build the commercial product in a genuinely independent history containing
   only newly authored or separately licensed code.
3. Record affected-source manifests and independent review evidence, then
   update the rights state and rerun both legal gates.
4. Retire the localization baseline through reviewed resource migrations and
   complete native-speaker review of reproductive-health copy.
5. Only after the distribution gate passes, complete signing, store,
   physical-device, accuracy, safety, and regulatory release work.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
