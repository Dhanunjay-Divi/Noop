#!/usr/bin/env python3
"""Prepare wearable CSV exports for WhoopExportRecoveryComparisonTests.

The self-service export contains `physiological_cycles.csv` with the reference Recovery outcome and the
raw daily summaries needed to derive NOOP Rest independently. The comparison harness must never feed the
reference Sleep Performance outcome back into NOOP Recovery: that is target leakage, not validation.

PRIVACY: the export is personal health data. Output goes to a temp directory and must never be committed.
Only day-level fields needed by the comparison are extracted. Journal text is never read.

    python3 Tools/validation/prepare_whoop_export.py ~/Downloads/export.zip
    NOOP_WHOOP_CYCLES=/tmp/whoop/prepared_cycles.json swift test --filter WhoopExportRecoveryComparisonTests

Multiple archives are written to numbered files so each wearer remains a separate validation cohort:

    python3 Tools/validation/prepare_whoop_export.py ~/Downloads/export-1.zip ~/Downloads/export-2.zip \
        --out-dir /tmp/whoop/cohorts
"""
from __future__ import annotations

import argparse
from collections import defaultdict
import csv
from datetime import datetime, timedelta, timezone
import glob
import io
import json
import os
import zipfile

FIELDS = {
    "recovery": "Recovery score %",
    "rhr": "Resting heart rate (bpm)",
    "hrv": "Heart rate variability (ms)",
    "skinTemp": "Skin temp (celsius)",
    "strain": "Day Strain",
    "sleepPerf": "Sleep performance %",
    "resp": "Respiratory rate (rpm)",
    "efficiency": "Sleep efficiency %",
    "asleepMin": "Asleep duration (min)",
    "inBedMin": "In bed duration (min)",
    "lightMin": "Light sleep duration (min)",
    "deepMin": "Deep (SWS) duration (min)",
    "remMin": "REM duration (min)",
    "awakeMin": "Awake duration (min)",
    "sleepNeedMin": "Sleep need (min)",
    "sleepDebtMin": "Sleep debt (min)",
    "sleepConsistency": "Sleep consistency %",
    "spo2": "Blood oxygen %",
    "energyKcal": "Energy burned (cal)",
    "avgHr": "Average HR (bpm)",
    "maxHr": "Max HR (bpm)",
}

# Only fields consumed by the private recovery/rest comparison determine whether a duplicate day
# has one usable physiology row or multiple ambiguous outcomes. Activity-only cycles can share the
# next cycle's wake day; they must not insert a second nil baseline row.
COMPARISON_FIELDS = {
    "recovery",
    "rhr",
    "hrv",
    "sleepPerf",
    "resp",
    "efficiency",
    "asleepMin",
    "inBedMin",
    "deepMin",
    "remMin",
}


def num(value: str | None) -> float | None:
    value = (value or "").strip()
    if value in ("", "-"):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def timezone_offset(raw: str | None) -> timezone:
    value = (raw or "").strip().upper()
    if value in ("", "UTC", "GMT", "Z"):
        return timezone.utc
    if value.startswith("UTC") or value.startswith("GMT"):
        value = value[3:].strip()
    if value == "Z":
        return timezone.utc

    sign = -1 if value.startswith("-") else 1
    if value.startswith(("+", "-")):
        value = value[1:]
    try:
        if ":" in value:
            hour_text, minute_text = value.split(":", 1)
        elif len(value) >= 3:
            hour_text, minute_text = value[:-2], value[-2:]
        else:
            hour_text, minute_text = value, "0"
        minutes = sign * (int(hour_text or "0") * 60 + int(minute_text or "0"))
        return timezone(timedelta(minutes=minutes))
    except (OverflowError, ValueError, TypeError):
        return timezone.utc


def parse_timestamp(raw: str | None, cycle_zone: timezone) -> datetime | None:
    value = (raw or "").strip()
    if not value:
        return None
    normalized = value[:-1] + "+00:00" if value.upper().endswith("Z") else value
    try:
        parsed = datetime.fromisoformat(normalized)
    except ValueError:
        return None
    if parsed.tzinfo is None:
        parsed = parsed.replace(tzinfo=cycle_zone)
    return parsed.astimezone(cycle_zone)


def canonical_day(source: dict[str, str | None]) -> str | None:
    cycle_zone = timezone_offset(source.get("Cycle timezone"))
    start = parse_timestamp(source.get("Cycle start time"), cycle_zone)
    end = parse_timestamp(source.get("Cycle end time"), cycle_zone)
    # Production ignores a malformed row that has neither a cycle start nor cycle end.
    if start is None and end is None:
        return None
    wake = parse_timestamp(source.get("Wake onset"), cycle_zone)
    selected = wake or end or start
    return selected.date().isoformat() if selected is not None else None


