# App Store privacy, entitlement, and compliance draft

This is a non-secret worksheet for the first NOOP iOS submission. It is grounded
in the current **Release** target and its embedded widgets and Watch app. It is
not legal advice, and it must be checked against the final Organizer archive and
App Store Connect questionnaire immediately before submission.

## Binary scope audited

- iPhone/iPad app: HealthKit read/write, Bluetooth central, motion step queries,
  user-started outdoor-workout location, local notifications, Live Activities,
  Files/share-sheet exports, widgets, optional Friends, optional AI providers,
  and optional user-configured self-hosted sync.
- Embedded targets: iOS widgets, Watch app, and Watch complications.
- Default Release settings do **not** define `OURA_CLOUD_IMPORT`; the Oura OAuth
  and cloud API lane is therefore compiled out. Local file import and local Oura
  BLE support are separate features and remain in the binary.
- Swift packages resolved for this build: GRDB, ZIPFoundation, NetworkImage,
  MarkdownUI, and swift-cmark. No advertising, attribution, crash-reporting, or
  remote product-analytics SDK was found.

## App Privacy answers — conservative shipping draft

Answer **Yes, data is collected** while the optional Friends and remote AI
provider features ship. Although the primary database and route history are
local, an explicit AI Coach request can send a health/fitness summary and chat
content to the provider selected by the user. Friends can send a display name,
installation/profile identifiers, and selected daily metrics to the server the
user configured. Apple requires answers to include third-party partners and
optional collection paths.

| App Store data type | Collected | Linked to the user | Tracking | Purpose | Exact shipping lane |
|---|---:|---:|---:|---|---|
| Health | Yes | Yes | No | App Functionality; Product Personalization | Opt-in AI context, Friends daily summaries, or self-hosted sync can include HRV, resting HR, sleep/recovery, temperature, SpO2, respiration, and related wellness summaries. |
| Fitness | Yes | Yes | No | App Functionality; Product Personalization | Opt-in AI context, Friends summaries, or self-hosted sync can include activity, effort, calories, steps, and workout summaries. |
| Name | Yes | Yes | No | App Functionality | A user-entered display name is sent only when Friends is configured. Profile photos remain local. |
| User ID | Yes | Yes | No | App Functionality | Friends creates server profile/enrollment identifiers. There is no required NOOP account. |
| Device ID | Yes | Yes | No | App Functionality | Self-hosted/Friends payloads use an app-generated installation/source identifier for deduplication; it is not an advertising identifier. |
| Other User Content | Yes | Yes | No | App Functionality; Product Personalization | An explicit AI request sends the question, recent chat transcript, and system context; optional context can include journal-pattern and Lab Book summaries. Journal notes are otherwise local. |

Do **not** select any of the following for this binary unless the final archive
or server behavior changes:

- Location: outdoor routes stay on device and are absent from self-hosted,
  Friends, and AI payloads.
- Photos or Videos: a chosen profile image stays on device.
- Audio: the app does not upload voice recordings.
- Contacts, email, phone number, address, payment/financial information,
  purchases, browsing/search history, advertising data, or environment/body
  scanning.
- Product Interaction, crash/performance data, or other diagnostics: no remote
  telemetry SDK is present. Diagnostic files are generated locally and leave
  only through an explicit Files/share action chosen by the user.

All declared types above should be marked **not used for tracking**. There are
no tracking domains, ads, data-broker lanes, or cross-company advertising uses.
Do not mark any type as used for third-party advertising, developer advertising,
or analytics.

If Friends and every remote AI provider are removed from the exact submitted
binary, repeat the audit before considering “Data Not Collected.” User-operated
self-hosted transfer still requires a documented App Privacy interpretation;
do not silently change the answer based only on the absence of a NOOP cloud.

## On-device and user-directed data that is not an automatic upload

- Apple Health permissions are optional. General reads cover heart rate,
  resting heart rate, HRV SDNN, oxygen saturation, respiratory rate, body and
  wrist temperature, steps, active/basal energy, VO2 max, sleep, and workouts.
  Body composition and menstrual-flow reads have separate explicit controls.
