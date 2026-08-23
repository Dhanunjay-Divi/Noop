# Release blockers & production readiness

**Assessed:** 2026-08-23
**Hosted implementation checkpoint:** `94661a17`; use `git log -1` for the
current Round 14 implementation and handoff commit.
**Verdict:** engineering gates are **green**. Commercial distribution is
blocked by the three unresolved rights entries in
`docs/provenance/rights-status.json`.

Current continuation instructions:
[`AGENT-HANDOFF-20260823.md`](AGENT-HANDOFF-20260823.md).

---

## 0. Gates — all green

| Gate | Result | Command |
|---|---|---|
| iOS app (`NOOPiOS`, Debug) | ✅ BUILD SUCCEEDED | `xcodebuild -scheme NOOPiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` |
| iOS production-shell UI suite | PASS, 17 tests, 0 failures | `xcodebuild -scheme NOOPiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test` |
| Profile keyboard regression | PASS, 5/5 on iPhone 17 Pro and 5/5 on compact iPhone 17e | `testProfileMeasurementsCanBeClearedAndRetyped` with `-test-iterations 5` |
| Charging fixture regression | PASS, 5/5 UI iterations and 2/2 focused unit contracts | Charging UI test on a new simulator plus `AppleDemoSeederTests` |
| macOS app (`Strand`, Debug) | ✅ BUILD SUCCEEDED | `xcodebuild -scheme Strand -destination 'platform=macOS' build` |
| macOS app tests | ✅ **1390** tests, 0 failures, 1 skipped | `xcodebuild test -scheme Strand -destination 'platform=macOS'` |
| Swift engines | ✅ **1322** tests, 0 failures | `cd Packages/StrandAnalytics && swift test` |
| **Android unit tests** | ✅ **3564** tests, 0 failures, 6 skipped (471 classes) | `cd android && ./gradlew :app:testFullDebugUnitTest` |
| Release legal inventory | ✅ 152 runtime components, 3 container inputs | `python3 Tools/release-legal-gate.py check` |

Android was previously flagged as compiler-unverified in the earlier handoff. **That gap is now closed** —
JDK 17 and the SDK were present at `~/Library/Android/sdk`; export `ANDROID_HOME` and the suite runs.

Hosted i18n run `32670362251` and health-claims run `32670362291` passed at
`94661a17`. Hosted app run `32668839522` is intentionally retained as a failed
attempt: its macOS leg passed and its iOS leg failed only the charging-state UI
assertion. Commit `94661a17` moves that DEBUG fixture ahead of first render;
local full-suite, clean-simulator repetition, and unit-contract evidence all
pass after the change. Final hosted app run `32670362286` passed both jobs at
`94661a17`: universal macOS build and tests, plus iOS simulator build and 16/16
production-shell tests including the charging assertion.

At the current local HEAD, Round 14 adds the complete Today metric-catalog UI
regression, bringing the iOS suite to 17/17. The macOS suite remains 1,390 tests
with 0 failures and 1 skip, StrandDesign passes 44/44, and the Android Demo
Debug unit suite passes. Visual and continuation evidence is in
[`ROUND-14-today-metrics-recovery.md`](ROUND-14-today-metrics-recovery.md).

---

## 1. BLOCKER — the current licence does not permit commercial distribution

The owner selected a commercially independent product, with this tree retained
as the non-commercial reference codebase. Qualified counsel still needs to
review the completed provenance evidence and commercial terms.

What is true in the tree right now:

| Artefact | Says |
|---|---|
| `LICENSE` | **PolyForm Noncommercial License 1.0.0** ("Copyright 2026 NoopApp"); 7 noncommercial references |
| `README.md:668` | "**Keep it non-commercial** … PolyForm Noncommercial — mirror and use freely, **just don't sell it or ship it in a paid product**" |
| `TERMS.md` 2.3 | This codebase is non-commercial and not cleared for commercial distribution |
| Apple and Android terms gates | Both require acknowledgment version `2.3`; CI verifies parity |
| `DISCLAIMER.md` | PolyForm Noncommercial applies to this tree's original work |
| `README`, `docs/CONTRIBUTING.md`, `docs/PRIVACY_SECURITY.md` | Describe this reference codebase as non-commercial |
| `codex/day4-sync-performance` (**merged in**) | "Prepare first App Store preview release" |

The earlier Terms/README mismatch was corrected in the repository-independence
pass. This makes the current tree internally consistent; it does not grant
commercial rights.

### The harder half — inherited code you may not have permission to sell

`NOTICE` states it plainly:

> That mechanical dependency work does **not** cure NOOP's inherited `johnmiddleton12/my-whoop` (now
> `johnmiddleton12/wearable`) provenance. The active base says that WHOOP 4 protocol/store and collection
> expression was adapted from that repository, but **the pinned reference has no explicit software
> licence. Attribution is not permission.**

Relicensing your own code is your right as copyright holder. **Code adapted from a repository with no
licence is not yours to relicense**, and "no licence" means no permission to redistribute at all, let alone
commercially. A free App Store listing is a weaker version of the same question; a paid product or bundled
hardware makes it sharper.

