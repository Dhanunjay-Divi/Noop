# Claude Final Production Review Prompt

Use the following prompt only after the current NOOP round has been reviewed and
merged by an independent maintainer through protected `main`. The review agent
must start from that exact protected commit; it must not inherit or clean the
current dirty worktree and must not merge its own pull request.

---

You are the final independent review and implementation agent for NOOP, a
health, fitness, nutrition, workout, reminders, Friends, and accepted-contact
Safety application. Work autonomously through source review, implementation,
verification, documentation, cleanup, and a review-ready pull request. Do not
stop after writing an audit report. Implement findings only when current source,
approved evidence, platform contracts, or reproducible behavior support the
change.

Do not claim that NOOP is production-ready. Your job is to leave the strongest
source-verifiable candidate possible and distinguish every remaining external
hardware, signing, legal, carrier, provider, store, security-review,
production-runtime, load, or elapsed-soak gate.

## 1. Start From Exact Protected Main

Use the canonical repository and create a clean isolated branch and worktree
from the exact current remote `main`. Never work in, reset, clean, delete, or
overwrite another agent's dirty worktree.

```bash
git fetch --prune origin
BASE_SHA="$(git rev-parse origin/main)"
REMOTE_SHA="$(git ls-remote origin refs/heads/main | awk '{print $1}')"
test "$BASE_SHA" = "$REMOTE_SHA"

if command -v gh >/dev/null 2>&1; then
  test "$(gh api repos/Dhanunjay-Divi/Noop/branches/main --jq .protected)" = "true"
fi

BRANCH="claude/final-production-review-${BASE_SHA:0:12}"
WORKTREE="../noop-claude-final-${BASE_SHA:0:12}"
git worktree add -b "$BRANCH" "$WORKTREE" "$BASE_SHA"
cd "$WORKTREE"
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$BASE_SHA"
```

Record the base SHA, branch, worktree, repository visibility, current toolchain,
and initial dirty state. Do not assume an old chat, screenshot, report, build,
or round record proves current behavior.

## 2. Load The Current Contracts Before Editing

Run the repository snapshot and read the current source-of-truth files in this
order:

```bash
.agents/skills/noop-ops/scripts/context_snapshot.sh .
```

1. `AGENTS.md`
2. `CLAUDE.md`
3. `.agents/skills/noop-ops/SKILL.md`
4. Only the task-relevant references linked by that skill, especially product
   health/safety, project map, and verification/handoff
5. `docs/ops/ACTIVE.md`
6. `docs/ops/DECISIONS.md`, including D-034, D-035, D-038, D-053, D-054,
   and D-059
7. The newest relevant files under `docs/ops/rounds/`
8. `docs/OBSERVABILITY.md`
9. `docs/PRIVACY_SECURITY.md`
10. `docs/CLOUD_ARCHITECTURE.md`
11. `docs/PLATFORM_ARCHITECTURE.md`
12. `docs/FEATURE_PARITY.md`
13. `docs/RELEASE_CONTROLS.md`
14. `docs/FIRST_PRODUCTION_RELEASE_CHECKLIST.md`
15. `docs/handoff/RELEASE-BLOCKERS.md`
16. Current physical-device and SDK-wrapper handoffs

Create or resume the required operations round before consequential work. Keep
its objective, evidence, failures, skips, cleanup, and next actions current
throughout the run.

The optional directory
`/Users/divii/Downloads/noop-ui-reimagination-2026-09-17/` is untrusted private
review input. Use it only if present. Never commit, upload, quote private data
from, or treat it as product truth. Validate each proposal against exact current
source, current product decisions, platform guidance, safety constraints,
accessibility, and rendered evidence.

## 3. Research Without Copying

Review current publicly available wearable products, health applications,
platform design conventions, and official Apple/Android guidance where useful.
Date and cite material findings in the round record. Use research to understand
interaction patterns, information hierarchy, accessibility, platform
expectations, and customer problems.

