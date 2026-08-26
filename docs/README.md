# NOOP documentation

Organised by the question you are trying to answer. This index is deliberately short: it names entry
points rather than listing every file, because an exhaustive list goes stale the day it is written.

## Start here

| If you want to | Read |
|---|---|
| Understand the system | [`ARCHITECTURE.md`](ARCHITECTURE.md), [`DATA_MODEL.md`](DATA_MODEL.md) |
| Build and run it | [`BUILD.md`](BUILD.md), [`ANDROID.md`](ANDROID.md), [`CROSS_PLATFORM.md`](CROSS_PLATFORM.md) |
| Know what ships | [`FEATURES.md`](FEATURES.md), [`FEATURE_PARITY.md`](FEATURE_PARITY.md) |
| Know why a number is what it is | [`ANALYTICS.md`](ANALYTICS.md), [`validation/`](validation/) |
| Know whether we can release | [`handoff/RELEASE-BLOCKERS.md`](handoff/RELEASE-BLOCKERS.md) |

## Can we ship? Read in this order

1. [`handoff/RELEASE-BLOCKERS.md`](handoff/RELEASE-BLOCKERS.md) — the P0 launch gates.
2. [`handoff/INDIA-FIRST-LAUNCH-PATH.md`](handoff/INDIA-FIRST-LAUNCH-PATH.md) — India-then-USA
   sequencing. DPDP, TRAI DLT for SMS, BIS and WPC/ETA for the band, and the case for a local-only v1.
3. [`handoff/HARDWARE-AND-PREMIUM-STRATEGY.md`](handoff/HARDWARE-AND-PREMIUM-STRATEGY.md) — what paid
   hardware plus a paid tier actually requires, and where the free/premium line must sit.
4. [`handoff/PRODUCTIONISING-ALERTS-AND-COMPETITIVE-GAP.md`](handoff/PRODUCTIONISING-ALERTS-AND-COMPETITIVE-GAP.md)
   — the alerting and notification production plan.

## Are the metrics right?

[`validation/`](validation/) holds the evidence, not the claims. Every verdict there is reproducible from
scripts in `Tools/validation/`.

| Document | What it establishes |
|---|---|
| [`validation/MULTI-DATASET-VERDICTS.md`](validation/MULTI-DATASET-VERDICTS.md) | Sleep staging vs PSG, sleep detection on sparse data, and why each verdict holds |
| [`validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md`](validation/THREE-WEARER-VERDICT-AND-AGENT-REVIEW.md) | Recovery vs WHOOP across three real wearers, and the between-person compression finding |
| [`validation/DEPLOYABILITY-AND-METRIC-AUDIT.md`](validation/DEPLOYABILITY-AND-METRIC-AUDIT.md) | HRV against Task Force 1996, training load against the ACWR literature, notification integrity |
| [`validation/COMPETITIVE-METRIC-GAPS.md`](validation/COMPETITIVE-METRIC-GAPS.md) | Competitive metric gap analysis across the wearable field |
| [`validation/RHYTHM-REAL-DATA-FINDINGS.md`](validation/RHYTHM-REAL-DATA-FINDINGS.md) | Rhythm screener against real MIT-BIH AF and NSR recordings |
| [`validation/SLEEP-PSG-HARNESS.md`](validation/SLEEP-PSG-HARNESS.md) | How to reproduce the PSG comparison |

Two conventions worth knowing before reading any of these: a missing input renders as an em-dash and
**never** as zero, and the engines are kept byte-identical between Swift and Kotlin.


## Protocol and devices

- [`BLE_REVERSE_ENGINEERING.md`](BLE_REVERSE_ENGINEERING.md) — protocol facts and how they were obtained
- [`DEVICE_DRIVER_ARCHITECTURE.md`](DEVICE_DRIVER_ARCHITECTURE.md), [`DEVICE_SUPPORT_ROADMAP.md`](DEVICE_SUPPORT_ROADMAP.md)
- [`OURA_PROTOCOL.md`](OURA_PROTOCOL.md) — documented facts only

## Operations and release

- [`ops/`](ops/) — runbooks and current operational state; [`ops/ACTIVE.md`](ops/ACTIVE.md) is the live entry point
- [`releases/`](releases/) — per-version release notes
- [`APP_STORE_RELEASE.md`](APP_STORE_RELEASE.md), [`BETA_TESTING.md`](BETA_TESTING.md)
- [`localization/`](localization/) — **never pretty-print `Localizable.xcstrings`**; the generators in
  `Tools/*Localization/` parse it line-by-line and reformatting corrupts the file

## Archive

[`handoff/archive/`](handoff/archive/) holds superseded round-by-round review logs. They record how a
decision was reached and are kept for that reason, but they are **history, not current reference**. If an
archived document disagrees with a document above, the one above wins.
