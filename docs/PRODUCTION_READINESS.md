# NOOP production readiness

Last reviewed: **2026-09-07**

This is the release decision record for NOOP. A compiled screen or passing unit
test proves code behavior only. It does not prove carrier delivery, wearable
firmware compatibility, algorithm accuracy, clinical safety, store acceptance,
or a person's response to a page.

The ordered first-release execution plan is
[`FIRST_PRODUCTION_RELEASE_PLAN.md`](FIRST_PRODUCTION_RELEASE_PLAN.md). It is the
canonical plan for the first-party NOOP Band, safe terminology/data migration,
mobile/cloud work, physical evidence, certification, signing, stores, and
launch. This readiness file remains the status ledger; neither document marks
an open gate complete.

The appendable action ledger is
[`FIRST_PRODUCTION_RELEASE_CHECKLIST.md`](FIRST_PRODUCTION_RELEASE_CHECKLIST.md).
New work belongs at its dependency position there; a checkbox closes only with
the evidence required by this readiness record.

## Status vocabulary

| Status | Meaning |
|---|---|
| **Locally verified** | The implementation passed the repository's local build or automated test gate on the review date. |
| **Implemented, evidence pending** | The product path exists, but release evidence requires a real provider, device, participant cohort, or signed distribution build. |
| **External launch gate** | Code cannot close this item without controlled credentials, hardware, accounts, people, or regulatory/safety work. |
| **Intentionally unavailable** | Shipping the behavior would overstate the available evidence. |

## Code-side readiness

The phase-R1 source and workflow defects have been repaired without waivers.
At source commit `1443acb1`, the hosted Apple, Android, Swift-package, server,
localization, health-claims, runtime-license, private-data, and
operations-record matrices pass. Apple and Android release evidence remains
bounded by the signed physical-device and storefront gates below; a green
hosted source matrix is not a public-release decision.

At source commit `b5caec52`, hosted run `34084340375` additionally passes the
fail-closed source release controls and retains a deterministic 216-component
CycloneDX SBOM plus commit/tree-bound evidence manifest. The downloaded
manifest independently verifies against that exact commit. `main` remains
unprotected, the repository still has no reviewed GitHub environments, and
credential rotation, signed artifacts, external evidence, and go-live approval
remain open.

