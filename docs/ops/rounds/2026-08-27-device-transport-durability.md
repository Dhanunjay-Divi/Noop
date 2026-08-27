# Round: 2026-08-27 - Device transport durability and support boundaries

## Status

- State: `completed locally; representative physical-device validation remains`
- Owner: project team
- Branch: `main`
- Start commit: `753f4ed8`
- End implementation commit: commit containing this record
- Record commit or PR: the same direct-to-`main` commit requested by the owner

## Objective

Recover and harden the complete device-support implementation without claiming
universal proprietary-wearable compatibility. Success means the stable WHOOP 4
path remains intact, WHOOP 5/MG and Oura experimental paths fail safely, Garmin
scope stays honest, history cursors never outrun durable data, and both platform
implementations build and pass their full local test suites.

## Scope

### In scope

- Audit the owner-supplied archived initial snapshot against current WHOOP,
  Oura, Garmin, generic-HR, import, and protocol files.
- Restore or harden missing transport behavior on Apple and Android.
- Correlate family discovery, session opening, battery routing, history,
  timestamps, persistence, teardown, and stale callbacks.
- Add focused cross-platform regression tests and update device/protocol docs.

### Non-goals

- Claim support for an unmeasured future device family.
- Claim WHOOP 5/MG or Oura Gen 4/5 physical validation from software tests.
- Implement proprietary Garmin deep history, Body Battery, cloud sync, or
  universal watch control.
- Restore obsolete one-off diagnostic probes when the production driver already
  contains the required behavior.

## Starting evidence

- The archived snapshot contained the same core WHOOP, Oura, Garmin import, and
  standard-HR foundations as current mainline. Its additional Oura and older
  WHOOP files were capture or diagnostic tools, not missing production drivers.
- Combined setup discovery could stamp a peripheral with a stale selected
  transport family when advertisement evidence was absent.
- WHOOP 5/MG confirmed-write callbacks were not correlated specifically to the
  connection's CLIENT_HELLO, and Android battery reads could run before the
  service family was established.
- Oura used an obsolete SyncTime layout and a zero-count event request that
  re-served the current hardware window.
- Oura history completion could race asynchronous store writes, late TLVs,
  source replacement, and teardown. Banked records could also leak into live
  state or receive an invented arrival timestamp when no clock anchor existed.

## Delivered

- WHOOP setup now scans both known service families and adopts a family only
  from explicit advertisement or discovered-service evidence. WHOOP 5/MG
  CLIENT_HELLO completion is correlated to the exact pending confirmed write.
- Android defers battery routing until service discovery establishes the family,
  keeps WHOOP 4 on its custom battery command, and uses the standard battery
  characteristic only for WHOOP 5/MG.
- Productive legacy history timeouts no longer contradict durable rows with an
  interruption banner; genuine stalls and future-clock errors remain visible.
- Oura now serializes no-response commands, uses the hardware-validated
  SyncTime layout, corrects generation from GetProductInfo, continues history
  with bounded nonzero requests, and disables plus unsubscribes live HR before
  a bounded transport close.
- Oura history has a two-phase, generation-scoped persistence barrier. Terminal
  summaries request completion, the next real request boundary seals the
  generation, and the durable cursor moves only after every associated stream
  and sleep-session write succeeds. Failure, timeout, disconnect, stale
  callback, or explicit teardown leaves the cursor behind.
- Banked TLVs stay persistence-only. Only a genuinely live secure push can
  update current HR/R-R/wear state; a state event from history must also resolve
  within 120 seconds of now. Unanchored history is omitted for retry rather than
  stamped at sync-arrival time.
- Banked IBI records materialize one conservative historical HR row from the
  median physiological interval, in the same anchored transaction and cursor
  obligation as their R-R rows.
- Apple source ownership uses a generation token so delayed Oura teardown
  callbacks cannot clear a replacement source. Android scan replay runs inline
  on its main owner so a queued callback cannot reconnect after stop, and stop
  invalidates the history barrier before a late Room completion can move it.
- The hosted clean universal macOS build exposed a Swift type-checker timeout in
  an existing chained timestamp expression. The expression is now split into
  explicitly typed appends; behavior is unchanged and both `x86_64` and `arm64`
  compile in the exact CI configuration.
