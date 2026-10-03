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

## Objective completion audit

| Requirement | Authoritative current evidence | Status |
|---|---|---|
| Metric-first mobile Today | The exact consolidated Apple and Android UI paths match visually reviewed commit `628554748`; current Today source renders the bounded Daily Signal and value-first metric cards before optional deeper content, and each supported card opens its focused detail/history route | Locally complete |
| Secondary explanation behind detail | Apple routes metric education through `explainedMetric` sheets and focused details; Android routes metric cards to their focused metric screens. The paired reviewed phone captures keep long formula and education copy off the primary Today scan | Locally complete |
| Distinctive movable NOOP N | Apple `NoopCommandNMark` and Android `NoopCommandNMark` replace the earlier plus/grid action marks while preserving the independent 48-by-52-point target, drag, clamp, nearest-edge snap, persistence, launcher, and accessibility movement actions | Locally complete |
| Useful Trends behavior | `TrendChart` keeps touch-scrub selection pinned after release; the exact-date iPhone case passed 1/1 on the dedicated review simulator, StrandDesign passed 58/58, and Android preserves date-qualified chart-selection labels and focused metric history | Locally complete |
| Fresh-install order | Clean iPhone Simulator first run passed 2/2. Android API 35 passed all 3 managed-device cases, including Terms, Bluetooth, supported-band selection, then account without a local bypass | Locally complete |
| Cross-platform semantics and accessibility | Five labeled tabs, selected state, dock footprint, Reduced Motion, touch targets, large-content behavior, OTP masking and clearing, command-lens semantics, and source-qualified metric routes are covered by focused Apple and Android contract tests and paired visual review | Locally complete; signed-device assistive-technology testing remains physical |
| Bounded gates and visual review | Exact combined software tests, repository controls, source-equivalence check, and paired `1206x2622` / `1080x2424` visual review passed as recorded above | Locally complete |
| Durable operations and physical handoff | This round, `docs/ops/ACTIVE.md`, `AGENTS.md`, the tracked `noop-ops` skill, and the production physical-validation handoff contain the exact continuation contract | Complete |
| Protected-main integration | Protected `main` remains `a8a617593`; the local candidate is 20 commits ahead. PR 32 remains on stale head `1d2543ba1` and is blocked by the iOS failure fixed locally in `3d8256978` | Pending authorization to push, run required exact-head checks, merge normally, and verify exact main |

Historical screenshots are not accepted as current-state proof. Source and
contract checks confirm that screenshots containing `your health data, local
by default`, `Continue in local test mode`, `Host your private circle`, and the
old plus/grid command control are superseded customer states: the local-test
string remains only in a historical operations record, retired self-hosted
Friends presentation is absent from the current Apple and Android UI, and the
current command surface is the NOOP N. Unused localization history may retain
older wording for the terminology ratchet, but it is not referenced by current
onboarding runtime source.

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
- Historical screenshots that show the local-first welcome, local-test account
  bypass, self-hosted Friends setup, or the earlier plus/grid command control
  are not the current candidate and must not be used for installation or
  release evidence.
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