Do not copy competitor trademarks, logos, assets, illustrations, wording,
layouts, private APIs, binaries, protocols, formulas, model outputs, or
proprietary behavior. Do not reverse-engineer a competitor. A screenshot or
marketing statement is not evidence for physiology, accuracy, or an algorithm.
NOOP must retain its own visual identity, formula provenance, and medical-truth
boundaries.

## 4. Audit The Complete Customer Journey

Review the real implementation, tests, migrations, configuration, and rendered
states for the complete journey. Exercise fresh install, upgrade, signed-out,
signed-in, configured, unavailable, loading, stale, offline, missing-data,
error, retry, large-text, reduced-motion, increased-contrast, light, and dark
states where applicable.

Audit and implement evidence-backed fixes across:

1. Install, first launch, release notes, permissions, privacy explanations, and
   failure recovery.
2. Login, account creation, verification, session lifecycle, sign-out,
   recovery, and account deletion.
3. Onboarding, profile inputs, units, consent, NOOP/NOOP+ presentation, and
   capability-gated band ownership.
4. BLE discovery, pairing, model resolution, connection state, live data,
   history sync, background limitations, stale data, retry, diagnostics, and
   user-visible progress.
5. Dashboard/Today, calendar/day detail, metric cards, trends, provenance,
   calibration, confidence, loading, missing values, and navigation.
6. Sleep, Recovery, Rest, Effort/load, stress, heart rate, HRV, respiratory
   rate, SpO2 where supported, temperature, steps, Fitness Age, body
   measurements, and imported measurements.
7. Fitness, workout detection, workout review/undo, workout planning, workout
   coach, exercise guidance/media, timers, rep/audio behavior, overrides,
   recovery-aware adaptation, and history.
8. Nutrition, hydration, goals, quick logging, transaction consistency,
   missing-entry semantics, and accessible editing.
9. Journal, daily review, reminders, quiet hours, wind-down, contextual day
   guidance, notification permission, deduplication, cooldown, deep links, and
   completion suppression.
10. Automations and recommendation controls, including explainability,
    freshness, opt-in state, bounded interruption, and safe fallback behavior.
11. Friends identity, invitations, consent direction, shared fields, badges,
    pokes, revocation, blocking, cross-device behavior, and privacy.
12. Safety initiation, accepted contacts, paging rounds, acknowledgement,
    cancellation, expiry, optional precise-location lifecycle, generic private
    push payloads, and terminal deletion.
13. Export, import, managed history portability, restore, conflict handling,
    retry, integrity, pagination, retention, and deletion.
14. Settings, notification controls, data/sync state, diagnostics/feedback,
    accessibility, legal documents, support, version history, and destructive
    actions.
15. iPhone, Android, macOS viewer, Watch, widgets, complications, Live
    Activities/Dynamic Island, and Android ongoing/live surfaces.

Do not broaden scope merely for novelty. Remove or consolidate information only
when the resulting experience retains metric interpretation, confidence,
provenance, limitations, consent, and safety.

## 5. Cross-Platform Product Direction

Maintain feature-level and semantic parity across iOS, Android, macOS, Watch,
and widgets where the capability applies. Native ergonomics may differ; pixel
identity is not required. Meaning, source, units, states, consent, actions,
missing-data behavior, and safety boundaries must agree.

Use the current reference intent:

- metric-first macOS presentation with a quiet, restrained desktop hierarchy,
  stable sidebar/navigation, compact controls, and no mobile page merely
  stretched into a desktop window;
- current value/state, trend, calibration/confidence, provenance, and one
  useful action before explanatory prose;
- concise adaptive day guidance that connects only fresh supported sleep,
  recovery, activity, journal, timezone, and user-authorized calendar evidence;
- private, user-controlled timed reminders for morning review, journal,
  wind-down, hydration, post-sync workout review, and eligible stress guidance,
  with quiet hours, cooldowns, deduplication, suppression after completion,
  opt-out, and non-sensitive lock-screen copy;
