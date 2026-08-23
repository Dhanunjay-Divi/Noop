# Agent handoff — deploy & merge (NOOP)

**From:** review/fix session on the sandbox clone (`/Users/divii/noop-sandbox/Noop`, host `192.168.4.86`)
**To:** the agent operating `uno@192.168.4.25:Documents/Whoop-Noop`
**Date:** 2026-08-23
**Branch to take:** `codex/noop-production-handoff-20260823`
**Tip commit:** `6242c995`

---

## TL;DR

Two new commits sit on top of `6ca08b57`. Both are verified green. Take the branch, verify it yourself
(§4), then merge per §5. Do **not** force-push; do **not** rebase what is already published.

```
6242c995  chore: capture concurrent session work at a verified green point
1557cf3c  fix: correct engine honesty, calendar valence and privacy scope   <-- the reviewed fixes
6ca08b57  docs: refresh production handoff evidence                          <-- already on uno
```

**Verified at `6242c995`:**

| Gate | Result |
|---|---|
| `NOOPiOS` (iOS Simulator, Debug) | ** BUILD SUCCEEDED ** |
| `Strand` (macOS, Debug) | ** BUILD SUCCEEDED ** |
| macOS app test suite | 1368 tests, **0 failures**, 1 skipped |
| `StrandAnalytics` engines | 1322 tests, **0 failures** |

---

## 1. Why this did not arrive over the network

`uno` was unreachable from the sandbox at handoff time:

```
$ ping -c 2 192.168.4.25   ->  2 packets transmitted, 0 received, 100.0% packet loss
$ git ls-remote --heads origin
ssh: connect to host 192.168.4.25 port 22: Operation timed out
```

Both hosts are on `192.168.4.0/24` (sandbox is `.86`), so this is `uno` being powered off / asleep /
off-network, not a routing or credential problem. Nothing was pushed. Use whichever transport in §3 works.

---

## 2. READ THIS FIRST — two agents shared one working tree

During this session another agent session was **writing the same working tree concurrently**. Proven by
timestamps and by a test's expected constant changing between two runs of the same suite. Consequences you
must know:

1. **Commit `6242c995` is not mine.** It captures that other session's in-flight edits, unmodified, taken
   at a moment when the tree had been quiet for 90 s and the whole snapshot verified green. It is a
   separate commit precisely so the boundary stays auditable. It has **not** been code-reviewed.
2. **Commit `1557cf3c` is the reviewed work** (findings + fixes, documented in
   `docs/handoff/ROUND-13-principal-review.md`).
3. Two failures reported early in that review turned out to be artifacts of reading half-written files, not
   real defects. They are corrected in the doc rather than claimed as fixes.
4. **Do not resume parallel agents on one checkout.** Give each session its own clone or `git worktree` and
   integrate through git. This is the single highest-value process change to make.

This handoff and the full review now travel WITH the code, under `docs/handoff/`:
- `docs/handoff/HANDOFF-uno-20260823.md` (this file)
- `docs/handoff/ROUND-13-principal-review.md` (the complete findings, fixes and deliberate non-fixes)

Still NOT in git (`noop_WIP/` is gitignored): the verification screenshots
`noop_WIP/screenshots/r13/{liquidtoday,calendar,calendar_effort,calendar_load}.png`. Copy those by hand if
you want them on `uno`.

---

## 3. Getting the commits onto `uno`

### Option A — push, once `uno` is awake (preferred)

Run on the **sandbox**:

```bash
cd /Users/divii/noop-sandbox/Noop
ping -c 2 192.168.4.25                     # confirm reachable first
git push origin codex/noop-production-handoff-20260823
```

No `--force`. If the push is rejected as non-fast-forward, **stop** — that means `uno` has commits the
sandbox has not seen. Fetch, inspect, and merge (§5); never overwrite.

### Option B — offline bundle (no network needed)

A bundle is a single file carrying the commits; copy it by any means (USB, AirDrop, scp later).

On the **sandbox**:

```bash
cd /Users/divii/noop-sandbox/Noop
git bundle create /tmp/noop-handoff-20260823.bundle 6ca08b57..codex/noop-production-handoff-20260823
git bundle verify /tmp/noop-handoff-20260823.bundle
```

On **uno**:

```bash
cd ~/Documents/Whoop-Noop
git bundle verify /path/to/noop-handoff-20260823.bundle          # expects 6ca08b57 to exist here
git fetch /path/to/noop-handoff-20260823.bundle \
  codex/noop-production-handoff-20260823:codex/noop-production-handoff-20260823
git log --oneline -n 3 codex/noop-production-handoff-20260823     # expect 6242c995 on top
```

