# Round: 2026-08-22 — First App Store submission

## Status

- State: `blocked before public upload`
- Owner: project team
- Branch: `codex/day4-sync-performance`
- Start commit: `241f2000`
- End implementation commit: `972a126b`
- Record commit or PR: documentation-only follow-up immediately after
  `972a126b`; no PR opened

## Objective

Prepare NOOP's first paid-developer public App Store submission, add a launch
gate using the user-provided shared secret without storing that secret in source
or documentation, preserve existing local data, and upload only after signing,
privacy, legal, build, and launch checks pass.

Success means the archive is accepted by App Store Connect, the listing and
review metadata are complete, App Review receives the credential privately, and
the version is submitted for public App Store review. Release after approval is
part of this round only when every final gate remains green.

## Scope

### In scope

- Verify the paid Apple team, App Store Connect access, identifiers,
  certificates, profiles, agreements, version/build, and embedded targets.
- Add a local launch gate with a one-way verifier and durable unlock state.
- Preserve the existing bundle identity and app data during upgrades.
- Run release, privacy, localization, build/archive, signing, and launch checks.
- Upload the validated archive to App Store Connect only if every hard gate
  passes.

### Non-goals

- TestFlight as the intended distribution lane.
- Storing the shared preview secret, credentials, or signing identity in Git.
- Claiming clinical validation, proprietary score parity, or completed physical
  sensor validation.
- Deleting local app data, changing the bundle identity, or uninstalling the
  existing app.

## Starting evidence

- The user reports that a paid developer account is now available.
- The repository is on private branch `codex/day4-sync-performance` at
  `241f2000`, with the preceding operations-documentation round still local and
  uncommitted.
- The project is on the NOOP 9.2.0 line and has iOS app, widget, Watch, and Live
  Activity surfaces that must all sign coherently.
- The current operations handoff records a public-distribution legal blocker for
  inherited WHOOP 4 expression; this must be resolved or the upload must stop.
- Paid-account signing and App Store Connect role/agreement status have not yet
  been verified in this round.

## Delivered

- Removed obsolete fork/upstream/sideload wording from non-legal project docs
  and workflow descriptions while preserving required legal documents, audit
  records, Git history/remotes, and all runtime protocol code.
- Added a non-sensitive
  [protocol redistribution-rights remediation plan](../../PROTOCOL_RIGHTS_REMEDIATION.md)
  with the affected Apple/Android modules, permission and independent-
  replacement routes, and acceptance tests. The plan records a blocker; it does
  not claim permission or clean-room status.
- Published public, unprotected App Store policy endpoints while keeping the
  installer itself passcode protected:
  - `https://noop-private-trial.usetaptech.chatgpt.site/privacy`
  - `https://noop-private-trial.usetaptech.chatgpt.site/support`
- The policy-site source was validated, committed at
  `b5312f9cbe2d041a1ce12ce92029d77d2db85d64`, saved as Sites version 8, and
  deployed successfully. Anonymous routing tests verify that `/privacy` and
  `/support` are public while `/` continues to redirect to `/access`.
- Added the App Store submission/media matrix and exact App Review path. It
  records privacy, export compliance, age rating, medical declaration, content
  rights, categories, availability, device-family media, optional WHOOP 5/MG
  hardware steps, and the safest disclosed Review Sample Mode design. The mode
  is explicitly not implemented yet.
- Added a deterministic, standard-library PNG validator/flattener and unit
  tests. The six provisional 1320×2868 iPhone screenshots were mechanically
  converted from RGBA to opaque RGB without resizing. They remain stale UI
  references and are not approved final storefront media.
- Added discoverable Privacy Policy and Support links to the in-app About
  surface. Both use the public policy-site routes rather than the private source
  repository.
- Split update delivery by distribution channel: App Store and TestFlight
  builds now show an honest Apple-managed update state and cannot invoke the
  private GitHub release checker; direct/private builds retain their existing
  opt-in release check.
- Narrowed the App Store description and review notes to the manual, local
  Oura/Fitbit/Garmin export-file import that the default Release binary contains.
  Oura OAuth must not be claimed unless the submitted archive explicitly enables
  and discloses that optional compilation lane.
