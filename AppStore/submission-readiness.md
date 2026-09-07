# App Store submission and reviewer-readiness matrix

This document is the release-owner checklist for the first NOOP App Store
submission. It records what can be established from the repository and what
must still be completed in App Store Connect or on physical hardware. A green
row means the evidence exists; it does not replace Apple's validation or App
Review.

## Current disposition

**No-go for upload or submission.** The disclosed reviewer sample path is now
implemented in shipping source and passes focused simulator tests plus an iOS
Release-simulator build, but it has not yet been exercised in the exact signed
archive or entered in App Review Information. App Store Connect answers,
iPad/Watch media, distribution signing, and physical-device release validation
are also incomplete. The source-rights and dependency gate passes. The existing
iPhone screenshots have valid dimensions and are now opaque, but show an older
UI and are only provisional layout references.

## Submission matrix

| Area | Proposed submission value or action | Evidence / owner | Status |
|---|---|---|---|
| App identity | Keep the existing `NOOPiOS` product, bundle family, App Group, version, and upgrade path. | `docs/APP_STORE_RELEASE.md`; release owner verifies resolved Release settings. | Pending portal/signing verification |
| Primary category | **Health & Fitness**. Do not select Medical merely because health data is displayed. | Product owner confirms in App Store Connect. | Proposed |
| Secondary category | Leave blank initially, or use **Lifestyle** only if the final listing materially supports it. | Product owner. | Decision required |
| Privacy policy URL | `https://noop-private-trial.usetaptech.chatgpt.site/privacy` | Anonymous HTTP check from outside the signed-in browser and storefront review. | Live; reverify before submission |
| Support URL | `https://noop-private-trial.usetaptech.chatgpt.site/support` | Anonymous HTTP check and working support contact. | Live; reverify before submission |
| App Privacy | Use the conservative field-by-field draft in `privacy-and-compliance-draft.md`, then confirm it against the exact Organizer archive and enabled server/provider configuration. Do not select “Data Not Collected” while Friends or remote AI-provider lanes ship. | Privacy owner plus final archive privacy/network report. | Draft complete; final archive confirmation required |
| Encryption / export compliance | Complete Apple's questionnaire for the exact archive. The app contains CryptoKit/CommonCrypto uses for encrypted backups, credential protection, and optional integrations in addition to ordinary TLS. Do not add `ITSAppUsesNonExemptEncryption = NO` without a documented exemption determination. | Release owner with legal/export review. | Decision required |
| Age rating | Start from the binary-grounded answers in `privacy-and-compliance-draft.md`: not Kids, health/wellness present, infrequent medical/treatment information, no broad UGC/social/chat/ads/unrestricted browser. Re-answer if public community or treatment guidance ships. | Product and safety owners enter the current questionnaire. | Draft complete; portal entry pending |
| Medical / regulated-device declaration | Select “not a regulated medical device” only if final behavior and copy remain general wellness, non-diagnostic, and non-emergency. Do not claim ECG/AFib/BP diagnosis, clinical fall detection, treatment, or guaranteed alerts. | Medical/safety and legal owners review binary and metadata. | Confirmation required |
| Content rights | Keep the owner declaration, NOOP license, dependency inventory, and final asset/media review aligned with the submitted archive. | `python3 Tools/release-legal-gate.py distribution`, owner declaration, and final media review. | Source gate passed; final media review pending |
| Third-party marks and hardware imagery | Avoid WHOOP/Apple/vendor logos and product renders in storefront media unless use is authorized. Plain compatibility text must be accurate and non-affiliating. | Rights review of every final image and metadata field. | Pending final media |
| Availability | Start with a deliberate territory list and manual release. A US-only first review is the lowest-complexity proposal, not an automatic choice. Complete trader/DSA and local regulatory requirements for every selected territory. | Account holder in App Store Connect. | Decision required |
| Pricing | Product-owner decision. Password protection is not a substitute for a private distribution method after public release. | Account holder. | Decision required |
| Copyright | Use the current legal owner and year, not a repository handle. | Account holder/legal owner. | Value required |
| Review contact | Enter a monitored name, telephone number, and email directly in App Store Connect. | Release owner. | Value required |
| Review credential | Put the current launch-gate credential only in App Review Information. Never put it in Git, screenshots, metadata, or reviewer video. Explain that it is a temporary preview gate, not an account or security boundary. | Release owner. | Required at submission |
| Hardware requirements | Review must not depend solely on an Apple reviewer owning a compatible strap. Use the disclosed sample path below; add optional physical-device steps and video as supporting evidence. | Shipping source, focused simulator tests, and Release-simulator build; product/release owner verifies the signed archive and App Review record. | Source path complete; signed-archive evidence pending |
| Background modes | Bluetooth restoration/history sync, HealthKit delivery, manual outdoor-workout route continuation, and best-effort BG refresh/diagnostic export are mapped in `privacy-and-compliance-draft.md`. State that iOS schedules background execution and NOOP cannot guarantee continuous delivery. | Final signed entitlements and physical-device test evidence. | Source audit complete; archive/device validation pending |
| Health permissions | Explain each HealthKit read/write request in the review notes and purpose strings; verify the app remains useful when optional access is denied. | Final archive and privacy review. | Pending |
| Release control | Use manual release for the first version so approval cannot publish an unverified build automatically. | Account holder. | Recommended |