| Area | Status | Current evidence and boundary |
|---|---|---|
| First-party NOOP Band and SDK | **Not implemented; hardware and protocol inputs pending** | Reusable framing, history, clock, storage, analytics, diagnostics, and pluggable-source patterns exist, but there is no NOOP firmware, GATT/wire contract, device provisioning, secure boot, signed DFU, manufacturing interface, or first-party native SDK. The required input dossier, architecture, conformance gates, and physical matrix are defined in the master plan. Existing third-party hardware cannot be relabeled as proof. |
| Band ownership account and onboarding | **Supplier-independent foundation implemented; possession and launch evidence pending** | PostgreSQL/FastAPI, Apple, and Android now implement verified-email identity mechanics, optional phone linking, immutable terms acceptance, secure per-installation credentials, atomic single-owner claim, replacement-installation authorization, installation revocation, resumable onboarding, and the pre-Home NOOP/NOOP+ preference. The service is default-off, has no public invoker, and its production possession provider intentionally returns unavailable. Supplier label mapping, signed possession, owner-key provisioning, approved recovery/release operations, payment, legal review, and physical evidence remain open. |
| Remote terms and returns | **Terms mechanism implemented; approved policy and return operations pending** | The clients enforce TLS, approved hosts, no redirects, no persistent cache, size/UTF-8 controls, and digest verification; the service stores immutable versions and exact acceptance metadata without placing rendered terms in diagnostics or app databases. No approved production terms document has been published. The owner has not selected 14 versus 30 days or the clock start, and condition grades, lawful disclosed deductions, appeal, operator wipe/unlink, quarantine, legal review, and operations evidence remain open. |
| macOS app | **Locally and hosted source-verified** | The current app suite passes 1,651 tests with one external-fixture skip, and exact-main hosted run `34080116658` builds the unsigned universal `x86_64`/`arm64` app and passes its tests. A distributable Developer ID build and notarization remain external. |
| iPhone, Watch, widgets | **Locally and hosted source-verified by build and simulator test** | A fresh unsigned 89-target graph validates the current iPhone app, embedded Watch app, widgets, and Live Activities; 34 production-shell tests pass with one private-pilot skip. Exact-main hosted run `34080116658` passes launch-gate isolation, the iOS graph build, and production-shell tests. The ownership plan chooser installed and rendered on an iOS 26.5 simulator. Simulator execution does not validate CoreBluetooth, HealthKit entitlements, background collection, attestation, or Watch connectivity. |
| Android app | **Locally and hosted source-verified** | Full and Demo each pass 4,098 unit tests with seven intentional skips, compile, and lint. Exact-main hosted run `34079190997` passes the debug build, unit, lint, instrumentation-compile, and API 35 managed-device lanes; the device lane passes 45 production-shell tests with two private-pilot skips and retains diagnostics. The production-flavor APK also installs and launches locally on an emulator. Physical-device/OEM, BLE, haptic, battery, background, and attestation behavior remain external evidence gates. |
| Self-hosted server | **Locally and hosted verified** | The complete suite passes 358 tests with one intentional environment-gated skip against isolated PostgreSQL databases. The pinned TimescaleDB 2.20.3/PostgreSQL 16 hosted lane also passes exact legal lock, lint, dependency audits, an extension-free PostgreSQL overlay, the complete suite, Compose validation, production and backup container builds, encrypted backup, and disposable restore. Public topology, load, regional recovery, and production operations remain separate gates. |
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
| Reference comparison and personal calibration | **Locally verified on Apple and Android; population validation pending** | Both clients keep imported official outcomes separate from independently recomputed NOOP values, pair exact calendar days, audit excluded provenance, and report bias, MAE, RMSE, and correlation. Twelve unit-compatible fields can be compared, but only the independently recomputed Charge, Effort, and Rest score families can receive a presentation-only personal transform. A model needs at least 28 pairs, uses at least 21 earlier training days and seven later holdout days, requires correlation and slope safety gates, at least 5% unseen MAE improvement, non-worsening RMSE, and exact algorithm-revision binding. Raw and official values are never overwritten. Current score windows and Rest evidence publish atomically on both platforms; malformed input fails before mutation, and Apple does not advance its analysis watermark after any core persistence failure. This does not prove physiological or population accuracy. |
| Long-history storage | **Host-synthetic profile verified; physical-device budgets pending** | The deterministic 10-, 30-, 90-, and 365-day harness exercises the production store, 7-day raw and 30-day essential retention candidate, full compact history, WAL checkpoint, exact same-platform backup/restore, and 14 content-equality checks. The 365-day retained database is about 444 MB and its temporary backup/restore peak is about 1.33 GB. Host calendar, selected-day, and trend reads stayed below 8 ms, but these numbers do not prove phone memory, scrolling, startup, thermal, battery, background survival, BLE continuity, or low-storage behavior. |
| NOOP+ managed storage | **Verified in private synthetic staging; public and physical evidence pending** | Phone OTP/App Check, per-installation credentials, explicit consent, immutable chunk upload, processor validation, snapshot/incremental restore, revocation, erasure, optional validated seven-day raw plus 30-day essential local retention, and complete managed-history ZIP export are implemented on Apple and Android. One scanned digest is deployed across the IAM-only API, processor, migration, and lifecycle workloads; migration/lifecycle jobs and a complete synthetic storage/isolation/restore/erasure smoke pass with zero infrastructure drift. No released mobile client is configured, the public invoker remains disabled, and no real health data is permitted in staging. |
| NOOP+ managed Friends | **Verified in private synthetic staging; physical delivery pending** | Apple and Android provide random rotatable exact-match IDs, profile and expiring invite links, mutual acceptance, directional six-field sharing, removal/block/delete, non-competitive badges, and receiver-controlled bounded pokes. Migration `025` and a two-account synthetic smoke prove accepted-date privacy, consent, badges, poke controls, blocks, and cleanup. Links still use a custom app scheme, and pokes rely on catch-up before generic local notification and eligible worn-band haptic; HTTPS universal/app links, APNs/FCM wake delivery, abuse/support operations, and physical-device evidence remain open. |
| UI shell | **Locally verified by build, contract, and current visual evidence** | The app-wide visual system, glass navigation, floating add action, loading/empty/error states, and primary routes compile on Apple and Android. Prior production-shell and 40-capture/two-viewport suites pass, and the current iOS overlay received a fresh deterministic bottom-of-page render after its text-occlusion fix. Android reserves its independently rendered navigation as a `Scaffold` bottom slot, so page content does not underlap that surface. Final accessibility acceptance and physical-device visual review remain release evidence gates. |
| Localization | **Implemented, evidence pending** | Extracted catalog keys are complete in the focus locales and the strict audit (`Tools/i18n_audit.py --ci`) now passes. It passes because the remaining hardcoded literals sit in `Tools/i18n_audit_baseline.json`, not because they are localized: the iOS baseline grew 57 to 166 entries, **64** of which contain "Noop Band" and therefore render in English in all eight non-English locales. Those are a rename regression whose original translations are still in the catalog, orphaned under the pre-rename wording. Worklist: `localization/BRAND-RENAME-WORKLIST.md` (22 exact pairs, 14 near, 28 fresh). `StrandTests/BrandLiteralRatchetTests` holds the count so it can only shrink. A localized store release needs that worklist finished. |

