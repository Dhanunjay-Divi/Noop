# App Review notes template

Complete these fields directly in App Store Connect. Do not place the actual
preview password, reviewer contact details, Apple identifiers, or credentials in
this repository.

## Review access

- State that this build is temporarily protected by a preview launch gate.
- Enter the review credential in **App Review Information**, not in Git, build
  logs, screenshots, or public metadata.
- Explain that the gate is a preview-access deterrent, not an account system or
  encryption boundary.
- Provide these exact steps: launch NOOP, enter the credential, tap **Explore
  Review Sample**, acknowledge the fictional-data disclosure, follow the paths
  below, then tap **Exit Review Sample**.
- Do not include those steps until the disclosed Review Sample Mode described in
  `submission-readiness.md` is implemented and verified in the uploaded Release
  build. Never use a hidden gesture, date, account, or reviewer-only server flag.

## Core behavior

- NOOP has no required account and stores its primary database on device.
- Apple Health, Bluetooth, motion, location, notifications, AI Coach, and
  self-hosted sync are optional and permission/consent gated. Manual
  Oura/Fitbit/Garmin export-file imports run locally and do not contact those
  vendors' services.
- Do not claim Oura OAuth cloud import unless the submitted archive's resolved
  Release settings explicitly include `OURA_CLOUD_IMPORT` and the App Privacy
  answers and review notes have been updated for that network lane.
- List the exact hardware-independent navigation path:
  **Today → daily signal → metric detail**, **Trends → interval → metric**,
  **Sleep**, **Friends** (only if it ships), **More → Data Sources & Privacy**,
  and **More → Devices**.
- State that Review Sample Mode is clearly labeled, uses fictional wellness
  data, is isolated from the production database, and disables Bluetooth
  commands, Health writes, uploads, Friends/AI/provider calls, and notifications.
- Attach a current sanitized screen recording. A Debug-only data seeder is not
  available to App Review and is not an acceptable review path.

## Hardware and medical scope

- Identify compatible hardware generically and explain that unavailable sensor
  inputs remain unavailable rather than being fabricated.
- For optional WHOOP 5/MG validation, say that the strap may be bonded to one
  phone app at a time: release/unpair it from the official app, fully close that
  app, put the strap in pairing mode, then use **More → Devices → Add device →
  WHOOP 5.0 / MG → Scan**. Explain that this interrupts simultaneous use with
  the official app.
- State the exact hardware-tested capabilities. Live Heart Rate is not evidence
  of complete history sync or proprietary score parity.
- State that NOOP is a general wellness/fitness product, not a medical device,
  and does not provide emergency monitoring or diagnostic claims.
- Explain why Bluetooth and background modes are required, and that iOS controls
  background timing.

## Privacy and network behavior

- Core history is local by default; optional network destinations are initiated
  and configured by the user.
- Provide a public, unprotected privacy-policy URL and support URL. Do not use a
  password-protected landing page for those required documents.
- Ensure the App Privacy answers match the shipping binary and every enabled
  optional network lane.

## Paste-ready skeleton (use only after all bracketed gates pass)

> NOOP is a general wellness/fitness app. Its primary history is stored locally
> on the device, no NOOP account is required, and unavailable sensor values are
> not fabricated. It is not a medical device, diagnostic service, emergency
> monitor, or a source of proprietary WHOOP scores.
>
> Review access: launch the app and enter the credential in the Password field.
> This temporary preview gate is not an account or encryption boundary. [VERIFY
> THE PRIVATE CREDENTIAL IS PRESENT IN APP REVIEW INFORMATION.]
>
> Hardware-independent review: tap Explore Review Sample and acknowledge the
> clearly labeled fictional-data disclosure. Then inspect Today → daily signal
> → metric detail; Trends → interval → metric; Sleep; [Friends, IF SHIPPING];
> More → Data Sources & Privacy; and More → Devices. Tap Exit Review Sample when
> finished. Sample data is isolated and the mode disables Bluetooth commands,
> Health writes, uploads, Friends/AI/provider calls, and notifications. [USE
> THIS PARAGRAPH ONLY AFTER THE EXACT RELEASE BUILD PASSES THE SAMPLE-MODE
> SECURITY AND RESET TESTS.]
>
> Optional compatible-strap test: a WHOOP 5/MG may be bonded to one phone app at
> a time. Release/unpair it from the official app, fully close that app, put the
> strap in pairing mode, then open More → Devices → Add device → WHOOP 5.0 / MG
> → Scan. Open More → Live Heart Rate to start and stop the opt-in stream. This
> build has physically validated [LIST EXACT CAPABILITIES, DEVICE CLASS, AND OS;
> DO NOT INCLUDE AN IDENTIFIER]. Missing inputs remain unavailable, and we do
> not claim proprietary score parity.
>
> Bluetooth supports opt-in live data and best-effort history/restoration.
> HealthKit access is optional and permission gated. iOS controls background
> scheduling, so delivery is not guaranteed. A sanitized current-build video is
> available at [PRIVATE REVIEW URL].
