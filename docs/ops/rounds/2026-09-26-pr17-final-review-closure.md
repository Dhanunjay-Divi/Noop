# Round: 2026-09-26 - PR 17 final review closure

## Status

- State: `exact checkpoint 6c7d3fa2 pushed and all ten required hosted contexts
  green; requested non-author review and protected integration pending`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `8da3ebf4c2d0fecc4cd924e81b27f60bb90ab106`
- Record commit or PR: application pull request `#17`

## Objective

Close the remaining current review findings on the supplier-band integration
without changing health formulas, weakening source provenance, bypassing
protected review, or claiming physical-device behavior.

## Scope

### In scope

- Supplier pairing and connectivity state recovery on Apple.
- Supplier PIN and inactive-device connection controls on Android.
- Final active-device registry reconciliation.
- Focused regression tests, repository controls, hosted exact-head evidence,
  review-thread closure, and generated-artifact cleanup.

### Non-goals

- New health inference, gait inference, heart-rate thresholds, or medical
  claims.
- Public traffic, signed distribution, production enablement, or physical BLE
  validation.

## Starting evidence

- The primary Steps contract already accepts only walking/running classified
  band deltas, prefers imported phone/watch pedometer totals, and rejects the
  exact reported 4,000-count stationary head-washing sequence in Swift and
  Kotlin.
- Heart rate remains effort and wear context, not proof of locomotion.
- Pull request `#17` is open with protected integration and physical validation
  still pending.

## Delivered

- Apple supplier pairing retains one bounded credential-cleanup owner and
  retries protected-data cleanup without creating an unbounded unlock loop.
- Apple and Android active-device reconciliation keeps compatible-band testing
  available while supplier state remains explicit and fail-closed.
- Android supplier PIN and inactive-device controls reject invalid state before
  transport work. The onboarding instrumentation fixture restores the
  Bluetooth permission state it found instead of leaving the test device
  mutated.
- The vendored SDK artifact verifier accepts only a validated generated
  directory-only `.swiftpm` tree and continues rejecting files, symlinks, or
  undeclared tracked artifacts.
- The separate step-source correction removes unverified wrist motion from
  primary Steps and keeps heart rate as wear/effort context rather than gait
  proof.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| WhoopProtocol wall | 406 tests pass with 1 intentional corpus skip | Compatible protocol extraction and synchronized fixtures remain coherent | Physical firmware behavior |
| StrandAnalytics wall | 1,513 tests pass with 7 documented skips | Production step rejection and downstream analytics are deterministic | Physical step accuracy |
| WhoopStore wall | 555 tests pass | Registry, capability, and source-scoped cleanup persistence contracts pass | BLE continuity or phone storage pressure |
| iPhone Simulator graph | `NOOPiOS` Debug build passes with Watch, complications, and widgets embedded | Current shared Apple source compiles through the complete simulator graph | Signing, installation, background execution, or physical BLE |
| Exact-head macOS app wall | 2,358 tests pass with 1 intentional fixture skip | The exact pushed app source passes the complete unsigned macOS graph | Signed installation, physical BLE, or production performance |
| Android complete wall | 5,213 tests pass with 7 intentional skips; Full/Demo compile, Full instrumentation-source compile, lint with zero errors, and Full APK assembly pass | Current Android source, tests, flavors, and packaging remain coherent | Emulator runtime, OEM background behavior, or physical BLE |
| Complete repository-control wall | 372 Tools tests pass with 1 intentional skip; 9 release checks, 10 required contexts, trusted self, 12-metric calibration, exact 10-file SDK artifact, legal/provenance, localization, private-data, 1,312-file health-claims scan, terminology, and 101 operations records pass | The local checkpoint satisfies the repository's independent source and policy gates | Exact-head hosted checks, non-author approval, or protected integration |
| Exact-head hosted checks | Commit `6c7d3fa2` passes all 10 required contexts, including Apple run `36264295238`, Android run `36264295298`, and package run `36264295274` | The exact remote source satisfies protected hosted source and build gates | Non-author approval, protected integration, or physical behavior |
| Public-repository privacy guard | Pass | No prohibited private-data filename entered the checkpoint | Full secret scanning or redistribution approval |
| Diff hygiene | Pass | The checkpoint has no whitespace errors | Hosted policy or protected integration |

## Data, privacy, and medical truth

- No new health inference is authorized in this round.
- Heart rate remains effort and wear context, not proof of locomotion.
- Raw biometric data, identifiers, permissions, retention, and network
  disclosure are unchanged by this record.

## Physical device and deployment

- Physical supplier-band behavior remains unverified.
- No signed install, background BLE, haptic, battery, store, or production
  deployment claim is made.

## Git and release state

- The branch contains the consolidated supplier/pairing and step-source
  replacement.
- Local and remote point to exact checkpoint
  `6c7d3fa2b1e7f744774a89a942465ff1aa137216`. All ten required hosted contexts
  pass. Pull request `#17` remains open and mergeable but blocked pending the
  requested non-author review before protected integration.

## Decisions

- No durable product decision is introduced by this review-closure record.
- Any step-source correction is owned and evidenced by the dedicated
  `2026-09-26-step-evidence-source-correction.md` round.

## Open risks and honest limitations

- Physical firmware classification and synchronized manual-count accuracy
  remain unverified.
- Protected integration requires exact-head required checks and a non-author
  approving review.

## Next round

1. Obtain the requested non-author review and integrate through protected
   `main`.
2. Verify the exact resulting mainline commit and clean only round-owned
   generated outputs.
3. Run the documented physical band matrix after normal protected integration.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
