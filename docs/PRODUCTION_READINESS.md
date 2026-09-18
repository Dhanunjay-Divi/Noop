# NOOP production readiness

Last reviewed: **2026-09-18**

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

Core collection, scoring, local history, export, and supported local device
control remain local-first. The first-party band ownership account is a narrow
activation/control exception, not health-data consent. NOOP+ remains a separate
explicit opt-in and cannot become a dependency of core local use.

## Status vocabulary

| Status | Meaning |
|---|---|
| **Locally verified** | The implementation passed the repository's local build or automated test gate on the review date. |
| **Implemented, evidence pending** | The product path exists, but release evidence requires a real provider, device, participant cohort, or signed distribution build. |
| **PARTIAL** | A bounded source foundation exists, but material implementation or release gates remain open. |
| **External launch gate** | Code cannot close this item without controlled credentials, hardware, accounts, people, or regulatory/safety work. |
| **Intentionally unavailable** | Shipping the behavior would overstate the available evidence. |

## Code-side readiness

The protected integrated baseline for the current review is `main` at
`b688b3b725cd497e96a31b28540a219bf50446e1`. The active
`codex/ui-cloud-readiness-20260917` branch is dirty, uncommitted, and not
integrated. Older commit- and run-bound results below remain historical evidence
for their exact trees; they are not exact-head proof for this branch.

Live GitHub state was reverified on 2026-09-18. Protected `main` requires strict
up-to-date checks, enforces the rule for administrators, requires linear
history, and rejects force pushes and deletion. Changes are integrated through
a protected pull request rather than pushed directly to `main`. The exact ten
required GitHub Actions contexts are:

- `android-ci-required`
- `apple-ci-required`
- `health-claims`
- `i18n-coverage`
- `operations-record`
- `release-controls`
- `runtime-license-required`
- `server-ci-required`
- `swift-packages-required`
- `trusted-release-controls`

All ten completed successfully on baseline `b688b3b7` under GitHub Actions
application `15368`. The trusted context is not a substitute for the other
nine: its pull-request-target workflow runs protected-base code against an
isolated candidate checkout, restricts release-authority changes to the
repository owner's exact in-repository head, and publishes one exact-head
result. Candidate release semantics remain independently enforced by
`release-controls`. The post-merge trusted run validates protected `main` and
publishes a distinct `protected-main` result; release publication rejects the
pull-request-scoped result.

Current focused evidence is deliberately narrower: the Xcode 27 license check
passes, the iOS widget target builds, a focused Apple app suite passes 38 of 38
tests, and nine focused Android classes pass 60 of 60 tests while compiling the
Full debug source. Complete current Apple, Android, package, server, static,
operations, hosted exact-SHA, signing, and physical-device walls remain open.
A focused pass is not a public-release decision.

Final active-branch evidence is intentionally left for closeout:

- Apple complete wall: `<pending final exact-current count and result>`
- Android Full/Demo and applicable device wall:
  `<pending final exact-current count and result>`
- Swift packages and harnesses: `<pending final exact-current count and result>`
- Server/static/privacy/operations walls:
  `<pending final exact-current count and result>`; no Docker build or restore
  result is claimed by this round unless the final record supplies it
- Hosted exact-head contexts: `<pending candidate SHA and 10/10 result>`
- Protected integration: `<pending pull request and merged main SHA>`

