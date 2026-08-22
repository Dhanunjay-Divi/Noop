# Active NOOP Handoff

Last updated: **2026-08-22**

## Repository state

- Repository visibility: private at the time of the last verified push.
- Active branch: `codex/day4-sync-performance`.
- Last implementation commit: `241f2000` (`Improve metric truth and Live Activity reliability`).
- Version line inherited from the integration branch: NOOP 9.2.0.
- Public distribution is not cleared: the distribution legal gate still flags
  inherited WHOOP 4 expression without an explicit software license.

## Last completed implementation evidence

- Today/detail metric resolution preserves source truth and measured-versus-
  estimated distinctions.
- Live Activity selection and reconciliation are deterministic, freshness
  bounded, and duplicate aware.
- Focused tests passed 21/21, the unsigned generic iOS Simulator build passed,
  and the i18n/private-data checks passed for commit `241f2000`.
- Those results do **not** prove overnight BLE continuity, a Day-4 history
  offload, scroll performance on a physical phone, or metric parity with a
  proprietary vendor model.

## Next priority round

An App Store public-submission round is active. It must first verify the paid
Apple team and App Store Connect role, add a non-plaintext launch gate, preserve
the existing app container, and clear every signing, privacy, build, review, and
distribution legal gate before upload or public release.

After that release preflight, the next engineering round must diagnose the
user-reported physical-iPhone state rather than infer a cause from the
screenshot:

1. **Day-4 sync/calibration:** recovery remains at 3/4 nights. Capture freshness,
   history-clock/range, offload lane, rejected rows, selected-day completeness,
   and score-input coverage without deleting the local database.
2. **Scrolling lag:** profile a release-like physical-device build, separate
   database/query cost from SwiftUI rendering and animation cost, and fix only
   measured hot paths.
3. **Capability gaps:** refresh the competitor audit from current official
   sources, then classify each gap as shippable, input-limited, validation-
   limited, regulated, or impossible to promise. Do not add a metric merely to
   fill a card.

## Handoff constraints

- Preserve the app's existing bundle identity and install upgrades in place.
  Do not uninstall as an update step when local data must survive.
- Back up before schema, container, import, or destructive device work.
- Keep the official WHOOP app available for firmware, account, servicing, and
  regulated MG features; BLE coexistence is not guaranteed.
- Simulator and synthetic tests are necessary but not sufficient for BLE,
  sleep, background, haptic, battery, or activity-detection claims.
- Keep the private branch private and do not treat a private/dev build as public
  distribution approval.
