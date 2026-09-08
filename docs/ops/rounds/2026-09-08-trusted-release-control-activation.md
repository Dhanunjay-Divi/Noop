# Round: 2026-09-08 - Trusted release-control activation

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/trusted-release-control-activation`
- Start commit: `ffae30d5b8072f5aa34afa2bd6f5945fdea8c8fc`
- End implementation commit: `f13b33c7ea69d2debfe93c473d273fc963f936a9`
- Record commit or PR: pending

## Objective

Activate the already-reviewed `trusted-release-controls` check as the tenth
protected merge and release context without bypassing the existing nine-context
bootstrap rule or creating an interval in which untrusted release-authority
changes can merge.

## Scope

### In scope

- Add the protected-base custom check to the machine-readable required-CI
  contract.
- Prove that pull-request trust cannot authorize publication and that only an
  exact protected-main result can satisfy release verification.
- Add the tenth GitHub branch-protection check only after the workflow exists
  on `main` and has produced a verified exact-main result.
- Reverify strict branch protection, Actions application ownership, tag
  rulesets, and immutable-release state before and after activation.

### Non-goals

- Do not bypass required review or any required status check.
- Do not publish a release, tag, package, testing snapshot, or app artifact.
- Do not enable disabled signing workflows or read, copy, rotate, or expose
  credential values.
- Do not remove the retained private synthetic GCP staging environment.

## Starting evidence

- The bootstrap source contract has five conditional and four universal
  workflows with nine exact contexts owned by GitHub Actions application
  `15368`.
- Live `main` protection is strict, enforces administrators, requires
  conversation resolution and linear history, and rejects force pushes and
  deletion. It currently has no required-review rule.
- The protected-base trusted workflow exists on `main`. Repaired protected-main
  run `34194149601` validated and published successful custom check
  `101958240443` on exact commit
  `ffae30d5b8072f5aa34afa2bd6f5945fdea8c8fc`.
- Immutable GitHub Releases remain disabled intentionally. Four tag rulesets
  are active, while the testing and community-release workflows remain
  manually disabled pending signing-secret migration.
- No production release mutation is authorized by this round.

## Delivered

- Staged the fifth universal workflow and tenth stable context in
  `release/required-ci.json`.
- Converted the trusted-context repository tests from a synthetic future
  configuration to the active contract.
- Kept publication fail closed: a valid pull-request-scope custom check still
  cannot satisfy exact protected-main release verification.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: the trusted reporting jobs retain
  only their existing exact `checks: write` permission and read-only source
  access.
- Health/medical claim impact and limitations: none.

## Observability

- The custom check retains only its fixed name, bounded success/failure
  summary, exact source SHA, authenticated canonical check-run link, and
  run-attempt-bound external ID.
- No credentials, application payloads, user data, health values, arbitrary
  exception text, or dynamic repository content enter the check output.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Full local policy suite | Passed: 222 tool tests; five conditional workflows, five universal workflows, ten contexts; trusted-self, release-control, operations, terminology, workflow-lint, private-data, health-claims, and calibration-parity gates | Candidate source has ten uniquely owned contexts and preserves the repository safety contracts | Hosted execution or live protection |
| Exact bootstrap `main` trusted check | Passed in run `34194149601`; custom check `101958240443` is successful on exact `ffae30d5` | Protected-base workflow validates and reports its own exact protected-main source | Candidate activation merge |
| Activation pull-request contexts | Pending | Existing nine contexts plus the custom exact-head check pass on the reviewed candidate | Exact-main post-merge state |
| Live ten-context branch rule | Pending | Strict `main` protection matches the activated source contract under the Actions app | Store, signing, or release readiness |
| Immutable-release setting | Pending until exact-main activation evidence | Published GitHub releases cannot be modified after activation | A completed release |

## Physical device and deployment

- Install/update action: none.
- Generalized device and OS class: not applicable to repository policy.
- Data-preservation result: no application or device data is mutated.
- BLE/background/haptic/battery scenarios exercised: not applicable.
- Unrun hardware gates: all supplier and physical-device release gates remain
  open.

## Git and release state

- Changed paths: required-CI contract, matching repository tests, and operations
  documentation only.
- Branch and remote state: rebased isolated activation branch; not yet pushed.
- Version/build impact: none.
- Release or distribution impact: policy activation only; no artifact or
  release mutation.

## Decisions

- The trusted custom context becomes required only after its protected-base
  workflow exists on `main` and one exact-main result is verified.
- Immutable releases become enabled only after the ten-context source contract,
  live branch rule, and exact-main hosted evidence agree.

## Open risks and honest limitations

- Publication remains blocked while a non-owner collaborator has write access.
- Testing and community-release workflows remain disabled until the key owner
  migrates four Android signing values into the protected `staging`
  environment and removes the repository-scoped copies.
- Supplier, physical-device, legal, carrier, signing, store, participant,
  population-calibration, and elapsed-operation gates remain outside this
  source-policy activation.

## Next round

1. Close the production-readiness execution record after exact protected-main
   activation and final scoped cleanup.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
