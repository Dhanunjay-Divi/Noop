# Release blockers & production readiness

**Assessed:** 2026-08-23
**Commit:** `main` @ the consolidation merge (see `git log -1`)
**Verdict:** engineering gates are **green**. There is **one non-engineering blocker** (§1) that only the
owner can clear, and it is the thing standing between this build and a paid/commercial release.

---

## 0. Gates — all green

| Gate | Result | Command |
|---|---|---|
| iOS app (`NOOPiOS`, Debug) | ✅ BUILD SUCCEEDED | `xcodebuild -scheme NOOPiOS -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build` |
| macOS app (`Strand`, Debug) | ✅ BUILD SUCCEEDED | `xcodebuild -scheme Strand -destination 'platform=macOS' build` |
| macOS app tests | ✅ **1389** tests, 0 failures, 1 skipped | `xcodebuild test -scheme Strand -destination 'platform=macOS'` |
| Swift engines | ✅ **1322** tests, 0 failures | `cd Packages/StrandAnalytics && swift test` |
| **Android unit tests** | ✅ **3564** tests, 0 failures, 6 skipped (471 classes) | `cd android && ./gradlew :app:testFullDebugUnitTest` |
| Release legal inventory | ✅ 152 runtime components, 3 container inputs | `python3 Tools/release-legal-gate.py check` |

Android was previously flagged as compiler-unverified in the earlier handoff. **That gap is now closed** —
JDK 17 and the SDK were present at `~/Library/Android/sdk`; export `ANDROID_HOME` and the suite runs.

---

## 1. BLOCKER — the licence does not permit the commercial posture the docs now take

**This is not a bug and I did not "fix" it. It is an owner decision, and probably a lawyer's.**

What is true in the tree right now:

| Artefact | Says |
|---|---|
| `LICENSE` | **PolyForm Noncommercial License 1.0.0** ("Copyright 2026 NoopApp"); 7 noncommercial references |
| `README.md:668` | "**Keep it non-commercial** … PolyForm Noncommercial — mirror and use freely, **just don't sell it or ship it in a paid product**" |
| `TERMS.md` §1 (**changed this session**) | "NOOP is a free, independent, **non-commercial**, local-first application" → "NOOP is an independent, local-first application" |
| `TERMS.md` §risk (**changed**) | "Because NOOP is provided **free of charge, on a non-commercial basis**…" → "Because this is **early-access software**…" |
| `TERMS.md` §1 (**changed**) | "published anonymously by an **unpaid hobbyist** maintainer" → "maintained by its project maintainers" |
| `TERMS.md:156` (**left behind**) | still says "NOOP is **free**, local-first, and independent" — now contradicts its own §1 |
| `DISCLAIMER.md` (**changed**) | dropped "non-commercial project by an individual hobbyist" |
| `README`, `docs/CONTRIBUTING.md:585`, `docs/PRIVACY_SECURITY.md:875` | **still** describe NOOP as non-commercial / hobbyist |
| `codex/day4-sync-performance` (**merged in**) | "Prepare first App Store preview release" |

So the terms have been quietly repositioned toward a commercial product while the licence that governs the
code still forbids selling it, and the rest of the docs still say "non-commercial". Those cannot all be true.

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

### What must happen before a commercial release

1. **Decide the posture**: stay noncommercial (revert the TERMS wording) *or* go commercial (then §2 below).
2. If commercial: **establish provenance for the inherited `my-whoop`/`wearable` code** — obtain a licence,
   or clean-room reimplement the adapted parts, or remove them.
3. Re-licence NOOP's own code deliberately (a new `LICENSE`, not silence).
4. Make every doc consistent: `TERMS.md:156`, `README.md:627/646/650/668`, `docs/CONTRIBUTING.md:585`,
   `docs/PRIVACY_SECURITY.md:875`, `DISCLAIMER.md`.
5. Add a gate so this cannot drift again — `Tools/release-legal-gate.py` verifies the **dependency**
   inventory but does **not** check TERMS ↔ LICENSE ↔ README coherence. It should.

