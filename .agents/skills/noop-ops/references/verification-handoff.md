# NOOP Verification And Handoff

Read this before broad verification, simulator work, commit/push/deploy, or
agent transfer.

## Worktree And Concurrency

- Inspect `git status --short --branch`, `git worktree list`, recent commits,
  and the active operations round before editing.
- Preserve user and concurrent-agent changes. Use isolated worktrees for broad
  rounds and disjoint file ownership for parallel agents.
- Before integrating delegated work, inspect its diff, run focused tests in the
  receiving tree, and resolve against current source rather than blindly
  cherry-picking.
- Keep main protected. Do not force-push, reset, checkout away, or delete
  another worktree's state.

## Verification Ladder

Run the narrowest meaningful tests after each slice, then the complete relevant
wall.

Typical Apple app commands:

```bash
xcodegen generate
xcodebuild -project Strand.xcodeproj -scheme Strand \
  -destination 'platform=macOS' CODE_SIGNING_ALLOWED=NO test
xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'generic/platform=iOS Simulator' \
  CODE_SIGNING_ALLOWED=NO build
```

Use `-only-testing:StrandTests/<Class>` with the `Strand` scheme for focused app
tests. `NOOPiOS` does not own `StrandTests`.

Typical Android commands:

```bash
cd android
./gradlew :app:compileFullDebugKotlin :app:testFullDebugUnitTest
./gradlew :app:compileDemoDebugKotlin :app:testDemoDebugUnitTest
./gradlew :app:lintFullDebug :app:lintDemoDebug
./gradlew :app:assembleFullDebug :app:assembleDemoDebug
```

Add production/instrumentation source compilation when the changed boundary
requires it. Run focused `--tests` selectors first.

Typical repository gates:

```bash
python3 Tools/validate-ops-rounds.py --all .
python3 Tools/i18n_audit.py --platform all --full
git diff --check
```

Also run current health-claims, terminology, private-data, secret, calibration,
legal/provenance, and required-CI gates documented by the active round or
release controls.

## Visual And Accessibility Evidence

- Use the repository's simulator QA scripts where available, then inspect the
  resulting images rather than trusting exit status alone.
- Verify normal and dark appearance, small phones, wide desktop, landscape when
  applicable, reduced motion, and accessibility text sizes.
- Check that values, units, labels, actions, tab/navigation state, and missing
  states do not clip, overlap, or shift.
- A screenshot proves rendering only. VoiceOver/TalkBack focus, haptics, BLE,
  notification delivery, background collection, and battery require physical
  devices.

## Backend And Cloud

- Use synthetic identities and non-health fixtures.
- Verify authorization, tenant isolation, pagination, idempotency, retention,
  deletion, retry, and direct database state.
- Keep public traffic, real paging, real contact/location data, and production
  health transfer disabled unless the current request and every release gate
  explicitly permit them.
- Clean temporary databases, containers, tokens, tunnels, emulators, derived
  data, and test resources. Do not delete shared or unidentified resources.

## Git And Actions Cost

- Commit bounded, reviewable slices locally.
- Finish local gates before the consolidated remote push so GitHub Actions does
  not repeatedly run against known-incomplete source.
- Do not avoid, weaken, or bypass required protected checks. Record exact SHA
  and hosted result after the final push.

## Handoff Contract

Before stopping, update:

- current round status and exact evidence;
- `docs/ops/ACTIVE.md`;
- `docs/ops/rounds/INDEX.md`;
- decisions/readiness/runbooks when their contract changed.

The handoff must state:

- repository/worktree/branch and exact commit;
- dirty paths and which worker owns them;
- what changed and why;
- commands run with pass/fail/skip results;
- deployment and resource-cleanup state;
- external-only gates;
- the next ordered command;
- health, privacy, and physical-device limitations.

Do not write "done", "production ready", or "deployed" when any required local
gate, protected check, production action, or external evidence is still open.