- Documentation now records the exact support boundary: WHOOP 4 stable; WHOOP
  5/MG implemented but physically unvalidated; future WHOOP families
  unsupported until measured; Oura Gen 3 physically exercised while Gen 4/5
  remain experimental; Garmin limited to owner-data import and standard HR
  broadcast.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: additive and fail-closed. Successful history
  remains idempotent; uncertain or failed history is re-served because the
  cursor stays behind. No database reset, device removal, or app reinstall ran.
- Source/provenance or formula impact: banked Oura IBI can now produce
  conservative anchored HR history. No NOOP score formula or vendor score was
  imported or changed.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: no detector or medical claim was
  enabled. Build and fixture evidence does not establish physiological accuracy.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| OuraProtocol package | 143 tests; 0 failures | Framing, SyncTime, generation, history, IBI-HR, and driver contracts pass | Physical Gen 4/5 behavior |
| WhoopStore package | 399 tests; 0 failures | Oura stream batching and persistence mapping remain coherent | Live radio behavior |
| macOS app suite | 1,508 tests; 1 fixture skip; 0 failures | Apple integration, persistence, and lifecycle tests pass | Physical iPhone or wearable behavior |
| Universal macOS build | Passed with `x86_64 arm64` in the exact hosted-CI configuration | A clean dual-architecture build no longer exceeds the Swift type-checker limit | Notarization or Intel runtime behavior |
| Unsigned iOS simulator build | Passed on iPhone 17 Pro destination | The consolidated iOS, Watch, widget, package, and localization graph compiles | Signing, background execution, battery, or physical BLE |
| Android Full and Demo unit tests | 7,652 tests; 14 skips; 0 failures/errors | Both variants compile and the final lifecycle regressions pass | Android OEM or physical BLE behavior |
| Android Full and Demo APK assembly | Passed | Both debug application variants package successfully | Play signing or store acceptance |
| Independent lifecycle review | Nine transport races found, fixed, and regression-covered | The changed async boundaries received a separate adversarial pass | Exhaustive concurrency or hardware validation |
| Archived-snapshot inventory | Core production lanes present; diagnostic-only extras classified | No active WHOOP/Oura/Garmin driver was blindly omitted | Runtime equivalence on every firmware |

## Physical device and deployment

- Install/update action: not run.
- Simulator evidence: iPhone 17 Pro build destination only; no UI behavior was
  changed in this round.
- Data-preservation result: no local application container or physical device
  was mutated.
- BLE/background/haptic/battery scenarios exercised: no new physical run.
- Unrun hardware gates: WHOOP 5/MG overnight history, reconnect, haptics,
  battery, background collection, Oura Gen 4/5, Android OEM behavior, and
  representative in-place upgrades.

## Git and release state

- Changed paths: Apple and Android device transports, Oura protocol/store
  packages, focused tests, device/protocol documentation, and operations docs.
- Commits: the direct-to-`main` commit containing this record.
- Branch and remote state: local `main` is pushed and checked against
  `origin/main` after all final gates pass.
- Version/build impact: no marketing version, build number, bundle identity, or
  database schema change.
- Release or distribution impact: no signed artifact or store release.

## Decisions

- Added D-032: direct-device support is scoped to an exact validated lane and
  model family; shared protocol shape is not future-device evidence.
- Preserved D-002, D-007, and D-024: source provenance stays explicit,
  physical-device claims require physical evidence, and customer wording remains
  NOOP or neutral while internal compatibility identifiers remain available.

## Open risks and honest limitations

- WHOOP 5/MG and Oura Gen 4/5 still need representative physical-device
  validation. Tests prove software behavior only.
- Oura Gen 3 raw on-device sleep stages remain experimental and are not the
  vendor application's post-processed score.
- Garmin direct support remains standard HR broadcast only. Proprietary device
  history and cloud account integration are absent.
- External signing, store, infrastructure, carrier, accuracy, localization, and
  regulatory gates remain in the release-blocker record.

## Next round

1. Run the physical WHOOP 5/MG and Oura Gen 4/5 matrix with captured firmware,
   overnight, reconnect, background, battery, and in-place upgrade evidence.
2. Complete Android OEM and physical iPhone background/reconnect validation.
3. Keep future device families unavailable until their exact transport and
   data-retention behavior is measured.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
