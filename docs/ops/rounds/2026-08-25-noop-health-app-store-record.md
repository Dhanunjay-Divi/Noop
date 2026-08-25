# Round: 2026-08-25 — NOOP Health App Store record and release preflight

## Status

- State: `record created; archive and upload blocked`
- Owner: project team
- Branch: `codex/app-store-submit-20260825`
- Start commit: `9d4a6957`
- End implementation commit: none
- Record commit or PR: pending

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
- Completed an unsigned generic iOS Release build from exact mainline.
- Rebuilt with the ignored local bundle/team mapping attached without adding it
  to Git. The app, widget, Watch app, and complication all resolve to the
  existing bundle family and version `9.2.0 (229)`.
- Generated the ignored one-way launch-access verifier interactively for
  rotation `appstore-2026-08-25-v1`. The file is mode `0600`, remains ignored
  by Git, contains no plaintext access code, and passes the Release archive
  validation contract.

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
| Private `origin/main` fetch | `9d4a6957`; repository private and standalone | The round uses current canonical private mainline. | Commercial distribution clearance. |
| `python3 Tools/release-legal-gate.py check` | Pass; 152 runtime components and 3 container inputs | Inventory is internally consistent. | Redistribution rights. |
| `python3 Tools/release-legal-gate.py distribution` | Expected fail on three recorded independence statuses | Release remains fail-closed. | That separate remediation is complete. |
| `python3 Tools/check-private-data.py` | Pass | No prohibited private-data filenames are tracked. | Final archive privacy labels. |
| `python3 Tools/validate-ops-rounds.py --all .` | Pass for 10 pre-existing rounds | Existing ledger was valid before this record. | This new record until revalidated. |
| `python3 Tools/health_claims_gate.py` | Pass across 1,052 files | Current copy gate is clear. | Clinical accuracy or regulatory status. |
| Release-tool unit tests | 25/25 pass | Release helper contracts pass locally. | App Store acceptance. |
| Unsigned generic iOS Release build | Pass | Exact mainline compiles for the app and embedded targets. | Signing, archive validation, or hardware behavior. |
| Bundle inspection | Existing app/widget/Watch/complication family; `9.2.0 (229)` | Artifact identity matches the intended App Store record and upgrade path. | Provisioning or distribution authorization. |
| Archive-like launch-access validation | Missing-verifier fixture fails; generated ignored verifier passes | Ungated archive fails closed and the local protected verifier has the required shape. | Strength against a patched client or App Review acceptance. |
| App Store Connect app record | `NOOP Health`, app ID `6804921246`, `Prepare for Submission` | Apple accepted the localized name and bound the existing main bundle ID to a durable record. | Archive validation, upload, review, or release. |
| Existing icon assets | Primary Obsidian NOOP mark plus existing alternate and Watch icon sets remain unchanged | The next signed build will carry the established NOOP logo. | That Apple has ingested or rendered the icon before build upload. |

## Physical device and deployment

- Install/update action: not run
- Generalized device and OS class: not run
- Data-preservation result: no device mutation in this round
- BLE/background/haptic/battery scenarios exercised: not run
- Unrun hardware gates: WHOOP 5/MG, HealthKit, Watch, widget, Live Activity,
  background sync, battery, haptics, and in-place upgrade retention

## Git and release state

- Changed paths: App Store localized name, this round record, decision log,
  and active/index pointers
- Commits: pending
- Branch and remote state: fresh local branch from exact private `origin/main`
- Repository visibility verified: private
- Version/build impact: none; `9.2.0 (229)`
- Release or distribution impact: the App Store record was created; no signed
  archive, upload, submission, review request, or release has occurred

## Decisions

- Durable decision added or changed: use `NOOP Health` as the first fallback
  App Store localization while keeping the installed bundle and app-group
  identity unchanged and retaining the NOOP logo.
- Decision-log entry: `D-027`.

## Open risks and honest limitations

- Local signing has no validated Apple Distribution identity or matching
  App Store profiles for every embedded target.
- Final iPad and Watch media, hardware-independent reviewer path, signed archive
  privacy/entitlement validation, and physical-device release matrix are open.
- The distribution gate still reports three unresolved source-independence
  statuses on exact private mainline.

## Next round

1. Resolve the remaining signing, reviewer, media, physical-device, and
   distribution gates.
2. Archive and validate every embedded target with the generated local
   verifier without staging the ignored verifier file.
3. Upload only the validated signed build, then complete metadata and submit
   for review as a separate, explicitly recorded action.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
