# Reconstructed NOOP Work History

This is a high-level reconstruction from Git commits, release notes, checked-in
design documents, and audits. It is **not** a complete transcript and must not
be used as proof that an unrecorded physical-device or clinical validation run
occurred.

## Before the private integration line

Git history begins with the Goose Swift MVP (`59353e06`), the server line
(`5975fc3e`), and the offline NOOP companion identity (`ecaabdc0`). Iterative
foundation releases through June added wearable UX, metrics/IMU work, sync and
sleep correctness, BLE/protocol reliability, architecture, and release tooling.

From early July through NOOP 9.1.1, the inherited upstream product line added
substantial metric, sleep, history/offload, Oura, packaging, localization, and
platform hardening. This is inherited project lineage and must not be presented
as entirely original fork work. The current repository contains the resulting
broad local-first platform: direct wearable interoperability, local SQLite
storage, transparent analytics, imports, Apple/Android surfaces, Oura research,
and extensive protocol, architecture, safety, and parity documentation.

## 2026-07-24 — iOS distribution and self-hosted foundation

Commit `7638fbaf` and adjacent release records show the fork's self-hosted
FastAPI/TimescaleDB platform, native sync, provenance, official-reference
comparison, and held-out personal calibration, alongside NOOP 9.1.1, iOS Dynamic
Island packaging, compact metric layouts, Android sleep-stage export, and an
AltStore source. The AltStore source did not remove Apple's signing and refresh
constraints.

## 2026-07-26 — parallel comparison workflow

Commit `ac6aab61` added public-beta comparison reporting so imported official
WHOOP reference values could be evaluated beside independent NOOP values. The
two sources remain separate; comparison does not establish proprietary formula
parity.

## 2026-08-11 — local-first beta integration

The integration line combined the iOS experience, BLE/history hardening,
activity tracking safety, Oura durability, widgets, background/foreground
catch-up, visual-system work, Friends, hydration, energy breakdown, and release
integrity. Representative commits include `67a15729`, `89ed6cd9`, `4f0e912a`,
`6142eb47`, `8b4be10e`, `81171bf6`, `0824ec40`, and `bf423768`.

This reconstruction records source integration, not a claim that every firmware,
phone, overnight, or background matrix was physically validated.

## 2026-08-12 to 2026-08-13 — NOOP 9.2 evidence-first update

Commits `f88b5422`, `f1e3fc67`, `9cac56f8`, and `d2b201c5` delivered the 9.2
Today-first reading flow, source-aware metrics, conservative workout/stress
automation, sleep-confidence provenance, readiness wording, widget/Live
Activity freshness, navigation/onboarding/device polish, localization, and
upgrade invalidation for retired derived values. See
[`../releases/v9.2.0.md`](../releases/v9.2.0.md).

## 2026-08-21 — metric truth and Live Activity integration

Commit `241f2000` preserved measured-versus-estimated step precedence, source-
pinned metric details, truthful metric empty states, and deterministic stale or
duplicate Live Activity reconciliation. Focused automated and simulator checks
passed. The commit did not modify BLE backfill/storage hot paths and therefore
does not close the later user report of Day-4 calibration stalling at 3/4 or of
physical-phone scroll lag.

## Ledger transition

Contemporaneous round records begin on 2026-08-21. Future work must update the
round ledger rather than relying on chat history or commit subjects alone.