## Storefront media matrix

| Surface | Required source | Current state | Release action |
|---|---|---|---|
| iPhone 6.9-inch | 1–10 current in-app screenshots; accepted portrait sizes include 1260×2736, 1290×2796, and 1320×2868 (or landscape reverses). | Six 1320×2868 opaque PNGs. They show an older UI and are **not final**. | Recapture from the exact Release candidate, rerun the validator, and approve copy/rights/privacy. |
| iPad 13-inch | Required because the iOS target declares iPad support. Accepted portrait sizes include 2064×2752 and 2048×2732 (or reverses). | Missing. | Capture a tested 13-inch iPad layout, or intentionally remove iPad support in a separately reviewed product decision. |
| Apple Watch | Required for the embedded Watch app. Supported classes include 422×514, 410×502, 416×496, 396×484, 368×448, and 312×390; use one consistent size per localization. | Missing. | Capture the exact submitted Watch build on a supported size. |
| App preview | Optional storefront video and subject to Apple's app-preview rules. | Missing. | Do not block the first submission on it. A private review video is still strongly recommended for BLE setup. |
| Private reviewer video | Sanitized screen/device recording linked only in App Review Information. | Missing. | Record the storyboard below after final hardware testing. |

The provisional iPhone audit covers `noop-today.png`, `noop-trends.png`,
`noop-sleep.png`, `noop-friends.png`, `noop-fitness-age.png`, and
`noop-devices.png`. Each is 1320×2868, 8-bit, RGB, and non-interlaced after the
mechanical alpha fix. The visible content was not redesigned or approved by
this media-preparation round.

Apple permits PNG/JPEG/JPG screenshots but does not permit alpha/transparency.
Validate repository PNGs with:

```bash
python3 Tools/prepare-appstore-screenshots.py --target iphone-6.9 marketing/screenshots
python3 Tools/prepare-appstore-screenshots.py --target ipad-13 /path/to/ipad/screenshots
python3 Tools/prepare-appstore-screenshots.py --target watch /path/to/watch/screenshots
```

For a reviewed PNG that is visually correct but encoded as RGBA, flatten it
deterministically over its intended solid background:

```bash
python3 Tools/prepare-appstore-screenshots.py \
  --target iphone-6.9 --fix --background '#000000' /path/to/screenshots
```

The tool rejects unsupported dimensions and unsupported PNG encodings instead
of silently resizing or altering them.

### Final screenshot capture list

Use synthetic or fictional profiles and biometric values. Never publish a real
person's identifiers, export, medical information, device identifier, invite
code, or credential.

1. Today: Recovery, Effort, Sleep, freshness/source labels, and no duplicate
   metric.
2. Metric detail: today's value first, then clearly labeled baseline and
   7-/30-day comparisons.
3. Sleep: detected interval, quality/completeness, and unavailable-state truth.
4. Trends: selected interval, sample count, source, and confidence/freshness.
5. Data Sources & Privacy: local-first storage, permissions, exports, and
   optional network lanes.
6. Devices: accurate supported-device state without implying official vendor
   affiliation or unsupported WHOOP 5/MG parity.
7. Friends only if the release backend, consent, deletion, and privacy answers
   are production-ready.
8. Apple Watch: one genuinely useful watch surface from the submitted build.

Every image must show the current app, status bar, legible text, safe-area
layout, and truthful availability states. Remove debugging, `BETA`, calibration,
sample, or preview labels only when those states are genuinely absent in the
submitted build.

## Exact App Review path

### Preferred path: disclosed Review Sample Mode

This is the safest reviewer option because Apple cannot be expected to own a
compatible wearable or existing biometric history. It is implemented in the
shipping source as a disclosed first-run choice after launch access, not behind
an undocumented gesture, date, account, or reviewer-only server flag. The exact
signed archive still must repeat this journey before submission.

Before submission, repeat the clearly labeled **Review Sample Mode** journey in
the exact signed Release archive, then give Apple this path:

1. Install and launch NOOP.
2. Enter the credential supplied privately in **App Review Information**.
3. On the welcome/reviewer screen, tap **Explore Review Sample**.
4. Read the disclosure: “Fictional sample wellness data; no sensor or medical
   reading is being taken.”
5. Navigate **Today → each daily signal → metric detail** to see today first,
   then baseline and comparisons.
6. Navigate **Trends**, change the interval, and open a metric.
7. Navigate **Workouts** and inspect the fictional session.
8. Navigate **Sleep** and inspect the fictional interval, stages, and wake
   events.
9. Navigate **Friends** only if it ships; the sample does not contact or expose
   real people.
10. Navigate **More → Data Sources & Privacy** to inspect optional permissions,
   local storage, export, and deletion controls.
11. Navigate **More → Devices** to see the no-hardware state and compatibility
    disclosure.
