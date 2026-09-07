# Round: 2026-09-07 - Post-release resource cleanup

## Status

- State: `completed`
- Owner: project team
- Branch: `main`
- Start commit: `c4d2039c`
- End implementation commit: `c4d2039c` (no source implementation change)
- Record commit or PR: pending

## Objective

Clean up temporary local resources started during the completed NOOP build,
test, staging, and preview work. Success requires graceful shutdown of every
confirmed temporary process and virtual device, removal of the confirmed
temporary PostgreSQL cluster, preservation of simulator data and unrelated
persistent services, and a post-cleanup process/port/device audit.

## Scope

### In scope

- Stop repository-owned local HTTP relays on ports 8765-8767.
- Stop repository-owned Cloud SQL proxies on ports 5433, 5434, and 6543.
- Stop both OpenGym preview servers on ports 4173 and 4174.
- Stop the NOOP Gradle daemon.
- Gracefully stop the `noop_api35` Android emulator.
- Shut down the three booted iOS NOOP test simulators without erasing them.
- Stop and remove the confirmed temporary PostgreSQL test cluster on port
  55439.
- Verify that the persistent Homebrew PostgreSQL service on port 5432 remains
  available.

### Non-goals

- Do not erase simulator/emulator data or uninstall test applications.
- Do not stop the persistent Homebrew PostgreSQL service.
- Do not destroy retained IAM-only synthetic GCP staging infrastructure,
  databases, buckets, identities, or configuration.
- Do not change application, server, firmware, analytics, or infrastructure
  source.

## Starting evidence

- Reproduction or observed symptom: temporary resources remained active after
  the preceding work completed.
- Relevant source/device/OS/firmware class: three booted iOS 26.5 simulators
  with NOOP installed, one Android API 35 emulator with Full and Demo packages,
  local HTTP/proxy processes, one Gradle daemon, and two preview servers.
- Existing tests, logs, exports, screenshots, or documents: process ownership,
  working-directory, listening-port, simulator application, Android package,
  and process-parent audits confirmed the inventory. The temporary PostgreSQL
  cluster contains 17 synthetic NOOP test databases and occupies 313 MB.
- Unknowns that must remain unknown until measured: none needed for local
  cleanup. Retained cloud state is deliberately outside this round.

## Delivered

- Gracefully terminated four repository-owned local HTTP relays and three
  repository-owned Cloud SQL proxies.
- Gracefully terminated both OpenGym preview process groups.
- Stopped the repository's Gradle daemon with the Gradle wrapper.
- Shut down the connected `noop_api35` emulator through ADB. The AVD remains
  registered and was not wiped.
- Shut down all three booted NOOP iOS simulators with `simctl`. Their simulator
  definitions remain registered and were not erased.
- Stopped the temporary PostgreSQL cluster with `pg_ctl`, verified that no
  postmaster PID remained, and removed its path-checked 313 MB test directory.
- Confirmed closure of all nine scoped listener ports and absence of every
  scoped process pattern.
- Confirmed that the unrelated persistent PostgreSQL service on port 5432
  still accepts connections and queries.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: only the confirmed temporary synthetic
  PostgreSQL test cluster was deleted. Simulator and emulator data were
  retained.
- Source/provenance or formula impact: none.
- Permissions/network disclosure impact: loopback/local development listeners
  were closed; no cloud IAM or public-ingress policy changes.
- Health/medical claim impact and limitations: none.

## Observability

- Evidence that diagnoses success, stall/rejection, and failure: process exit,
  listening-port closure, virtual-device state, Gradle daemon state, temporary
  directory removal, and a positive persistent-PostgreSQL readiness check.
- Why existing evidence is sufficient, or why new evidence is required:
  cleanup changes only local operational state, so operating-system and
  toolchain lifecycle evidence is sufficient; no product runtime boundary
  changes.
- Existing evidence reused: `ps`, `lsof`, `simctl`, `adb`, Gradle, PostgreSQL
  control/readiness tools, and filesystem checks.
