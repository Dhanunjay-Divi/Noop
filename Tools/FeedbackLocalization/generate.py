#!/usr/bin/env python3
"""Generate Apple app-report strings from the nine Android locale resources."""

from __future__ import annotations

import argparse
import json
import re
import sys
import xml.etree.ElementTree as ET
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
CATALOG = ROOT / "Strand/Resources/Localizable.xcstrings"
LOCALE_FILES = {
    "en": "values",
    "de": "values-de",
    "es": "values-es",
    "fr": "values-fr",
    "it": "values-it",
    "pt-PT": "values-pt-rPT",
    "ru": "values-ru",
    "zh-Hans": "values-zh",
    "zh-Hant": "values-zh-rTW",
}
KEY_PREFIX = "app_report_"
CATALOG_MARKER = '\n  },\n  "version":'


def android_strings(directory: str) -> dict[str, str]:
    path = ROOT / "android/app/src/main/res" / directory / "strings.xml"
    root = ET.parse(path).getroot()
    return {
        node.attrib["name"]: "".join(node.itertext())
        for node in root.findall("string")
        if node.attrib.get("name", "").startswith(KEY_PREFIX)
    }


def apple_format(value: str) -> str:
    return re.sub(r"%(\d+)\$s", r"%\1$@", re.sub(r"%(\d+)\$d", r"%\1$lld", value))


def expected_entries() -> dict[str, dict[str, object]]:
    localized = {
        locale: android_strings(directory)
        for locale, directory in LOCALE_FILES.items()
    }
    source_keys = set(localized["en"])
    if not source_keys:
        raise RuntimeError("No app-report strings were found in Android resources")
    for locale, values in localized.items():
        actual = set(values)
        if actual != source_keys:
            missing = sorted(source_keys - actual)
            extra = sorted(actual - source_keys)
            raise RuntimeError(
                f"{locale}: app-report key mismatch; missing={missing}, extra={extra}"
            )

    return {
        key: {
            "localizations": {
                locale: {
                    "stringUnit": {
                        "state": "translated",
                        "value": apple_format(values[key]),
                    }
                }
                for locale, values in localized.items()
            }
        }
        for key in sorted(source_keys)
    }


def verify(entries: dict[str, dict[str, object]]) -> list[str]:
    catalog = json.loads(CATALOG.read_text(encoding="utf-8"))
    actual = catalog.get("strings", {})
    failures: list[str] = []
    for key, expected in entries.items():
        if actual.get(key) != expected:
            failures.append(key)
    return failures


def write(entries: dict[str, dict[str, object]]) -> None:
    catalog = CATALOG.read_text(encoding="utf-8")
    catalog = "".join(
        line
        for line in catalog.splitlines(keepends=True)
        if not re.match(rf'^\s+"{re.escape(KEY_PREFIX)}[^"]+":', line)
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
        for key, value in entries.items()
    )
    CATALOG.write_text(
        f"{head},\n{rendered}{CATALOG_MARKER}{tail}",
        encoding="utf-8",
    )


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--check",
        action="store_true",
        help="verify Android locale parity and the generated Apple catalog entries",
    )
    args = parser.parse_args()

    try:
        entries = expected_entries()
        if args.check:
            failures = verify(entries)
            if failures:
                print(
                    "Apple app-report localization is stale for: "
                    + ", ".join(failures),
                    file=sys.stderr,
                )
                return 1
            print(
                f"Verified {len(entries)} app-report strings across "
                f"{len(LOCALE_FILES)} locales."
            )
            return 0
        write(entries)
        print(
            f"Generated {len(entries)} Apple app-report strings from "
            f"{len(LOCALE_FILES)} Android locales."
        )
        return 0
    except (OSError, RuntimeError, ET.ParseError, json.JSONDecodeError) as error:
        print(f"feedback localization failed: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
