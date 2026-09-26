# Round: 2026-09-26 - PR 17 hosted closeout

## Status

- State: `historical hosted-green product checkpoint; superseded by the
  September 26 step-release/app-report replacement before protected
  integration`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `4bcaa17a1e61eba864c03b7f1a16284cc5550c19`
- End implementation commit:
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19`
- Record commit or PR: application pull request `#17`; record commit is the
  documentation-only commit containing this file

This record remains authoritative for exact product-code head `4bcaa17a`.
Later PR head `d775d7c36bed7795f67ff447f0a8d645625be5ba` exposed an iOS app-report
scroll regression and therefore is not represented as current-green by this
checkpoint. The replacement and its current evidence are recorded in
[Step release and app-report scroll](2026-09-26-step-release-and-report-scroll.md).

## Objective

Close the supplier-independent PR `#17` product candidate with durable evidence
for the exact hosted source, protected-review state, resource cleanup, and
remaining external gates. Do not reinterpret simulator or CI evidence as proof
of physical-band behavior, signing, production deployment, or metric accuracy.

## Scope

### In scope

- Verify the exact PR head and every required protected context.
- Verify normal merge state, auto-merge state, and the remaining review gate.
- Record the final stationary-motion step correction and supplier-wrapper
  quarantine evidence.
- Remove only exact round-owned generated output after hosted evidence is
  durable.
- Reconcile the active handoff and round index.

### Non-goals

- Changing product code, formulas, UI, cloud authority, or release controls.
- Bypassing required review or branch protection.
- Claiming signed installation, BLE/background behavior, supplier firmware
  classification, haptics, battery behavior, or physical step accuracy.
- Enabling public traffic or real health-data transfer.

## Starting evidence

- Exact remote PR head:
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19`.
- The branch and remote tracking ref were byte-identical and the worktree was
  clean.
- All local focused and complete walls were already recorded in the September
  25 step-integrity and PR `#17` integration rounds.
- The operations handoff and round index still described the preceding remote
  head and incorrectly listed hosted verification and cleanup as pending.

## Delivered

- Verified all ten required protected contexts on exact product-code head
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19`.
- Verified the complete hosted Apple graph, including the 28-minute iOS
  production-shell job, and the complete hosted Android, macOS, Swift package,
  policy, localization, claims, runtime-license, operations, server, and
  trusted-release paths.
- Verified PR `#17` is mergeable and auto-merge is armed. GitHub still reports
  the PR as blocked because the requested non-author review has not approved
  it. No administrative bypass, self-approval, force push, or branch-protection
  change was used.
- Verified the final stationary-motion correction keeps heart rate as
  wear/effort context rather than gait proof, rejects current non-locomotion
  counter deltas, and limits stale all-still cleanup to the exact owning
  computed source/day.
- Removed only exact round-owned generated output: the bounded step-closeout
  logs, Android app/build/project cache directories, and the exact regenerated
  Strand DerivedData directory. About 6.3 GiB was reclaimed and Data-volume
  free space increased to about 32 GiB.
- Reviewed the regenerated terminology snapshot: 18,548 classified occurrences
  across 1,629 path/category groups, zero forbidden mappings, and a
  byte-identical active customer/core allowlist.
- Reconciled the authoritative handoff and round index with this evidence.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none in this documentation-only closeout.
- Source/provenance or formula impact: none beyond the already-reviewed product
  candidate.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no new claim. Step filtering
  remains an activity estimate and requires synchronized physical ground truth.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: unchanged from
  the owning product rounds. The step path retains bounded category/count
  traces, and supplier lifecycle paths retain fixed-stage bounded events.
- Why existing evidence is sufficient, or why new evidence is required: this
  closeout changes documentation only and adds no operational boundary.
- Existing evidence reused: hosted check conclusions, PR state, clean Git state,
  cleanup path existence checks, free-space evidence, and the bounded mobile
  diagnostics already recorded by the owning rounds.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: unchanged.
- Cross-platform/backend correlation: exact hosted Apple/Android/package/server
  checks are green; physical and canonical-cloud metric parity remain separate
  gates.
- Remaining blind spots: physical sensor classification, firmware aggregates,
  background execution, battery, haptics, signed distribution, and real
  production services.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| `gh pr checks 17 --required` | 10 required contexts pass | The protected Apple, Android, server, package, claims, localization, operations, license, release, and trusted controls are green | Physical behavior or production launch |
| Apple hosted run `36233287879` | `apple-ci-required` passes; macOS passes in 16m30s; iOS production shell passes in 28m44s | The exact Apple app graph and production-shell suite pass on hosted runners | Signing, installation, BLE, haptics, background collection, or device performance |
| Android hosted run `36233287858` | `android-ci-required`, build/unit/lint/instrumentation compile, production shell, and Review Sample shell pass | The exact Android Full graph and required emulator paths pass | OEM behavior, physical BLE, or battery use |
| Swift package hosted run `36233287831` | Required aggregate and every applicable package pass | The exact package and storage/formula contracts compile and test together | App runtime or physiology |
| PR state query | Exact head matches; mergeable; auto-merge armed; blocked only by requested review | Normal protected integration is prepared without bypass | Approval or protected-main integration |
| Cleanup verification | Every exact cleanup path absent; Data volume about 32 GiB free; worktree clean | Round-owned generated output was removed without changing source | Global machine cleanup or unrelated process ownership |
| Operations and terminology controls | 97 round records validate; 18,548 classified occurrences across 1,629 groups; zero forbidden mappings; active allowlist unchanged | The closeout is indexed and introduces no active customer/core terminology regression | Physical or runtime behavior |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: hosted Apple/Android runners and local source
  verification only.
- Data-preservation result: no schema or user-data mutation in this closeout.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: supplier and WHOOP physical pairing, reconnect,
  history, background collection, haptics, battery, firmware compatibility, and
  synchronized true/false step counting.

## Git and release state

- Changed paths: operations documentation and the reviewed terminology snapshot
  required by repository policy.
- Commits: product-code candidate
  `4bcaa17a1e61eba864c03b7f1a16284cc5550c19`; documentation record commit is the
  commit containing this file.
- Branch and remote state: product-code candidate is pushed and hosted green.
  PR `#17` remains open, mergeable, and auto-merge-enabled while required
  non-author approval is pending.
- Repository visibility verified: public.
- Version/build impact: none.
- Release or distribution impact: no release, deployment, signed artifact, or
  public-traffic claim.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none. Existing local-first and staged D-059 authority
  contracts remain unchanged.

## Open risks and honest limitations

- The requested non-author approval is an external protected-branch gate.
- Physical firmware may misclassify stationary motion as walking or expose only
  an aggregate step count that application software cannot reconstruct.
- CI and simulators cannot validate physical collection, background execution,
  battery, haptics, sensor accuracy, or signed distribution.
- Protected `main` cannot be verified until normal auto-merge occurs.

## Next round

1. Obtain the requested non-author approval and allow normal auto-merge.
2. Verify the resulting protected `main` SHA through required and trusted-main
   checks.
3. Run the recorded physical validation matrix with synchronized manual counts,
   including walking and stationary bathing/hand-motion intervals.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
