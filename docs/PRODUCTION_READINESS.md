# NOOP production readiness

Last reviewed: **2026-08-22**

This is the release decision record for NOOP. A compiled screen or passing unit
test proves code behavior only. It does not prove carrier delivery, wearable
firmware compatibility, algorithm accuracy, clinical safety, store acceptance,
or a person's response to a page.

## Status vocabulary

| Status | Meaning |
|---|---|
| **Locally verified** | The implementation passed the repository's local build or automated test gate on the review date. |
| **Implemented, evidence pending** | The product path exists, but release evidence requires a real provider, device, participant cohort, or signed distribution build. |
| **External launch gate** | Code cannot close this item without controlled credentials, hardware, accounts, people, or regulatory/safety work. |
| **Intentionally unavailable** | Shipping the behavior would overstate the available evidence. |

## Code-side readiness

| Area | Status | Current evidence and boundary |
|---|---|---|
| macOS app | **Locally verified** | The 1,272-test app suite passes and an unsigned Release build produces a universal `x86_64` + `arm64` app. A distributable Developer ID build and notarization remain external. |
| iPhone, Watch, widgets | **Locally verified** | Phone UI tests pass in Simulator and an unsigned generic Release simulator build validates the embedded Watch app and widgets; the phone visual matrix captured 32/32 primary routes on iPhone 17 Pro Max and iPhone 17e; and Watch visual captures cover glance, home, and strength handoff. Simulator execution does not validate CoreBluetooth, HealthKit entitlements, background collection, or Watch connectivity. |
| Android app | **Locally verified** | `assembleFullDebug`, all JVM tests, Android-test source compilation, `lintFullDebug`, and the API 35 Gradle-managed-device instrumentation suite pass. Physical-device/OEM behavior remains an external gate. |
| Self-hosted server | **Locally verified** | The full Pytest suite and Ruff check/format gates pass. PostgreSQL integration and real-provider tests remain separately gated by environment variables. |
| Private Friends | **Locally verified on Apple and Android** | Invitation-only enrollment, accepted requests, directional six-field privacy, summary-only replacement upload, removal, deletion, and localized Android UI are implemented. Android uses an encrypted member credential, retry-stable enrollment and upload identities, best-effort WorkManager refresh, and server-confirmed cleanup for an interrupted first join. There is no public directory, ranking, or end-to-end encryption. |
| Safety contact enrollment | **Locally verified** | Two accepted contacts are required, five is the maximum, invitations are one-time, and clients keep reminding until the accepted minimum is met. |
| Acknowledged Safety paging | **Locally verified in automation** | Durable incidents, idempotency, leases, bounded retries, attempt history, provider receipts, SMS-first delivery, voice fallback, signed responder links, DTMF, acknowledgement, cancellation, resolution, expiry, and privacy-safe monitoring are covered. This is contact paging, not emergency dispatch. |
| Strength Trainer | **Locally verified** | Apple and Android provide manual routines/sessions/sets, per-exercise history and PRs, weekly goals, muscle exposure, import/export, and portable restore. Watch can request a routine start on the paired iPhone. Rep sensing and muscular-load claims remain unavailable pending studies. |
| Sleep planning | **Locally verified** | Target, Balance, and Extra Opportunity modes, debt bounds, behavioral timing context, per-day wake overrides, reminders, and alarm boundaries exist on Apple and Android. Comparative accuracy and physical travel/DST behavior remain evidence gates. |
| Coach | **Locally verified** | Local durable transcript and editable memory, opt-in scheduled check-ins, voice/text Journal drafts, and confirmed Journal/routine actions exist. Model output cannot silently mutate records. |
| Nutrition | **Locally verified** | Editable meals, nullable nutrients, CSV reconciliation, barcode scan/manual lookup, Open Food Facts, saved foods/meals, and portable restore exist on Apple and Android. Product values require review before save. |
| Backup and restore | **Locally verified for implemented scope** | Same-platform native backups use integrity manifests and staged restore. The cross-platform portable payload validates and restores nutrition/library and normalized strength records. It is not a complete server-to-device restore of every local table. |
| UI shell | **Locally verified by build, contract, UI, and visual tests** | The app-wide visual system, glass navigation, floating add action, loading/empty/error states, and primary routes compile on Apple and Android. iOS UI tests and the 32-route/two-viewport screenshot matrix pass. Final accessibility acceptance and physical-device visual review remain release evidence gates. |

