# Round: 2026-10-02 - Release candidate and physical handoff

## Status

- State: `completed`
- Owner: project team
- Branch: `codex/noop-release-candidate-handoff-20261002`
- Start commit: `a8a617593b4b81485fca672353ebcebe2d073f55`
- End implementation commit: `e5f11cfe1602ec02e8b08bc4a766f7b07689e752`
- Record commit or PR: local record; no push, merge, or workflow dispatch

## Objective

Consolidate the verified mobile UI correction, supplier optional-read
hardening, deployment/security review, and physical-device continuation into
one locally reviewable candidate. Produce an executable handoff that lets a
device-connected agent validate signed iPhone and Android candidates without
guessing supplier artifacts, weakening release gates, or treating simulator
evidence as physical proof.

## Scope

### In scope

- Consolidate the iOS Recovery scrub correction and its mobile tab/OTP branch.
- Consolidate supplier step/sleep serialization, request identity, and timeout
  handling.
- Review the accessible physical-band branch and transferred PyJWT request
  against current protected main.
- Reverify the combined Apple and Android software boundaries.
- Record the private staging revision/digest and secure local configuration
  paths without exposing credentials.
- Provide one production and physical-validation handoff that uses the tracked
  `noop-ops` skill.

### Non-goals

- No GitHub push, merge, workflow dispatch, or branch deletion.
- No new cloud mutation, public invocation, real OTP, or real health-data use.
- No signed phone install, physical BLE, band vibration, possession gesture,
  permanent ownership claim, battery, background, retention, or accuracy claim.
- No supplier trust-manifest repin and no firmware flashing.

## Starting evidence

- Protected-main baseline:
  `a8a617593b4b81485fca672353ebcebe2d073f55`.
- Mobile UI correction: `3d8256978`; evidence update: `628554748`.
- Supplier serialization commits: original `769b8b8c8` and request-fenced
  `6d0805485`, consolidated as `cc8df6123` and `eae1c5d71`.
- Physical handoff commits: original `6a615ff50` and `17441847e`, consolidated
  as `13e787d0b` and `e5f11cfe1`.
- The requested checkout under another user's home directory, commits
  `d390e4a9a` and `6bf66cdb1`, and its discovery/account review document were
  unavailable.
- The accessible remote physical branch head `7db906359` is based on
  superseded main `08ad0f472`, lacks current supplier request fencing, and
  would regress PyJWT and newer product work if merged wholesale.
- Unknowns that remain physical or external: every physical transport,
  firmware, ownership, battery, retention, accuracy, provider, signing, legal,
  and launch gate.

## Delivered

- Preserved the matched five-tab mobile treatment, transient four-through-eight
  digit verification-code behavior, and touch-pinned exact-date trend
  selection.
- Serialized supplier optional reads through one source lane.
- Carried a monotonic app-owned request ID through source, adapter core, native
  wrapper callback, and persistence boundary.
- Added bounded 15-second step and 60-second sleep timeouts; late, duplicate,
  wrong-stage, and post-reconnect callbacks cannot satisfy a newer request.
- Preserved WHOOP as the distinct comparison transport.
- Confirmed protected main already carries hash-locked PyJWT `2.15.0` and the
  matching license inventory. No unavailable commit was reconstructed.
- Added and hardened
  `docs/handoff/NOOP-PRODUCTION-PHYSICAL-VALIDATION-HANDOFF-2026-10-02.md`.
- Updated `AGENTS.md` so the next device-connected agent must load the tracked
  `noop-ops` skill and both physical handoffs.
- Kept the supplier adapter disabled because the available local iOS and
  Android archives do not match protected trust evidence.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or formula impact: none; source-qualified persistence and
  formulas are unchanged.
- Permissions/network disclosure impact: none.
- Health/medical claim impact and limitations: none. Missing inputs remain
  missing; simulator values remain fictional; no sensor or derived-metric
  accuracy is claimed.

## Observability

- Supplier success, rejection, timeout, cancellation, disconnect, and stale
  callback paths use fixed diagnostic categories.
- Request identity is app-owned and is not a band, account, or device
  identifier.
- No health values, raw frames, addresses, serials, credentials, provider
  payloads, or arbitrary SDK errors were added to shared logs.
- Existing managed-service state and bounded test logs cover the UI and account
  paths without retaining verification codes.
- Remaining blind spots are physical radio behavior, supplier timing, OS/OEM
  background policy, signed-app egress, provider delivery, and sensor truth.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| XcodeGen | Pass | The combined tracked Apple graph generates | Runtime or signing |
