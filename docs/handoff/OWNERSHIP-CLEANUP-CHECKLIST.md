# Ownership cleanup — the checklist I will execute once the code is yours

**Purpose:** the owner is having the inherited code rewritten. When that lands, attribution for code that
no longer exists is stale text and removing it is correct. This file is the gate that makes each removal
**provable** rather than taken on faith.

**Rule I hold myself to:** a reference comes out only when I can demonstrate the code it covers is gone or
replaced. Removing a notice while the code still ships is what creates exposure, so each item below has a
verification command that must pass first.

---

## 0. Corrected scope (earlier estimate was wrong)

I previously said ~209,000 lines were vendored from the unlicensed source. **That was wrong** — the count
included `.build/checkouts/` (GRDB and other SwiftPM dependencies), which are not inherited code. Actual:

| Target | Files | Lines | Notes |
|---|---|---|---|
| `Packages/WhoopProtocol/Sources` | 30 | **6,425** | the real reimplementation target |
| `Packages/WhoopProtocol/Tests` | 50 | 6,410 | rewrite alongside |
| `Packages/WhoopStore/Sources` | 38 | **9,555** | the real reimplementation target |
| `Packages/WhoopStore/Tests` | 53 | 7,461 | rewrite alongside |
| **Source subtotal** | **68** | **15,980** | what must actually be written fresh |
| `Strand/BLE` | 24 | 12,154 | ATTRIBUTION says "adapted from"; needs per-file assessment |
| `Strand/Collect` | 8 | 1,510 | same |
| Repo total (excl. build dirs) | — | 461,598 | for proportion |

So the clean-room target is **~16k lines of source**, not 200k+. That is a real project but a finite one.

**What is already free and reusable:** every BLE UUID, frame layout, CRC parameter, command/event number and
byte offset. `LICENSE` states it, and it is correct in law — those are facts about bytes on a wire, not
copyrightable expression. The rewrite must produce new *expression* of the same *facts*.

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

1. **Written relicensing consent** from each contributor above (a short e-mail granting permission to
   relicense their contributions is enough; keep the replies).
2. **Rewrite their contributions too** — much larger than 16k lines; likely not worth it.
3. **Stay noncommercial** for the forked app and ship the commercial product as the *new* codebase (below).

---

## 3. Strong recommendation — build the clean product as a NEW repository

If the goal is "the repository should be clean of all," a fresh repository achieves it **by construction**,
and scrubbing this one does not. Reason: even with every inherited file replaced, this repo's **git history
still contains other people's commits and their authorship**. Deleting notices from the tip does not change
that, and rewriting published history would destroy the audit trail that currently protects you.

So:

- **`Whoop-Noop` (this repo)** stays as-is: honest lineage, PolyForm Noncommercial, the historical record.
- **New repo (e.g. `noop-band`)** starts from the clean-room packages plus originally-authored app code,
  with your own licence from commit one. Nothing to scrub, nothing inherited, no contributor-consent
  problem, and the provenance question never arises at App Store review.

That is also the cheaper path: you are already writing new hardware-first code for NOOP Band.

---

## 4. Execution order (what I will do, in this order)

1. **Wait** for the other agent's clean-room packages to land.
2. **Verify 1.1**: obtain the original `my-whoop` sources, diff structure/naming/expression against the new
   ones, confirm only facts survive. Record the comparison.
3. **Verify 1.2**: per-file pass over `Strand/BLE` + `Strand/Collect`.
4. **Run every gate**: iOS + macOS builds, macOS app suite, `StrandAnalytics`, Android
   `:app:testFullDebugUnitTest`, `Tools/release-legal-gate.py check`.
5. **Then edit the text** — remove 1.1/1.2 from `ATTRIBUTION.md`, `NOTICE`, `DISCLAIMER.md`; keep 1.7
   intact; leave 1.3 alone until §2 is decided.
6. **Add a gate** so this cannot silently drift: a test asserting TERMS ↔ LICENSE ↔ README agree on the
   commercial posture (`Tools/release-legal-gate.py` currently checks only the dependency inventory).
7. **Re-run all gates** and commit with the verification evidence in the message.

---

## 5. What I need from you at step 5

One line confirming the posture, because the docs must state something true:

- **Noncommercial** → I revert the TERMS/DISCLAIMER drift and fix `TERMS.md:156`; shippable free today.
- **Commercial** → I need §2 resolved (consent, or the new-repo route) before the docs can claim it.

Until then the tree stays internally inconsistent on exactly one axis: TERMS no longer says
"non-commercial", while `LICENSE` and `README.md:668` still do. It is recorded in
`docs/handoff/RELEASE-BLOCKERS.md` §1 and is not a code defect.
