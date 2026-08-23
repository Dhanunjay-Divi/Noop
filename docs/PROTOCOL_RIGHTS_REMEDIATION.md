# Protocol redistribution-rights remediation

Status: **open distribution blocker**. This document is a remediation plan, not
evidence of permission, independent implementation, or legal clearance.

NOOP's public-distribution gate currently stops because part of the shipped
WHOOP interoperability implementation is derived from a repository that has no
explicit software license. A private repository, paid Apple Developer
membership, successful archive, or App Review acceptance does not grant rights
held by another author.

## Resolution routes

Choose and complete one route before distributing a build that contains the
affected implementation.

### 1. Written permission from the rightsholder

Obtain a signed grant from the actual rightsholder for the relevant
`johnmiddleton12/wearable` implementation. The grant must expressly cover:

- modification and source and binary redistribution;
- Apple App Store distribution and every other intended release channel;
- the relevant commits and contributions, including any required notices,
  attribution, sublicense terms, patent terms, and warranty disclaimer; and
- the code paths inherited through later NOOP repositories, not only the
  original repository name.

Separately reconcile the historical WHOOP 5/MG lineage associated with
`b-nnett/goose`. The repository has no explicit software license, and historical
project records used stronger language than the current facts-only inventory.
Either obtain sufficient written permission or complete the independently
reviewed replacement route below for that expression too.

Keep the signed grant outside the public repository when it contains personal
or contractual information. Record only a counsel-reviewed public summary or
evidence hash here. Update `ATTRIBUTION.md`, `NOTICE`, and
`docs/reference-repositories.lock.json` only after the grant's scope has been
verified. Repository-owner consent is not a substitute for consent from the
actual rightsholder.

### 2. Independently replace the affected implementation

Use a documented two-role process:

1. A specification analyst may use owned-device traces, public standards, and
   observable wire behavior to write a behavior-only specification. The
   specification must not contain source expression from the restricted
   repositories.
2. An implementer who has not viewed the restricted implementation writes the
   replacement from that specification. An independent reviewer verifies the
   provenance record and overlap report before it enters a distributable build.

This is future work. Until the process and review evidence exist, do not label
the current code clean-room or independently implemented.

## Affected shipping surface

The shared framing, schema, history, storage, and collection layers serve both
WHOOP 4 and WHOOP 5/MG. Removing only the WHOOP 4 enum cases would not resolve
the provenance issue and could break WHOOP 5/MG. Audit or replace the affected
expression at file and function granularity across:

- Apple shared protocol: `Packages/WhoopProtocol/Sources/WhoopProtocol/**`,
  including `WhoopProtocol.swift`, `Framing.swift`, `Schema.swift`,
  `Streams.swift`, `Values.swift`, `Interpreter.swift`, historical stream and
  metadata handling, `DataRange.swift`, and post hooks.
- Apple persistence: `Packages/WhoopStore/Sources/WhoopStore/**`, especially
  `WhoopStore.swift`, `Database.swift`, `StreamStore.swift`, `Reads.swift`,
  `Cursors.swift`, `MetricsCache.swift`, and `PairedDevice.swift`.
- Apple transport and collection: WHOOP-specific portions of `Strand/BLE/**`
  and `Strand/Collect/**`, including `BLEManager.swift`, `Commands.swift`,
  `FrameRouter.swift`, `LiveState.swift`, `WhoopModel.swift`, `Collector.swift`,
  `Backfiller.swift`, `ClockCorrelation.swift`, and the backfill/clock policies.
- Android protocol: `android/app/src/main/java/com/noop/protocol/**`.
- Android transport and collection: WHOOP-specific portions of
  `android/app/src/main/java/com/noop/ble/**`, including `WhoopBleClient.kt`,
  `WhoopConnectionService.kt`, `Backfiller.kt`, `BackfillPolicy.kt`, and
  `WhoopModel.kt`.

WHOOP 5/MG additionally depends on `DeviceFamily`, `Whoop5*`, `Puffin*`,
`PpgHr`, fd4b service handling, CRC16 framing, and client-hello branches on both
Apple and Android. Those paths need their own lineage reconciliation even if
the common WHOOP 4-derived core is replaced or licensed.

Build-graph files such as `project.yml` and the Swift package manifests are not
the underlying protocol expression, but they must be audited to prove that no
blocked implementation is linked into the archive.

## Acceptance criteria

Public upload stays disabled until all applicable criteria pass:

1. **Provenance:** a file/function manifest maps every shipped WHOOP protocol,
   store, and collection component to original project work or a verified
   licensed source. For the replacement route, an independent reviewer signs a
   source-overlap report showing no restricted expression beyond necessary
   interoperability identifiers and wire constants.
2. **Legal gate:** `python3 Tools/release-legal-gate.py check` and
   `python3 Tools/release-legal-gate.py distribution` both exit successfully
   from the reviewed evidence, and the required license, notice, attribution,
   disclaimer, and terms files remain bundled.
3. **Cross-platform protocol fixtures:** Swift and Kotlin tests produce the
   same frames, CRCs, commands, event/history decodes, malformed-frame
   rejection, unsigned-integer behavior, and time-boundary behavior for WHOOP 4
   and WHOOP 5/MG fixtures.
4. **Upgrade and storage continuity:** a backed-up existing app database opens
   in place; migrations preserve row counts, cursors, paired-device state, raw
   history, sleep, and workouts; SQLite integrity checks pass; no uninstall or
   reset is used.
5. **Physical hardware matrix:** representative WHOOP 4 and WHOOP 5/MG devices
   pass pairing, reconnect, opt-in live HR, offline banked-history recovery,
   overnight/background catch-up, battery, time-zone, and daylight-saving
   scenarios on real supported iPhone and Android hardware. Destructive device
   commands are out of scope.
6. **Release regression:** the Swift packages, Android unit suite, iOS/macOS
   release builds, archive signing/entitlements, privacy gates, and user-visible
   legal-document checks pass.
7. **Independent approval:** the project records the reviewer, evidence scope,
   residual risks, and approved release commit without publishing credentials,
   personal identifiers, raw biometric data, or private contract text.

## Contingency build

A HealthKit/import-only App Store variant may omit direct WHOOP BLE support only
if a fresh link-map and archive audit proves that none of the blocked protocol,
store, or collection expression is shipped. That variant does not satisfy the
goal of direct WHOOP 5/MG interoperability and is therefore a contingency, not
the default remediation.
