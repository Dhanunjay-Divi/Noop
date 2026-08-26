#!/usr/bin/env python3
"""Privacy-safe structural audit for one or more four-CSV wearable exports.

The tool prints aggregate counts, coverage, numeric ranges, duplicate/conflict counts, and cross-table
identities. It never prints journal questions, notes, activity names, timestamps, or row-level values.
Raw exports remain outside the repository.
"""
from __future__ import annotations

import argparse
import csv
import glob
import io
import math
import os
import statistics
import zipfile
from collections import Counter, defaultdict
from dataclasses import dataclass

TABLES = (
    "physiological_cycles.csv",
    "sleeps.csv",
    "workouts.csv",
    "journal_entries.csv",
)

KEYS = {
    "physiological_cycles.csv": ("Cycle start time",),
    "sleeps.csv": ("Sleep onset", "Wake onset"),
    "workouts.csv": ("Workout start time", "Workout end time"),
    "journal_entries.csv": ("Cycle start time", "Question text"),
}

NUMERIC_FIELDS = {
    "physiological_cycles.csv": (
        "Recovery score %",
        "Resting heart rate (bpm)",
        "Heart rate variability (ms)",
        "Skin temp (celsius)",
        "Blood oxygen %",
        "Day Strain",
        "Energy burned (cal)",
        "Max HR (bpm)",
        "Average HR (bpm)",
        "Sleep performance %",
        "Respiratory rate (rpm)",
        "Asleep duration (min)",
        "In bed duration (min)",
        "Light sleep duration (min)",
        "Deep (SWS) duration (min)",
        "REM duration (min)",
        "Awake duration (min)",
        "Sleep need (min)",
        "Sleep debt (min)",
        "Sleep efficiency %",
        "Sleep consistency %",
    ),
    "sleeps.csv": (
        "Sleep performance %",
        "Respiratory rate (rpm)",
        "Asleep duration (min)",
        "In bed duration (min)",
        "Light sleep duration (min)",
        "Deep (SWS) duration (min)",
        "REM duration (min)",
        "Awake duration (min)",
        "Sleep need (min)",
        "Sleep debt (min)",
        "Sleep efficiency %",
        "Sleep consistency %",
    ),
    "workouts.csv": (
        "Duration (min)",
        "Activity Strain",
        "Energy burned (cal)",
        "Max HR (bpm)",
        "Average HR (bpm)",
        "HR Zone 1 %",
        "HR Zone 2 %",
        "HR Zone 3 %",
        "HR Zone 4 %",
        "HR Zone 5 %",
    ),
}


@dataclass
class Export:
    label: str
    tables: dict[str, list[dict[str, str]]]


def number(value: str | None) -> float | None:
    try:
        parsed = float((value or "").strip())
        return parsed if math.isfinite(parsed) else None
    except ValueError:
        return None


def load_archive(path: str, label: str) -> Export:
    tables: dict[str, list[dict[str, str]]] = {}
    with zipfile.ZipFile(path) as archive:
        for table in TABLES:
            matches = [name for name in archive.namelist() if name.endswith(table)]
            if len(matches) != 1:
                raise SystemExit(f"{label}: expected one {table}, found {len(matches)}")
            with archive.open(matches[0]) as raw:
                text = io.TextIOWrapper(raw, encoding="utf-8-sig", newline="")
                tables[table] = list(csv.DictReader(text))
    return Export(label=label, tables=tables)


def identity(row: dict[str, str], table: str) -> tuple[str, ...]:
    return tuple((row.get(key) or "").strip() for key in KEYS[table])


def duplicate_summary(rows: list[dict[str, str]], table: str) -> tuple[int, int, int]:
    groups: dict[tuple[str, ...], list[dict[str, str]]] = defaultdict(list)
    for row in rows:
        groups[identity(row, table)].append(row)
    duplicate_groups = [group for group in groups.values() if len(group) > 1]
    exact_extras = 0
    conflicting_groups = 0
    for group in duplicate_groups:
        distinct = {tuple(sorted(row.items())) for row in group}
        exact_extras += len(group) - len(distinct)
        if len(distinct) > 1:
            conflicting_groups += 1
    return len(duplicate_groups), exact_extras, conflicting_groups


def numeric_summary(rows: list[dict[str, str]], field: str) -> str:
    values = [value for row in rows if (value := number(row.get(field))) is not None]
    if not values:
        return f"{field}: n=0/{len(rows)}"
    return (
        f"{field}: n={len(values)}/{len(rows)} "
        f"min={min(values):.2f} median={statistics.median(values):.2f} max={max(values):.2f}"
    )


def delta_count(
    rows: list[dict[str, str]],
    fields: tuple[str, ...],
    calculation,
    tolerance: float,
) -> tuple[int, int, float]:
    usable = 0
    bad = 0
    largest = 0.0
    for row in rows:
        values = [number(row.get(field)) for field in fields]
        if any(value is None for value in values):
            continue
        delta = abs(calculation(values))
        usable += 1
        if delta > tolerance:
            bad += 1
            largest = max(largest, delta)
    return usable, bad, largest


