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
import csv
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
def num(value: str | None) -> float | None:
    value = (value or "").strip()
    if value in ("", "-"):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def prepare(
    archive: str,
    label: str,
) -> tuple[list[dict[str, float | str | None]], int]:
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
                if not start:
                    continue
                record: dict[str, float | str | None] = {"start": start}
                record.update({key: num(source.get(column)) for key, column in FIELDS.items()})
                rows.append(record)

    rows.sort(key=lambda row: str(row["start"]))
    # Keep every dated physiology row. Reference Recovery availability is an outcome, not a license
    # to include or exclude that day from a later baseline; production likewise folds any usable prior
    # HRV/RHR/respiration/Rest value even when the provider did not publish a Recovery score that day.
    return rows, len(rows)


def write_prepared(
    label: str,
    output: str,
    complete: list[dict[str, float | str | None]],
    total: int,
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
        "(owner-only fixture; personal data, do not commit)"
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
        complete, total = prepare(matches[0], "cohort-1")
        write_prepared("cohort-1", output, complete, total)
        print("Prepared 1 cohort. Run the documented NOOP_WHOOP_CYCLES harness.")
        return

    output_dir = args.out_dir or os.path.join("/tmp", "whoop", "cohorts")
    os.makedirs(output_dir, mode=0o700, exist_ok=True)
    os.chmod(output_dir, 0o700)
    for index, archive in enumerate(matches, start=1):
        output = os.path.join(output_dir, f"export-{index}.json")
        label = f"cohort-{index}"
        complete, total = prepare(archive, label)
        write_prepared(label, output, complete, total)
    print(f"Prepared {len(matches)} cohorts. Run each with the documented harness.")


if __name__ == "__main__":
    main()
