# NOOP physical-band test start checklist — 2026-10-01

**Connected-session update:** the owner-supplied SDKs are integrated and enabled
builds pass on both platforms. Android’s same-signature SDK update and a fresh
signed install on the 13 Pro Max are complete. Both screens are currently locked;
owner first-run setup, approved account/provider configuration and exact band
qualification remain. The earlier preparation findings below are historical;
use the [SDK intake](NOOP-SUPPLIER-SDK-INTAKE-2026-10-01.md) and
[connected round](../ops/rounds/2026-10-01-connected-band-test-attempt.md)
for the current artifact and device state. No physical band pass yet.


Preparation is verified; installation and live band scenarios are **not run**.
Use this alongside the [detailed review](NOOP-PHYSICAL-BAND-TEST-REVIEW-2026-10-01.md)
and [physical validation runbook](NOOP-BAND-PHYSICAL-VALIDATION-HANDOFF.md).

## Prepared on this Mac

- Review branch: `codex/physical-band-review-20261001`, draft [PR 28](https://github.com/Dhanunjay-Divi/Noop/pull/28).
- Retained build source: `0f762f348f4386daca70aaaa71439b5c7e558e14`; implementation fix: `2e676e75dda24c203c12d755fe0530b92ca56f3b`.
- Last remote check: main `08ad0f472a577e66fd612281550f549fa09c7703`; PR 28 open, unmerged, based on the pending Today candidate rather than main.
- Android Full Debug APK: `android/app/build/outputs/apk/full/debug/app-full-debug.apk`, version `9.2.1-debug / 304`. Retained file hash and APK signature verification pass.
- APK SHA-256: `77c4513713f95166e4502ff273f1d9b780ccccec4f4091baf15ca04bd5832fb6`.
- Unsigned iPhoneOS Debug app/Watch/widget graph passes. This is not an installable signed iPhone candidate.
- Supplier source tests: 70/70. SDK boundary tests: 7/7. Neutral SDK ten-file verifier passes at revision `b02808372b7c537f22058c7ebc75d92c750373be`.
- Both requested iPhones report Developer Mode enabled. Latest discovery reports the 13 Pro Max disconnected and the 17 Pro Max transport unavailable; recheck with cables and unlocked screens.
- No Android phone detected. Existing phone data and apps have not been changed.

## Required before installation and collection

| Gate | Current evidence | Needed next |
|---|---|---|
| iPhone signing | Signed build fails with capability/profile mismatch | Authorized development profiles covering App Groups, HealthKit, push, App Attest and the app/extension bundle family |
| Account and ownership | Approved local managed-account configuration absent in review, original and integration checkouts | Working approved provider configuration and account/ownership setup; keep secrets in ignored local files |
| Supplier transport | Neutral SDK verified; approved transport frameworks/AARs and local supplier configuration absent | Exact approved supplier drop for each platform, verified with the protected artifact manifests |
| Hardware qualification | Runtime compatibility manifest has zero approved band rows | Exact band model/firmware identification and reviewed approval; a shared sensor list does not establish compatibility |
| Data preservation | 13 Pro Max inventory previously contained no NOOP; 17 Pro Max was locked | Refresh unlocked app inventory; confirm bundle/signature and a recovery path before any existing-app update |
| Android install | Debug APK is signed, but phone unavailable | Detect actual phone, check OS/ABI, existing app identity/signature and recovery before in-place installation |

The current default-off APK cannot validate supplier transport. Current required
account onboarding also fails closed without provider configuration. Enabling
approved supplier/account inputs changes the build: rebuild, record the exact
source/configuration and hash, and verify that new artifact before installation.
A debug signature does not establish compatibility with an existing app signature.

## When the owner returns

1. Connect and unlock both iPhones. Connect Android with a data-capable USB cable.
   On Android, enable Developer options (normally Settings → About phone → Build
   number, tap seven times), enable USB debugging, and accept this Mac's prompt.
   Some brands place Build number under Software information; discover the model
   from the cable before giving model-specific directions. iPhone Developer Mode
   is already enabled; no repeat toggle or security reset is needed.
2. Charge both bands and phones. Identify which phone gets WHOOP and which gets
   the supplier band; record generalized model and firmware versions. Stop other
   collecting apps for each band during the comparison. Use one collector per
   band; do not force two collectors onto one account. Confirm approved separate
   comparison accounts or the configured collector/viewer ownership policy.
3. Recheck remote source and PR status. Keep this reviewed candidate pinned for
   its comparison; if the primary agent integrates a newer candidate, use a clean
   isolated checkout and rebuild/test that exact source. Do not silently swap a
   retained APK for a different source or enable a stale supplier package.
4. Resolve the gates above, then build exact signed/configured artifacts through
   `Tools/run-bounded-command.py` with private round-owned logs/status files.
   Verify identities and recovery, then update in place where compatible. No
   uninstall, reset, entitlement removal, fabricated account or firmware flash.
5. Complete the ordinary first-run band/account/ownership/profile journey. Run
   WHOOP first, then the approved supplier path, keeping source labels distinct.
6. Run the matrix below on each applicable platform/source. Export bounded
   in-app diagnostics after a failure; retain any private evidence locally.
   Public review evidence contains categorical results and aggregate counts,
   without device identifiers, credentials or raw health values.
7. Compare metric availability, provenance, freshness and calibration. Shared
   formulas require qualified inputs: missing R-R/HRV, respiration, oxygen,
   temperature or REM cannot be manufactured from HR or a similar sensor list.
   Overnight/history-derived metrics need sufficient observations; a same-day
   session cannot validate mature Recovery or Fitness Age calibration.

## Session evidence sheet

Fill one column per actual platform/source pairing. A device merely connected
by cable is not evidence that its band scenario passed. Use PASS / FAIL / BLOCKED
/ NOT SUPPORTED with a short categorical reason, observed behavior and next fix.

| Scenario | iPhone WHOOP | iPhone supplier | Android WHOOP | Android supplier |
|---|---|---|---|---|
| Installed exact candidate; version, source and hash recorded | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| First-run account, ownership and profile | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Discovery, connection and battery | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Live HR received, persisted and shown with correct source | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Disconnect/reconnect without duplicates or stale state | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Band-only/offline interval, supported history catch-up | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Lock/background, return and collection recovery | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Native steps and sleep inputs where supported | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Derived metrics: valid inputs vs missing/calibrating | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Notification permission and delivery where configured | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Diagnostics export; VoiceOver/TalkBack traversal | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Controlled source switch, provenance isolation and retained history | NOT RUN | NOT RUN | NOT RUN | NOT RUN |
| Overnight session and longer calibration follow-up | NOT RUN | NOT RUN | NOT RUN | NOT RUN |

For each failure record the source/build, generalized device/OS/band/firmware,
scenario steps, expected/actual behavior, bounded diagnostic category, preserved
data status and whether the failure reproduces. Keep private evidence outside
Git. Android supplier currently exposes HR/battery; reviewed step/sleep command
paths are absent, so do not mark those cases passed based on Apple results.
