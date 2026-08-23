# Ownership cleanup checklist

**Current decision (2026-08-23):** the owner selected a commercially independent
NOOP repository. The local remote now targets `Dhanunjay-Divi/Noop` rather than
the prior repository, but this checkout still has the inherited source and
multi-author history. It is therefore the reference codebase, not a clean
commercial implementation. Authenticated GitHub inspection verified the
canonical repository is standalone (`isFork=false`, no parent, zero child
forks).

**Purpose:** the owner is having the inherited code rewritten. When that lands, attribution for code that
no longer exists is stale text and removing it is correct. This file is the gate that makes each removal
**provable** rather than taken on faith.

**Rule I hold myself to:** a reference comes out only when I can demonstrate the code it covers is gone or
replaced. Removing a notice while the code still ships is what creates exposure, so each item below has a
verification command that must pass first.

---

## 0. Corrected cross-platform scope

I previously said ~209,000 lines were vendored from the unlicensed source. **That was wrong** — the count
included `.build/checkouts/` (GRDB and other SwiftPM dependencies), which are not inherited code. A later
`15,980`-line estimate was also incomplete because it described only the known Apple package core and
omitted the Android and Apple transport/collection assessment surfaces.

| Target | Source files | Source lines | Status |
|---|---|---|---|
| `Packages/WhoopProtocol/Sources` | 30 Swift | **6,425** | known replacement core |
| `Packages/WhoopStore/Sources` | 38 Swift | **9,555** | known replacement core |
| `Strand/BLE` | 24 Swift | 12,154 | per-file classification/replacement |
| `Strand/Collect` | 8 Swift | 1,510 | per-file classification/replacement |
| `android/.../protocol` | 22 Kotlin | 4,369 | per-file classification/replacement |
| `android/.../ble` | 32 Kotlin | 15,155 | per-file classification; also contains separately developed device paths |
| **Review ceiling** | **154** | **49,168** | not every classified file will necessarily require replacement |

The **15,980-line Apple package core is the known minimum**, not the complete
clean-room target. Tests and fixtures must be independently regenerated or
licensed alongside production code; they are not included in the table's source
line totals.

BLE UUIDs, frame layouts, CRC parameters, command/event numbers, and byte
offsets are observable wire facts that can be documented independently. That
does not permit copying source expression or a protectable selection or
arrangement. The replacement must express independently collected facts in new
code, and the final rights review should be performed by qualified counsel.

**Precedent in this repo:** `ATTRIBUTION.md` already records Oura as "original clean-room work",
`XiaomiBandImporter` as "re-derived … no code is copied", and WHOOP 5.0 as facts-only. The method is proven
here; this applies it to the WHOOP 4.0 layer.

---

## 1. Removal gate — per claim

Each row: remove the reference **only** when its verification passes.

| # | Reference | Lives in | Verification before removal |
|---|---|---|---|
| 1.1 | `johnmiddleton12/my-whoop` — `WhoopProtocol`/`WhoopStore` packages | `ATTRIBUTION.md` §"WHOOP 4.0 protocol + Swift packages", `NOTICE`, `DISCLAIMER.md` | New sources in place; **no file under `Packages/WhoopProtocol/Sources` or `Packages/WhoopStore/Sources` shares non-trivial expression with the original**. Diff against the original checkout, not from memory. All tests green. |
| 1.2 | same — "iOS collection logic that `WhoopBLE`/`Collect` are adapted from" | `ATTRIBUTION.md` | Per-file assessment of `Strand/BLE` (24 files) and `Strand/Collect` (8 files): each either rewritten, or shown to contain only protocol facts + original expression. |
| 1.3 | `ryanbr/noop` fork lineage | `ATTRIBUTION.md` §"Project lineage", `LICENSE`, `NOTICE`, `README.md` | **See §2 — this one is not solved by rewriting the packages.** |
| 1.4 | `tigercraft4/goose` | `ATTRIBUTION.md` | Already "no source copied". Safe to drop once §2 resolves, since it only documents inspiration. |
| 1.5 | `b-nnett/goose` (WHOOP 5.0 facts) | `ATTRIBUTION.md` | Facts-only already. Keep or drop at will — **recommend keeping** as a research citation; it is not a licence obligation and it makes the provenance story stronger, not weaker. |
| 1.6 | `artyomxx/xiaomi-band-ios-export`, Gadgetbridge, `open_ring`/`open_oura`/`ringverse`/`relue` | `ATTRIBUTION.md` | Already clean-room / facts-only. Same recommendation as 1.5. |
| 1.7 | Third-party dependency notices (152 runtime components) | `ThirdPartyNotices/`, `NOTICE`, `docs/THIRD_PARTY_NOTICES.md`, `server/NOTICE` | **Never removable.** MIT/BSD/Apache all require notice retention; Apache-2.0 §4 is explicit. Every commercial app ships these. Keeping them is normal and costs you nothing. |

