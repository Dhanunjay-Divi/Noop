# Round: 2026-09-30 - Supplier band metrics integration

## Status

- State: `in progress`
- Owner: project team
- Branch: `codex/supplier-metrics-integration-20260930`
- Start commit: `fd2f0f8165742c328767add904d69a74d67c0d81`
- End implementation commit: pending
- Record commit or PR: pending

## Objective

Integrate the working supplier-band steps and sleep implementation from pull
request `#20` onto current protected main while preserving the newer pairing,
ownership, viewer, source-switching, and release safeguards already merged
through pull request `#18`.

The product commit `7ca94bf8ab79375ce8bc363a2718aae2bebed710`
is the implementation candidate. The separate commit
`0b99aca0c40680c19bb1a29b798b42cb1229146d` remains excluded because it is
explicitly development-only.

## Scope

### In scope

- Preserve quoted generated xcconfig paths so external SDK roots may contain
  spaces.
- Normalize only the verified outer quote pair exported to Python and the
  framework-copy shell.
- Add fail-closed tests for quoted paths, malformed quotes, unrelated settings,
  and verifier-before-copy ordering.
- Transplant supplier day-step and sleep-window ingestion onto current main.
- Replace raw console diagnostics with bounded categorical operations and
  counts that contain no health values, dates, device identifiers, payloads, or
  arbitrary errors.
- Preserve source-qualified metric provenance and unavailable states when the
  supplier capability or physical evidence is absent.

### Non-goals

- Changing approved supplier artifact hashes or enabling Release transports.
- Integrating the development-only artifact repin, entitlement removals, or
  Watch-target changes.
- Publishing exploratory HRV table interpretation as a product metric.
- Inventing Android supplier behavior that is not supported by the reviewed
  wrapper or supplier SDK contract.
- Claiming a physical-device build, pairing, history, background, battery, or
  sensor result.

## Starting evidence

- Pull request `#20` includes working product commit
  `7ca94bf8ab79375ce8bc363a2718aae2bebed710`, reported by the owner as the
  branch that connected to the supplier band and returned device data.
- Pull request `#20` also includes commit
  `0b99aca0c40680c19bb1a29b798b42cb1229146d`, explicitly marked
  development-only and not mergeable.
- Its local build notes identify that custom xcconfig path values retain their
  grouping quotes when exported to Run Script phases.
- Current main intentionally quotes paths to support spaces, but the
  build-environment verifier and framework-copy script consume the exported
  values as filesystem paths.

## Delivered

- Pending verification.

## Data, privacy, and medical truth

- No user, account, health, sensor, location, calendar, or diagnostic data is
  read or written.
- No formula, score, provenance, retention, permission, or notification
  behavior changes.
- The owner-reported supplier connection is retained as relevant evidence, but
  this round does not independently reproduce physical behavior.

## Observability

- No runtime event is added. Failure remains a bounded build-time verifier
  error naming only the invalid setting, never a local path value.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Focused supplier iOS wiring tests | Pending | Generated and exported path handling | Physical SDK compatibility |
| Current-main transplant and focused metric tests | Pending | Source, persistence, and analytics behavior | Sensor accuracy |
| Shell syntax and repository release controls | Pending | Build helper remains fail closed | Signed iPhone installation |

## Physical device and deployment

- Install/update action: not run.
- BLE/background/haptic/battery scenarios exercised: none.
- Exact approved SDK artifact remains required by the physical-validation
  handoff.

## Git and release state

- Changed paths: supplier iOS configurator, embed script, focused tests, and
  this operations record.
- Version/build impact: local Debug iPhoneOS supplier qualification only.
- Release or distribution impact: none.

## Decisions

- Preserve support for external SDK paths containing spaces. Do not adopt the
  branch-local workaround that rejects spaces.
- Normalize only after the protected verifier has matched the exact approved
  paths.

## Open risks and honest limitations

- A signed physical-device build with the approved supplier bundle remains
  external evidence.

## Next round

1. Run focused and complete repository controls.
2. Merge through protected main.
3. Replace pull request `#20` with the reviewed current-main integration, then
   close only the stale historical branch after the replacement is protected.

## Privacy check

- [x] No credentials, raw biometric values, device identifiers, local paths, or
      private supplier artifacts are present.