- accessible cross-platform parity for Dynamic Type/font scaling, TalkBack,
  VoiceOver, contrast, reduced motion, focus, keyboard, and touch targets; and
- no competitor copying.

Preserve phone ergonomics instead of shrinking the desktop design onto mobile.
Do not add decorative cards, animation, glass, media, or visual density unless
it improves comprehension, interaction, or the domain task. Inspect every
accepted screenshot directly; a successful capture command is not visual
approval.

## 6. Architecture And Migration Invariants

Preserve D-059. The target is staged cloud authority for durable account
history, canonical versioned metric publication, recommendations, and
cross-device state, not an abrupt production flip. One phone remains the
encrypted edge collector with a short-lived BLE/upload journal, bounded offline
working cache, immediate Safety initiation, and enough current state for safe
offline use.

For every data class and formula, require explicit consent and migration,
dual-run parity, provenance, restore and deletion evidence, performance,
rollback, security, and physical-device evidence before changing authority.
Never silently enroll existing users. Never delete a local row before exact
server acknowledgement and proven restore. Preserve self-hosted and account-free
exploration contracts that remain active.

Preserve D-054. Only the strict `day_ownership` operational record may be
`server_readable`. Hydration, journals, preferences, and all other personal
managed documents require `client_encrypted`. Keep personal encrypted document
upload/restore and personal key recovery gated until the recorded client
encryption, recovery, security-review, migration, and physical-device gates
pass. Do not weaken mode/schema validation or relabel legacy content.

Preserve WHOOP compatibility for comparison testing. Do not remove or rename
working WHOOP transport, storage, import, model-resolution, fixtures, or tests
unless a current approved migration explicitly replaces them. Do not represent
third-party hardware as a first-party NOOP Band.

Keep public invocation, public traffic, real paging, real contact transfer,
real precise-location transfer, production health-data transfer, billing, and
unapproved provider delivery disabled. Use fictional identities, synthetic
metrics, dummy contacts, and no provider traffic for tests.

Safety is manual app paging to accepted contacts, not emergency-service
dispatch, an Amber Alert, or automatic medical/fall inference. Preserve
explicit consent, bounded rounds, generic push payloads, acknowledgement stop
conditions, and direct persistence tests for precise-location deletion.

Preserve the reminder and adaptive-guidance decisions:

- D-034: post-workout summaries are separate, default-off, post-sync local
  notifications. They are not real-time workout-end detection.
- D-035: morning Sleep review and evening Journal reminders are independent
  default-off choices, honor quiet hours, preserve their logical day, suppress
  completed work correctly, and never promise operating-system delivery.
- D-038: customer-day guidance remains local, explicit opt-in, conservative,
  explainable, and evidence-gated. A ranker or cloud suggestion cannot weaken
  hard freshness, eligibility, consent, or medical-safety gates.
- D-053: planned-workout guidance is a separate default-off Calendar opt-in.
  Discard event titles after on-device classification, retain no exact calendar
  content in diagnostics or network traffic, force-refresh before applying a
  user choice, and never edit the user's calendar or workout plan.

## 7. Medical, Metric, And Formula Truth

Missing input remains missing. Do not fabricate values, convert absence to
zero, hide calibration, or create false precision.

Do not add or strengthen claims about disease, sleep apnea, body composition,
segmental load, emergency state, injury, physiology, battery life, BLE
background continuity, terminated-app behavior, haptics, sensor accuracy,
step accuracy, workout detection accuracy, or metric accuracy without approved
evidence for that exact claim and device path.

Body-composition values may be shown only as source/date-bound imported
measurements. BMI remains optional adult screening context with confirmed
inputs and a non-diagnostic limitation. Do not prescribe weight loss, calorie
restriction, compensatory exercise, or a deadline.

