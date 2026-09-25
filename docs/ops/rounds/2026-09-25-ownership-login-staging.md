# Round: 2026-09-25 - Ownership login staging

## Status

- State: `incomplete; operator reauthentication required`
- Owner: project team
- Branch: `codex/noop-band-sdk-app-integration-20260921`
- Start commit: `4604fd53d15b459d0c2251da8e8697134bdb30e1`
- End implementation commit: none
- Record commit or PR: application pull request `#17`
- Environment: private synthetic GCP staging only

## Objective

Make the first account milestone testable end to end before proceeding to band
pairing: configure verified email/password identity, immutable synthetic terms,
the private ownership API, and one controlled staging owner account. Keep
payment, NOOP+ entitlement grants, public customer traffic, and physical-band
ownership claims disabled.

## Scope

### In scope

- Audit existing GCP/Firebase/Cloud Run/Cloud SQL state without exposing
  credentials or identifiers in tracked files.
- Apply only the missing private staging resources required by the existing
  ownership foundation.
- Create one verified synthetic owner/test identity with a generated temporary
  credential stored outside Git.
- Generate ignored Apple and Android staging configuration.
- Run focused server, Apple, Android, and simulator account-flow verification.
- Commit and push the tested account milestone before starting the next flow.

### Non-goals

- Public mobile ingress or production customer traffic.
- Payment gateway, billing, or NOOP+ entitlement activation.
- Application-user infrastructure administrator access.
- Physical-band claim, replacement, release, BLE, background, haptic, battery,
  or physiological validation.
- Real health-data upload.

## Starting evidence

- The canonical checkout retains ignored mode-restricted Apple, Android,
  backend, and infrastructure staging configuration files.
- The active integration worktree intentionally contains no copied credential
  values.
- A live `gcloud auth print-access-token` check returns `invalid_grant`; current
  operator authentication is expired.
- Payment and entitlement grant paths remain unavailable and fail closed.
- Ownership possession verification is unavailable, so a physical-band claim
  cannot be completed or represented as complete.

## Delivered

- Audited the existing ignored staging configuration by file presence,
  permissions, and key names without printing values.
- Confirmed that account/phone identity uses Firebase Identity rather than
  Twilio. Twilio remains outside this account milestone.
- Kept payment, NOOP+ entitlement grants, public traffic, health-data transfer,
  and physical ownership claims disabled.
- Recorded operator reauthentication as the next external prerequisite instead
  of embedding or copying credentials into the worktree.

## Safety and privacy boundaries

- Use only a synthetic staging identity; do not upload real health data.
- Never print or commit passwords, API keys, tokens, database URLs, Firebase
  subjects, app-check assertions, or service identities.
- Store temporary credentials in an ignored mode-`0600` file or macOS Keychain.
- Keep the ownership possession verifier unavailable, so band claims fail
  closed.
- Keep payment and managed entitlement modes disabled.

## Data, privacy, and medical truth

- Schema or migration impact: none applied in this round.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: no public ingress or health-data
  transfer was enabled.
- Health/medical claim impact and limitations: none; no real user, health
  record, physical claim, or physiological outcome was created.

## Observability

- Evidence for configured ownership uses bounded native operation spans and
  server request observability.
- Fixed operation, route template, status family, duration, and categorical
  outcome are sufficient; credential failure is recorded only as an external
  prerequisite in this operations record.
- Email, password, phone, OTP, identity, installation, account, band, token,
  terms body, URL, and arbitrary provider errors remain excluded.
- No new event was added because no runtime ownership request or deployment was
  attempted under expired authentication.
- Live provider behavior remains opaque until operator reauthentication and a
  private synthetic staging smoke.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Ignored staging-file audit | Required file classes and restrictive modes are present in the canonical checkout | Local staging inputs exist outside Git | Values are current or a deployment works |
| Live GCP token check | `invalid_grant` | Operator authentication is expired | Resource health or deployment state |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: not applicable; cloud prerequisite audit
  only.
- Data-preservation result: no cloud or device data mutation.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical ownership, band proof, BLE, background,
  haptic, battery, and physiological checks.

## Git and release state

- Changed paths: this operations record only for the staging prerequisite.
- Commits: pending.
- Branch and remote state: local record; no cloud deployment commit.
- Repository visibility verified: unchanged.
- Version/build impact: none.
- Release or distribution impact: none.

## Decisions

- Durable decision added or changed: none. Private synthetic staging, no public
  traffic, no real health data, disabled payment, and fail-closed physical
  ownership remain authoritative.
- Decision-log entry: none.

## Open risks and honest limitations

- Operator reauthentication is required before live resource inventory,
  OpenTofu plan/apply, Firebase test-user creation, or private account smoke.
- Credential validity, service health, tenant isolation, and end-to-end account
  behavior are unverified in this round.
- No cloud resource is described as deployed, healthy, or launch-ready.

## Next round

1. Reauthenticate the owner-selected GCP account outside Git.
2. Audit private staging drift and produce a bounded OpenTofu plan.
3. Apply only reviewed private synthetic changes, then run tenant-isolated
   account and ownership smokes with no real health data.
4. Remove temporary identities, tokens, and test resources after evidence.

## Privacy check

- [x] No credential, user identifier, project identifier, endpoint, or private
      test value is recorded in this document.
