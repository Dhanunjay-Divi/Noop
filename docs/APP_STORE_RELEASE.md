# App Store release gate

This is the authoritative checklist for the first public NOOP iOS submission.
Passing a compile, installing a development build, or owning a paid Apple
Developer membership does not by itself authorize an upload.

## Fixed product identity

- Scheme: `NOOPiOS`
- Release product: `NOOP.app`
- iOS bundle identifier: the existing configured `$(BUNDLE_ID_PREFIX).noop`
- Embedded bundle identifiers: `.noop.widgets`, `.noop.watch`, and
  `.noop.watch.complications` under the same prefix
- Shared App Group: the existing configured `$(APP_GROUP_ID)`
- Minimum versions: iOS 17 and watchOS 10

Do not change the prefix, bundle identifiers, App Group, or signing team as a
routine release step. Those identities select the application and shared-data
containers. Back up and plan an explicit migration before any intentional
transition.

## Hard gates before archive

- [ ] `python3 Tools/release-legal-gate.py distribution` passes. This verifies
      the owner-rights record, NOOP license, and exact independent dependency
      notices; it does not replace signing, privacy, trademark, or store review.
- [ ] The paid organization/team—not a Personal Team—is selected for the iOS
      app, widget, Watch app, and complication.
- [ ] Apple Developer identifiers exist for all four bundle identifiers, with
      HealthKit and the shared App Group enabled where declared.
- [ ] An unexpired Apple Distribution identity and App Store profiles can be
      resolved by Xcode automatic signing for every embedded executable.
- [ ] The App Store Connect app record uses the exact iOS bundle identifier.
- [ ] The submitter has a sufficient App Store Connect role and all current
      agreements, tax, and banking actions required for this app are complete.
- [ ] The chosen marketing version is intentional for the first storefront
      release and the build number is unused and higher than every uploaded
      build for that version.
- [ ] The preview launch gate has a one-way verifier, preserves unlock state,
      and never commits or logs the plaintext credential.
- [ ] A reviewer credential and a deterministic review path are entered
      privately in App Review Information.
- [x] Public, unprotected policy endpoints are live at
      `https://noop-private-trial.usetaptech.chatgpt.site/privacy` and
      `https://noop-private-trial.usetaptech.chatgpt.site/support`. The
      password-protected preview landing page is not used for these fields.
- [ ] App Privacy, encryption/export-compliance, age-rating, content-rights,
      category, contact, copyright, and availability answers are complete.
- [ ] Final descriptions, keywords, release notes, screenshots, and review
      notes are approved. Draft copy lives under `AppStore/`.
- [ ] Every row and go/no-go item in
      [`AppStore/submission-readiness.md`](../AppStore/submission-readiness.md)
      has owner-approved evidence.
- [ ] Final iPhone, iPad, and Apple Watch PNGs match the submitted build and pass
      `Tools/prepare-appstore-screenshots.py` for their display class. Opaque
      legacy iPhone files under `marketing/screenshots/` remain provisional.

## Verification before upload

1. Regenerate the project and inspect the resolved Release settings without
   printing account, team, profile, device, or certificate identifiers:

   ```bash
   xcodegen generate
   xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
     -configuration Release -destination 'generic/platform=iOS' \
     -showBuildSettings
   ```

2. Run the repository release, privacy, localization, test, and distribution
   gates. Then archive with Xcode-managed signing. The path below is ignored by
   Git:

   ```bash
   xcodebuild -project Strand.xcodeproj -scheme NOOPiOS \
     -configuration Release -destination 'generic/platform=iOS' \
     -archivePath "$PWD/build/AppStore/NOOP.xcarchive" \
     -allowProvisioningUpdates archive
   ```

   `-allowProvisioningUpdates` may create/update Apple identifiers,
   certificates, and profiles. Run it only after the portal identities and
   capabilities above have been reviewed.

3. Verify the signed archive before upload:

   ```bash
   bash Tools/verify-ios-release-contract.sh \
     "$PWD/build/AppStore/NOOP.xcarchive/Products/Applications/NOOP.app" \
     /path/to/previous/NOOP.app
   ```

   Omit the previous-app argument only for the first production artifact. An
   existing development install still needs an in-place upgrade/data-continuity
   test before public release.

4. Validate in Organizer and on a physical iPhone/watch. Confirm launch-gate
   review access, upgrade retention, BLE/history sync, HealthKit permission,
   background restoration, widgets, Live Activity cleanup, Watch embedding,
   offline launch, export/backup, and the user-visible privacy disclosures.

## Upload command—run only after every gate is green

`Config/AppStoreExportOptions.plist` deliberately keeps the repository's build
number and asks Xcode to upload using automatic distribution signing:

```bash
xcodebuild -exportArchive \
  -archivePath "$PWD/build/AppStore/NOOP.xcarchive" \
  -exportOptionsPlist "$PWD/Config/AppStoreExportOptions.plist" \
  -exportPath "$PWD/build/AppStore/export" \
  -allowProvisioningUpdates
```

This command uploads because the export plist sets `destination` to `upload`.
Do not run it as a validation probe. Use Xcode Organizer's **Validate App**
action first when signing or App Store Connect state is new.

After upload, confirm processing, privacy-manifest results, embedded versions,
and App Store Connect warnings before attaching the build to a version. Upload
is not submission; submission is not approval; approval is not release when
manual release is selected.

## Current locally observed blockers (updated 2026-08-25)

- Xcode has an Apple account/team selection, but local files do not prove paid
  membership, App Store Connect role, agreements, or portal capability state.
- Only an Apple Development signing identity is locally available; no Apple
  Distribution identity or App Store provisioning profile is installed.
- The source-rights and dependency distribution gate now passes under the
  owner-controlled consolidation record. NOOP's PolyForm license and required
  independent dependency notices remain unchanged.
- App Store Connect name availability, app-record existence, build-number
  availability, and required listing-field configuration are not established
  locally. The required public privacy and support endpoints are live.
- The shipping Release build has no deterministic sample-data path for an App
  Reviewer who lacks supported wearable hardware; review notes/video alone may
  not remove this review risk. The safest disclosed design is specified in
  [`AppStore/submission-readiness.md`](../AppStore/submission-readiness.md), but
  it has not been implemented.
- Current repository media covers only the iPhone 6.9-inch class. The iOS target
  declares iPad support and the project embeds a Watch app, so final 13-inch
  iPad and Apple Watch screenshot sets are still required.
