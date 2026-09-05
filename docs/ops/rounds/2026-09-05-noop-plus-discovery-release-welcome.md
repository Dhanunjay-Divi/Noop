# Round: 2026-09-05 - NOOP+ discovery and release welcome

## Status

- State: `implemented and locally verified; managed enrollment remains unavailable`
- Owner: project team
- Branch: `main`
- Start commit: `b7f609ea`
- End implementation commit: commit containing this record

## Objective

Make NOOP+ unmissable on iPhone and Android without implying that the managed
GCP service is live. Ship the change with a clear version welcome, permanent
update history, matched first-install behavior, focused regression coverage,
and honest account-free product boundaries.

## Scope

### In scope

- An always-visible NOOP+ entry at the top of More on both phone platforms.
- A conventional NOOP+ row under Data and a dedicated destination.
- Explicit unavailable-state copy when managed configuration is absent.
- A scrollable version welcome with Skip and OK actions.
- A one-time, reduced-motion-aware first-install edge treatment.
- Permanent update history under More and a v9.2.1 release record.
- Version, localization, policy, visual, build, and navigation verification.

### Non-goals

- Enable GCP identity, public ingress, OTP delivery, or real health-data upload.
- Make an account mandatory or restrict metrics, coaching, workouts, journal,
  automations, local backup, or export.
- Claim physical-device, background-sync, BLE, or managed-cloud behavior from
  simulator and emulator evidence.

## Starting evidence

- NOOP+ was reachable only through the collapsed Backup & Sync path.
- The Apple card was omitted when managed-cloud configuration was unavailable,
  making a correctly disconnected build look as though NOOP+ did not exist.
- The current `origin/main` build did not contain the pending discovery UI.
- Managed GCP enrollment remained blocked by unaccepted Firebase terms and
  intentionally disabled public runtime invocation.

## Delivered

- Added a prominent NOOP+ banner before Quick Access on iPhone and Android.
  Its description wraps instead of truncating and states that core NOOP remains
  available without an account.
- Added dedicated NOOP+ rows under Data, typed `noop_plus` routes, and dedicated
  destinations on both platforms.
- Kept the managed-storage card visible when configuration is absent. The
  destination now explains that local NOOP and folder backup continue to work
  instead of exposing a setup action that cannot succeed.
- Added deterministic debug routes for the More, NOOP+, release-welcome, and
  update-history surfaces.
- Added a version welcome after onboarding or a genuinely newer update. It
  presents only the current release, supports Skip, OK, swipe/back dismissal,
  and persists acknowledgement without replaying after a downgrade.
- Added a restrained first-install-only edge glow that becomes static for
  reduced motion or battery saving. Existing installations migrate without
  receiving a false first-install treatment.
- Added More -> Updates for the complete newest-first history and generated the
  matching v9.2.1 Apple and Android changelog entries.
- Corrected the Apple primary action contrast and localized the managed-service
  unavailable message across all supported Apple locales.
- Advanced Apple to `9.2.1 (231)` and Android to `9.2.1 (304)`.

## Data, privacy, and medical truth

- Schema or migration impact: none.
- Existing-data retention impact: none.
- Source/provenance or metric-formula impact: none.
- Permissions/network disclosure impact: none. Empty managed configuration
  remains fail-closed and performs no managed upload.
- Health/medical claim impact and limitations: none. This is discovery,
  release communication, and storage-boundary UI.

## Evidence