- Added a non-secret, binary-grounded App Privacy and compliance worksheet for
  the release owner. It maps the optional network data types, required-reason
  manifests, iOS/widget/Watch entitlements, background-mode justifications,
  export-encryption decision, age-rating answers, and content-rights blocker.
- Renamed the permitted scheduled local diagnostic task from the engineering
  suffix `.debugexport` to `.diagnosticexport`. Existing opt-in preferences and
  exported files retain their keys/names; an in-place update cancels a pending
  legacy task rather than losing user state.
- Corrected the HealthKit read/write purpose strings: optional AI-provider
  summary sharing and enabled workouts/sleep writes are now disclosed rather
  than implying the only egress is self-hosted sync or every write originates
  solely from a strap.
- Expanded the optional AI coaching disclosure so it names the recovery,
  effort, sleep, heart, available vital, and workout summaries that may be
  shared when the user enables that feature.

## Data, privacy, and medical truth

- Schema or migration impact: none planned.
- Existing-data retention impact: upgrades must remain in place with the same
  bundle identity; no uninstall or reset is authorized.
- Secret handling: only a one-way verifier may be compiled; the shared secret
  must not appear in source, logs, Git, round records, crash metadata, or UI
  analytics.
- Permissions/network disclosure impact: source-level Release audit complete
  and recorded in `AppStore/privacy-and-compliance-draft.md`; final signed
  archive privacy report and physical background tests remain required.
- Health/medical claim impact: none planned.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `python3 Tools/release-legal-gate.py check` | Pass | The tracked provenance inventory is internally consistent | Public redistribution rights |
| `python3 Tools/release-legal-gate.py distribution` | Blocked as designed | The gate prevents release while inherited WHOOP 4 expression lacks an explicit software license | That permission or replacement has been completed |
| Legal remediation plan | Recorded | The affected modules, routes, and acceptance criteria are explicit and non-sensitive | Legal clearance or an independently implemented replacement |
| Policy-site unit/build suite | 9/9 pass | Anonymous privacy/support access, gated installer routing, secure-cookie behavior, and fail-closed secret handling | App Store approval or production binary behavior |
| Policy-site runtime dependency audit | Pass, 0 high runtime vulnerabilities | The deployed site has no known high-severity production dependency finding in the current audit database | Future advisories or application-level security proof |
| Live anonymous HTTP checks | `/privacy` and `/support` return 200; `/` returns 302 to `/access` | Required policy pages are reachable without the preview code and install content remains gated | App Store Connect field configuration |
| Focused `ProjectInfoTests` and `UpdateDeliveryPolicyTests` | 4/4 pass | Public policy URLs are exact and Apple-distributed channels short-circuit before private-release work | Storefront metadata entry or Apple approval |
| Unsigned `NOOPiOS` Debug simulator build | Pass | The in-app links and update-channel UI compile with the full iOS target graph | Signing, archive validity, or physical-device behavior |
| Release build-settings audit | No `OURA_CLOUD_IMPORT` condition | The current resolved Release configuration cannot promise Oura OAuth | Manual export-file import or a future credentialed archive |
| Privacy manifests and entitlement audit | App, widgets, Watch, complications, GRDB, and ZIPFoundation plists/manifests parse; reasons and capabilities mapped | The checked-in capability/privacy surface has a documented App Store answer and no unexplained background mode | Final archive aggregation/signatures or Apple acceptance |
| Background-location source trace | Used only by a user-started distance workout with `allowsBackgroundLocationUpdates`; routes are absent from remote/Friends/AI payloads | The `location` background mode is necessary for the shipping screen-off route feature and location is local-only | Physical route continuation/termination behavior |
| `swiftc -parse Strand/System/ScheduledDebugExport.swift`; identifier cross-check | Pass; one permitted/registered `.diagnosticexport` identifier plus legacy cancellation only | The renamed task parses and the generated/source Info identifiers match without resetting opt-in state | iOS scheduling or exact-time delivery |
| `Tools/i18n_audit.py --ci origin/main` and `git diff --check` | Pass | New copy is localized for required locales and the working diff is whitespace-clean | Linguistic review in every locale |
| Focused launch/distribution/project/update Xcode tests | 28/28 pass | Launch-gate policy, distribution-channel notice behavior, public project URLs, and Apple-managed update routing pass their focused contracts | Physical-device behavior or App Review acceptance |
| Unsigned `NOOPiOS` Release simulator build | Pass (`** BUILD SUCCEEDED **`) | The consolidated Release source graph, embedded simulator targets, localization assets, and launch-gate build phase compile together | Distribution signing, a device archive, physical BLE/background behavior, or App Store acceptance |
| `python3 Tools/tests/test_prepare_appstore_screenshots.py` | 3/3 pass | The tool rejects alpha, composites deterministically, is idempotent, and does not rewrite a wrong-size input | Final screenshot content or Apple acceptance |
| `python3 -m unittest discover -s Tools/tests -p 'test_*.py'` | 21/21 pass | The complete Python tool test directory still passes with the new media checks | iOS runtime behavior or physical-device behavior |
| `python3 Tools/prepare-appstore-screenshots.py --target iphone-6.9 marketing/screenshots` plus `sips`/`file` inspection | 6/6 pass; 1320×2868; 8-bit RGB; no alpha | Existing provisional iPhone assets meet the checked pixel/alpha contract | That their older UI is accurate for the submitted build |
| `python3 Tools/validate-ops-rounds.py --all .`; `python3 Tools/check-private-data.py`; `git diff --check` | Pass | Round structure, private-data filename guard, and diff whitespace are clean | A full secret-history audit or App Store acceptance |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: pending.
- Data-preservation result: no device mutation yet.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all release-specific physical checks pending.
- Build-cache cleanup: removed only the exact generated
  `build/appstore-final-tests` DerivedData tree and Release simulator log after
  the successful build, reclaiming about 3.2 GiB; source and app/device data
  were untouched.