---

## 2. The part a rewrite does not fix

Rewriting the two packages clears **1.1** and **1.2**. It does not clear **1.3**, and this is the one to be
clear-eyed about.

This repository's own history shows the app itself is multi-author:

```
886  NoopApp <thenoopapp@gmail.com>
469  ryanbr / Fanboynz <mp3geek@gmail.com>, <ryan.borsix@gmail.com>
 47  digitalerdude <schaedlich.max@gmail.com>
 27  Uno <kooldhanunjay@gmail.com>
 24  Kaveman            18  tanarchytan          17  Dhanunjay Divi
 15  Pipiche            + others
```

Those contributions were made under **PolyForm Noncommercial**, and `docs/CONTRIBUTING.md` accepts
contributions "for non-commercial use … under those terms" — i.e. **no CLA assigns copyright to the
project**. So the app code outside the two packages is not fully yours to relicense either.

Three honest ways to close it:

1. **Written relicensing consent** from each contributor above in a form and
   scope reviewed by qualified counsel; keep the grants outside the public
   repository when they contain personal information.
2. **Rewrite their contributions too** — much larger than 16k lines; likely not worth it.
3. **Stay noncommercial** for the forked app and ship the commercial product as the *new* codebase (below).

---

## 3. Strong recommendation — build the clean product as a NEW repository

If the goal is "the repository should be clean of all," a fresh repository achieves it **by construction**,
and scrubbing this one does not. Reason: even with every inherited file replaced, this repo's **git history
still contains other people's commits and their authorship**. Deleting notices from the tip does not change
that, and rewriting published history would destroy the audit trail that currently protects you.

So:

- **This reference checkout** stays as-is: honest lineage, PolyForm
  Noncommercial, and the historical record.
- **New repo (e.g. `noop-band`)** starts from the clean-room packages plus originally-authored app code,
  with your own licence from commit one. Nothing to scrub, nothing inherited, no contributor-consent
  problem, and the provenance question never arises at App Store review.

That is also the cheaper path: you are already writing new hardware-first code for NOOP Band.

---

## 4. Execution order

1. Create a separate empty repository/history for the independent
   implementation; do not push this repository's `main` into it.
2. Give a behavior-only specification to an implementer who has not inspected
   the restricted implementation.
3. **Verify 1.1**: obtain the original `my-whoop` sources, diff structure/naming/expression against the new
   ones, confirm only facts survive. Record the comparison.
4. **Verify 1.2**: per-file pass over `Strand/BLE` + `Strand/Collect`.
5. **Run every gate**: iOS + macOS builds, macOS app suite, `StrandAnalytics`, Android
   `:app:testFullDebugUnitTest`, `Tools/release-legal-gate.py check`.
6. **Then edit the text** — remove 1.1/1.2 from `ATTRIBUTION.md`, `NOTICE`, `DISCLAIMER.md`; keep 1.7
   intact; leave 1.3 alone until §2 is decided.
7. Update `docs/provenance/rights-status.json` with the reviewed evidence. The
   release gate now rejects missing blockers and removed provenance markers.
8. **Re-run all gates** and commit with the verification evidence in the message.

---

## 5. Current blocker

The commercial posture is selected, but §2 is not resolved. The independent
repository must begin with independently authored or separately licensed code;
copying this tree and deleting its references does not satisfy that requirement.
The machine-readable state is
`docs/provenance/rights-status.json`.