| Evidence | Result | What it proves | What it does not prove |
|---|---|---|---|
| Apple focused clean test action | 17/17 passed | First-install state and NOOP+ discovery/unavailable contracts compile and pass | Signed iPhone or cloud behavior |
| Android focused unit tests | Passed for release-welcome state and primary-navigation contracts | Android version gating and the permanent `noop_plus` route are pinned | OEM runtime behavior |
| Full Android Debug APK | Built successfully | The complete Full flavor packages with the change | Play signing or physical-device behavior |
| Full iOS simulator graph | Passed for the app, Watch, complications, and widgets before the final catalog-only fix; the final clean shared-app test build compiled the edited catalog | The production target graph and final String Catalog accept the source | App Store signing or physical background behavior |
| iPhone and Android visual captures | NOOP+ appears first in More; dedicated destination and unavailable copy render; Apple welcome OK contrast is clear | The intended phone layouts render without expanding Data | Accessibility review on every device size or physical interaction |
| Strict localization audit | Passed after adding the missing Apple unavailable-state translation | No new raw UI literal or focus-locale coverage regression remains | Native-speaker review |
| Health claims, legal, and private-filename gates | Passed; 1,168 files scanned and 213 runtime components plus three container inputs verified | The release copy and dependency/provenance records satisfy current automated gates | Clinical, legal, or security certification |
| Version and changelog parity | Apple and Android report `9.2.1`; release manifest and both in-app changelogs match | Users receive one coherent release identity | Store publication |
| `git diff --check` | Passed | The final source delta is whitespace-clean | Runtime correctness |

## Physical device and deployment

- Install/update action: installed the rebuilt debug app on an iPhone simulator;
  the Android Full Debug APK was built and exercised on an emulator.
- Generalized device and OS class: current iPhone simulator and API-35 Android
  emulator.
- Data-preservation result: no physical app container or user health database
  was modified.
- BLE/background/haptic/battery scenarios exercised: none.
- Unrun hardware gates: in-place signed upgrades, accessibility interaction,
  OTP enrollment, background managed sync, restore, and storage-pressure
  behavior on physical iPhone and Android devices.

## Git and release state

- Changed paths: Apple and Android More/navigation, managed-storage card UI,
  release-welcome state and presentation, changelogs, localized resources,
  focused tests, version files, release notes, and this operations record.
- Branch and remote state at start: `main` matched `origin/main` at
  `b7f609ea`.
- Version/build impact: Apple `9.2.1 (231)`; Android `9.2.1 (304)`.
- Release or distribution impact: source and debug artifacts only. No signed
  store artifact or public managed runtime is claimed.

## Decisions

- NOOP+ discovery is independent of runtime availability. A disconnected build
  must show the feature and explain why enrollment is unavailable.
- Core NOOP remains account-free; only managed storage and multi-device restore
  belong to NOOP+.
- A release welcome is acknowledged on any intentional dismissal, while the
  full history remains permanently reachable under More.
- No durable architecture decision changed, so `DECISIONS.md` needs no entry.

## Open risks and honest limitations

- NOOP+ setup cannot complete until the account holder accepts Firebase terms,
  identity/App Check are applied, the private runtime is deployed and tested,
  and public invocation is deliberately enabled.
- A visible NOOP+ entry does not prove OTP, upload, restore, retention, erasure,
  isolation, or multi-device behavior against live GCP.
- Simulator and emulator captures do not validate signed upgrades, physical
  accessibility, background execution, BLE continuity, or storage pressure.
- The release welcome contains localized framing text, but the detailed
  changelog prose remains subject to the project's existing localization debt
  and native-speaker review.

## Next round

1. Accept Firebase terms in the authenticated GCP owner account.
2. Regenerate the zero-destroy identity plan, apply identity and App Check, and
   keep all test data synthetic.
3. Deploy the reviewed managed runtime IAM-only, run Cloud SQL migrations
   through `024`, and prove upload, duplicate, restore, isolation, retention,
   erasure, and recovery before public invocation.
4. Install v9.2.1 in place on physical iPhone and Android devices and verify
   More, NOOP+, update acknowledgement, accessibility, and local-data
   preservation.
5. Produce signed distribution artifacts only after the existing release,
   privacy, security, and physical-device gates pass.

## Privacy check

- [x] No credentials, account identifiers, raw biometric data, personal names,
      device identifiers, signing identities, or absolute personal paths are
      present.