## Git and release state

- Changed paths: the round includes local App Store documentation, the
  screenshot validator/tests, and mechanical alpha removal from provisional
  iPhone screenshots in addition to other release work recorded above.
- Commits: implementation and release-preparation commit `972a126b`; this round
  record is finalized in the documentation-only commit immediately after it.
- Branch and remote state: the private branch matched its private remote at the
  start commit. The two round commits are prepared for a private push; no PR or
  App Store upload is part of this evidence.
- Repository visibility verified: private in the preceding audit; recheck before
  push.
- Version/build impact: iOS remains 9.2.0 (229) and Android remains 9.2.0
  (303). The iOS Release product filename is now `NOOP.app`; bundle and App
  Group identities remain unchanged.
- Release or distribution impact: no upload or release yet.
- Website deployment: Sites version 8 is live at the existing production URL;
  the App Store binary is not uploaded.

## Decisions

- The first paid-developer build targets public App Store review rather than
  TestFlight; the temporary launch gate remains until an authorized update
  removes it.
- A client-side shared-secret gate is only a preview-access deterrent, not strong
  authentication; this limitation must be disclosed.
- Decision-log entry: D-010.

## Open risks and honest limitations

- A client-side verifier can be reverse engineered from a distributed binary and
  must not be represented as protection for biometric data against a determined
  attacker.
- Apple requires review access and may reject a shared-password gate if its
  purpose, review path, or user value is unclear.
- Existing inherited-license scope may block any distribution upload.
- WHOOP 5/MG uses shared protocol/store/collection layers, so deleting a small
  WHOOP 4 branch is not a safe or sufficient remediation.
- Paid membership alone does not establish App Store Connect permissions,
  agreements, certificates, profiles, or a valid archive.
- The current screenshot set covers only iPhone 6.9-inch and shows an older app
  state. Final iPhone captures, 13-inch iPad captures, Watch captures, and a
  sanitized compatible-hardware reviewer video remain missing.
- The exact App Privacy/export-compliance answers require review of the final
  archive. CryptoKit/CommonCrypto use means the encryption answer must not be
  guessed from the app's use of TLS alone.
- An earlier unsigned Release simulator attempt reached the host's storage
  limit while Xcode was writing DerivedData. After deleting only verified
  generated Xcode caches, the same consolidated unsigned Release simulator
  build passed. A signed archive and physical-device validation remain pending.

## Next round

1. Resolve the third-party redistribution gate or complete an independently
   reviewed replacement before any public archive upload.
2. Generate the ignored launch verifier interactively, then complete signing,
   App Store Connect owner decisions, final media, reviewer access, signed-
   archive inspection, and physical-device validation.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, shared secrets, or absolute personal
      paths are present.
