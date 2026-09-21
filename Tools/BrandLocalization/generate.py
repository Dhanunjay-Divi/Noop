#!/usr/bin/env python3
"""Reuse complete pre-rename translations for current Noop Band UI copy."""

from __future__ import annotations

import argparse
import copy
import json
import re
import sys
from pathlib import Path


ROOT = Path(__file__).resolve().parents[2]
DEFAULT_CATALOG = ROOT / "Strand/Resources/Localizable.xcstrings"
DEFAULT_BASELINE = ROOT / "Tools/i18n_audit_baseline.json"
CATALOG_MARKER = '\n  },\n  "version":'
REQUIRED_LOCALES = (
    "de",
    "es",
    "fr",
    "it",
    "pt-PT",
    "ru",
    "zh-Hans",
    "zh-Hant",
)

# Each current English key keeps the shipped wording while reusing the complete
# locale values from its semantically equivalent pre-rename predecessor. Known
# bad or English-copy predecessor values stay visible for locale-owner review.
MAPPINGS = {
    "Noop Band not connected": "Strap not connected",
    "Connect Noop Band to see live heart rate":
        "Connect your strap to see live heart rate",
    "When the system prompt appears, choose Allow so NOOP can find Noop Band.":
        "When the system prompt appears, choose Allow so NOOP can find your strap.",
    "Connect Noop Band for haptic guidance. You'll feel one pulse on the inhale and two on the exhale, so you can breathe with your eyes closed.":
        "Connect your strap for haptic guidance. You'll feel one pulse on the inhale, two on the exhale, so you can breathe with your eyes closed.",
    "No live heart rate yet. Open Live to pair Noop Band.":
        "No live heart rate yet. Open Live to pair your strap.",
    "A 60-second snapshot of beat-to-beat (R-R) intervals from Noop Band, cleaned with range and ectopic-beat filtering before computing RMSSD the same way your overnight HRV is computed.":
        "A 60-second snapshot of your beat-to-beat (R-R) intervals from the strap, cleaned (range and ectopic-beat filtering) before computing RMSSD the same way your overnight HRV is computed.",
    "An HRV reading needs the live R-R stream. Open the Live screen and connect Noop Band, then come back.":
        "An HRV reading needs the live R-R stream. Open the Live screen and connect your strap, then come back.",
    "NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from Noop Band.":
        "NOOP never shows you a number it had to make up. If a score isn't ready, it tells you why and what to do next. Everything here runs on your device, from your strap.",
    "Pair Noop Band on the Live screen to feel the transitions hands-free.":
        "Bond your strap on the Live screen to feel the transitions hands-free.",
    "Can't connect: Noop Band pairing was reset":
        "Can't connect: your strap's pairing was reset",
    "Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery because Noop Band streams heart rate continuously while connected.":
        "Keeps the detailed beat-to-beat heart-rate stream running all day and night, not just while a live screen is open, so NOOP captures much more for overnight HRV, recovery and sleep. Uses more battery: your strap streams heart rate continuously while connected.",
    "Noop Band accepted all 15 R22 flags":
        "Strap accepted all 15 R22 flags",
    "No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside Noop Band, they'll appear here so you can see how close the estimate is.":
        "No days yet where both NOOP and your phone counted steps. Once your phone logs a few days alongside the strap, they'll appear here so you can see how close the estimate is.",
    "The Noop Band alarm is a silent vibration, not a sound":
        "The strap alarm is a silent buzz, not a sound",
    "Use Noop Band alarm time": "Use strap alarm time",
}

LOCALE_OWNER_REVIEW = {
    "Noop Band battery":
        "The inherited pt-PT value uses the wrong device noun.",
    "Not enough clean beat data to lock a pace today. Try again rested, sitting still with Noop Band snug. For now we'll pace you at 5.5 br/min (coherence).":
        "Health-adjacent pacing copy includes a bad inherited pt-PT device noun.",
    "Connect Noop Band for the felt cue. The sweep paces you with one vibration on the inhale and two on the exhale.":
        "The inherited pt-PT value mistranslates both device and felt cue.",
    "Noop Band vibrates a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it and stops on its own.":
        "Health-adjacent wording needs owner review; the inherited pt-PT meaning drifts.",
    "Connect Noop Band. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.":
        "The inherited pt-PT value changes bonded connection to strong connection.",
    "Connect a Noop Band, Apple Watch, heart-rate strap, ring, or supported gym machine. NOOP will show only the signals that device actually provides.":
        "All inherited locale values are copies of the English source.",
    "No nights with sleep data yet. Your ledger fills in as you wear Noop Band to bed.":
        "The inherited pt-PT value uses the wrong device noun.",
    "Buzz Noop Band or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap automation. No setup needed.":
        "The inherited pt-PT value says tap the band instead of making it vibrate.",
    "Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz Noop Band.":
        "The inherited pt-PT value changes vibration to moving a handle.",
}