- Optional Apple Health writes cover selected resting metrics, sleep, workouts,
  and separately enabled high-resolution heart rate/energy/distance. NOOP does
  not write RMSSD into Apple's SDNN field.
- Bluetooth streams, the SQLite database, GPS route, profile photo, Lab Book,
  exports, encrypted backups, and scheduled diagnostic exports are local by
  default. A Files/share sheet is a user-selected destination, not a background
  developer upload.
- Self-hosted sync is off by default and sends raw wearable rows, daily metrics,
  sleep, workouts, and journals only to the endpoint and credential configured
  by the user. Routes and Lab Book records are not in that payload version.
- AI Coach is bring-your-own-provider and sends nothing merely by saving a key.
  Sending a question transmits the question and recent transcript; optional
  consent adds a compact health/fitness context. The provider's own privacy
  terms apply.
- Post-workout summaries are local, off by default, and evaluated only after a
  wearable sync persists a newer workout. Lock-screen copy is generic and
  contains no effort, duration, heart-rate, or other workout health detail.
  Existing history is not announced when the setting is enabled.

## Privacy manifests and required-reason APIs

| Bundle/component | Manifest declaration | Audit result |
|---|---|---|
| iOS app | File timestamps `C617.1`, `3B52.1`; UserDefaults `CA92.1`, `1C8F.1` | Matches app-container/user-selected file handling plus standard/App Group preferences. |
| iOS widgets | UserDefaults `CA92.1`, `1C8F.1` | Matches standard/App Group preferences. |
| Watch app | UserDefaults `CA92.1`, `1C8F.1` | Matches standard/App Group preferences. |
| Watch complications | UserDefaults `CA92.1`, `1C8F.1` | Matches standard/App Group preferences. |
| GRDB 6.29.3 | Empty privacy manifest | Dependency supplies a manifest and declares no collection/tracking/reason API. |
| ZIPFoundation 0.9.20 | File timestamp `0A2A.1` | Dependency supplies its own required-reason declaration. |
| NetworkImage, MarkdownUI, swift-cmark | No manifest found in the resolved checkout | No integrated remote analytics behavior was found; confirm the final archive privacy report has no missing-signature or required-reason warning. |

The app manifests intentionally do not declare collected data types. App Store
privacy-label answers describe developer/partner collection; a privacy manifest
is not a substitute for those App Store Connect answers.

## Capabilities, entitlements, and background modes

| Surface | Shipping setting | Why it exists / reviewer wording |
|---|---|---|
| iOS app | HealthKit + HealthKit background delivery | Optional Health reads/writes and best-effort observer delivery. iOS controls timing. |
| iOS app | App Group | Shares a minimal snapshot/preferences with the iOS widgets. |
| iOS app | `bluetooth-central` | Direct wearable/device connection, history retrieval, restoration, and opt-in live heart rate. It does not guarantee continuous background sync. |
| iOS app | `location` plus When-In-Use purpose string | Used only after the user starts a distance-based outdoor workout. `GpsWorkoutRecorder` continues that route while the screen is off; the route stays local. Remove the feature before removing this mode. |
| iOS app | `fetch` plus `.refresh` and `.diagnosticexport` BG identifiers | Best-effort data refresh and the separately enabled local diagnostic auto-export. Neither is a guaranteed timer. |
| iOS app | Live Activities | User-controlled live heart-rate/session presentation; no push-notification entitlement is present. |
| iOS widgets | App Group only | Reads the iPhone app's shared snapshot. |
| Watch app | HealthKit + App Group | Starts a basic workout session to obtain higher-fidelity live Watch heart rate; its App Group is Watch-local. Phone/Watch transfer uses the companion channel, not a cross-device App Group. |
| Watch complications | App Group only | Reads the Watch app's local shared snapshot. |

Local notifications require user authorization but no `aps-environment`
entitlement. This includes the opt-in generic post-sync workout summary; its
content is built and scheduled on device, and tapping it opens the local
Workouts view. The binary does not declare remote push, background processing,
always-location authorization, a network extension, Sign in with Apple, or an
advertising attribution entitlement.

### Paste-ready background explanation