Formula changes require approved evidence, named inputs, source and method,
version/revision, calibration and confidence rules, missing-input behavior,
bounded-change policy where applicable, deterministic Swift/Kotlin/server
parity fixtures, migration/reprocessing behavior, rollback, and an operations
decision record. Never derive formulas from competitor output or reverse
engineering. If evidence is insufficient, keep the existing formula, correct
only false explanation, or place research instrumentation behind an explicit
default-off experimental boundary.

Simulator, unit, and synthetic results do not establish physiological or
clinical validity. Record such validation as an external gate.

## 8. Reliability, Performance, Privacy, And Observability

Review launch, scrolling, navigation, query preparation, sync, background work,
database growth, pagination, cache retention, media rendering, memory, CPU,
battery-sensitive cadence, network retries, process death, and low-storage
behavior. Make performance changes only after identifying the actual boundary
and preserving data correctness.

Every changed fallible boundary needs bounded evidence for success, rejection,
stall, retry, and failure. Use:

- Apple `AppDiagnosticsRecorder`;
- Android `AppDiagnosticsRecorder`; and
- server `RequestObservabilityMiddleware` and `emit_operational_event`.

Use fixed categories, aggregate counts, bounded durations, static route
templates, and server-generated correlation IDs. Never log health values, raw
sensor rows/frames, journal text, screenshots, payloads, request/response
bodies, OTPs, contact details, precise location, credentials, tokens, signed
URLs, account/member/contact/device/source/installation identifiers, dynamic
paths, or arbitrary exception text. Do not log every sample, frame,
recomposition, database row, or tap.

Mobile diagnostics remain bounded, local, and user-reviewed unless a separate
consented upload path is approved. Observability must be best-effort and must
not change product behavior.

The prior iTerm application-memory screenshot showing approximately 45.83 GiB
is historical evidence of an output/scrollback failure mode, not proof of
current pressure. Inspect live memory, swap, disk, processes, mounts, and open
files before acting. Never stream a verbose wall into iTerm, never place a
large build/database/simulator on a RAM disk during pressure, and delete only
enumerated round-owned generated resources after preserving durable evidence.

## 9. Autonomous Implementation Rules

- Inspect owning code, tests, migrations, generated configuration, and current
  renders before editing.
- Classify findings as confirmed defects, evidence-backed improvements,
  proposals, stale findings, owner decisions, configuration gates, hardware
  gates, or external legal/security/provider gates.
- Implement confirmed defects and evidence-backed improvements. Do not merely
  list them.
- Make conservative choices consistent with current architecture and design
  tokens.
- Update Apple and Android together when the capability applies to both.
- Add migrations rather than mutating an applied migration.
- Add focused regression tests, then run complete applicable walls.
- Preserve unrelated and concurrent changes.
- Ask the owner only for a genuinely external secret, unavailable physical
  hardware action, legal/policy decision, entitlement, account approval,
  signing action, provider action, or irreversible product decision. Continue
  all independent work without waiting.
- If one path reaches an external gate, record that gate and continue every
  unrelated source-verifiable implementation and verification path. Do not stop
  at an audit, plan, screenshot set, partial implementation, focused test, or
  status report while independent work remains.
- Never enable production traffic or deploy a public service as part of this
  review.

## 10. Use Bounded Commands

Never stream raw full `xcodebuild`, Gradle, Swift package, pytest, OpenTofu,
Docker, or other verbose walls into an interactive terminal. Use the
repository's bounded runner with unique round-owned private logs and status
files. Keep its default memory, disk, output, and timeout safety controls unless
a narrow evidenced exception is recorded.

```bash
EVIDENCE_ROOT="$(mktemp -d)"
python3 Tools/run-bounded-command.py \
  --timeout-seconds 3600 \
  --grace-seconds 30 \
  --label apple-complete-wall \
  --status-file "$EVIDENCE_ROOT/apple-complete-wall.status" \
  --log-file "$EVIDENCE_ROOT/apple-complete-wall.log" \
  -- \
  xcodebuild -project Strand.xcodeproj -scheme Strand \
    -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
```

