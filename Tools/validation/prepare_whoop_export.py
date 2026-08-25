#!/usr/bin/env python3
"""Prepare a WHOOP data export for WhoopExportRecoveryComparisonTests.

WHOOP's self-service export contains `physiological_cycles.csv` with, per day, its own Recovery %, resting
heart rate, HRV, sleep performance, respiratory rate, skin temperature and Day Strain. That makes it the
best available reference for NOOP's Charge/Recovery family: same wearer, same nights, same underlying
signals, and the vendor's own score alongside.

PRIVACY: the export is personal health data. Output goes to a temp directory and must never be committed.
Only the day-level fields the comparison needs are extracted; journal entries and workouts are ignored.

    python3 Tools/validation/prepare_whoop_export.py ~/Downloads/my_whoop_data_*.zip
    NOOP_WHOOP_CYCLES=/tmp/whoop/prepared_cycles.json swift test --filter WhoopExportRecoveryComparisonTests
"""
from __future__ import annotations

import argparse
import csv
import glob
import json
import os
import statistics
import tempfile
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
}
REQUIRED = ("recovery", "rhr", "hrv")


def num(value: str | None) -> float | None:
    value = (value or "").strip()
    if value in ("", "-"):
        return None
    try:
        return float(value)
    except ValueError:
        return None


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("archive", help="path to my_whoop_data_*.zip (globs allowed)")
    ap.add_argument("--out", default="/tmp/whoop/prepared_cycles.json")
    args = ap.parse_args()

    matches = sorted(glob.glob(os.path.expanduser(args.archive)))
    if not matches:
        raise SystemExit(f"no archive matched {args.archive}")
    archive = matches[-1]

    with tempfile.TemporaryDirectory() as tmp:
        with zipfile.ZipFile(archive) as zf:
            names = [n for n in zf.namelist() if n.endswith("physiological_cycles.csv")]
            if not names:
                raise SystemExit("physiological_cycles.csv not found in the archive")
            zf.extract(names[0], tmp)
            csv_path = os.path.join(tmp, names[0])

        rows = []
        with open(csv_path, newline="", encoding="utf-8-sig") as f:
            for raw in csv.DictReader(f):
                start = (raw.get("Cycle start time") or "").strip()
                if not start:
                    continue
                record = {"start": start}
                record.update({key: num(raw.get(column)) for key, column in FIELDS.items()})
                rows.append(record)

    rows.sort(key=lambda r: r["start"])
    complete = [r for r in rows if all(r[k] is not None for k in REQUIRED)]

    os.makedirs(os.path.dirname(args.out), exist_ok=True)
    with open(args.out, "w") as f:
        json.dump(complete, f)

    print(f"archive : {archive}")
    print(f"cycles  : {len(rows)} total, {len(complete)} with recovery+rhr+hrv")
    if complete:
        print(f"range   : {complete[0]['start']} -> {complete[-1]['start']}")
        for key in ("recovery", "rhr", "hrv", "sleepPerf", "resp", "strain"):
            vals = [r[key] for r in complete if r.get(key) is not None]
            if vals:
                print(f"  {key:>10}: n={len(vals):>4}  median={statistics.median(vals):>7.1f}")
    print(f"\nwrote {args.out}  (personal data - do not commit)")
    print(f"NOOP_WHOOP_CYCLES={args.out} swift test --filter WhoopExportRecoveryComparisonTests")


if __name__ == "__main__":
    main()