| Area | Status | Current evidence and boundary |
|---|---|---|
| First-party NOOP Band and SDK | **Not implemented; hardware and protocol inputs pending** | Reusable framing, history, clock, storage, analytics, diagnostics, and pluggable-source patterns exist, but there is no NOOP firmware, GATT/wire contract, device provisioning, secure boot, signed DFU, manufacturing interface, or first-party native SDK. The required input dossier, architecture, conformance gates, and physical matrix are defined in the master plan. Existing third-party hardware cannot be relabeled as proof. |
| Band ownership account and onboarding | **PARTIAL** | PostgreSQL/FastAPI, Apple, and Android provide a default-off supplier-independent foundation for verified-email identity mechanics, optional phone linking, immutable terms acceptance, secure per-installation credentials, atomic single-owner claim, replacement-installation authorization, installation revocation, resumable onboarding, and the pre-Home NOOP/NOOP+ preference. It has no public invoker, and its production possession provider intentionally returns unavailable. Supplier label mapping, signed possession, owner-key provisioning, ownership-account deletion (`ACC-340`), billing, recovery/release operations, legal approval, physical evidence, and production deployment/operations remain open. |
| Remote terms and returns | **Terms mechanism implemented; approved policy and return operations pending** | The clients enforce TLS, approved hosts, no redirects, no persistent cache, size/UTF-8 controls, and digest verification; the service stores immutable versions and exact acceptance metadata without placing rendered terms in diagnostics or app databases. No approved production terms document has been published. The owner has not selected 14 versus 30 days or the clock start, and condition grades, lawful disclosed deductions, appeal, operator wipe/unlink, quarantine, legal review, and operations evidence remain open. |
| macOS app | **Historical integrated evidence; active-branch wall pending** | Prior exact-main source evidence includes an unsigned universal build and app tests for its recorded tree. The active branch's final exact-current count belongs in the placeholder above. A distributable Developer ID build and notarization remain external. |
| iPhone, Watch, widgets | **Focused active-branch evidence; complete wall pending** | The active branch has the focused Apple and widget results recorded above. Historical exact-main evidence covers its then-current unsigned iPhone/Watch/widget graph and simulator shell only. Neither proves CoreBluetooth, HealthKit entitlements, background collection, attestation, Watch connectivity, notification delivery, or physical accessibility. |
| Android app | **Focused active-branch evidence; complete wall pending** | The active branch has the focused Full-debug result recorded above. Historical exact-main evidence covers its then-current build, unit, lint, instrumentation compile, and emulator lanes only. Demo, final exact-current, physical-device/OEM, BLE, haptic, battery, background, attestation, and physical accessibility evidence remain open until separately recorded. |
| Self-hosted server | **Historical integrated evidence; active-branch wall pending** | Prior exact-main hosted evidence covers its recorded PostgreSQL/server and container/restore lanes. It is not exact-head proof for the active branch. The current round has no final server count and makes no Docker build or restore claim; public topology, load, regional recovery, credentials, and production operations remain separate gates. |
| Shared server tenancy | **Locally verified, identity pending** | `NOOP_AUTH_MODE=shared` requires retry-safe per-installation credentials for biometric routes, gives each native device one exclusive installation owner, returns `404` across tenant boundaries, and keeps the operator token administrative. Rotation, export, hard deletion, and Safety/Friends erasure pass memory and PostgreSQL isolation tests. Public signup, identity proof, recovery, support access, managed key posture, and independent penetration testing remain launch gates. |
| Private Friends | **Locally verified on Apple and Android** | Invitation-only enrollment, accepted requests, directional six-field privacy, summary-only replacement upload, removal, deletion, and localized Android UI are implemented. Android uses an encrypted member credential, retry-stable enrollment and upload identities, best-effort WorkManager refresh, and server-confirmed cleanup for an interrupted first join. There is no public directory, ranking, or end-to-end encryption. |
| Managed Safety contact enrollment | **Locally verified** | Exact-match NOOP IDs and one-time invitations create a separate accepted Safety relationship without granting Friends or health-data access. Two accepted outbound contacts are required, five is the maximum, limits are concurrency-safe, and remove, block, profile deletion, and installation revocation are covered. |
| Managed app Safety paging | **Implemented, evidence pending** | The first-release transport is manual app-to-app paging of accepted NOOP Safety contacts. APNs/FCM payloads contain only a fixed event kind, opaque incident reference, and expiry; authenticated clients fetch details and may respond or decline. Location is not implicit: the launch contract requires separate incident-scoped consent, latest-only replacement during the selected 8- or 12-hour window, and terminal deletion. Existing source and private synthetic evidence covers accepted-contact enrollment, paging state, latest-location replacement, response, resolution, and cleanup, but physical terminated/background push, permission and consent journeys, token invalidation, deletion persistence, and OEM/iOS battery behavior remain open. This is contact paging, not emergency dispatch. |
| SMS/voice Safety fallback | **Intentionally unavailable for the app-to-app launch path** | Automation exists for bounded SMS/voice rounds, acknowledgement, cancellation, responder links, provider receipts, DTMF, resolution, and expiry, but it does not authorize release. SMS/voice remains disabled until country-specific carrier or DLT sender/template registration, legal review, controlled physical-phone delivery, monitoring, failover, and staffed operations pass. |
| Safety data lifecycle | **Locally verified for the managed Safety profile scope** | Managed push tokens and legacy Safety credentials rotate and revoke retry-safely; profile export excludes credential and invitation secrets; profile and installation erasure cover account contacts, incidents, participants, latest location, push deliveries, provider queues and attempts, Friends, and biometric data. Bounded retention touches only terminal incidents and inactive contacts and preserves required replay tombstones. This does not implement deletion of the separate first-party band ownership account. |
| Strength Trainer | **Locally verified** | Apple and Android provide manual routines/sessions/sets, per-exercise history and PRs, weekly goals, muscle exposure, import/export, and portable restore. Watch can request a routine start on the paired iPhone. Rep sensing and muscular-load claims remain unavailable pending studies. |
| Sleep planning | **Locally verified** | Target, Balance, and Extra Opportunity modes, debt bounds, behavioral timing context, per-day wake overrides, reminders, and alarm boundaries exist on Apple and Android. Comparative accuracy and physical travel/DST behavior remain evidence gates. |
| Coach | **Locally verified** | Local durable transcript and editable memory, opt-in scheduled check-ins, voice/text Journal drafts, and confirmed Journal/routine actions exist. Model output cannot silently mutate records. |
| Nutrition | **Locally verified** | Editable meals, nullable nutrients, CSV reconciliation, barcode scan/manual lookup, Open Food Facts, saved foods/meals, and portable restore exist on Apple and Android. Product values require review before save. |
| Backup and restore | **Locally verified for implemented scope** | Same-platform native backups use integrity manifests and staged restore. The cross-platform portable payload validates and restores nutrition/library and normalized strength records. It is not a complete server-to-device restore of every local table. |
| Reference comparison and personal calibration | **Locally verified on Apple and Android; population validation pending** | Both clients keep imported official outcomes separate from independently recomputed NOOP values, pair exact calendar days, audit excluded provenance, and report bias, MAE, RMSE, and correlation. Twelve unit-compatible fields can be compared, but only the independently recomputed Charge, Effort, and Rest score families can receive a presentation-only personal transform. A model needs at least 28 pairs, uses at least 21 earlier training days and seven later holdout days, requires correlation and slope safety gates, at least 5% unseen MAE improvement, non-worsening RMSE, and exact algorithm-revision binding. Raw and official values are never overwritten. Current score windows and Rest evidence publish atomically on both platforms; malformed input fails before mutation, and Apple does not advance its analysis watermark after any core persistence failure. This does not prove physiological or population accuracy. |
| Long-history storage | **Host-synthetic profile verified; physical-device budgets pending** | The deterministic 10-, 30-, 90-, and 365-day harness exercises the production store, 7-day raw and 30-day essential retention candidate, full compact history, WAL checkpoint, exact same-platform backup/restore, and 14 content-equality checks. The 365-day retained database is about 444 MB and its temporary backup/restore peak is about 1.33 GB. Host calendar, selected-day, and trend reads stayed below 8 ms, but these numbers do not prove phone memory, scrolling, startup, thermal, battery, background survival, BLE continuity, or low-storage behavior. |
| NOOP+ managed storage | **Implemented for a bounded source scope; portability, public, and physical evidence pending** | Apple and Android implement explicit-consent chunk upload, processor validation, snapshot/incremental restore, installation revocation, NOOP+ managed-data erasure, and optional validated seven-day raw plus 30-day essential local retention. They also implement a non-resumable snapshot-bound ZIP for selected managed chunk classes; `day_ownership` is the only managed document included by the current exporter. There is no managed-history importer, interrupted-export continuation, or complete live expiry/corruption round-trip proof, so `DAT-170` remains open. NOOP+ managed erasure is separate from first-party ownership-account deletion (`ACC-340`). A prior round recorded private synthetic staging against one scanned IAM-only digest with no real health data or public invoker; retained runtime and drift were not reverified in this review. |
| NOOP+ managed Friends | **Implemented; historical private synthetic evidence, physical delivery pending** | Apple and Android provide random rotatable exact-match IDs, profile and expiring invite links, mutual acceptance, directional six-field sharing, removal/block/delete, non-competitive badges, and receiver-controlled bounded pokes. A prior round recorded migration `025` plus a two-account private synthetic smoke for accepted-date privacy, consent, badges, poke controls, blocks, and cleanup; retained runtime state was not reverified here. Links still use a custom app scheme, and pokes rely on catch-up before generic local notification and eligible worn-band haptic; HTTPS universal/app links, APNs/FCM wake delivery, abuse/support operations, and physical-device evidence remain open. |
| UI shell | **Implementation under active review; final accessibility evidence pending** | The app-wide visual system, navigation, loading/empty/error states, and primary routes exist on Apple and Android. Focused source evidence is recorded above; final exact-current visual and large-text results belong in the round closeout. Simulator captures can reveal clipping or overlap but do not establish VoiceOver/TalkBack order, touch behavior, haptics, contrast on physical displays, or physical accessibility acceptance. |
| Localization | **Implemented, evidence pending** | Extracted catalog keys are complete in the focus locales and the strict audit (`Tools/i18n_audit.py --ci`) now passes. It passes because the remaining hardcoded literals sit in `Tools/i18n_audit_baseline.json`, not because they are localized: the current iOS baseline contains 149 entries, **60** of which contain "Noop Band" and therefore render in English in all eight non-English locales. Those are a rename regression whose original translations are still in the catalog, orphaned under the pre-rename wording. Worklist: `localization/BRAND-RENAME-WORKLIST.md` (22 exact pairs, 14 near, 28 fresh). `StrandTests/BrandLiteralRatchetTests` currently caps the brand-literal subset at 61, so that source ratchet still needs to be lowered to the measured 60 in a source-authorized slice. A localized store release needs that worklist finished. |