def print_export(export: Export) -> None:
    print(f"\n=== {export.label} ===")
    for table in TABLES:
        rows = export.tables[table]
        duplicate_groups, exact_extras, conflicts = duplicate_summary(rows, table)
        print(
            f"{table}: rows={len(rows)} duplicate_keys={duplicate_groups} "
            f"exact_extras={exact_extras} conflicting_keys={conflicts}"
        )
        for field in NUMERIC_FIELDS.get(table, ()):
            print(f"  {numeric_summary(rows, field)}")

    sleeps = export.tables["sleeps.csv"]
    checks = (
        (
            "asleep + awake = in-bed",
            ("Asleep duration (min)", "Awake duration (min)", "In bed duration (min)"),
            lambda values: values[0] + values[1] - values[2],
            1.0,
        ),
        (
            "light + deep + REM = asleep",
            (
                "Light sleep duration (min)",
                "Deep (SWS) duration (min)",
                "REM duration (min)",
                "Asleep duration (min)",
            ),
            lambda values: values[0] + values[1] + values[2] - values[3],
            1.0,
        ),
    )
    for name, fields, calculation, tolerance in checks:
        usable, bad, largest = delta_count(sleeps, fields, calculation, tolerance)
        print(f"  check {name}: usable={usable} outside_tolerance={bad} max_delta={largest:.2f}")

    workouts = export.tables["workouts.csv"]
    zone_fields = tuple(f"HR Zone {index} %" for index in range(1, 6))
    zone_sums: list[float] = []
    for row in workouts:
        values = [number(row.get(key)) for key in zone_fields]
        if all(value is not None for value in values):
            zone_sums.append(sum(value for value in values if value is not None))
    if zone_sums:
        print(
            "  workout zone 1-5 coverage: "
            f"median={statistics.median(zone_sums):.1f}% min={min(zone_sums):.1f}% "
            f"max={max(zone_sums):.1f}% (remainder is below zone 1)"
        )

    journal = export.tables["journal_entries.csv"]
    answers = Counter((row.get("Answered yes") or "").strip().lower() or "<blank>" for row in journal)
    notes = sum(bool((row.get("Notes") or "").strip()) for row in journal)
    questions = len({(row.get("Question text") or "").strip() for row in journal})
    print(f"  journal: questions={questions} answers={dict(answers)} notes_present={notes}/{len(journal)}")

    cycles = export.tables["physiological_cycles.csv"]
    main_sleep_by_cycle = {
        row.get("Cycle start time", ""): row
        for row in sleeps
        if (row.get("Nap") or "").strip().lower() != "true"
    }
    sleep_fields = (
        "Sleep onset",
        "Wake onset",
        "Sleep performance %",
        "Respiratory rate (rpm)",
        "Asleep duration (min)",
        "In bed duration (min)",
        "Light sleep duration (min)",
        "Deep (SWS) duration (min)",
        "REM duration (min)",
        "Awake duration (min)",
        "Sleep need (min)",
        "Sleep debt (min)",
        "Sleep efficiency %",
        "Sleep consistency %",
    )
    comparable = 0
    mismatched = 0
    for cycle in cycles:
        sleep = main_sleep_by_cycle.get(cycle.get("Cycle start time", ""))
        if sleep is None:
            continue
        comparable += 1
        if any((cycle.get(key) or "").strip() != (sleep.get(key) or "").strip() for key in sleep_fields):
            mismatched += 1
    print(f"  cycle/main-sleep parity: comparable={comparable} mismatched={mismatched}")


def print_overlap(exports: list[Export]) -> None:
    if len(exports) < 2:
        return
    print("\n=== logical-key overlap ===")
    for left_index, left in enumerate(exports):
        for right in exports[left_index + 1 :]:
            print(f"{left.label} vs {right.label}")
            for table in TABLES:
                left_keys = {identity(row, table) for row in left.tables[table]}
                right_keys = {identity(row, table) for row in right.tables[table]}
                print(f"  {table}: common={len(left_keys & right_keys)}")


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("archives", nargs="+", help="export ZIP paths (globs allowed)")
    args = parser.parse_args()

    paths: list[str] = []
    for pattern in args.archives:
        matches = sorted(glob.glob(os.path.expanduser(pattern)))
        if not matches:
            raise SystemExit(f"no archive matched {pattern}")
        for match in matches:
            absolute = os.path.abspath(match)
            if absolute not in paths:
                paths.append(absolute)

    exports = [load_archive(path, f"export-{index}") for index, path in enumerate(paths, start=1)]
    for export in exports:
        print_export(export)
    print_overlap(exports)


if __name__ == "__main__":
    main()
