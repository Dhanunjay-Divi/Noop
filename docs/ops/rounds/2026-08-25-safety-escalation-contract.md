# Round: 2026-08-25 - Safety escalation and validated-fall contract

## Status

- State: `completed in code; external launch gates remain`
- Owner: project team
- Branch: `main`
- Start commit: `9d4a6957`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Allow a person who cannot reach the phone to page accepted emergency contacts
from a repeated Noop Band SOS gesture, provide a fail-closed server contract for
a future validated no-response fall workflow, continue bounded SMS and voice
paging until acknowledgement, and share latest-only location for a user-selected
8 or 12 hours without converting wellness values into medical SOS.

## Scope

### In scope

- Distinct app SOS, band SOS, and gated validated-fall incident origins.
- Fresh chronological fall evidence, detector allowlisting, master kill gate,
  duplicate-event prevention, and disabled-by-default deployment posture.
- Independent bounded SMS and voice rounds with acknowledgement cancellation.
- Latest-only 8/12-hour location across Apple, Android, server, responder page,
  process restart, and retry compatibility.
- Origin context in SMS, voice, web, Apple, and Android surfaces.
- Schema migration, backup/restore contract, deployment examples,
  localization, privacy, release, operations, and agent handoff.

### Non-goals

- Automatic paging from heart rate, rhythm, ECG, SpO2, temperature, stress,
  sleep, readiness, delayed history, or any other wellness estimate.
- Claiming a shipping fall detector, emergency dispatch, carrier delivery,
  human receipt, diagnosis, or confirmed cause.
- Enabling the fall gate before firmware, physical-device, detector,
  human-factors, carrier, legal, and regulatory evidence exists.

## Starting evidence

- Repeated band taps already formed an explicit SOS gesture but were sent as a
  generic manual page.
- One SMS and one deferred voice job existed per accepted contact; there were no
  independent follow-up rounds.
- Active incident and latest-location lifetime was 30 minutes to one hour in
  several server and client paths.
- The future Fall Response state machines were intentionally disconnected from
  production clients and the server accepted only `manual_sos`.
- The first review of this round found Android persisted an idempotency key and
  request body separately, allowing a process death to retain mismatched retry
  state.

## Delivered

- Added `manual_sos`, `band_sos`, and `validated_fall` API origins with strict
  evidence pairing and one incident per profile/event ID.
- Added preparatory automatic-paging configuration and bounded
  `detector_id:version` metadata, then hard-disabled new automatic fall
  transport after review showed that an allowlist cannot authenticate detector
  evidence. Freshness and ordering validation remain defense-in-depth only.
- Added configurable 1-8 escalation rounds, default four, at a default
  15-minute interval. Each contact and round owns independent SMS and voice
  jobs; acknowledgement cancels all unsent work.
- Added 8- and 12-hour page choices. Apple and Android retain only the latest
  fix, resume sequence safely, and stop on resolution, cancellation, or
  expiry. Acknowledgement stops unsent paging rounds but does not end the
  active location-sharing window.
- Added non-diagnostic origin summaries to provider copy, responder pages, and
  owner incident UI. No health values or raw coordinates are placed in SMS or
  voice.
- Preserved retry compatibility for pre-escalation manual request hashes and
  legacy client pending keys.
- Made Android pending page key/body persistence atomic and ignore an orphaned
  stale body when no pending key exists.
- Added migration 013 plus immutable backup manifest and restore-smoke checks.
- Updated generated nine-locale Safety copy, iOS permission text, Compose and
  environment defaults, product/privacy/release docs, durable decisions, and
  handoff records.

## Data, privacy, and medical truth

- Schema impact: migration 013 adds incident origin metadata, selected duration,
  bounded detector evidence, escalation configuration, per-delivery round, and
  a unique profile/fall-event index.
- Existing-data impact: historical incidents remain readable with nullable new
  incident metadata; existing deliveries become round zero. No app-local
  biometric history or user profile is rewritten.
- Network impact: provider copy receives a fixed non-diagnostic origin summary.
  The signed responder page can read only the latest location fix for its active
  capability. SMS and voice contain no biometric values or raw coordinates.