## Launch gates requiring external evidence

| Gate | Required evidence before the related claim ships |
|---|---|
| NOOP Band production support | Final hardware/firmware/printed-label/pairing dossier and supplier SDK; secure provisioning and key custody; authenticated physical confirmation; atomic single-owner claim; signed secure-boot/OTA rollback; offline flash retention; protocol conformance across firmware, Swift, and Kotlin; manufacturing calibration/traceability; required market certifications; and the complete physical collection, history, clock, power, haptic, update, storage, recovery, release, and upgrade matrix. |
| Band account and transfer policy | Production verified-email identity with optional phone; App Check/attestation; enumeration-resistant recovery; tenant-isolated claim/release records; replacement-phone authorization; account deletion; return/RMA/recovery/dispute exits; future eligible-upgrade release; and India/USA consumer, privacy, warranty, and transfer approval. |
| Terms and return policy | Immutable signed remote terms, ephemeral no-persistent-cache app rendering, exact acceptance evidence, public historical versions, approved 14- or 30-day clock, eligibility, objective condition grades, disclosed lawful refund deductions, original-rail refunds, appeals, operator-only wipe/unlink, and India/USA approval. |
| SMS/voice Safety fallback, if enabled | Country-specific carrier or DLT entity/header/template approval; legal review; controlled-number SMS, voice, DTMF, callback, retry, restart, cancellation, and all-contact-failure evidence; physical-phone delivery latency; monitoring; failover; and staffed operations. These gates do not apply while SMS/voice remains disabled behind the app-to-app path. |
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
| Hosted release controls | Protected `main` currently enforces the ten exact contexts listed above, and baseline `b688b3b7` has successful exact-SHA results from GitHub Actions application `15368`. The trusted gate binds protected-base authorization to the exact pull-request head and binds post-merge verification to a separate `protected-main` result; `release-controls` independently validates candidate semantics. The active September 17-18 branch remains dirty, uncommitted, unpushed, and unevaluated by those hosted contexts, so it must complete local walls, open a PR, pass all ten on its exact head, merge without bypass, and pass the protected-main checks before it becomes integrated evidence. Historical runs at `1443acb1` and `b5caec52` remain evidence only for those trees. Production signing/deployment credentials, credential rotation, reviewed environments, signed artifacts, physical and supplier evidence, legal/certification approvals, store records, production operations, and go-live approval remain open. This Mac has no evidenced Apple distribution identity or Android production release keystore for this round. |
| Remote push posture | Local reminders and managed Friends pokes currently depend on background/foreground catch-up. App-to-app Safety paging requires a deliberate managed APNs/FCM relay with an opaque minimal wake payload, token deletion/key rotation, accepted-contact authorization, privacy review, abuse controls, and real physical delivery evidence. Ordinary App Store/Play builds cannot safely give provider credentials to user-operated servers. Until the managed relay and device matrix pass, the product must not imply immediate or guaranteed delivery. |
| Managed account portability | The native exporter can pin one restore snapshot, page selected retained chunk classes, include cloud-only chunks, verify object digests/counts/bytes, and include `day_ownership` as the only managed document in its current manifest-backed ZIP scope. It is not every user-authored record. `DAT-170` remains open for resumable continuation, effective snapshot-expiry handling, corrupted-archive rejection at import, a documented importer, and live large-account/cancellation/auth-refresh/cross-tenant tests. The client-upload `/exports` control plane remains a separate encrypted-archive facility and does not provide round-trip managed-history portability. |

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

The first-release target is app-confirmed app-to-app paging of accepted NOOP
Safety contacts. Precise location is off by default and may be shared only
after explicit incident-scoped consent; retention is latest-only for the
selected 8- or 12-hour window and ends with the incident. SMS and voice are
disabled fallback channels until carrier or DLT, legal, physical delivery,
monitoring, failover, and staffed-operations gates pass. The repeated band
gesture remains behind hardware and physical-device gates. NOOP does not
contact emergency services and cannot guarantee push delivery, carrier
delivery, or human response.

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