**Scope (corrected 2026-08-23):** the **known minimum** replacement core is
`Packages/WhoopProtocol/Sources` (6,425 Swift lines) plus
`Packages/WhoopStore/Sources` (9,555 Swift lines), or **15,980 lines**. The
complete classification surface also includes `Strand/BLE` (12,154),
`Strand/Collect` (1,510), Android protocol (4,369 Kotlin lines), and Android BLE
(15,155). That is a review ceiling of **49,168 source lines across 154 files**;
some transport files may prove independently developed, but that must be shown
file by file. Tests and fixtures require the same provenance treatment. An
earlier ~209,000-line figure counted `.build/checkouts/` dependencies and was
wrong. Observable wire constants can be documented independently, but source
expression must not be copied.

A rewrite of those packages does **not** by itself clear the fork lineage: the app is multi-author under
PolyForm Noncommercial with no CLA. See `docs/handoff/OWNERSHIP-CLEANUP-CHECKLIST.md` §2.

### What must happen before a commercial release

1. Keep this reference tree non-commercial under its existing terms.
2. For the separate commercial implementation, **establish provenance for the
   inherited `my-whoop`/`wearable` behavior** — obtain a licence,
   or clean-room reimplement the adapted parts, or remove them.
3. Give the independently authored commercial repository its own deliberately
   chosen licence and counsel-reviewed terms.
4. Record contributor grants or independent replacement evidence for every
   affected component, not only the protocol packages.
5. Keep the new repository-rights gate green. It now rejects missing blockers,
   deleted provenance entries, and removed markers while rights remain
   unresolved.
6. Put the commercial implementation in a genuinely new history containing
   only independently authored or separately licensed code. Changing `origin`
   is hosting migration, not source clearance.

**Until 2–4 are done, this tree is not a commercial release candidate.**

---

## 2. Also required before an App Store submission

| # | Item | Why |
|---|---|---|
| 2.1 | **Trademark review of the WHOOP references** | The app still interoperates with WHOOP hardware and names it throughout. Nominative fair use is a real defence and the disclaimer is careful, but App Review and WHOOP's counsel are different audiences. `DISCLAIMER.md` is strong; have someone confirm the store listing matches it. |
| 2.2 | **Privacy manifest / nutrition label must match the new usage strings** | This session corrected `NSHealthShareUsageDescription` to disclose all three destinations (local, self-hosted server, user-chosen AI provider) and `NSHealthUpdateUsageDescription` to name workouts + sleep. The App Store privacy answers must say the same. |
| 2.3 | **HealthKit + reproductive-health review** | Cycle tracking reads Apple Health cycle-start dates behind a dedicated consent gate and stores optional user-typed flow/symptoms locally. Verified: `menstrualFlow` is **not** in general `readTypes`, the request is read-only, detail is independently erasable. Expect reviewer questions; the answers are in `docs/handoff/ROUND-13-principal-review.md` §3. |
| 2.4 | **Native-speaker sign-off on 8 machine-translated locale values** | The cycle disclosure was machine-translated this round and is not approved for release. CI marks the four focus locales structurally complete, while the other four remain `needs_review`; neither state is native-speaker sign-off. |
| 2.5 | **Fall response must stay visibly inert** | It is correctly gated ("Not active", "Supported band firmware required", no production code constructs a candidate). Do not enable it without a validated detector; do not let marketing imply fall detection exists. |
| 2.6 | **"NOOP Band is in development"** | TERMS/DISCLAIMER now say this. Keep the store listing consistent — no implication that first-party hardware ships today. |
| 2.7 | **Retire the imported i18n baseline** | Canonical CI now blocks new debt, but 247 Android and 166 Apple unique literals remain baseline-tracked and are not proof of translated UI. Migrate them to reviewed resources before claiming supported-language readiness. |

---

## 3. Engineering follow-ups (not release blockers)

1. **One agent per checkout.** Two agents shared this working tree; it produced phantom test failures and a
   half-written file mid-build. Use separate clones or `git worktree`.
2. **Decide WHY's driver engine** — the WHY section uses `ReadinessEngine`, the Charge breakdown uses
   `ChargeDrivers`; they can name different drivers for the same day. Needs a product call plus a
   no-contradiction test.
3. **Move `UIv2/NoopV2Components.swift` + `NoopV2Tokens.swift`** out of `UIv2` — production code in a
   prototype-named folder already caused one build break.
4. **Real timing-based SRI**, then re-fit the sleep-regularity coefficient (currently marked
   INTERNAL/UNCITED on purpose).
5. **`StressHeatmap` has no consumer** — give it one or retire it.
6. **Add a catalog-format guard** — a test asserting `Localizable.xcstrings` stays one-entry-per-line. The
   five Ruby generators strip their namespace with a line-based regex; pretty-printing the file corrupts it.
7. **Review the two captured concurrent-session commits** (`6242c995`, `86b6d17e`) — verified green, but
   not code-reviewed.

---

## 4. Repository migration

The local `origin` now targets
`https://github.com/Dhanunjay-Divi/Noop.git`. Cached remote-tracking refs from
the prior server were removed. Authenticated GitHub inspection verified
the private canonical repository reports `isFork=false`, has no parent, and has
zero child forks.

Do not push this inherited `main` into an empty repository intended to be the
commercial clean codebase. Follow
`docs/REPOSITORY_INDEPENDENCE.md` and keep this checkout as the auditable
reference until an independent implementation and rights review are complete.