## Launch gates requiring external evidence

| Gate | Required evidence before the related claim ships |
|---|---|
| NOOP Band production support | Final hardware/firmware/printed-label/pairing dossier and supplier SDK; secure provisioning and key custody; authenticated physical confirmation; atomic single-owner claim; signed secure-boot/OTA rollback; offline flash retention; protocol conformance across firmware, Swift, and Kotlin; manufacturing calibration/traceability; required market certifications; and the complete physical collection, history, clock, power, haptic, update, storage, recovery, release, and upgrade matrix. |
| Band account and transfer policy | Production verified-email identity with optional phone; App Check/attestation; enumeration-resistant recovery; tenant-isolated claim/release records; replacement-phone authorization; account deletion; return/RMA/recovery/dispute exits; future eligible-upgrade release; and India/USA consumer, privacy, warranty, and transfer approval. |
| Terms and return policy | Immutable signed remote terms, ephemeral no-persistent-cache app rendering, exact acceptance evidence, public historical versions, approved 14- or 30-day clock, eligibility, objective condition grades, disclosed lawful refund deductions, original-rail refunds, appeals, operator-only wipe/unlink, and India/USA approval. |
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
| Hosted release controls | At `1443acb1`, server run `34078811154`, Apple run `34080116658`, Android run `34079190997`, Swift/study run `34078979831`, localization run `34078811190`, claims run `34078811160`, legal-inventory run `34078979957`, and operations run `34078811177` pass. At `b5caec52`, Release Controls run `34084340375` passes and retains a reverified commit/tree-bound SBOM manifest; localization run `34084340416`, claims run `34084340413`, and operations run `34084340476` pass. `main` is still unprotected, the repository has no reviewed GitHub environments, and the four present Android credentials are staging-only; production signing/deployment credentials, credential rotation, and required-check policy remain open. This Mac has no valid Apple distribution identity or Android production release keystore. |
| Remote push posture | Local reminders and managed Friends pokes currently depend on background/foreground catch-up. Ordinary App Store/Play builds cannot safely give APNs/FCM provider credentials to user-operated servers. Cloud-grade delivery requires a deliberate managed relay with an opaque minimal wake payload, token deletion/key rotation, privacy review, abuse controls, and real delivery evidence; otherwise the product must disclose the non-immediate local-only reliability boundary. |
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