| Focused Apple supplier tests | 88/88: 75 adapter/source and 13 neutral-SDK integration tests | Request fencing, timeout reset, stale-callback rejection, cleanup, and SDK contract compile together | Physical supplier timing or BLE |
| Complete iPhone Simulator build | Pass | App, Watch, widgets, supplier-disabled wrapper, managed account UI, and shared design package compile together | Signed install, background, or physical transport |
| Recovery exact-date UI | Passed 1/1 in 22.494 seconds on the dedicated iPhone 17 Pro review simulator | Touch scrub preserves the selected exact date after release | Physical touch latency or complete hosted status |
| Recovery simulator sensitivity | The same assertion failed on an older retained PR27 simulator state before passing on the dedicated review simulator | Exact-head hosted execution remains the integration authority; retained simulator state is not universal proof | A deterministic physical-device result |
| Clean first-run UI | Passed 2/2 in 88.554 seconds | Terms, Bluetooth, supported-band selection, account order, and configured synthetic completion remain intact | Real provider, real band, or ownership claim |
| Local Xcode teardown | XCTest completed successfully for the green UI runs, then local Xcode did not exit and the bounded process was terminated | Product assertions completed before cleanup | A clean command exit for those two UI invocations |
| StrandDesign package | 58/58 | Shared chart and design contracts remain green | App integration by itself |
| Android exact-branch contract | `PrimaryNavigationContractTest` 12/12 plus Full production and Android-test Kotlin compilation; build successful | Android tab/OTP semantics and both source sets compile on the combined branch | Emulator rendering, TalkBack, or physical phone behavior |
| Android API 35 first run | 3/3 managed-device cases passed in 10.663 seconds: post-Terms band-first order, true fresh-install Terms/Bluetooth/band-before-account order, and configured synthetic completion | The exact consolidated branch preserves the required Android first-run sequence in a clean managed emulator | Real account provider, physical band discovery, ownership, OEM behavior, or signed-phone behavior |
| Android environment retry | First invocation failed before compilation because the temporary worktree had no SDK path; rerun with the installed SDK path passed | The first result was environment configuration, not product behavior | Other developer environments |
| Consolidated UI equivalence and visual review | `git diff --quiet 628554748..HEAD` passed for shared design, iPhone UI, Android UI/resources, and mobile UI tests; the source-equivalent revision previously passed paired `1206x2622` iPhone and `1080x2424` Android review without observed clipping or overlap | No later supplier or handoff commit changed the visually reviewed mobile UI implementation | Physical display behavior, every locale/font size, or accessibility-service interaction |
| Supplier and quarantine Python tests | 62/62 | Public neutral SDK, artifact, wrapper, iOS slice, Android verifier, and compatibility boundaries remain coherent | External binary approval |
| Repository controls | 119 operations records, private-data guard, 1,325-file claims scan, 230 runtime plus 3 container legal inventory, 9 release controls, 10 required contexts, and trusted-release self-check passed | Release metadata and policy controls remain coherent | Hosted checks for a future remote head |
| Diff hygiene | Pass | No whitespace errors | Runtime correctness |

The terminology inventory is regenerated after this record is added, then
checked again so line numbers and historical counts match the final tree.

## Physical device and deployment

- Install/update action: not run.
- Generalized device and OS class: local macOS build host, iPhone 17 Pro
  Simulator, Android JVM compilation/tests, and an Android API 35 managed
  emulator.
- Data-preservation result: synthetic simulator state only; no user or phone
  data was cleared.
- BLE/background/haptic/battery scenarios exercised: not run.
- Unrun hardware gates: all `PHY-*` cases, signed candidates, WHOOP physical
  comparison, supplier physical transport, source switching, account claim,
  retention, battery, background, notifications, accessibility, and accuracy.

Private synthetic staging remains the previously integrated deployment:

- protected source merge:
  `cb57ce4fb6cdae2baf8ef7cf2b9fb4cd5781552c`;
- image digest:
  `sha256:318aee6a0160df7b5d4eb4f8f7430698dfaec7fa9261f2361c90f58bce24be3c`;
- ready revisions:
  `noop-staging-api-00001-rsg`,
  `noop-staging-managed-api-00002-6k7`, and
  `noop-staging-managed-processor-00001-cq8`.

No deployment mutation was performed in this round. The durable deployment
record reports a passing private-runtime verifier and zero-drift OpenTofu plan.

## Git and release state

- Changed paths: mobile UI and tests, supplier adapter/source/core and tests,
  `AGENTS.md`, physical handoffs, operations records, and generated terminology
  inventory.
- Commits: `3d8256978`, `628554748`, `cc8df6123`, `eae1c5d71`,
  `13e787d0b`, and `e5f11cfe1`.
- Branch and remote state: clean local consolidation branch; no push, merge,
  Actions dispatch, or GitHub runner use.
- Repository visibility verified: unchanged by this round.
- Version/build impact: none.
- Release or distribution impact: the local candidate is ready for protected
  review, not for public distribution or physical release claims.

## Decisions

- Durable decision added or changed: none.
- Decision-log entry: none.
- Existing D-059 boundary remains: cloud authority is staged for durable
  account history and canonical data, while one phone remains the encrypted
  edge collector and bounded offline working set.

## Open risks and honest limitations

- Protected integration of this combined candidate remains pending.
- The available supplier archives do not match the approved trust evidence, so
  supplier physical validation is blocked.
- WHOOP physical comparison can proceed only after an exact signed candidate is
  produced from clean protected main.
- Real OTP, public traffic, payments, provider delivery, permanent account
  linking, and every physical or metric-accuracy gate remain open.
- The unavailable transferred commits and document cannot be reviewed until a
  privacy-safe bundle or patch series is provided.

## Next round

1. Integrate through normal protected review without GitHub Actions dispatches
   for physical testing.
2. Start from clean protected main and follow
   `docs/handoff/NOOP-PRODUCTION-PHYSICAL-VALIDATION-HANDOFF-2026-10-02.md`.
3. Validate WHOOP first on signed iPhone and Android candidates.
4. Keep supplier testing blocked until the exact approved artifact tuple and
   manifest are available.
5. Record every physical result in a new operations round and update the first
   production release checklist.

## Privacy check

- [x] No credentials, emails, raw biometric exports, personal names, device
      identifiers, signing identities, or absolute personal paths are present.