LOCALE_OWNER_REVIEW_PATHS = {
    "Noop Band battery": "Strand/Liquid/LiquidTodayView.swift",
    "Not enough clean beat data to lock a pace today. Try again rested, sitting still with Noop Band snug. For now we'll pace you at 5.5 br/min (coherence).":
        "Strand/Screens/BreathingView.swift",
    "Connect Noop Band for the felt cue. The sweep paces you with one vibration on the inhale and two on the exhale.":
        "Strand/Screens/BreathingView.swift",
    "Noop Band vibrates a gentle rhythm just below your current heart rate, a felt metronome to relax toward. It trails your heart down rather than yanking it and stops on its own.":
        "Strand/Screens/BreathingView.swift",
    "Connect Noop Band. Calm me is a felt rhythm on the wrist, so it needs a bonded connection.":
        "Strand/Screens/BreathingView.swift",
    "Connect a Noop Band, Apple Watch, heart-rate strap, ring, or supported gym machine. NOOP will show only the signals that device actually provides.":
        "Strand/Screens/DevicesView.swift",
    "No nights with sleep data yet. Your ledger fills in as you wear Noop Band to bed.":
        "Strand/Screens/SleepView.swift",
    "Buzz Noop Band or mark a moment from Siri, Spotlight, the Shortcuts app, or a Back-Tap automation. No setup needed.":
        "StrandiOS/App/SiriShortcutsSettingsView.swift",
    "Wire NOOP's actions into a Back-Tap, a focus automation, or a longer Shortcut. For example, double-tap the back of your iPhone to buzz Noop Band.":
        "StrandiOS/App/SiriShortcutsSettingsView.swift",
}

MANAGED_KEYS = set(MAPPINGS) | set(LOCALE_OWNER_REVIEW)

ANDROID_FIXED_LITERALS = {
    (
        "android/app/src/main/java/com/noop/ui/SettingsScreen.kt",
        "✓ Noop Band accepted all 15 R22 flags",
    ),
}


def load_json(path: Path) -> dict:
    return json.loads(path.read_text(encoding="utf-8"))


def expected_entries(catalog: dict) -> dict[str, dict]:
    strings = catalog.get("strings", {})
    expected: dict[str, dict] = {}
    for current, predecessor in MAPPINGS.items():
        source = strings.get(predecessor)
        if not isinstance(source, dict):
            raise RuntimeError(f"Missing predecessor catalog key: {predecessor}")
        source_localizations = source.get("localizations", {})
        localizations = {}
        for locale in REQUIRED_LOCALES:
            localized = source_localizations.get(locale)
            unit = (localized or {}).get("stringUnit", {})
            if unit.get("state") != "translated" or not unit.get("value"):
                raise RuntimeError(
                    f"{predecessor}: missing complete {locale} translation"
                )
            if unit["value"] in {current, predecessor}:
                raise RuntimeError(
                    f"{predecessor}: {locale} is still an English source copy"
                )
            localizations[locale] = copy.deepcopy(localized)
        expected[current] = {
            "comment": (
                "Reuses complete pre-rename locale values; "
                "the English source key keeps current Noop Band wording."
            ),
            "localizations": localizations,
        }
    return expected


def verify_catalog(catalog: dict, expected: dict[str, dict]) -> list[str]:
    strings = catalog.get("strings", {})
    return [
        key
        for key, value in expected.items()
        if strings.get(key) != value
    ]


def write_catalog(path: Path, expected: dict[str, dict]) -> None:
    catalog = path.read_text(encoding="utf-8")
    patterns = [
        re.compile(
            rf"^\s*{re.escape(json.dumps(key, ensure_ascii=False))}\s*:"
        )
        for key in MANAGED_KEYS
    ]
    catalog = "".join(
        line
        for line in catalog.splitlines(keepends=True)
        if not any(pattern.match(line) for pattern in patterns)
    )
    head, separator, tail = catalog.partition(CATALOG_MARKER)
    if not separator:
        raise RuntimeError("Could not find String Catalog closing marker")
    head = head.rstrip()
    if head.endswith(","):
        head = head[:-1]
    rendered = ",\n".join(
        f"    {json.dumps(key, ensure_ascii=False)}: "
        f"{json.dumps(value, ensure_ascii=False, separators=(',', ': '))}"
        for key, value in sorted(expected.items())
    )
    path.write_text(
        f"{head},\n{rendered}{CATALOG_MARKER}{tail}",
        encoding="utf-8",
    )


