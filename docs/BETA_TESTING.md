# NOOP public beta testing

NOOP's beta program is for people who want to test the app with hardware and
data they own, compare its results with another app or wearable, and report
useful differences without publishing private health data.

NOOP is not affiliated with WHOOP and is not a medical device. A difference
between two apps does not by itself mean that either result is wrong: devices
can use different sensors, sampling windows, baselines, day boundaries, and
proprietary models.

## Install a build

Use only artifacts hosted by the
[Dhanunjay-Divi/Noop releases page](https://github.com/Dhanunjay-Divi/Noop/releases).
Check the release notes and filename before installing.

| Platform | Artifact | Installation |
|---|---|---|
| Android | `NOOP-android-*.apk` | Download on the phone, allow installation from the browser or file manager for this install, then open the APK. A staging build uses a separate app identity and can be installed beside another NOOP build. |
| macOS | `NOOP-macos-*.zip` | Download, unzip, move NOOP to Applications, then right-click it and choose **Open** the first time. Community builds are ad-hoc signed and are not notarized. |
| iPhone | `NOOP-ios-unsigned-*.ipa` | This is an unsigned community build. Add NOOP's AltStore/SideStore source for convenient installs and updates, or re-sign the IPA with another sideloading tool. A normal App Store-style beta will require a separately signed TestFlight build. |

The fixed version tags are stable releases. When present, `testing-latest` is a
rolling prerelease for testers. It is replaced in place, may contain unfinished
work, and should not be treated as a backup of your data.

For AltStore or SideStore, add this source URL:

```text
https://raw.githubusercontent.com/Dhanunjay-Divi/Noop/main/altstore-source.json
```

See the [iPhone installation guide](IOS.md) for the exact setup and the
limitations of free Apple-ID signing.

Source builds remain the most auditable option. See [BUILD.md](BUILD.md) and
[IOS.md](IOS.md).

## Compare results fairly

1. Record the NOOP version, phone/OS, wearable model, firmware if known, wear
   location, and reference app version.
2. Keep device source and wear location consistent for the comparison.
3. Import your own official WHOOP export in **Data Sources** if WHOOP is the
   reference. Never give NOOP or a tester your WHOOP password.
4. Let NOOP independently compute the same calendar days from its supported
   input. Imported official scores remain reference-only and are not fed into
   NOOP's raw formulas.
5. In the iPhone or Mac app, open **Compare → Official reference** and select
   Charge, Effort, or Rest. Android currently supports general metric overlays
   and correlations, but its provenance-gated official-reference card has not
   been ported yet.
6. Use at least seven paired days for an early observation. Twenty-eight or more
   paired days is much more useful; personal presentation calibration also
   reserves untouched chronological holdout days.
7. Report the paired-day count, comparison-window length, bias, MAE, RMSE, and
   correlation shown by NOOP. Correlation describes co-movement, not agreement.
   Also describe any relevant context, such as a source change, travel, illness,
   unusually loose wear, or missing nights.

WHOOP 5.0 and MG may pair with only one app at a time. If the official WHOOP app
prevents NOOP from connecting, finish its sync, fully close it, and follow the
pairing guidance shown by NOOP. Do not repeatedly re-pair a device merely to
produce a missing metric. If a source did not measure a metric, report it as
unavailable rather than substituting another value.

## Report a difference

Use the
[metric difference form](https://github.com/Dhanunjay-Divi/Noop/issues/new?template=metric_difference.yml)
for a NOOP-versus-WHOOP or cross-device comparison.

For connection, import, crash, or missing-data bugs, use **Settings → Test
Centre → Report**. NOOP creates a redacted diagnostic bundle, asks you to review
it, and opens a prefilled bug report.

Include:

- the two sources being compared;
- exact metric and units;
- comparison-window length and number of same-day pairs;
- the aggregate statistics shown in Compare;
- the NOOP algorithm and importer revisions shown in the reference card;
- what you expected and what you observed; and
- screenshots only after cropping names, notifications, and unrelated health
  details.

Never attach:

- a WHOOP, Apple Health, Fitbit, Garmin, or other raw account export;
- an account email, password, API key, access token, or server URL containing a
  secret;
- a full database or `.noopbak` backup;
- an unreviewed Bluetooth capture or log; or
- another person's data.

If maintainers need a narrowly scoped diagnostic after reviewing the issue,
they will ask for it explicitly. The default report should contain aggregate
comparison values, not raw health rows, exact dates, daily pairs, or personal
mean values. Remember that a GitHub issue is public.

## What makes a useful result

A useful report distinguishes these cases:

- **Unavailable:** the device or source did not measure the input.
- **Pending:** the source has not finished processing or calibration.
- **Different definition:** both values are valid but use different windows,
  units, day ownership, or algorithms.
- **Likely app defect:** the same underlying input was decoded, mapped, or
  calculated inconsistently.

NOOP should never fabricate a vendor metric. Any NOOP-derived estimate must be
named as a NOOP estimate, list its required inputs, and remain unavailable when
those inputs are insufficient.
