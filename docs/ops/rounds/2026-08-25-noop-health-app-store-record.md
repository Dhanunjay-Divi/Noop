# Round: 2026-08-25 — NOOP Health App Store record and release preflight

## Status

- State: `protected release candidate compiled; signed archive and upload blocked`
- Owner: project team
- Branch: `codex/app-store-submit-20260825`
- Start commit: `9d4a6957`
- End implementation commit: `c1cdd8b3`
- Record commit or PR: private branch head

## Objective

Reserve the first available App Store name in the order `NOOP`,
`NOOP Health`, then `NOOP Fit`; preserve the existing production bundle
identity; build the exact private mainline as Release; and archive, upload, or
submit only when the current release gates pass.

## Scope

### In scope

- Create one iOS App Store Connect record using the first accepted name.
- Keep the embedded Watch app, complication, and widget inside the iOS record.
- Validate exact private `origin/main` without overwriting prior safety records.
- Require the local launch-access verifier before any archive can succeed.

### Non-goals

- Changing the bundle identifier, app-group identity, or local data container.
- Storing the plaintext launch code in Git, source, logs, or this record.
- Claiming that compilation proves BLE, background, medical, or store behavior.
- Bypassing distribution, signing, media, reviewer, or physical-device gates.

## Starting evidence

- Reproduction or observed symptom: exact `NOOP` was previously rejected as
  unavailable; the owner requested `NOOP Health`, then `NOOP Fit` as fallback.
- Relevant source/device/OS/firmware class: private canonical iOS/iPadOS app with
  embedded Watch app, complication, and widget.
- Existing tests, logs, exports, screenshots, or documents: closed 2026-08-24
  submission audit and current private `origin/main`.
- Unknowns that must remain unknown until measured: whether Apple accepts the
  fallback name, whether signing can be provisioned, and whether the final
  signed archive passes validation and physical-device review.

## Delivered

- Fetched private `origin/main` and isolated exact commit `9d4a6957` in a
  separate worktree so older local operations notes could not overwrite newer
  safety records.
- Created the App Store Connect iOS record as `NOOP Health` with English
  (U.S.), the existing bundle identifier, the fixed internal SKU, and full
  team access. Apple assigned durable app ID `6804921246`; the record is in
  `Prepare for Submission`.
- Kept the existing NOOP icon assets unchanged. App Store Connect does not
  accept an icon during record creation; the storefront icon will be taken
  from the signed app build when it is uploaded.
- Changed App Store Version Release from Apple's automatic-release default to
  `Manually release this version`, so approval cannot publish the protected
  preview before an explicit owner go-live action.
- Completed an unsigned generic iOS Release build from exact mainline.
- Rebuilt with the ignored local bundle/team mapping attached without adding it
  to Git. The initial mainline artifact resolved the existing bundle family at
  `9.2.0 (229)`; the protected candidate was then rebuilt in lockstep as
  `9.2.0 (230)`.
- Generated the ignored one-way launch-access verifier interactively for
  rotation `appstore-2026-08-25-v1`. The file is mode `0600`, remains ignored
  by Git, contains no plaintext access code, and passes the Release archive
  validation contract.
- Matched the App Store record to marketing version `9.2.0` and advanced the
  source build from `229` to `230` across the iPhone app, widget, Watch app,
  and Watch complication without changing any bundle or App Group identity.
- Extended the temporary preview boundary to every embedded user-facing
  surface. A required build now defaults to a neutral locked presentation in
  iOS widgets, Lock Screen widgets, Live Activities, Dynamic Island, the Watch
  app, and Watch complications until the iPhone has accepted the current gate
  version. Missing, corrupt, legacy, or version-mismatched receipts deny.
- Deferred returning-user BLE restoration, paired-scale reconnection,
  analysis, Watch publishing, Health observers, GPS-workout restoration, and
  scheduled diagnostic work until launch access and the current Terms are
  accepted. Extensions receive only a non-secret required/version marker;
  they never receive the verifier, salt, candidate code, or a derivative.
- Isolated the ignored verifier build settings to the `NOOPiOS` target through
  a dedicated target wrapper. CI and local validation inspect setting names
  only and fail if salt, verifier, or iteration keys reach the widget, Watch,
  or complication targets.
- Added a locked-start WatchConnectivity scrub for staggered upgrades. A build
  230 iPhone sends a build-229-decodable empty score snapshot and empty
  strength plan while locked, so an older paired Watch cannot keep presenting
  cached health values until it receives the newer Watch binary.
- Localized the neutral locked presentation for the iPhone-adjacent widgets,
  Live Activity/Dynamic Island, Watch app, and complication in the supported
  Apple catalog languages.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: the existing bundle and app-group identity
  remain mandatory for in-place upgrade continuity.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: unchanged by this preflight; final
  App Store disclosures must be checked against the signed archive.
- Health/medical claim impact and limitations: compilation and name reservation
  do not validate sensors, scores, background delivery, or medical claims.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Private `origin/main` fetch | `9d4a6957`; repository private and standalone | The round used the canonical private mainline at its start. | Current signing or store readiness. |