12. Tap **Exit Review Sample** to discard the process-only fictional view tree
    and continue into the normal Terms/setup journey.

The current sample path is a deterministic in-memory presentation tree. It
does not write sample values to Apple Health or the production database and
does not invoke BLE commands, uploads, Friends network calls, AI/provider
calls, notifications, or emergency/medical behavior. The UI remains visibly
labeled while sample data is active. Android additionally defers its
operational Room/BLE/cloud/worker runtime until current Terms are accepted and
uses lazy WorkManager initialization instead of the pre-application AndroidX
Startup initializer. Apple constructs its normal inert bootstrap objects at
process launch but does not start operational work or pass sample values into
them. App Review notes must disclose the mode and its exact controls.

### Optional compatible WHOOP 5/MG hardware path

Use this only as supporting evidence, not as the sole review path. WHOOP 5/MG
support remains experimental beyond the physically validated capabilities.

1. Use a compatible iPhone running iOS 17 or later with Bluetooth enabled.
2. Charge the strap and put it into pairing mode.
3. A WHOOP 5/MG strap can be bonded to one phone app at a time. If it is already
   bonded to the official WHOOP app, release/unpair it there and fully close that
   app. This interrupts simultaneous official-app use.
4. In NOOP, open **More → Devices → Add device → WHOOP 5.0 / MG → Scan**.
5. Select the nearby strap and accept the iOS Bluetooth/pairing prompts.
6. Verify the displayed model/device identifier and firmware before relying on
   the connection label.
7. Open **More → Live Heart Rate**, opt in, and confirm the current heart-rate
   stream. Stop the live session when finished.
8. State exactly which history/sensor inputs were validated on the hardware.
   Missing inputs must remain unavailable; do not imply proprietary WHOOP score
   parity.

### Private reviewer-video storyboard

Record the exact release candidate and include the version/build in the video
or accompanying note:

1. Fresh launch, launch-gate access, and the Review Sample disclosure.
2. Today, one metric detail with today/comparison hierarchy, Trends, Sleep, and
   the Data Sources & Privacy screen.
3. Exit the sample and show the normal Terms/setup journey; separately show the
   genuine empty/no-hardware state after setup if that state is part of the
   submitted reviewer video.
4. On a separate sanitized segment, show a compatible WHOOP 5/MG entering
   pairing mode, the NOOP connection path, verified model/firmware, Live Heart
   Rate start, current value, and stop.
5. Demonstrate that unavailable sensor inputs remain unavailable and that BLE
   or notification denial has a clear recovery path.

Blur device identifiers, names, contacts, notifications, credentials, Apple
account information, and real biometric history. Do not show another vendor's
app or copyrighted marketing assets unless use is authorized.

## Final go/no-go checklist

- [ ] `python3 Tools/release-legal-gate.py distribution` passes with reviewed
      evidence.
- [ ] Final archive is signed by the paid distribution team and validates in
      Organizer with every embedded target/profile/capability.
- [ ] In-place upgrade preserves the existing local database, settings,
      widgets, and shared App Group data.
- [ ] Review Sample Mode is disclosed, isolated, deterministic, and retested in
      the exact signed archive supplied to App Review. Shipping-source,
      simulator, and unsigned Release-simulator evidence is already complete.
- [ ] Exact App Privacy and export-compliance answers are approved for the
      uploaded binary.
- [ ] Age rating, medical declaration, categories, copyright, content rights,
      availability, review contact, and credential are complete.
- [ ] Privacy and support URLs work anonymously from an external network.
- [ ] Final iPhone, iPad, and Apple Watch screenshots pass the PNG validator and
      match the submitted UI.
- [ ] Final screenshots and video contain no real health data, identifiers,
      credentials, unauthorized marks, or unsupported claims.
- [ ] WHOOP 5/MG live and history behavior is retested on physical hardware and
      described without claiming full proprietary score parity.
- [ ] Bluetooth denial/recovery, HealthKit denial, offline launch, background
      restoration, export/backup, Live Activity cleanup, widgets, Watch
      embedding, and notification controls pass on production hardware.
- [ ] The first release is set to manual release and the final App Store Connect
      version is reviewed once more after build attachment.

## Apple references

- [App Review Guidelines](https://developer.apple.com/app-store/review/guidelines/)
- [Screenshot specifications](https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/)
- [App information reference](https://developer.apple.com/help/app-store-connect/reference/app-information/app-information)
- [Manage app privacy](https://developer.apple.com/help/app-store-connect/manage-app-information/manage-app-privacy)
- [Export compliance overview](https://developer.apple.com/help/app-store-connect/manage-app-information/overview-of-export-compliance)
- [Set an app age rating](https://developer.apple.com/help/app-store-connect/manage-app-information/set-an-app-age-rating/)
- [Set distribution methods](https://developer.apple.com/help/app-store-connect/manage-your-apps-availability/set-distribution-methods)
- [Submit an app](https://developer.apple.com/help/app-store-connect/manage-submissions-to-app-review/submit-an-app/)