- Medical boundary: a possible fall is an observed motion event, not a
  diagnosis or confirmed cause. Wellness and biometric values are structurally
  excluded from the incident request model.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Server full suite | 142 passed; 10 PostgreSQL-runtime and 1 real-Twilio test skipped without their explicit environments | Memory repository, API, paging, retry, expiry, restore, and deployment contracts pass together | Managed PostgreSQL, carrier delivery, or production topology |
| PostgreSQL migration 013 and focused escalation contract | Passed on the disposable PostgreSQL 14 fixture | The additive migration and fall/escalation/location SQL path execute against PostgreSQL | Timescale, managed failover, load, or long-running production data |
| NoopRemoteSync | 44/44 passed | Apple request encoding, legacy decoding, origin, duration, and retry contracts pass | Network, background, location, or carrier behavior |
| macOS app suite | 1,431 executed; 0 failures; 1 intentional skip | The complete Apple app graph and generated Safety resources pass after project regeneration | Physical iPhone, Watch, band, haptic, BLE, or background behavior |
| iOS simulator build | Passed unsigned from regenerated `project.yml` | Current iOS sources, resources, permission copy, widgets, and Watch dependencies compile | Signing, archive, App Review, or physical-device behavior |
| Android Full Debug | 3,649 tests, 0 failures, 6 skips; APK, lint, and instrumentation-source compilation passed; final 221-key Safety localization contract rerun passed | Android logic, resources, and build graph remain coherent | OEM background behavior, band haptics, Play signing, or carrier delivery |
| Localization and claims | Strict i18n gate passed; Safety source has 221 keys with nine-locale parity; health-claims gate clear across 1,052 files | No new baseline debt, generated parity, and no prohibited affirmative health claim | Native-speaker approval or clinical validity |
| Repository policy | 62/62 tool tests, ops validator, private-data guard, legal inventory, Ruff check/format, and `git diff --check` passed | Repository policy, documentation, inventory, Python formatting, and whitespace contracts pass | Signing, carrier, store, or physical-device readiness |
| Distribution gate | Current gate passes under the 2026-08-25 NOOP owner declaration | The NOOP license, owner record, and dependency notices are coherent | Current signing, carrier, store, or physical-device readiness |

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: no physical device in this round.
- Data-preservation result: no physical app container or band state modified.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: repeated-tap SOS, overnight/background reconnect,
  haptic confirmation, fall candidates, location duration, battery, OEM
  policies, and carrier delivery.

## Git and release state

- Changed paths: Safety server/model/worker/repository, migration and backup,
  Apple and Android clients/UI/tests, generated localization, permissions,
  deployment examples, and operations/handoff documents.
- Commits: the direct-to-`main` commit containing this record.
- Branch and remote state: local `main` tracks `origin/main`; the validated
  record commit is pushed immediately after creation.
- Repository visibility verified: not rechecked in this round.
- Version/build impact: no marketing version or build-number change.
- Release or distribution impact: no artifact publication. Existing source
  rights and external production blockers remain.

## Decisions

- D-021 remains historical and is superseded by D-023.
- D-023 permits explicit app/band SOS and defines one fail-closed possible-fall
  contract while prohibiting wellness/biometric paging.

## Open risks and honest limitations

- No shipping client or firmware currently constructs an authenticated fall
  candidate; the UI remains visibly inactive and the server rejects every new
  automatic fall request even if preparatory configuration is populated.
- Unit and simulator evidence cannot establish sensitivity, false pages,
  physical haptic delivery, background reliability, location continuity,
  carrier reach, or human acknowledgement.
- Twilio staging, A2P/country registration, on-call ownership, failover/load,
  identity/recovery, signing, stores, and regulatory review remain.
- Generated translations require native-speaker review.

## Next round

1. Keep the owner-rights record, NOOP license, and independent dependency
   notices enforced by the distribution gate.
2. Run controlled carrier staging and physical app/band scenarios without
   resetting existing user data.
3. Provision identity/recovery, cloud regions, monitoring/on-call, backup,
   load, failover, signing, and store infrastructure before a production claim.
4. Keep the possible-fall gate disabled and retain the attestation hard block
   until every release condition in the fall-response contract is recorded.

## Privacy check

- [x] No credentials, phone numbers, raw biometric exports, personal names,
      device identifiers, signing identities, or absolute personal paths are
      present.
