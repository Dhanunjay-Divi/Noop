# Round: 2026-09-08 - Trusted check URL compatibility

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/trusted-check-details-url-fix`
- Start commit: `c3c377abd57ab090b2ed0b5ade4461f6769a0d3a`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Make the protected release-control reporter and exact-SHA verifier accept the
canonical check-run URL returned by GitHub without weakening repository,
application, source SHA, workflow run, run-attempt, scope, or conclusion
binding.

## Trigger

The first protected-main bootstrap run validated source successfully and
created the intended successful custom check. GitHub returned that check with
its canonical `/runs/<check-id>` details URL instead of the requested
`/actions/runs/<workflow-run-id>` URL. The reporter rejected the otherwise
correct authenticated response.

## Starting evidence

- Protected `main` commit:
  `c3c377abd57ab090b2ed0b5ade4461f6769a0d3a`.
- Trusted workflow run `34193579552` completed source validation successfully.
- The created custom check is successful, exact-SHA bound, owned by the GitHub
  Actions application, and uses external ID scope `protected-main`, run attempt
  `1`.
- The reporting job failed only because GitHub returned the canonical
  repository check-run URL instead of preserving the requested Actions-run
  URL.

## Scope

- Accept the requested Actions-run URL or GitHub's canonical check-run URL.
- Bind the canonical URL to the exact authenticated response check ID and
  repository.
- Continue deriving and verifying the workflow run and attempt from the
  bounded external ID and Actions API response.
- Add positive and negative focused tests for both URL forms.

## Non-goals

- Do not activate the tenth protected context in this round.
- Do not weaken exact-SHA, GitHub Actions application, protected-main scope, or
  workflow-path verification.
- Do not publish a tag, release, package, testing snapshot, or app artifact.
- Do not enable signing workflows or change retained private GCP staging.

## Delivered

- Added strict support for GitHub's canonical repository check-run URL.
- Bound that URL to the authenticated response's exact positive check ID and
  repository.
- Kept workflow-run identity sourced from the bounded external ID and verified
  against the Actions API.
- Added positive and negative tests for canonical URL acceptance, wrong check
  ID rejection, and the existing Actions-run URL.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: no new permission or payload; the
  reporter continues to use the existing bounded check-run API response.
- Health/medical claim impact and limitations: none.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Full Tools suite | Passed, 222 tests | Both authenticated URL forms are accepted, mismatched IDs are rejected, and the repository release-control contract remains fail closed | Hosted GitHub behavior |
| Required-CI, trusted-self, release-control, operations, terminology, workflow-lint, private-data, and health-claims gates | Passed | Reviewed source digests, workflow contracts, durable records, and repository safety gates remain exact | Hosted execution |
| Actual bootstrap check parser | Passed for protected-main run `34193579552`, attempt `1` | The repaired exact-SHA verifier accepts the real canonical check-run object while retaining external workflow identity | Reporter execution from the repaired protected source |
| Protected-main rerun after merge | Pending | GitHub's canonical response is accepted on the exact protected commit | Tenth-context activation |

## Physical device and deployment

- Install/update action: none.
- Generalized device and OS class: not applicable to repository policy.
- Data-preservation result: no application, band, account, or cloud user data
  is mutated.
- BLE/background/haptic/battery scenarios exercised: not applicable.
- Unrun hardware gates: all supplier and physical-device release gates remain
  open.

## Git and release state

- Changed paths: trusted reporter, exact-SHA verifier, focused tests, reviewed
  source digest, and operations documentation.
- Version/build impact: none.
- Release or distribution impact: compatibility repair only.

## Decisions

- Accept GitHub's requested Actions-run URL or its canonical check-run URL,
  never an arbitrary redirect or third-party URL.
- Require the canonical check-run path to match both the exact repository and
  authenticated response check ID.
- Keep the custom context optional until this repair has passed on exact
  protected `main`.

## Open risks and honest limitations

- The custom context is not yet required by branch protection.
- The activation round remains blocked until this fix is merged and one exact
  protected-main custom check passes.
- Supplier, physical-device, legal, carrier, signing, store, participant,
  population-calibration, and elapsed-operation gates remain open.

## Next round

1. Resume the isolated trusted release-control activation after exact-main
   hosted evidence is green.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
