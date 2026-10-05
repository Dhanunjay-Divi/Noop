# NOOP dual-band, two-phone physical-test handoff

Date: 2026-10-05

## Purpose

Use this handoff to test the existing WHOOP comparison transport and the
account-linked NOOP Band transport on two separate physical phones. It
specializes the execution topology in:

- `NOOP-PRODUCTION-PHYSICAL-VALIDATION-HANDOFF-2026-10-02.md`
- `NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md`

Those documents remain authoritative for signing, supplier artifacts, install
commands, privacy, evidence, and the detailed `PHY-*` matrix.

## Agent start prompt

> Start from a new clean checkout of protected main. Load
> `.agents/skills/noop-ops/SKILL.md`, run its context snapshot, and read all
> three physical handoffs. Create a new operations round before installing
> anything. Use two separate supported phones and one exact signed app
> revision. Run the WHOOP comparison band on one phone and the NOOP Band on the
> other, with one collector and one band per lane. Keep the NOOP Band lane
> blocked unless its exact approved hardware, firmware, protocol, wrapper, and
> artifact tuple verifies. After the isolated parallel baseline, disconnect
> safely and cross the bands between iPhone and Android; one band tested on one
> OS cannot establish cross-platform support. Record privacy-safe PASS, FAIL,
> SKIPPED, or BLOCKED evidence. Do not clear retained phone data, use local-test
> onboarding, repin an unapproved archive, or flash guessed firmware.

## Starting gate

- Start at or after protected main
  `84ce9006e7a87078d7991b7dbd3a3425c77cb698`.
- Verify all ten required checks for the exact SHA.
- Confirm neutral SDK revision
  `b02808372b7c537f22058c7ebc75d92c750373be` and manifest SHA-256
  `6beca829f3b2a367cf7046544e8d06dc74ae9f905e1eefe4bb58ccf41615fd34`.
- Install the same signed app revision on both phones.
- The WHOOP lane may proceed independently.
- The NOOP Band lane is `BLOCKED` until the exact approved model, board,
  firmware, protocol, wrapper, and transitive Apple/Android artifact hashes
  match protected trust records.

## Test topology

The initial assignment may be reversed, but record the actual generalized
phone/OS and band classes.

| Phase | Phone A | Phone B |
|---|---|---|
| Parallel baseline | iPhone + WHOOP comparison band | Android + NOOP Band |
| Cross-over | iPhone + NOOP Band | Android + WHOOP comparison band |
| Source switching | One phone runs WHOOP -> NOOP Band -> WHOOP | Other phone disconnected from both |

The parallel baseline alone is insufficient for a platform claim. If an
approved NOOP Band adapter is unavailable on one OS, record that cross-over
lane as `BLOCKED`.

## Isolation and account rules

1. One band has one active phone collector at a time.
2. A phone has only one active band source.
3. Fully close official, supplier, and prior test apps that can hold BLE.
4. Disable auto-reconnect from non-test phones and watches.
5. Keep the supplier adapter disabled on the WHOOP lane.
6. Keep WHOOP stopped while the NOOP Band adapter owns a phone.
7. Never copy cursors, databases, credentials, backups, or source IDs between
   lanes.
8. Use dedicated synthetic test accounts, not personal accounts.
9. Treat the NOOP Band link as permanent. Disconnect, logout, app deletion, or
   phone reset must not release it to another account.
10. A different-account claim must fail without revealing owner identity.

## Preflight and install

```bash
git fetch origin
git checkout main
git pull --ff-only origin main
git status --short
.agents/skills/noop-ops/scripts/context_snapshot.sh .
git rev-parse HEAD
```

`git status --short` must be empty. Create a new operations round and then use
section 1.2 of `NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md` for exact signed
iPhone and Android build/install commands.

Keep signing, supplier, cloud, and device configuration ignored and private.
Never place credentials, signing identities, device identifiers, account
identifiers, serials, printed band identifiers, or BLE addresses in chat,
commits, screenshots, or shared logs.

## Required flow

1. Build both phone candidates from the same protected SHA.
2. Reject retired setup states, including local-test continuation and static
   device-model rows instead of the live scanner.