| `python3 Tools/release-legal-gate.py check` | Pass; 152 runtime components and 3 container inputs | Inventory is internally consistent. | Signing, store review, or physical behavior. |
| `python3 Tools/release-legal-gate.py distribution` | Pass under the NOOP owner declaration | The NOOP license, owner declaration, and exact dependency notices are coherent. | Signing, store review, or physical behavior. |
| `python3 Tools/check-private-data.py` | Pass | No prohibited private-data filenames are tracked. | Final archive privacy labels. |
| `python3 Tools/validate-ops-rounds.py --all .` | Pass for all 11 rounds | The current ledger, including this round, is structurally valid. | Product or release correctness. |
| `python3 Tools/health_claims_gate.py` | Pass across 1,053 files | Current copy gate is clear. | Clinical accuracy or regulatory status. |
| Release-tool unit tests | 30/30 pass | Release helper and launch-isolation contracts pass locally. | App Store acceptance. |
| `python3 Tools/i18n_audit.py --ci origin/main` | Pass for Android and all Apple focus catalogs | The locked-surface update adds no untranslated focus-locale copy or new raw UI literals. | Native-speaker quality. |
| Unsigned generic iOS Release build | Pass | Exact mainline compiles for the app and embedded targets. | Signing, archive validation, or hardware behavior. |
| Bundle inspection | Existing app/widget/Watch/complication family; final candidate `9.2.0 (230)` | Artifact identity matches the intended App Store record and upgrade path. | Provisioning or distribution authorization. |
| Archive-like launch-access validation | Missing-verifier fixture fails; generated ignored verifier passes | Ungated archive fails closed and the local protected verifier has the required shape. | Strength against a patched client or App Review acceptance. |
| App Store Connect app record | `NOOP Health`, app ID `6804921246`, `Prepare for Submission` | Apple accepted the localized name and bound the existing main bundle ID to a durable record. | Archive validation, upload, review, or release. |
| App Store release control | `Manually release this version` saved | An approved build will wait for an explicit release action. | That a build has been uploaded or approved. |
| Existing icon assets | Primary Obsidian NOOP mark plus existing alternate and Watch icon sets remain unchanged | The next signed build will carry the established NOOP logo. | That Apple has ingested or rendered the icon before build upload. |
| `swift test` for `StrandDesign` | 51/51 pass | Cross-surface authorization, version rotation, malformed state, legacy Watch denial, and build-229 scrub decoding contracts pass. | Physical Watch/Widget/ActivityKit behavior. |
| Focused `LaunchAccessTests` | 13/13 pass | Explicit `required=false` disables the gate consistently in Debug, malformed required flags fail closed, and Release remains required. | Signed archive or App Review behavior. |
| Unsigned generic iOS Release build after gate hardening | Pass for app, widget/Live Activity, Watch app, and complication | The full embedded Release dependency graph compiles as `9.2.0 (230)`. | Signing, upload, App Review, or hardware behavior. |
| Built-product launch policy inspection | All four bundles require one resolved gate version; all three extensions contain no verifier, salt, or iteration value | Embedded surfaces carry only non-secret exact-version policy and fail closed on absent authorization. | Encryption or resistance to a patched binary/container owner. |
| `Tools/validate-launch-gate-isolation.py` | Pass with the local verifier and in clean-checkout mode | Verifier setting names resolve only for `NOOPiOS`; embedded targets receive public policy only. The checker retains names and never prints values. | Runtime secrecy against a controlled build host. |
| Staggered Watch payload tests | Build-229-shaped decoder receives nil scores/HR, empty summary, epoch time, and empty strength state | A locked build-230 phone can overwrite health-bearing caches understood by the immediately preceding Watch build. | Apple-managed delivery timing or a physical staggered upgrade. |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no device mutation in this round
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: WHOOP 5/MG, HealthKit, Watch, widget, Live Activity,
  background sync, battery, haptics, and in-place upgrade retention

## Git and release state

- Changed paths: App Store localized name and release records, cross-surface
  launch authorization contract/tests, iPhone startup/BLE deferral, Watch
  transport/UI, widgets/Live Activity, embedded target policy, and build number
- Commits: App Store reservation/metadata record committed on the branch;
  protected-surface implementation committed as `c1cdd8b3`
- Branch and remote state: pushed to private origin as
  `codex/app-store-submit-20260825`
- Repository visibility verified: private
- Version/build impact: App Store version remains `9.2.0`; build advanced in
  lockstep from `229` to `230`
- Release or distribution impact: the App Store record was created; no signed
  archive, upload, submission, review request, or release has occurred

## Decisions

- Durable decision added or changed: use `NOOP Health` as the first fallback
  App Store localization while keeping the installed bundle and app-group
  identity unchanged and retaining the NOOP logo.
- Durable decisions: `D-027` for App Store identity and `D-028` for the
  exact-version, fail-closed embedded-surface preview boundary.

## Open risks and honest limitations

- Local signing has no validated Apple Distribution identity or matching
  App Store profiles for every embedded target.
- Final iPad and Watch media, hardware-independent reviewer path, signed archive
  privacy/entitlement validation, and physical-device release matrix are open.
- The source-rights gate is clear. Signing, final media rights review, store
  disclosures, and physical-device release evidence remain open.
- The preview gate is a client-side presentation/distribution deterrent, not
  health-data encryption or durable authentication. App Group data remains at
  rest, and a party controlling the binary or container can bypass the UI.
- A locked cold launch intentionally postpones a staged database restore until
  the next authorized cold launch; BLE and scale restoration resume after
  authorization. This behavior requires physical in-place upgrade testing.
- WatchConnectivity application-context delivery is Apple-managed. A physical
  staggered-upgrade test must still update the iPhone from 229 to 230 while the
  Watch remains on 229, confirm old complication values clear while locked,
  then confirm current data rehydrates after authorization.

## Next round

1. Resolve the remaining signing, reviewer, media, and physical-device gates.
2. Archive and validate every embedded target with the generated local
   verifier without staging the ignored verifier file.
3. Upload only the validated signed build, then complete metadata and submit
   for review as a separate, explicitly recorded action.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
