# Founder review — what is needed, what is pending

**Date:** 2026-08-23 · **Branch:** `main` · **Lens:** what I would demand before putting my name and my
hardware behind this.

**Verified now:** iOS ✅ · macOS ✅ **1393** app tests 0 failures · engines **1323** 0 failures · Android
**3564** 0 failures · i18n strict gate ✅ · legal inventory ✅ · distribution **BLOCKED** (by design, §1).

---

## 0. Answer to "are all the references removed?" — No, and they must not be yet

The clean-room rewrite has **not** happened. Measured, not assumed:

| | Files | Lines | Status |
|---|---|---|---|
| `Packages/WhoopProtocol/Sources` | 30 | 6,425 | **unchanged** |
| `Packages/WhoopStore/Sources` | 38 | 9,555 | **unchanged** |

`ATTRIBUTION.md` still records `johnmiddleton12/my-whoop` (1 reference) and `ryanbr/noop` (2). Removing them
now would delete the notice while the code still ships — the exact thing that converts "we credited our
sources" into "we concealed them".

**What did land is better than a text edit:** `Tools/release-legal-gate.py` now has a `distribution` mode
that fails closed:

```
DISTRIBUTION BLOCKED: repository independence is not established
(contributor-relicensing-rights, polyform-upstream-lineage, unlicensed-whoop4-expression).
A new remote, fork detachment, renamed history, or deleted attribution does not grant
source rights; resolve the recorded blockers with reviewed evidence.
```

with machine-readable state in `docs/provenance/rights-status.json` (`intendedPosture:
commercial-independent`, `distributionStatus: blocked`, `independentHistoryEstablished: false`) and
clearance requirements per blocker: resolution route, affected source manifest, reviewed commit,
independent reviewer, evidence digest. Allowed routes: `rights-holder-license`,
`independent-replacement`, `removal`.

That is the correct architecture: the rights problem is now impossible to forget and impossible to
accidentally ship past. **It is also the only thing standing between this build and a commercial release.**
Sequence to unblock: rewrite `WhoopProtocol`/`WhoopStore` Sources (15,980 lines) → record the evidence →
gate turns green → *then* I remove the attribution, verified per
`docs/handoff/OWNERSHIP-CLEANUP-CHECKLIST.md`.

---

## 1. Found and fixed this session

### A localization regression that had been made invisible *(fixed the visibility, handed off the copy)*

Renaming the device to "Noop Band" rewrote sentences that were **already translated into 8 locales**. The new
sentences are not catalog keys, so they render **English in every non-English locale**, while the old
translations sit orphaned in the catalog.

The strict gate passes anyway, because those literals were **absorbed into
`Tools/i18n_audit_baseline.json`** rather than extracted: the iOS baseline grew **57 → 166**, and **64** of
those entries contain "Noop Band". `docs/PRODUCTION_READINESS.md` still describes the pre-absorption state
("fails on 68 Android and 102 Apple literals"), which is now stale.

A baseline is a fair tool; using it to swallow a shipped regression is not. What I did:

* `docs/localization/BRAND-RENAME-WORKLIST.md` — every affected string, paired with the orphaned
  translation to reuse: **22 exact pairs**, 14 near matches, 28 needing fresh translation.
* `StrandTests/BrandLiteralRatchetTests` — turns the baseline into a **ratchet**: the count can only go
  down, and a second test stops the orphaned translations being deleted before they are reused.
* I did **not** machine-substitute the brand into the translations. They inflect the device as a common
  noun with articles and cases — de "Weckzeit **des Bands**", fr "**du** bracelet", it "**della** fascia",
  ru genitive "**браслета**" — so a proper noun cannot be dropped in without producing "de la Noop Band".
  That is a translator's call.
* **Structural fix to do once:** stop baking the brand into translatable sentences. Both pieces already
  exist (`WhoopModel.customerName`, the `Platform.deviceNounPhrase` pattern). Convert to
  `String(format: String(localized: "Connect %@ …"), WhoopModel.customerName)` and renames become free
  forever.

### Two in-flight breakages from the parallel session
* An **em dash** in the Russian `appwide.rhythm.methodology` string, which `UserVisiblePunctuationPolicyTests`
  forbids. Fixed at the JSON source, regenerated.
* `appwide` string count pin stale at 100 → **122**.

---

## 2. Pending — ranked as I would run it

### P0 — blocks any commercial release
1. **Clean-room `WhoopProtocol` + `WhoopStore`** (15,980 lines of source). Protocol facts — UUIDs, frame
   layouts, CRC parameters, byte offsets — are free to reuse; only expression must be new. Precedent
   already in this repo: Oura is clean-room, Xiaomi re-derived, WHOOP 5.0 facts-only.
2. **Contributor relicensing** — the app is multi-author under PolyForm Noncommercial with no CLA
   (`ryanbr`/`Fanboynz` 469 commits, `digitalerdude` 47, `Kaveman` 24, `tanarchytan` 18, `Pipiche` 15, …).
   Written consent, or ship the commercial product from a **new repository** built on the clean-room code.
   The new-repo route is cleaner by construction: git history keeps third-party authorship no matter what
   the tip says.
3. **Pick the posture and make the docs agree.** `TERMS` no longer says "non-commercial"; `LICENSE` and
   `README.md:668` still do. One of them is wrong today.

### P1 — blocks a *trustworthy* release, and this is the moat
4. **Publish the accuracy validation.** The product's whole claim is "we never fabricate a number." That is
   worth far more with a preregistered protocol, held-out participants/devices, and published error and
   failure rates for Charge/Effort/Rest and sleep staging. WHOOP and Oura get believed because they
   published; a glass-box competitor that doesn't is asking for the same trust with less evidence.
5. **Finish the localization work** in §1 (22 pairs are near-free) and re-tighten the ratchet.
6. **Physical-device evidence.** Simulator does not exercise CoreBluetooth, HealthKit entitlements,
   background collection, or Watch connectivity. Overnight runs on real hardware across reboot, process
   death, DST, and airplane mode. Battery drain per 24 h is a headline number people compare.

### P2 — needed for the band, not the app
7. **Firmware contract for `FallResponse`.** Correctly inert today ("Not active", no production code builds
   a candidate). Do not light it up without a validated detector, a cancellation window, hard-negative
   studies, and the regulatory analysis the readiness doc already names.
8. **Support and diagnostics loop.** Local-first with no telemetry means you learn about breakage only when
   a user tells you. The log export exists; make the path from "it's wrong" to a reproducible bundle
   one tap, or you will be debugging blind at scale.
9. **Data durability.** Local-first means device loss equals data loss. Backup/restore is "verified for
   implemented scope" and explicitly *not* a complete server-to-device restore of every table. For a
   product holding years of someone's health history, complete restore is table stakes.

### P3 — deliberately not doing
10. Automatic fall/anomaly/medical SOS; ECG/AFib; blood pressure; apnea; epigenetic "biological age".
    VO₂max-based **Fitness Age** (Nes/HUNT) and **Wellness Age** already ship and are honest.

---

## 3. The one thing I would change about how this is being built

Two agents are writing this working tree at the same time. It has produced, measurably: phantom test
failures from reading half-written files, a constant changing mid-review, and now an em-dash policy break
and a stale count pin arriving between my own runs. Every "green" has a shelf life of minutes.

Give each session its own clone or `git worktree` and integrate through git. It costs nothing and it is the
difference between a verified build and a hopeful one.