- New bounded events or operation spans: none.
- Redaction, retention, and high-frequency controls: the record contains
  aggregate counts, generic simulator names, and local port classes only. It
  excludes UDIDs, credentials, user data, health values, and cloud resource
  identifiers.
- Cross-platform/backend correlation: not applicable.
- Remaining blind spots: process shutdown cannot establish physical-device,
  BLE, health, or production cloud behavior.

## Evidence

Record exact commands and results. Distinguish unit, integration, simulator,
physical-device, and external-service evidence.

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Initial process, port, and working-directory inventory | Confirmed the scoped temporary resources and persistent PostgreSQL exclusion | Cleanup targets are locally owned and attributable | Product correctness or cloud state |
| Initial virtual-device and package inventory | Three booted NOOP iOS simulators and one connected NOOP Android emulator | The virtual devices are in scope | Physical-device behavior |
| `kill -TERM` for the confirmed relay, proxy, and preview processes | All 11 scoped processes exited within the bounded wait | Local development listeners stopped gracefully | Remote cloud-resource deletion |
| `adb emu kill`, `./gradlew --stop`, and targeted `simctl shutdown` | One emulator, one Gradle daemon, and three simulators stopped | The active Android and Apple test resources are no longer consuming runtime resources | Physical-device behavior or erased simulator state |
| `pg_ctl -m fast -w stop` followed by path-checked test-directory removal | Server stopped; the 313 MB directory and port 55439 are absent | The temporary synthetic database resource was removed | The retained persistent database or cloud database contents |
| `lsof` on ports 8765-8767, 4173-4174, 5433-5434, 6543, and 55439 | All nine ports closed | No scoped listener remains | Unrelated listeners |
| Process-pattern, `simctl`, ADB, Gradle, and AVD audit | No scoped process, booted simulator, connected emulator, or Gradle daemon; simulator definitions and `noop_api35` remain registered | Runtime cleanup succeeded without erasing virtual devices | Application correctness |
| `pg_isready` plus `SELECT 1` on port 5432 | Accepted connections and returned `1` | The persistent local PostgreSQL service was preserved | Production database health |
| Docker CLI availability check | Docker CLI was not installed, so no live container query was available | The audit limitation is explicit | Absence of containers in an unavailable runtime |
| First combined whitespace-check wrapper | Failed before reporting a result because it assigned zsh's read-only `status` variable | The shell wrapper needed correction | Documentation validity |
| Corrected operations, privacy, credential-pattern, and whitespace gates | 32 round records validated; all checks passed | The documentation is structurally valid and contains no detected private artifact, high-confidence credential pattern, or whitespace error | Product runtime behavior |

## Physical device and deployment

- Install/update action: none.
- Generalized device and OS class: iOS 26.5 simulators and Android API 35
  emulator only.
- Data-preservation result: simulator definitions and the Android AVD remain
  registered; no erase, wipe, uninstall, or application-data command ran. Only
  the confirmed synthetic temporary PostgreSQL cluster was deleted.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all physical-device, BLE, background, haptic, battery,
  attestation, notification, and sensor gates.

## Git and release state

- Changed paths: this operations record, `docs/ops/rounds/INDEX.md`, and
  `docs/ops/ACTIVE.md`.
- Commits: none.
- Branch and remote state: clean `main` matched `origin/main` at round start.
- Repository visibility verified: not re-queried; unchanged by this round.
- Version/build impact: none.
- Release or distribution impact: none.

## Decisions

- Durable decision added or changed: none. Temporary local resources are
  removed while retained private cloud staging and persistent local services
  remain available.
- Decision-log entry: not required.

## Open risks and honest limitations

- Cleanup does not validate the product or alter any outstanding launch gate.
- The Docker CLI was unavailable, so there is no container-runtime query in
  this round. The initial process and listener inventory found no confirmed
  NOOP container resource to clean.

## Next round

1. Resume the ordered first-production-release checklist from the current
   active handoff.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