3. Complete Terms and Bluetooth permission handling.
4. Connect and identify the band first.
5. Then create or sign in to the required account and complete ownership.
6. Restart and verify the same account and source restore without a bypass.
7. Record app hashes and generalized signing/device classes privately.

## Execution order

### 1. WHOOP baseline

With the supplier factory disabled, run discovery, connect, battery, live heart
rate, history interruption/resume, reconnect, background/foreground, process
restart, notifications, diagnostics, and source provenance.

### 2. NOOP Band baseline

Only after exact artifact verification, repeat the baseline and add identify
vibration, the approved confirmation gesture, atomic account claim, optional
step/sleep timeout handling, delayed/duplicate callback rejection, and pending
read cancellation on disconnect.

Missing approved artifacts or procedures means `BLOCKED`, not a substituted
archive, firmware, key, model, or command.

### 3. Simultaneous isolation

Run both worn lanes for at least 30 minutes. Each phone must report only its
assigned source. Disconnecting or restarting one lane must not alter the other.
Notifications must open on the correct phone, and diagnostics must use fixed
source categories without private identifiers.

### 4. Cross-over

Stop and disconnect both lanes in-app, confirm no other collector holds either
band, cross the bands between iPhone and Android, and repeat discovery,
identification, connection, battery, live data, short history catch-up,
restart, background/foreground, diagnostics, and provenance checks.

### 5. Source switching

Run `PHY-CON-007` on one phone while the second is disconnected:

1. WHOOP -> NOOP Band.
2. Restart and verify.
3. NOOP Band -> WHOOP.
4. Restart and verify.
5. Confirm no samples, cursors, battery state, or provenance cross namespaces.

## Minimum matrix

| ID | Required result |
|---|---|
| DUAL-001 | Clean first run uses live scan, band-first identification, required account, and no local-test bypass |
| DUAL-002 | Concurrent scans and connections remain isolated |
| DUAL-003 | Battery, live HR, freshness, and provenance are source-correct |
| DUAL-004 | Interrupted history resumes durably without duplicate/cross-source rows |
| DUAL-005 | Background, foreground, process restart, and reconnect recover independently |
| DUAL-006 | Actionable notifications open the correct action on the correct phone |
| DUAL-007 | Identify vibration/approved gesture occurs only on the selected band |
| DUAL-008 | Today, Trends, details, and export retain correct source and missingness |
| DUAL-009 | Steps, sleep, workouts, and derived metrics obey provenance/confidence rules |
| DUAL-010 | Restarting or disconnecting one lane leaves the other unchanged |
| DUAL-011 | Both transports complete the core matrix after iPhone/Android cross-over, or the lane is `BLOCKED` |
| DUAL-012 | `PHY-CON-007` proves one collector and no state leakage |
| DUAL-013 | Second-account NOOP Band claim is privacy-preservingly rejected |
| DUAL-014 | VoiceOver and TalkBack can traverse scanner, status, actions, and errors |
| DUAL-015 | In-app diagnostics distinguish lanes without prohibited data |

Use the corresponding `PHY-*` rows for detailed procedures and pass conditions.

## Evidence and output

For every case record the exact protected SHA and artifact digest, generalized
platform/OS/phone/band/firmware class, lane/source, result, bounded timing or
aggregate count, fixed failure category, data-preservation result, and next
reproducible action.

Never record personal details, identifiers, credentials, precise locations,
raw frames, sensor rows, biometric values, payloads, or arbitrary SDK errors.

The agent must leave:

1. A new operations round with all `DUAL-*` and applicable `PHY-*` results.
2. A review note stating what was observed, fixed, failed, or blocked.
3. A focused defect branch with platform-parity tests when code changes are
   required.
4. Sanitized evidence hashes and secure local paths, never credentials.
5. The exact next command for every failed or blocked case.

## Stop conditions

Stop the affected lane when main/checks are not green, phone revisions differ,
the supplier tuple is unknown or mismatched, another collector holds the band,
provenance crosses sources, ordinary actions release ownership, unexpected
supplier egress occurs, or continuation requires guessed firmware, keys,
credentials, destructive procedures, or unsafe evidence capture.
