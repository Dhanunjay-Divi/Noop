# NOOP production readiness

Last reviewed: **2026-09-04**

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
| macOS app | **Locally verified** | The current app suite passes 1,428 tests with one intentional fixture skip, and the unsigned app builds. A distributable Developer ID build and notarization remain external. |
| iPhone, Watch, widgets | **Locally verified by build; current UI rerun host-blocked** | The unsigned generic simulator build validates the current app, embedded Watch app, and widgets. Earlier production-shell and visual suites passed. The current UI rerun could not launch a test worker because Xcode 26.6 repeatedly reported a missing debugger-version store on two simulators; a fresh simulator also failed its own data migration. This is not a test failure, but it must be rerun after repairing Xcode/CoreSimulator. Simulator execution does not validate CoreBluetooth, HealthKit entitlements, background collection, or Watch connectivity. |
| Android app | **Locally verified** | `assembleFullDebug`, all JVM tests, Android-test source compilation, `lintFullDebug`, and the API 35 Gradle-managed-device instrumentation suite pass. Physical-device/OEM behavior remains an external gate. |
| Self-hosted server | **Locally verified** | The normal suite passes 129 tests with nine database tests and the explicit real-Twilio test skipped. All nine database tests then pass against PostgreSQL 14 after removing only the unavailable TimescaleDB extension/hypertable calls from a disposable migration copy. Ruff check/format, the 12-file migration manifest, restore application SQL smoke, shell/JavaScript syntax, and both dependency audits pass. The pinned Timescale container, encrypted archive restore, and managed topology still require staging evidence. |
| Shared server tenancy | **Locally verified, identity pending** | `NOOP_AUTH_MODE=shared` requires retry-safe per-installation credentials for biometric routes, gives each native device one exclusive installation owner, returns `404` across tenant boundaries, and keeps the operator token administrative. Rotation, export, hard deletion, and Safety/Friends erasure pass memory and PostgreSQL isolation tests. Public signup, identity proof, recovery, support access, managed key posture, and independent penetration testing remain launch gates. |
| Private Friends | **Locally verified on Apple and Android** | Invitation-only enrollment, accepted requests, directional six-field privacy, summary-only replacement upload, removal, deletion, and localized Android UI are implemented. Android uses an encrypted member credential, retry-stable enrollment and upload identities, best-effort WorkManager refresh, and server-confirmed cleanup for an interrupted first join. There is no public directory, ranking, or end-to-end encryption. |
| Safety contact enrollment | **Locally verified** | Two accepted contacts are required, five is the maximum, invitations are one-time, and clients keep reminding until the accepted minimum is met. |
| Acknowledged Safety paging | **Locally verified in automation; carrier evidence pending** | App SOS and repeated band SOS origins create durable incidents. Independent bounded SMS/voice rounds continue until acknowledgement; acknowledgement cancels unsent work. Signed responder links expose latest-only location for a selected 8 or 12 hours. Idempotency, leases, retries, attempt history, provider receipts, DTMF, cancellation, resolution, expiry, and privacy-safe monitoring are covered. This is contact paging, not emergency dispatch. |
| Safety data lifecycle | **Locally verified** | Safety-token rotation is versioned and retry-safe; profile export excludes credential/invitation hashes; profile and installation erasure cover contacts, incidents, latest location, queues, attempts, Friends, and biometric data; bounded retention touches only terminal incidents and inactive contacts and preserves replay tombstones. |
| Strength Trainer | **Locally verified** | Apple and Android provide manual routines/sessions/sets, per-exercise history and PRs, weekly goals, muscle exposure, import/export, and portable restore. Watch can request a routine start on the paired iPhone. Rep sensing and muscular-load claims remain unavailable pending studies. |
| Sleep planning | **Locally verified** | Target, Balance, and Extra Opportunity modes, debt bounds, behavioral timing context, per-day wake overrides, reminders, and alarm boundaries exist on Apple and Android. Comparative accuracy and physical travel/DST behavior remain evidence gates. |
| Coach | **Locally verified** | Local durable transcript and editable memory, opt-in scheduled check-ins, voice/text Journal drafts, and confirmed Journal/routine actions exist. Model output cannot silently mutate records. |
| Nutrition | **Locally verified** | Editable meals, nullable nutrients, CSV reconciliation, barcode scan/manual lookup, Open Food Facts, saved foods/meals, and portable restore exist on Apple and Android. Product values require review before save. |
| Backup and restore | **Locally verified for implemented scope** | Same-platform native backups use integrity manifests and staged restore. The cross-platform portable payload validates and restores nutrition/library and normalized strength records. It is not a complete server-to-device restore of every local table. |
| NOOP+ managed storage | **Implemented and locally verified; deployment and physical evidence pending** | Phone OTP/App Check, per-installation credentials, explicit consent, immutable chunk upload, processor validation, snapshot/incremental restore, revocation, erasure, optional validated 90-day local detail retention, and complete managed-history ZIP export pass PostgreSQL 14, Android Demo/Full unit/lint/managed-device, and the 89-target Apple simulator matrices. The Apple and Android exporter includes cloud-only chunks and current personal records, verifies each object plus snapshot totals, and is separate from `/exports`. A clean-commit runtime image was built at immutable digest `sha256:7567a6fccfe73436f167b5df17a32a0a15422dc18dd0f664a116d1d8ab2665fb`; its on-demand scan reported zero findings. A current `7 add, 0 change, 0 destroy` identity plan is blocked because the project-owner account has not accepted Firebase terms. No mobile client is configured, the managed runtime/public invoker remain disabled, and no real health data is permitted in staging. |
| UI shell | **Locally verified by build, contract, and prior visual/UI evidence** | The app-wide visual system, glass navigation, floating add action, loading/empty/error states, and primary routes compile on Apple and Android. Prior production-shell and 40-capture/two-viewport visual suites pass; the current iOS UI action still needs a clean rerun after the host debugger-store failure described above. Final accessibility acceptance and physical-device visual review remain release evidence gates. |
| Localization | **Implemented, evidence pending** | Extracted catalog keys are complete in the focus locales and the strict audit (`Tools/i18n_audit.py --ci`) now passes. It passes because the remaining hardcoded literals sit in `Tools/i18n_audit_baseline.json`, not because they are localized: the iOS baseline grew 57 to 166 entries, **64** of which contain "Noop Band" and therefore render in English in all eight non-English locales. Those are a rename regression whose original translations are still in the catalog, orphaned under the pre-rename wording. Worklist: `localization/BRAND-RENAME-WORKLIST.md` (22 exact pairs, 14 near, 28 fresh). `StrandTests/BrandLiteralRatchetTests` holds the count so it can only shrink. A localized store release needs that worklist finished. |

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
| Source redistribution rights | Cleared by the NOOP owner declaration. Every artifact still requires a passing distribution gate, unchanged NOOP PolyForm license, and complete independent dependency notices. |
| Hosted vendor integrations | Approved OAuth applications, secret/token operations, webhook/backfill/deletion behavior, rate-limit handling, provider terms, and end-to-end tests for each of Strava, Garmin, Fitbit, or another service. |
| Broader social product | Teams, challenges, ranking rules, abuse/reporting controls, moderation operations, and product-scale load/authorization tests. Private Friends itself is available on Apple and Android; this gate applies only to a broader competitive/community product. |
| 10,000-user shared infrastructure | Deploy and prove the regional-cell design in `PLATFORM_ARCHITECTURE.md`: identity/recovery, DNS/TLS/WAF, digest-pinned deploys, HA PostgreSQL with bounded pools, immutable objects, queues, managed secrets/keys, off-region recovery, observability/on-call, independent isolation review, and reconnect/soak/failover/restore/mixed-workload evidence. Source and synthetic foundation exist, but no production topology has been provisioned or load-tested. |
| Hosted release controls | Restore the GitHub Actions budget; use an account/organization tier that supports protected `main` on a private repository; create reviewed staging/production environments; add scoped signing/deployment secrets; and require current server, Apple, Android, localization, claims, legal-inventory, and distribution checks. The repository currently has no Actions secrets or environments, this Mac has no valid code-signing identity or Android release keystore, and its configured AWS session is expired. |
| Remote push posture | Local reminders depend on background sync. Ordinary App Store/Play builds cannot safely give APNs/FCM provider credentials to user-operated servers. Cloud-grade delivery requires a deliberate optional relay with minimal or end-to-end-encrypted payloads, deletion/key rotation, privacy review, and real delivery evidence; otherwise the product must disclose the local-only reliability boundary. |
| Managed account portability | The native snapshot exporter now covers all managed-history data classes, cloud-only chunks, derived summaries, current user-authored records, and provenance in a verified manifest-backed ZIP. Before public enrollment, prove it live with large accounts, cancellation, auth refresh, snapshot expiry, cross-tenant denial, and corrupted-object cases; add resumable continuation and successful documented import. The client-upload `/exports` control plane remains a separate encrypted-archive facility. |

## Safety release boundary

Automatic medical, rhythm, SpO2, temperature, stress, and wellness SOS is
**intentionally unavailable**. Those signals never enter the paging API.

The server models a separate possible-fall contract, but new automatic fall
incidents are hard-disabled because authenticated detector attestation is not
implemented. The preparatory flag and allowlist cannot activate transport, and
shipping clients construct no fall candidate. Replacing the hard block still
requires authenticated firmware transport, staged-event and hard-negative
studies, participant/device-held-out evidence, physical background/haptic
testing, carrier evidence, accessible human-factors review, regional legal
analysis, and any required regulatory authorization.

Available Safety actions are app-confirmed SOS and a configured repeated band
SOS gesture. They page accepted trusted contacts and tell them to call the owner
or local emergency services. NOOP does not contact emergency services and cannot
guarantee carrier delivery or human response.

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
