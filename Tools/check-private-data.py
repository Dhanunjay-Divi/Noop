#!/usr/bin/env python3
"""Fail when a tracked file looks like a personal wearable export.

This is deliberately filename/extension based and conservative. It does not
open or print health data. The only export-shaped allowlist is the generated
synthetic StrandImport resource directory.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import PurePosixPath


SYNTHETIC_ALLOWLIST = "Packages/StrandImport/Tests/StrandImportTests/Resources/"
BLOCKED_SUFFIXES = {
    ".zip",
    ".noopbak",
    ".sqlite",
    ".sqlite3",
    ".db",
    ".parquet",
    ".feather",
    ".arrow",
    ".jsonl",
}
WHOOP_FILENAMES = {
    "prepared_cycles.json",
    "physiological_cycles.csv",
    "sleeps.csv",
    "workouts.csv",
    "journal_entries.csv",
    "physiologische_zyklen.csv",
    "schlaf.csv",
    "trainings.csv",
    "logbuch_eintraege.csv",
    "sueño.csv",
    "sueno.csv",
    "entrenamientos.csv",
    "sommeil.csv",
    "entrainements.csv",
    "entraînements.csv",
    "ciclos_fisiológicos.csv",
    "ciclos_fisiologicos.csv",
    "sonos.csv",
    "treinos.csv",
    "entradas_diário.csv",
    "entradas_diario.csv",
}


def is_prepared_cohort_json(name: str) -> bool:
    if not name.startswith("export-") or not name.endswith(".json"):
        return False
    cohort = name[len("export-") : -len(".json")]
    return cohort.isdigit()


def tracked_files() -> list[str]:
    result = subprocess.run(
        ["git", "ls-files", "-z"],
        check=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
    )
    return [item.decode("utf-8") for item in result.stdout.split(b"\0") if item]


def blocked(path: str) -> bool:
    if path.startswith(SYNTHETIC_ALLOWLIST):
        return False
    item = PurePosixPath(path)
    lowered = item.name.lower()
    if lowered in WHOOP_FILENAMES or is_prepared_cohort_json(lowered):
        return True
    suffixes = "".join(item.suffixes).lower()
    return any(
        suffixes == suffix
        or suffixes.endswith(suffix + "-wal")
        or suffixes.endswith(suffix + "-shm")
        for suffix in BLOCKED_SUFFIXES
    )


def main() -> int:
    offenders = sorted(path for path in tracked_files() if blocked(path))
    if not offenders:
        print("Private-data filename guard passed.")
        return 0
    print("Refusing tracked export/database artifacts:", file=sys.stderr)
    for path in offenders:
        print(f"  {path}", file=sys.stderr)
    print(
        "Move real health data outside the repository; commit only minimized synthetic fixtures.",
        file=sys.stderr,
    )
    return 1


if __name__ == "__main__":
    raise SystemExit(main())