**Until 1–4 are done, the honest release channel is a free, noncommercial distribution.**

---

## 2. Also required before an App Store submission

| # | Item | Why |
|---|---|---|
| 2.1 | **Trademark review of the WHOOP references** | The app still interoperates with WHOOP hardware and names it throughout. Nominative fair use is a real defence and the disclaimer is careful, but App Review and WHOOP's counsel are different audiences. `DISCLAIMER.md` is strong; have someone confirm the store listing matches it. |
| 2.2 | **Privacy manifest / nutrition label must match the new usage strings** | This session corrected `NSHealthShareUsageDescription` to disclose all three destinations (local, self-hosted server, user-chosen AI provider) and `NSHealthUpdateUsageDescription` to name workouts + sleep. The App Store privacy answers must say the same. |
| 2.3 | **HealthKit + reproductive-health review** | Cycle tracking reads Apple Health cycle-start dates behind a dedicated consent gate and stores optional user-typed flow/symptoms locally. Verified: `menstrualFlow` is **not** in general `readTypes`, the request is read-only, detail is independently erasable. Expect reviewer questions; the answers are in `docs/handoff/ROUND-13-principal-review.md` §3. |
| 2.4 | **Native-speaker sign-off on 8 `needs_review` strings** | The cycle disclosure was machine-translated this round and is flagged, not final. Shipping unreviewed reproductive-health copy in 8 locales is a bad trade. |
| 2.5 | **Fall response must stay visibly inert** | It is correctly gated ("Not active", "Supported band firmware required", no production code constructs a candidate). Do not enable it without a validated detector; do not let marketing imply fall detection exists. |
| 2.6 | **"NOOP Band is in development"** | TERMS/DISCLAIMER now say this. Keep the store listing consistent — no implication that first-party hardware ships today. |

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

## 4. Branch consolidation

Everything now lives on **`main`**. Fully contained in it (safe to delete):

```
origin/codex/day4-sync-performance             origin/codex/public-beta-feedback
origin/codex/noop-production-handoff-20260823  origin/codex/reference-integration
origin/ui-v2
```

Deliberately **not** merged:

| Branch | Why |
|---|---|
| `origin/codex/noop` | **Unrelated history** (no merge base) and explicitly archived — tip is "docs: archive project", 2026-07-23. Merging would graft a foreign 1,869-commit lineage. |
| `origin/codex/noop-fullstack` | Stale: merge-base *and* tip are both 2026-07-24 while this line moved 42 commits since. Dry-run merge produced **89 conflicts**. Its server work appears superseded (`server/app/safety_repository.py`, migrations 005–007, current test suite). If anything there is still wanted — `server/tests/test_api.py` is the one file with no obvious successor — cherry-pick it deliberately. |

Optional cleanup (**destructive to shared refs — run only if you agree**; SHAs recorded above so any can be
restored):

```bash
git push origin --delete codex/day4-sync-performance codex/public-beta-feedback \
                          codex/reference-integration ui-v2
```

Keep `codex/noop` (archive) and `codex/noop-fullstack` (unmerged) until §4 is decided.

### Recorded branch tips (2026-08-23) — restore any deleted branch with these

```
origin/codex/day4-sync-performance                 b82c4da277266cd54df039559af27c9c46682aa3
origin/codex/noop                                  33cea3fd88412486b91fc693970329fb484a4600
origin/codex/noop-fullstack                        49ada8e5fc5af9c0b64de680ef2bcc6c57a32ae2
origin/codex/noop-production-handoff-20260823      6ca08b577a941abf756b10a51334978818c579c0
origin/codex/public-beta-feedback                  9bb157a292882d7cb9c47b935af3fdb0c738c942
origin/codex/reference-integration                 d2b201c5e9cb4e3616dec89cd262c99bf6e7d045
origin/main                                        849fc99bd8f86df9713ba9f44722a4de0383be1f
origin/ui-v2                                       332583d6ac5ff984827ea01e30f356021f51985f
```