> The bundle is incremental from `6ca08b57`. If `uno` lacks that commit, create a full bundle instead:
> `git bundle create /tmp/noop-full.bundle --all`

---

## 4. Verify on `uno` before merging

Do not merge on my word. Reproduce:

```bash
cd ~/Documents/Whoop-Noop
git checkout codex/noop-production-handoff-20260823
xcodegen generate

xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' \
  -configuration Debug -derivedDataPath /tmp/dd build CODE_SIGNING_ALLOWED=NO

xcodebuild -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -configuration Debug -derivedDataPath /tmp/mac_dd build CODE_SIGNING_ALLOWED=NO

xcodebuild test -project Strand.xcodeproj -scheme Strand -destination 'platform=macOS' \
  -derivedDataPath /tmp/mac_dd CODE_SIGNING_ALLOWED=NO      # expect 1368 tests, 0 failures

(cd Packages/StrandAnalytics && swift test)                  # expect 1322 tests, 0 failures
```

**Android was not built in this session** (no Android toolchain on the sandbox). The Kotlin edits are
small and mechanical, but they are **unverified by compiler**. Build them before shipping Android:

```bash
cd android && ./gradlew :app:testDebugUnitTest
```

Kotlin files touched: `analytics/HydrationGoal.kt`, `analytics/RecoveryScorer.kt`,
`analytics/VitalityEngine.kt`, `ui/LogExport.kt`, `testcentre/TestBundleAssembler.kt`,
`testcentre/ReportReviewGateTest.kt`, plus generated `res/values*/appwide.xml`.
Highest-risk of those: the `HydrationGoal.kt` `isFinite` guard (§6, E1) — it has a Kotlin unit test.

### Visual QA (optional)

```bash
xcrun simctl install "iPhone 17 Pro" \
  "/tmp/dd/Build/Products/Debug-iphonesimulator/NOOP Staging.app"
xcrun simctl launch "iPhone 17 Pro" com.noopapp.noop \
  --demo-seed --demo-screen calendar --demo-calendar-metric load   # new hook this round
```
Expect: Load ramp reads **Calm(blue) / Elevated(amber) / High(red)** and shows the
"experimental estimate … treat it as a hint" line. Effort must show **no red at all**.

---

## 5. Merging

Branches present on the sandbox: `codex/noop-production-handoff-20260823` (this one),
`codex/day4-sync-performance`, `ui-v2`. Remote also has `codex/noop`, `codex/noop-fullstack`,
`codex/public-beta-feedback`, `codex/reference-integration`, `main`.

**I deliberately did not merge to `main`.** Reasons: `main`'s true state was unreachable, so I could not see
what would conflict; and `6242c995` is unreviewed third-party work. Merging is your call, with `main` in
front of you.

Suggested sequence:

```bash
cd ~/Documents/Whoop-Noop
git fetch --all
git log --oneline --graph -n 25 main codex/noop-production-handoff-20260823   # see the real divergence

git checkout main
git pull --ff-only
git merge --no-ff codex/noop-production-handoff-20260823
# re-run every gate in §4 AFTER the merge, not just before
```

Rules: no force-push; no rebase of published commits; if `main` has diverged, resolve conflicts forward in
a new commit. Prefer `--no-ff` so the review boundary stays visible in history.

**If a conflict lands in `Strand/Resources/Localizable.xcstrings`:** do **not** resolve it with a JSON
pretty-printer. The five Ruby generators strip their namespace with a *line-based* regex that assumes one
entry per line; reformatting corrupts the file (it happened this round, §6 V2). Resolve by taking one side,
then re-run the generators:

```bash
for g in AppWide Safety Coach Nutrition DailyPlan; do ruby Tools/${g}Localization/generate.rb; done
python3 -c "import json;json.load(open('Strand/Resources/Localizable.xcstrings'));print('catalog OK')"
```

---

## 6. What changed in `1557cf3c` (the reviewed commit)

Full detail: `docs/handoff/ROUND-13-principal-review.md`.

**Engines**
- **E1 Android crash.** `HydrationGoal.kt` lacked the `isFinite` guard its Swift twin has; a NaN Effort
  reached `roundToInt()`, which **throws** on Kotlin/JVM for input Swift returns `0` for. Crash + parity break.
- **E2** `RecoveryScorer` header still credited "WHOOP's published population-average" — a claim the same
  file had already retracted. Withdrawn; 58% marked internal/uncited.
- **E3** `VitalityEngine` applied a **UK Biobank Sleep Regularity Index** hazard ratio to a duration-CV
  proxy (SRI is derived from sleep–wake *timing*). Attribution withdrawn, constant marked INTERNAL/UNCITED.
  **The number is deliberately unchanged** — see §7.
