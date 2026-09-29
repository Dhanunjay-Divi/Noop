# Round: 2026-09-29 - September 17 protected-main closeout

## Status

- State: `completed`
- Owner: project team
- Branch: `codex/september17-protected-main-closeout-20260929`
- Start commit:
  `7488283c3c21e794eaa8d6a7d08889f18b933bfa`
- End implementation commit:
  `7488283c3c21e794eaa8d6a7d08889f18b933bfa`
- Record commit or PR: this documentation and release-evidence protected pull
  request

## Objective

Close the September 17 UI/cloud readiness round after normal protected
integration. Record exact source and hosted evidence, reconcile stale release
handoffs, separate completed supplier-neutral work from physical/supplier
acceptance, and leave no product runtime change in the closeout.

## Scope

### In scope

- Verify PR `#18`, its reviewed candidate, normal merge, exact source tree,
  resolved review threads, and first protected-main required contexts.
- Update active operations, release-readiness, production-plan, SDK checklist,
  decision, and signed-device handoff records.
- Preserve D-059's staged migration and all physical/external gates.

### Non-goals

- Product-code, formula, schema, infrastructure, or runtime changes.
- Claiming physical BLE, background execution, battery, haptics, physiology,
  signed distribution, provider delivery, supplier rights, or production
  operations from source, simulator, emulator, or hosted CI evidence.
- Enabling an unapproved cloud-authority migration.

## Starting evidence

- PR `#18` merged normally as protected product commit
  `7488283c3c21e794eaa8d6a7d08889f18b933bfa`.
- Reviewed candidate
  `91e20504eb824572becfe6dcc440b5a6d5ecc8f2` and merged product commit share
  tree `f45676caf1d4d70ef2c732d859e6bf12ea78e470`.
- Seven review threads were resolved from matching implementation and test
  evidence.
- All ten pull-request and first protected-main required contexts passed.
- An independent read-only audit found no additional in-scope product,
  accessibility, localization, privacy, observability, metric, or
  supplier-neutral source blocker. It found stale handoffs and overly broad
  unchecked SDK rows, which this round corrects.

## Delivered

- Made protected `main` and PR `#18` the authoritative active source.
- Added the exact candidate, merged commit, source-tree identity, protected
  checks, and strict verifier outcome to release handoffs.
- Updated the physical-device continuation to start from clean protected
  `main`, while retaining WHOOP as the comparison transport and keeping the
  supplier path fail closed without exact approved artifacts.
- Updated D-056 to record the default-off SDK integration on protected main.
- Regenerated the reviewed terminology inventory for the changed records and
  repinned its exact digest in the required-CI trust contract.
- Split completed supplier-neutral SDK models, capability schema, session
  machines, fixtures, virtual bands, fault cases, source adapters, and
  collector ownership from still-open firmware, exact protocol, signed-egress,
  and physical acceptance.
- Preserved application-level encrypted-cache migration, existing-user cloud
  backfill, selective restore, conflict replacement, Coach evidence, and
  Automation execution state as separately decision-gated roadmap work rather
  than claiming an unapproved authority flip.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no new claim. Simulator,
  source, and CI evidence remain insufficient for physiology or medical use.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: existing
  required contexts, trusted exact-SHA check, bounded operation tests, and
  privacy-safe round records.
- Why existing evidence is sufficient, or why new evidence is required: this
  round changes documentation only, so no runtime boundary is added.
- Existing evidence reused: PR checks, protected-main checks, local trust,
  operations validator, SDK artifact verifier, and independent audit.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: unchanged.
- Cross-platform/backend correlation: unchanged.
- Remaining blind spots: physical transport, signed push, provider delivery,
  supplier firmware, and production operations.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| PR `#18` state and merge query | Merged normally at `7488283c3c21e794eaa8d6a7d08889f18b933bfa`; zero unresolved threads | Reviewed source integrated without an administrative bypass | Physical behavior or production launch |