## Launch gates requiring external evidence

| Gate | Required evidence before the related claim ships |
|---|---|
| Twilio/carrier paging | Controlled-number staging in every launch country/carrier; invitation, SMS, voice, DTMF, callback, retry, worker/API restart, cancellation, and alert evidence with timestamps and provider references. |
| WHOOP 5/MG and other wearables | Model/firmware/OS matrix covering pair/re-pair, live data, overnight history, backlog, reconnect, background/termination, clock/DST, haptics, battery, duplicates, loss, and source attribution. |
| HealthKit, Watch, Health Connect, Android OEMs | Signed physical-device runs with real permissions, entitlement checks, process death/reboot, delayed delivery, upgrade preservation, and representative OEM battery policies. |
| Workout detection | Participant- and device-held-out precision/recall, confusion matrix, false prompts per day, latency, and calibrated confidence. Until then detection remains **Ask**, never unattended save. |
| Sleep, temperature, Charge/Effort/Rest accuracy | Preregistered reference protocol, frozen revisions, participant/device-held-out evaluation, missing-data rules, subgroup results, calibration, error, and failure rates. |
| Apple distribution | Stable production identifiers, paid signing team, privacy labels, export/compliance answers, archive validation, TestFlight review, App Store metadata, and upgrade testing. |
| Google Play distribution | Production keystore custody, Play App Signing, AAB, target/API policy checks, Data safety form, content rating, store listing, closed-track testing, and upgrade/rollback evidence. |
| macOS distribution | Developer ID signing, Hardened Runtime review, notarization, stapling, Gatekeeper test, privacy disclosures, and upgrade validation. |
| Source redistribution rights | The fail-closed distribution gate identifies inherited WHOOP 4 protocol/store and collection expression from `johnmiddleton12/my-whoop` / `wearable`, whose pinned source has no explicit software license. No external binary or source release may ship until the rights holder grants an explicit license or the affected expression is independently replaced with an audited clean-room implementation. |
| Hosted vendor integrations | Approved OAuth applications, secret/token operations, webhook/backfill/deletion behavior, rate-limit handling, provider terms, and end-to-end tests for each of Strava, Garmin, Fitbit, or another service. |
| Broader social product | Teams, challenges, ranking rules, abuse/reporting controls, moderation operations, and product-scale load/authorization tests. Private Friends itself is available on Apple and Android; this gate applies only to a broader competitive/community product. |

## Safety release boundary

Automatic anomaly, fall, or medical SOS is **intentionally unavailable**.
Current wellness signals must not page contacts automatically. That program needs
a validated detector, an accessible cancellation window, hard-negative and
staged-event studies, dispatch reliability evidence, human-factors review,
clinical/safety governance, regional legal analysis, and any required regulatory
authorization.

The supported Safety action is explicit and user-confirmed. It pages accepted
trusted contacts and tells them to call the owner or local emergency services;
NOOP does not contact emergency services and cannot guarantee carrier delivery or
human response.

## Release rule

A release may describe only rows backed by completed evidence. An untested
device/provider/country stays experimental or disabled. Missing data remains
missing, imported/vendor outputs retain their provenance, and no wellness result
is promoted into a medical or emergency claim by UI copy.

Operational procedures for paging are in
[`../server/SAFETY.md`](../server/SAFETY.md). Capability details and accuracy
protocols are in
[`FEATURE_PARITY.md`](FEATURE_PARITY.md) and
[`COMPETITIVE_CAPABILITY_AUDIT.md`](COMPETITIVE_CAPABILITY_AUDIT.md).