- **E4** Hydration headers still listed pre-correction `3700/2700/3200` (actual `2960/2160/2560`).

**Month calendar**
- **C1** Colour valence was inverted for 2 of 4 metrics: a **rest day** painted alarm-red, a **high-load**
  day painted positive. Valence is now per metric; legend words follow it; swatches derive from the same
  function as the cells.
- **C2** `Load` discarded its confidence/limitations, so an experimental single-signal proxy looked like a
  scored metric. It now carries that provenance.
- **C3** Title/subtitle were English literals despite translations existing (8 locales showed English).
- **C4** Per-day VoiceOver used interpolated throwaway keys → English in every locale. 4 real format keys ×9.
- **C5** Neutral-ramp alpha floor `0.38 → 0.55` (contrast on near-black).
- **C6** Now references `RecoveryScorer.bandRedMax/bandYellowMax` instead of local `34/67` literals.

**Reproductive-health privacy**
- **P1** The consent test caught a **real capability change**, not drift: optional user-typed flow/symptom
  logging exists now. Test re-pinned to the contract that still holds. Verified intact: `menstrualFlow` is
  **not** in general `readTypes`, the cycle request is read-only, dedicated consent gate present, detail
  independently erasable.
- **P2** `CycleTrackerView` documented "not symptoms, flow" three lines above the state that stores them.
- **P3** The reworded disclosure had **no catalog entry** → English in all 9 locales, while the old
  (now-false) text sat orphaned. Added ×9, orphan removed. **Non-English marked `needs_review`** — see §7.

**Parity** — Swift now mirrors Kotlin when a ready plan has no target (calibrating row, not a bare action).

**Dead code** — 1,648 lines of demo-only prototype screens (`TodayV2View`, `V2MonthCalendar`, `UIv3`,
`UIv4`) excluded from both app targets. **`UIv2/NoopV2Components.swift` and `NoopV2Tokens.swift` are NOT
excluded — they are production**: the shipping `LiquidTodayView` renders `V2HeroArc`, `V2SatelliteRing`,
`V2Chip` from them. Excluding the directory breaks both targets.

**Stale contracts from in-flight work** — localization canaries `182→204`, `61→87`; tab-bar reserved height
`88→76` (bar body shrank 56→48 pt); tab-label test re-pointed after an **untranslated** `"Train"` literal
was removed.

---

## 7. Open items you are inheriting

| # | Item | Why it is open |
|---|---|---|
| 1 | **Separate the agents' checkouts** | Process fix; blocks reliable verification (§2) |
| 2 | **Build Android** | Kotlin edits are compiler-unverified (§4) |
| 3 | **Review `6242c995`** | Concurrent session's work, not reviewed |
| 4 | **Native-speaker sign-off** on 8 `needs_review` cycle-disclosure translations | Machine-assisted translation of reproductive-health copy should not ship as final |
| 5 | **Decide WHY's driver engine** | WHY uses `ReadinessEngine`; Charge breakdown uses `ChargeDrivers`. Both legitimate, but they can name different drivers for the same day. Needs a product decision + a no-contradiction test |
| 6 | **Move `NoopV2Components.swift` / `NoopV2Tokens.swift` out of `UIv2`** | Production code in a prototype-named folder; the trap already caused a build break |
| 7 | **Real timing-based SRI, then re-fit** the sleep-regularity coefficient | E3 left the value unchanged on purpose: replacing an over-claimed constant with an arbitrary attenuation swaps one uncited number for another while moving a headline user metric |
| 8 | **Give `StressHeatmap` a consumer or retire it** | Its only consumer was the excluded prototype; kept (pure, 11 tests, Kotlin twin) but now unused |
| 9 | **Add a catalog-format guard test** | A test asserting `Localizable.xcstrings` stays one-entry-per-line would have caught the corruption in §5 immediately |

---

## 8. Invariants to preserve

- **Never fabricate a value.** Missing input renders an em-dash — never `0`, never interpolated. The
  calendar's empty outlines and "not counted as zero" summary exist for this reason.
- **Swift ↔ Kotlin parity** for anything scoring-related. E1 is what a one-sided guard costs.
- **Not a medical device.** No ECG/AFib, BP, apnea, or fabricated biological age. Fall response stays
  gated and inert until a validated band detector exists — its UI must keep saying "Not active".
- **Provenance or silence.** Every constant is cited or explicitly marked internal/uncited.
- **No em dash (U+2014) in user-visible strings** — `UserVisiblePunctuationPolicyTests` enforces it.
- **Do not pretty-print `Localizable.xcstrings`** (§5).
