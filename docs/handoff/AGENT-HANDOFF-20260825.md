# Agent handoff - 2026-08-25

## Authority

- Canonical repository: `https://github.com/Dhanunjay-Divi/Noop`
- Work directly from `main`; do not create a replacement lineage.
- Preserve NOOP's PolyForm Noncommercial License 1.0.0, Required Notice, and
  exact independent dependency notices.
- The repository owner has recorded control of the consolidated NOOP source and
  contribution rights in
  [`../provenance/OWNER-RIGHTS-DECLARATION.md`](../provenance/OWNER-RIGHTS-DECLARATION.md).

## Product constraints

- Local-first and account-free by default.
- No telemetry or NOOP-operated biometric cloud by default.
- Missing or stale health input stays missing; never fabricate a wellness
  score, alert, or completed sync.
- Medical/anomaly/Rhythm paging remains unavailable.
- Automatic fall paging remains hard-disabled until the external detector,
  firmware, staged-event, human-factors, carrier, and regulatory gates pass.
- Manual app SOS and repeated band SOS use acknowledged, bounded paging and
  latest-only live location under the selected 8- or 12-hour window.

## Current implementation round

Round 21 changes analytics, import/storage integrity, Apple and Android
presentation, migration 34, localization, validation tooling, and compact-device
UI tests. Its detailed decisions and prior evidence are in
[`ROUND-21-validation-calibration-import-integrity.md`](ROUND-21-validation-calibration-import-integrity.md).

This continuation also:

- clears the owner-controlled source-rights state without changing NOOP's
  public license;
- removes obsolete repository identifiers and upstream-monitor automation;
- retains generated third-party dependency notices;
- restores and tests the pink/white liquid pull-to-sync feedback; and
- closes with complete verification, a direct `main` commit, push, and clean
  local/remote equality check.

## Required closeout

1. Run every relevant Swift package suite.
2. Run the complete macOS app suite and generic iOS Simulator build.
3. Run production-shell UI tests on compact and larger iPhone classes, including
   pull-to-sync and navigation endpoint screenshots.
4. Run Android Full Debug unit, APK, lint, and instrumentation compilation;
   run managed-device migration/import tests when the emulator is available.
5. Run server tests, strict localization, health claims, private-data, legal
   check/distribution, ops, and whitespace gates.
6. Update this handoff and the matching ops round with exact final evidence.
7. Commit all intentional changes to `main`, push, and verify a clean
   `HEAD == origin/main`.

## External gates

Signing, store records, production infrastructure, controlled carrier delivery,
representative physical-device validation, held-out accuracy studies,
native-speaker review, and any applicable regulatory program remain external
release work. See [`RELEASE-BLOCKERS.md`](RELEASE-BLOCKERS.md).