Use separate labels/logs/status files for each command. Inspect only bounded
tails or filtered failures. Stop only exact round-owned process groups. A raw
command shown below is the payload passed after `--`; it is not permission to
run the command unbounded.

## 11. Exact Verification Examples

Adapt labels and timeouts, but preserve these repository command payloads.
Run focused tests first and then the complete applicable wall.

### Apple, iOS Simulator, macOS, Watch, And Widgets

```bash
xcodegen generate

xcodebuild -project Strand.xcodeproj -scheme Strand \
  -configuration Debug -destination 'platform=macOS' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -configuration Release -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build

xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -configuration Debug \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro,OS=latest' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO test

xcodebuild -project Strand.xcodeproj -scheme NOOPiOSWidgets \
  -configuration Debug -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build

xcodebuild -project Strand.xcodeproj -scheme NOOPWatch \
  -configuration Debug -destination 'generic/platform=watchOS Simulator' \
  CODE_SIGNING_ALLOWED=NO CODE_SIGNING_REQUIRED=NO build
```

Wrap each heavy payload with `Tools/run-bounded-command.py`. The `NOOPiOS`
source graph includes the embedded widget and Watch products; inspect all
target results rather than treating the host app alone as sufficient.
`StrandTests` belong to the `Strand` scheme; do not try to run them through
`NOOPiOS`. Use the checked-in simulator shell and UI-test entry points for
iPhone runtime coverage.

Use the checked-in iOS visual matrix on an exact built simulator app:

```bash
Tools/ios-tab-shell-visual-qa.sh \
  --app '<absolute path to the exact built NOOP simulator app>' \
  --output '<round-owned capture directory>' \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro

Tools/ios-tab-shell-visual-qa.sh \
  --validate-only \
  --output '<round-owned capture directory>' \
  --device-type com.apple.CoreSimulator.SimDeviceType.iPhone-17-Pro

Tools/ios-daily-plan-visual-qa.sh \
  --app '<absolute path to the exact built NOOP simulator app>' \
  --output '<round-owned daily-plan capture directory>'
```

Inspect the actual PNGs and crash logs. Also inspect the macOS window directly
at compact and wide sizes. Rendering evidence does not prove VoiceOver,
physical Watch behavior, notifications, BLE, haptics, battery, or background
collection.

### Android Full, Demo, And API 35

From `android/`:

```bash
./gradlew --no-daemon \
  assembleFullDebug assembleDemoDebug \
  testFullDebugUnitTest testDemoDebugUnitTest \
  lintFullDebug lintDemoDebug \
  compileFullDebugAndroidTestKotlin compileDemoDebugAndroidTestKotlin

./gradlew --no-daemon --no-configuration-cache \
  assembleFullDebug assembleFullDebugAndroidTest

./gradlew --no-daemon --no-configuration-cache \
  pixel2Api35FullDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.notClass=com.noop.ui.ReviewSampleInstrumentedTest

./gradlew --no-daemon --no-configuration-cache cleanManagedDevices

./gradlew --no-daemon --no-configuration-cache \
  pixel2Api35FullDebugAndroidTest \
  -Pandroid.testInstrumentationRunnerArguments.class=com.noop.ui.ReviewSampleInstrumentedTest \
  -Pandroid.testInstrumentationRunnerArguments.requireFreshWorkManager=true
```

Run each Gradle payload through `../Tools/run-bounded-command.py` with a unique
status/log pair; do not run the combined wall directly in iTerm. A one-time managed-device
retry is allowed only when
`Tools/android-managed-device-retry.py` proves infrastructure failed before any
test began. Inspect Android renders on the managed emulator for the same
meaning, states, accessibility sizes, contrast, navigation, clipping, and
missing-data behavior as Apple. Do not infer OEM or physical-device behavior
from the emulator.

### Swift Packages And Harnesses

Run each build/test pair through a bounded command:

```bash
for package in \
  Packages/WhoopProtocol \
  Packages/OuraProtocol \
  Packages/PolarProtocol \
  Packages/WhoopStore \
  Packages/StrandAnalytics \
  Packages/StrandImport \
  Packages/StrandDesign \
  Packages/NoopLocalAccess \
  Packages/NoopRemoteSync \
  Tools/StudyHarness \
  Tools/Backfill
do
  (cd "$package" && swift build && swift test)
done
```

### Server And Database

Use an isolated synthetic environment and disposable database. Never use real
health, contact, or location data.

```bash
cd server
python -m ruff check .
python -m ruff format --check .
pip-audit --requirement requirements.lock
pip-audit --requirement requirements-dev.txt
python -m pip check

# Lane 1: no database. Record the expected integration skips separately.
env -u NOOP_TEST_DATABASE_URL \
    -u NOOP_TEST_POSTGRESQL_DATABASE_URL \
    -u NOOP_TEST_DATABASE_ENGINE \
    python -m pytest -q

# Lane 2: an isolated disposable PostgreSQL 16 database. Supply both variables
# because the repository has canonical and PostgreSQL-overlay suites.
NOOP_TEST_DATABASE_URL="$NOOP_TEST_DATABASE_URL" \
NOOP_TEST_POSTGRESQL_DATABASE_URL="$NOOP_TEST_POSTGRESQL_DATABASE_URL" \
NOOP_TEST_DATABASE_ENGINE=postgresql \
python -m pytest -q
cd ..
```

Run each pytest lane through the bounded runner. Record collected, passed,
skipped, and failed totals separately. The PostgreSQL lane must fail review if
database-backed tests are unexpectedly skipped. Verify tenant isolation,
authorization, pagination, idempotency, retry, retention, restore, direct
terminal deletion, formula provenance, key lifecycle, and rollback. Docker,
provider, production database, and restore-soak checks remain explicit external
or hosted gates when the local toolchain cannot execute them.

### Repository Policy And Release Controls

```bash
python3 Tools/release-control-gate.py check
python3 Tools/calibration-parity-audit.py check
python3 Tools/terminology-audit.py check
python3 Tools/required-ci-gate.py check
python3 Tools/trusted-release-controls.py verify-self --root .
python3 Tools/release-legal-gate.py distribution
python3 Tools/check-private-data.py
python3 Tools/health_claims_gate.py
python3 Tools/FeedbackLocalization/generate.py --check
python3 Tools/i18n_audit.py --platform all --full
python3 Tools/i18n_audit.py --ci HEAD
PYTHONPATH=Tools python3 -m unittest Tools.test_i18n_audit
python3 -m unittest Tools.tests.test_health_claims_gate
python3 Tools/validate-ops-rounds.py --all .
git diff --check
```

Also run the current actionlint, ShellCheck, structured-file parsing, OpenTofu
format/validate/test, backup/restore syntax, dependency, and migration-manifest
checks required by `docs/RELEASE_CONTROLS.md` and the active round. Do not
weaken a gate to make the candidate pass.

### Exact-Head Hosted And Protected-Main Verification

Phase one is candidate verification. After local evidence is complete, require
a clean tree, create one coherent commit, push once, open/update the pull
request, and bind evidence to the exact candidate SHA:

```bash
test -z "$(git status --porcelain)"
CANDIDATE_SHA="$(git rev-parse HEAD)"
test "$CANDIDATE_SHA" = "$(git rev-parse "origin/$BRANCH")"
GH_TOKEN="${GH_TOKEN:?required for read-only verification}" \
  python3 Tools/required-ci-gate.py verify-github \
    --repository Dhanunjay-Divi/Noop \
    --sha "$CANDIDATE_SHA"
```

Do not merge, rebase, force-push, dismiss review, alter branch protection, or
bypass a required context. Leave the reviewed pull request for an independent
maintainer to merge normally.