def prepare(
    archive: str,
    label: str,
) -> tuple[list[dict[str, float | str | None]], int, int, int]:
    with zipfile.ZipFile(archive) as zf:
        names = [n for n in zf.namelist() if n.endswith("physiological_cycles.csv")]
        if len(names) != 1:
            raise SystemExit(
                f"{label}: expected exactly one physiological_cycles.csv, found {len(names)}"
            )
        with zf.open(names[0]) as raw:
            text = io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")
            rows = []
            for source in csv.DictReader(text):
                start = (source.get("Cycle start time") or "").strip()
                day = canonical_day(source)
                if day is None:
                    continue
                record: dict[str, float | str | None] = {"day": day, "_start": start}
                record.update({key: num(source.get(column)) for key, column in FIELDS.items()})
                rows.append(record)

    total = len(rows)
    by_day: dict[str, list[dict[str, float | str | None]]] = defaultdict(list)
    for row in rows:
        by_day[str(row["day"])].append(row)

    prepared: list[dict[str, float | str | None]] = []
    collapsed_activity_rows = 0
    ambiguous_days = 0
    for day, candidates in by_day.items():
        useful = [
            row for row in candidates
            if any(row.get(field) is not None for field in COMPARISON_FIELDS)
        ]
        if len(useful) > 1:
            # Two scored sleeps on one wake day do not have a defensible one-to-one daily reference.
            # Exclude the whole day instead of choosing whichever row happened to sort last.
            ambiguous_days += 1
            continue
        if len(useful) == 1:
            prepared.append(useful[0])
            collapsed_activity_rows += len(candidates) - 1
        else:
            # Keep one all-missing day so baseline gap semantics remain calendar-aligned.
            prepared.append(min(candidates, key=lambda row: str(row["_start"])))
            collapsed_activity_rows += len(candidates) - 1

    prepared.sort(key=lambda row: (str(row["day"]), str(row["_start"])))
    for row in prepared:
        del row["_start"]
    # Reference Recovery availability is an outcome, not a license to exclude a unique day from
    # baseline history. The only exclusions above are ambiguous multi-outcome wake days.
    return prepared, total, collapsed_activity_rows, ambiguous_days


def write_prepared(
    label: str,
    output: str,
    complete: list[dict[str, float | str | None]],
    total: int,
    collapsed_activity_rows: int,
    ambiguous_days: int,
) -> None:
    parent = os.path.dirname(output)
    if parent:
        os.makedirs(parent, mode=0o700, exist_ok=True)
    flags = os.O_WRONLY | os.O_CREAT | os.O_TRUNC
    flags |= getattr(os, "O_CLOEXEC", 0)
    flags |= getattr(os, "O_NOFOLLOW", 0)
    descriptor = os.open(output, flags, 0o600)
    os.fchmod(descriptor, 0o600)
    with os.fdopen(descriptor, "w", encoding="utf-8") as f:
        json.dump(complete, f)

    print(
        f"{label}: prepared {len(complete)} of {total} cycle rows "
        f"({collapsed_activity_rows} activity-only duplicate rows collapsed; "
        f"{ambiguous_days} ambiguous wake days excluded; "
        "owner-only fixture; personal data, do not commit)"
    )


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("archives", nargs="+", help="one or more export ZIP paths (globs allowed)")
    ap.add_argument("--out", help="single-archive output (default: /tmp/whoop/prepared_cycles.json)")
    ap.add_argument("--out-dir", help="multi-archive output directory")
    args = ap.parse_args()

    matches: list[str] = []
    for pattern in args.archives:
        expanded = sorted(glob.glob(os.path.expanduser(pattern)))
        if not expanded:
            raise SystemExit("an archive pattern matched no files")
        for path in expanded:
            absolute = os.path.abspath(path)
            if absolute not in matches:
                matches.append(absolute)
    if not matches:
        raise SystemExit("no archives selected")
    if args.out and (len(matches) != 1 or args.out_dir):
        raise SystemExit("--out requires exactly one archive and cannot be combined with --out-dir")

    if len(matches) == 1:
        output = args.out or os.path.join("/tmp", "whoop", "prepared_cycles.json")
        complete, total, collapsed, ambiguous = prepare(matches[0], "cohort-1")
        write_prepared("cohort-1", output, complete, total, collapsed, ambiguous)
        print("Prepared 1 cohort. Run the documented NOOP_WHOOP_CYCLES harness.")
        return

    output_dir = args.out_dir or os.path.join("/tmp", "whoop", "cohorts")
    os.makedirs(output_dir, mode=0o700, exist_ok=True)
    os.chmod(output_dir, 0o700)
    for index, archive in enumerate(matches, start=1):
        output = os.path.join(output_dir, f"export-{index}.json")
        label = f"cohort-{index}"
        complete, total, collapsed, ambiguous = prepare(archive, label)
        write_prepared(label, output, complete, total, collapsed, ambiguous)
    print(f"Prepared {len(matches)} cohorts. Run each with the documented harness.")


if __name__ == "__main__":
    main()