def filter_baseline(data: dict) -> tuple[dict, int, int, int]:
    result = copy.deepcopy(data)
    ios_before = result.get("ios", [])
    existing_ios = {tuple(row) for row in ios_before}
    restored = 0
    for literal, path in LOCALE_OWNER_REVIEW_PATHS.items():
        row = (path, literal)
        if row not in existing_ios:
            ios_before.append(list(row))
            existing_ios.add(row)
            restored += 1
    ios_before.sort(key=lambda row: tuple(row))
    android_before = result.get("android", [])
    result["ios"] = [
        row
        for row in ios_before
        if len(row) < 2 or row[1] not in MAPPINGS
    ]
    result["android"] = [
        row
        for row in android_before
        if len(row) < 2 or (row[0], row[1]) not in ANDROID_FIXED_LITERALS
    ]
    return (
        result,
        len(ios_before) - len(result["ios"]),
        len(android_before) - len(result["android"]),
        restored,
    )


def write_baseline(path: Path) -> tuple[int, int, int]:
    filtered, ios_removed, android_removed, restored = filter_baseline(
        load_json(path)
    )
    path.write_text(
        json.dumps(filtered, indent=2, ensure_ascii=False) + "\n",
        encoding="utf-8",
    )
    return ios_removed, android_removed, restored


def verify_baseline(data: dict) -> list[str]:
    failures = []
    for row in data.get("ios", []):
        if len(row) >= 2 and row[1] in MAPPINGS:
            failures.append(f"ios:{row[0]}:{row[1]}")
    for row in data.get("android", []):
        if len(row) >= 2 and (row[0], row[1]) in ANDROID_FIXED_LITERALS:
            failures.append(f"android:{row[0]}:{row[1]}")
    return failures


def verify_deferred_review(catalog: dict, baseline: dict) -> list[str]:
    strings = catalog.get("strings", {})
    baselined = {
        tuple(row)
        for row in baseline.get("ios", [])
        if len(row) >= 2
    }
    failures = []
    for key, path in LOCALE_OWNER_REVIEW_PATHS.items():
        if key in strings:
            failures.append(f"cataloged:{key}")
        if (path, key) not in baselined:
            failures.append(f"not-baselined:{path}:{key}")
    return failures


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--check", action="store_true")
    parser.add_argument("--catalog", type=Path, default=DEFAULT_CATALOG)
    parser.add_argument("--baseline", type=Path, default=DEFAULT_BASELINE)
    args = parser.parse_args()

    try:
        catalog = load_json(args.catalog)
        expected = expected_entries(catalog)
        if args.check:
            stale = verify_catalog(catalog, expected)
            baseline = load_json(args.baseline)
            baseline_failures = verify_baseline(baseline)
            deferred_failures = verify_deferred_review(catalog, baseline)
            if stale or baseline_failures or deferred_failures:
                if stale:
                    print(
                        "Brand localization catalog is stale for: "
                        + ", ".join(stale),
                        file=sys.stderr,
                    )
                if baseline_failures:
                    print(
                        "Localized brand literals remain baselined: "
                        + ", ".join(baseline_failures),
                        file=sys.stderr,
                    )
                if deferred_failures:
                    print(
                        "Locale-owner review boundary is stale: "
                        + ", ".join(deferred_failures),
                        file=sys.stderr,
                    )
                return 1
            print(
                f"Verified {len(expected)} Apple brand phrases across "
                f"{len(REQUIRED_LOCALES)} non-English locales."
            )
            return 0

        write_catalog(args.catalog, expected)
        ios_removed, android_removed, restored = write_baseline(args.baseline)
        print(
            f"Generated {len(expected)} Apple brand phrases; removed "
            f"{ios_removed} Apple and {android_removed} Android baseline entries; "
            f"restored {restored} deferred Apple review entries."
        )
        return 0
    except (OSError, RuntimeError, json.JSONDecodeError) as error:
        print(f"brand localization failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