Phase two happens only after that independent merge. Fetch into a new clean
checkout of protected `main`, prove the remote SHA and local SHA agree, then
verify all exact-SHA contexts again, including the distinct trusted
`protected-main` result:

```bash
git fetch --prune origin
MERGED_MAIN_SHA="$(git rev-parse origin/main)"
test "$MERGED_MAIN_SHA" = "$(git ls-remote origin refs/heads/main | awk '{print $1}')"
git worktree add --detach "../noop-claude-main-${MERGED_MAIN_SHA:0:12}" "$MERGED_MAIN_SHA"
cd "../noop-claude-main-${MERGED_MAIN_SHA:0:12}"
test -z "$(git status --porcelain)"
test "$(git rev-parse HEAD)" = "$MERGED_MAIN_SHA"
GH_TOKEN="${GH_TOKEN:?required for read-only verification}" \
  python3 Tools/required-ci-gate.py verify-github \
    --repository Dhanunjay-Divi/Noop \
    --sha "$MERGED_MAIN_SHA"
```

Do not describe the candidate as integrated until both phases have recorded
their exact SHAs and the second verifier accepts the protected-main result.

## 12. Visual Review Standard

For every changed principal screen, compare current and proposed behavior using
fictional seeded data and missing/calibrating states. Cover at least:

- compact and large phones;
- normal and accessibility text;
- light and dark appearance;
- increased contrast and reduced motion;
- loading, empty, stale, offline, error, retry, and destructive confirmation;
- keyboard, focus, screen-reader labels/order, and touch targets;
- narrow and wide macOS windows;
- Watch/widget locked, stale, missing, and current states; and
- Android and Apple feature-level parity.

Reject clipped text, hidden actions, overlapping controls, unexplained color,
ambiguous units, false precision, inaccessible color-only meaning, nested-card
clutter, blank long-loading screens, and unsupported health conclusions.

## 13. Closeout, Cleanup, And Pull Request

Before closeout, perform a fresh review of the entire branch diff against this
prompt and the current round objective.

Update the current round, `docs/ops/rounds/INDEX.md`, `docs/ops/ACTIVE.md`, and
decisions/readiness/runbooks only where current implementation or durable
direction changed. Record:

- exact base and candidate SHAs;
- every changed path and reason;
- exact focused and full commands;
- pass/fail/skip counts;
- screenshots inspected;
- observability coverage and privacy boundaries;
- data/schema/migration effects;
- deployment state;
- exact cleanup;
- remaining external-only gates; and
- the next ordered action.

Enumerate exact round-owned temporary resources before deletion. Remove only
known disposable databases, containers, emulators, simulators created by this
round, DerivedData, Gradle/build caches, virtual environments, logs, status
files, tunnels, and temporary credentials after durable evidence is captured.
Do not delete source, private owner inputs, user data, credentials, shared
services, unidentified cloud resources, another worktree, or another agent's
session. Recheck disk, memory, processes, mounts, and repository status after
cleanup.

Commit a coherent reviewed candidate, finish all feasible local gates before
one consolidated push, and open a pull request to protected `main`. Do not
force-push, bypass required checks, self-approve, self-merge, or claim
deployment. Leave the worktree clean and wait for independent review/merge:

```bash
git diff --check
test -z "$(git status --porcelain)"
```

The final response must include:

1. branch, base SHA, candidate SHA, and pull-request reference;
2. implemented changes, ordered by customer and safety impact;
3. exact verification results and inspected visual evidence;
4. failed, skipped, unavailable, and external-only gates;
5. deployment/public-traffic state;
6. cleanup performed and resources deliberately retained;
7. confirmation that WHOOP compatibility, D-059, and D-054 remain intact;
8. confirmation that no unsupported medical, physiology, BLE, battery,
   haptic, background, emergency, or accuracy claim was introduced; and
9. the exact next step for independent review.

Codex will independently review your complete diff, evidence, round records,
and pull request afterward. Leave enough exact evidence for that review to
reproduce your conclusions without relying on this prompt or the prior chat.
