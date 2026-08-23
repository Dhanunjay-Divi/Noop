# App Store metadata

This directory holds reviewable, non-secret draft metadata for NOOP's first App
Store Connect submission. It is not an upload credential store.

- `metadata/en-US/` contains the English storefront copy.
- `review-notes-template.md` is a checklist/template. Paste the actual review
  credential directly into App Store Connect; never commit it here.
- `submission-readiness.md` is the field, media, and exact reviewer-path matrix.
- `privacy-and-compliance-draft.md` records the non-secret, binary-grounded App
  Privacy, entitlement/background-mode, export-compliance, age-rating, and
  content-rights answers for the release owner to verify in App Store Connect.
- `Tools/prepare-appstore-screenshots.py` validates Apple display dimensions
  and rejects PNG alpha; `--fix` can flatten a reviewed RGBA PNG without
  resizing it.
- Final screenshots, contact details, Apple account identifiers, signing keys,
  API keys, profile UUIDs, and provider identifiers stay outside Git. Existing
  files under `marketing/screenshots/` are provisional and must be recaptured
  from the exact release candidate.

The release owner must confirm field lengths and final wording in App Store
Connect. Store copy does not override the in-app wellness disclaimer or turn a
NOOP estimate into a medical measurement.