> NOOP uses Bluetooth central background operation for best-effort wearable
> restoration and history transfer. It uses HealthKit background delivery for
> optional observer updates. Location background mode is active only while the
> user is recording a distance-based outdoor workout so the route can continue
> with the screen off; the route remains on device. Background App Refresh is
> used for best-effort refresh and a separately enabled local diagnostic export.
> iOS decides when background work runs, and NOOP does not promise continuous or
> exact-time delivery.

## Export compliance draft

Answer **Yes** to the top-level question asking whether the app uses, accesses,
contains, implements, or incorporates encryption. The binary uses Apple TLS,
CryptoKit/CommonCrypto AES-256-GCM and PBKDF2-HMAC-SHA256 for user-encrypted
backups/credential handling, SHA-256 identifiers, and standard AES used by an
optional wearable authentication protocol.

No proprietary or unpublished cryptographic algorithm was found. However, the
release owner must complete Apple's current decision tree for the intended
territories and obtain export/legal confirmation before claiming an exemption.
Leave `ITSAppUsesNonExemptEncryption` unset until that determination is written
down. If the approved determination is that all uses are exempt, the archive can
then set that key to `NO`; otherwise attach the documentation Apple requests.

## Age-rating draft

Use the current questionnaire, not a guessed numeric rating:

- Made for Kids: **No**. Parental controls: **No**. Age assurance: **No**.
- Unrestricted web access: **No**. The app opens fixed support/privacy/provider
  destinations and does not provide a general browser.
- User-Generated Content: **No** for the current private Friends summary lane;
  it does not broadly distribute posts, media, or text. Re-answer **Yes** if a
  public community/feed ships.
- Social media: **No**. Messaging and chat between users: **No**. Advertising:
  **No**.
- Health or Wellness Topics: **Yes**.
- Medical or Treatment Information: **Infrequent** is the conservative answer
  because the app includes wellness warning/explanation copy and tells users
  when professional care may be appropriate, while explicitly avoiding
  diagnosis or treatment. Choose **Frequent** only if the final binary adds
  ongoing medical-condition management or treatment guidance.
- Profanity/crude humor, horror/fear, alcohol/tobacco/drugs, sexual content or
  nudity, violence, gambling, simulated gambling, loot boxes, and contests:
  **None/No** in the audited binary.

Apple calculates the regional ratings from those answers. Do not override to a
lower rating. Because Health & Fitness is the primary category, complete the
regional regulated-medical-device declaration and answer that NOOP is **not a
regulated medical device** only while the binary and metadata remain explicitly
general-wellness, non-diagnostic, non-emergency, and non-treatment.

## Content-rights answer and release blocker

Answer that the app **does contain/show/access third-party content**: it imports
user-selected vendor export files, interoperates with third-party wearables,
and includes third-party dependencies and references. App Store Connect's
Content Rights certification must match the owner-controlled source declaration,
NOOP's project license, and the generated runtime dependency inventory. Both
legal gate modes must pass for the exact release commit before upload.

## Final archive checks still required

1. Archive the exact Release configuration, then inspect the Organizer privacy
   report, generated `Info.plist`, signed entitlements for all four targets, and
   embedded privacy manifests/dependency signatures.
2. Confirm `OURA_CLOUD_IMPORT` is absent (or redo this worksheet if enabled).
3. Capture a clean-install permission walk and denial/recovery path for Health,
   Bluetooth, motion, location, notifications, Live Activities, and local
   network access.
4. Physically verify background Bluetooth restoration, Health observer delivery,
   route continuation/stop, and both BG task registration paths. Background
   delivery remains best effort even after a passing test.
5. Re-run the distribution legal gate for the exact archive commit.

## Apple sources

- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [App Privacy Details and data definitions](https://developer.apple.com/app-store/app-privacy-details/)
- [Required-reason APIs](https://developer.apple.com/documentation/BundleResources/describing-use-of-required-reason-api)
- [Export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Age-rating values and definitions](https://developer.apple.com/help/app-store-connect/reference/app-information/age-ratings-values-and-definitions/)
- [App information, content rights, and medical declaration](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