| Candidate/main tree comparison | Both resolve to `f45676caf1d4d70ef2c732d859e6bf12ea78e470`; `git diff --quiet` passed | Squash merge did not alter reviewed source | Signed artifact identity |
| `Tools/required-ci-gate.py verify-github` on protected product commit | `10/10 exact-SHA checks passed` | Exact protected-main Apple, Android, packages, server, policy, claims, localization, operations, licensing, and trust contexts are green | Physical-device or external-service behavior |
| Complete release-tool test wall | 372 tests passed with one intentional skip | Terminology, required-CI, trust-root, operations, release-policy, and bounded-runner regressions agree after the closeout edits | App runtime or physical-device behavior |
| Top-level localization tests | Initial repository-root invocation failed before discovery because `Tools` was not on the import path; supported `cd Tools && python3 -m unittest test_i18n_audit` rerun passed 50/50 | The localization auditor's top-level regression contract passes in its supported execution context | Native-speaker or physical visual-fit review |
| `Tools/trusted-release-controls.py verify-self --root .` | Passed | Clean checkout matches protected-main trust contract | Store/signing approval |
| `Tools/validate-ops-rounds.py --all .` | 103 records passed | All durable operations records, including this closeout, are structurally valid | Runtime or physical behavior |
| Terminology inventory and reviewed digest | 18,564 occurrences across 1,635 groups; zero forbidden mappings; required-CI and trusted-self checks passed | Changed records are classified and the exact generated evidence is pinned | Product or physical behavior |
| Direct policy wall | Nine release checks, distribution provenance, 12-metric calibration parity, private-data, 1,312-file health-claims, full localization, exact SDK artifact, and diff hygiene passed | Repository-controlled release contracts remain intact | Signing, store, supplier, legal, carrier, or production approval |
| Independent read-only completion audit | No additional in-scope implementation blocker; stale docs and checklist split identified | Fresh review covered the stated closeout scope | Hardware or legal approval |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not run.
- Data-preservation result: not run.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: every applicable `PHY-*` row in the physical
  validation handoff, signed iPhone/Android installation, exact supplier
  hardware/firmware qualification, and synchronized reference measurements.
- Cleanup: the bounded Tools log/status and full-localization log were checked
  for open handles and exact-deleted after their outcomes were captured. No
  database, container, simulator, DerivedData, Gradle output, or cloud resource
  was created by this documentation and release-evidence closeout.

## Git and release state

- Changed paths: documentation, operations records, the regenerated
  terminology inventory, and its reviewed required-CI digest pin only; no app,
  server, metric, schema, or transport implementation.
- Commits: documentation and release-evidence closeout commit on this branch.
- Branch and remote state: created from clean protected product commit
  `7488283c3c21e794eaa8d6a7d08889f18b933bfa`; normal protected integration is
  required.
- Repository visibility verified: public.
- Version/build impact: none.
- Release or distribution impact: no artifact, deployment, or publication.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: D-056 status corrected to the integrated source state;
  its policy is unchanged.

## Open risks and honest limitations

- Physical BLE, background restoration, history retention, battery, haptics,
  notification delivery, accessibility traversal, and physiological accuracy
  remain unverified on representative signed devices.
- Supplier rights, exact immutable binaries, hardware/firmware identity,
  provisioning, OTA, and signed-egress evidence remain open.
- Signing, stores, credentials, production infrastructure, legal/carrier
  approval, native-language review, and elapsed production operations remain
  external gates.
- D-059 migration items that require separate design, consent, migration,
  restore, rollback, security, and physical evidence remain intentionally
  unenabled and are not disguised as this round's missing implementation.

## Next round

1. Start from clean protected `main` and execute
   `docs/handoff/NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md` on one signed iPhone
   and Android phone, validating WHOOP first and the supplier band only with
   exact approved artifacts and hardware/firmware inputs.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
