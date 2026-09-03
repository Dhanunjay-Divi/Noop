#!/usr/bin/env python3
"""Preserve supplied strength-media sources in a local, git-ignored archive."""

from __future__ import annotations

import argparse
import csv
import hashlib
import json
import os
import shutil
import subprocess
import sys
import zipfile
from collections import Counter
from dataclasses import dataclass
from datetime import date
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent.parent
DEFAULT_ARCHIVE_ROOT = REPO_ROOT / "LocalAssets/StrengthMotion"
DEFAULT_TRACKED_INVENTORY = TOOL_DIR / "source-asset-inventory.json"


@dataclass(frozen=True)
class SourceSpec:
    source_name: str
    archive_path: str
    source_id: str
    kind: str


SOURCE_SPECS = (
    SourceSpec(
        "Vital Animations.zip",
        "originals/Vital Animations.zip",
        "vital-animations-original",
        "file",
    ),
    SourceSpec(
        "exercises-gifs-main.zip",
        "originals/exercises-gifs-main.zip",
        "exercise-gifs-original",
        "file",
    ),
    SourceSpec(
        "openGym.zip",
        "originals/openGym.zip",
        "opengym-original",
        "file",
    ),
    SourceSpec(
        "opengym_2.zip",
        "originals/opengym_2.zip",
        "opengym-second-original",
        "file",
    ),
    SourceSpec(
        "VitalAnimations",
        "sources/VitalAnimations",
        "vital-animations-working-tree",
        "tree",
    ),
    SourceSpec(
        "exercises-gifs-main",
        "sources/exercises-gifs-main",
        "exercise-gifs-working-tree",
        "tree",
    ),
    SourceSpec(
        "openGym-main",
        "sources/openGym-main",
        "opengym-working-tree",
        "tree",
    ),
    SourceSpec(
        "opengym-main 2",
        "sources/opengym-main-2",
        "opengym-second-working-tree",
        "tree",
    ),
    SourceSpec(
        "openGym-comparison",
        "sources/openGym-comparison",
        "opengym-comparison-images",
        "tree",
    ),
)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--downloads",
        type=Path,
        default=Path.home() / "Downloads",
    )
    parser.add_argument(
        "--archive-root",
        type=Path,
        default=DEFAULT_ARCHIVE_ROOT,
    )
    parser.add_argument(
        "--tracked-inventory",
        type=Path,
        default=DEFAULT_TRACKED_INVENTORY,
    )
    parser.add_argument(
        "--acknowledge-local-only",
        action="store_true",
        help=(
            "Required when creating the archive. The sources are retained for "
            "private QA/reference and are not approved for redistribution."
        ),
    )
    parser.add_argument(
        "--verify-only",
        action="store_true",
        help="Verify the existing local archive against SHA256SUMS.",
    )
    return parser.parse_args()


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    if path.is_symlink():
        digest.update(b"symlink:")
        digest.update(os.readlink(path).encode("utf-8"))
        return digest.hexdigest()
    with path.open("rb") as handle:
        while chunk := handle.read(1024 * 1024):
            digest.update(chunk)
    return digest.hexdigest()


def remove_existing(path: Path) -> None:
    if path.is_symlink() or path.is_file():
        path.unlink()
    elif path.exists():
        shutil.rmtree(path)


def archive_source(
    source: Path,
    destination: Path,
    kind: str,
) -> str:
    remove_existing(destination)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if sys.platform == "darwin":
        result = subprocess.run(
            ["cp", "-ac", str(source), str(destination)],
            check=False,
        )
        if result.returncode == 0:
            return "apfs-clone-or-copy"
        remove_existing(destination)
    if kind == "file":
        shutil.copy2(source, destination)
    else:
        shutil.copytree(source, destination, symlinks=True)
    return "independent-copy"


def files_under(path: Path) -> list[Path]:
    if path.is_file() or path.is_symlink():
        return [path]
    return sorted(
        item
        for item in path.rglob("*")
        if item.is_file() or item.is_symlink()
    )


def summarize_source(
    source_id: str,
    source_name: str,
    archive_path: Path,
    archive_root: Path,
) -> tuple[dict[str, object], list[str]]:
    paths = files_under(archive_path)
    extensions: Counter[str] = Counter()
    total_bytes = 0
    checksum_lines: list[str] = []
    tree_digest = hashlib.sha256()
    for path in paths:
        relative_archive_path = path.relative_to(archive_root).as_posix()
        relative_source_path = path.relative_to(archive_path).as_posix()
        file_hash = sha256(path)
        size = 0 if path.is_symlink() else path.stat().st_size
        suffix = path.suffix.lower() or "<none>"
        extensions[suffix] += 1
        total_bytes += size
        checksum_lines.append(f"{file_hash}  {relative_archive_path}")
        tree_digest.update(
            f"{file_hash}  {relative_source_path}\n".encode("utf-8")
        )
    summary: dict[str, object] = {
        "id": source_id,
        "sourceName": source_name,
        "archivePath": archive_path.relative_to(archive_root).as_posix(),
        "fileCount": len(paths),
        "bytes": total_bytes,
        "treeSha256": tree_digest.hexdigest(),
        "extensions": dict(sorted(extensions.items())),
    }
    if len(paths) == 1 and not paths[0].is_symlink():
        summary["sha256"] = sha256(paths[0])
    return summary, checksum_lines


def count_csv_rows(path: Path) -> tuple[int, set[str]]:
    with path.open(encoding="utf-8-sig", newline="") as handle:
        rows = list(csv.DictReader(handle))
    return len(rows), {row["id"] for row in rows}


def catalog_facts(archive_root: Path) -> dict[str, object]:
    gif_root = archive_root / "sources/exercises-gifs-main"
    gif_rows, gif_ids = count_csv_rows(gif_root / "exercises.csv")
    gif_files = {
        path.stem for path in (gif_root / "assets").glob("*.gif")
    }
    vital_root = archive_root / "sources/VitalAnimations"
    vital_metadata = json.loads(
        (vital_root / "Free50/50gymworkouts.json").read_text()
    )
    vital_mp4s = list(vital_root.rglob("*.mp4"))
    opengym_gifs = list(
        (archive_root / "sources/openGym-main").rglob("*.gif")
    )
    with zipfile.ZipFile(
        archive_root / "originals/exercises-gifs-main.zip"
    ) as archive:
        zip_members = archive.namelist()
    return {
        "exerciseGifCsvRows": gif_rows,
        "exerciseGifFiles": len(gif_files),
        "exerciseGifMissingIds": sorted(gif_ids - gif_files),
        "exerciseGifZipIncludesLicense": any(
            name.endswith("/LICENSE") for name in zip_members
        ),
        "exerciseGifZipIncludesReadme": any(
            name.endswith("/README.md") for name in zip_members
        ),
        "vitalMetadataRows": len(vital_metadata),
        "vitalMp4Files": len(vital_mp4s),
        "openGymGifFiles": len(opengym_gifs),
        "noopBuiltInExercises": 56,
    }


def write_local_readme(archive_root: Path) -> None:
    content = """# Local Strength Source Archive

This directory preserves the exact user-supplied exercise-media ZIPs and
working trees for private development, QA, and future mapping work.

It is intentionally ignored by Git. The media is not approved for public
redistribution or inclusion in App Store/Play Store artifacts. Review
`Tools/StrengthMotion/ASSET-PROVENANCE.md` before using any source.

Verify every archived file:

```sh
python3 Tools/StrengthMotion/archive-source-assets.py --verify-only
```

Recreate the archive from `~/Downloads`:

```sh
python3 Tools/StrengthMotion/archive-source-assets.py \\
  --acknowledge-local-only
```

`SHA256SUMS` contains a digest for every archived file. The tracked compact
inventory is `Tools/StrengthMotion/source-asset-inventory.json`.
"""
    (archive_root / "README.md").write_text(content, encoding="ascii")


def verify_archive(archive_root: Path) -> int:
    checksum_path = archive_root / "SHA256SUMS"
    if not checksum_path.is_file():
        print(f"Missing archive checksum file: {checksum_path}", file=sys.stderr)
        return 1
    failures: list[str] = []
    lines = checksum_path.read_text(encoding="utf-8").splitlines()
    for line in lines:
        expected, separator, relative = line.partition("  ")
        path = archive_root / relative
        if (
            not separator
            or not path.exists() and not path.is_symlink()
            or sha256(path) != expected
        ):
            failures.append(relative or line)
    if failures:
        print(
            f"Archive verification failed for {len(failures)} file(s):",
            file=sys.stderr,
        )
        for failure in failures[:20]:
            print(f"  {failure}", file=sys.stderr)
        return 1
    print(f"Strength source archive verified: {len(lines)} files.")
    return 0


def create_archive(args: argparse.Namespace) -> int:
    if not args.acknowledge_local_only:
        print(
            "--acknowledge-local-only is required; these sources are retained "
            "for private reference and are not approved for redistribution.",
            file=sys.stderr,
        )
        return 2

    missing = [
        args.downloads / spec.source_name
        for spec in SOURCE_SPECS
        if not (args.downloads / spec.source_name).exists()
    ]
    if missing:
        print("Missing source paths:", file=sys.stderr)
        for path in missing:
            print(f"  {path}", file=sys.stderr)
        return 1

    args.archive_root.mkdir(parents=True, exist_ok=True)
    operations: Counter[str] = Counter()
    for index, spec in enumerate(SOURCE_SPECS, start=1):
        source = args.downloads / spec.source_name
        destination = args.archive_root / spec.archive_path
        print(f"[{index}/{len(SOURCE_SPECS)}] Archiving {spec.source_name}")
        operations[archive_source(source, destination, spec.kind)] += 1

    summaries: list[dict[str, object]] = []
    checksum_lines: list[str] = []
    for spec in SOURCE_SPECS:
        summary, source_checksums = summarize_source(
            spec.source_id,
            spec.source_name,
            args.archive_root / spec.archive_path,
            args.archive_root,
        )
        summaries.append(summary)
        checksum_lines.extend(source_checksums)

    checksum_lines.sort(key=lambda line: line.split("  ", 1)[1])
    (args.archive_root / "SHA256SUMS").write_text(
        "\n".join(checksum_lines) + "\n",
        encoding="utf-8",
    )
    write_local_readme(args.archive_root)

    inventory = {
        "schemaVersion": 1,
        "generatedDate": date.today().isoformat(),
        "archivePath": "LocalAssets/StrengthMotion",
        "distributionStatus": (
            "Local private reference only; source-media redistribution "
            "rights are not established."
        ),
        "sources": summaries,
        "catalogFacts": catalog_facts(args.archive_root),
        "totals": {
            "sourceEntries": len(summaries),
            "archivedFiles": sum(
                int(summary["fileCount"]) for summary in summaries
            ),
            "archivedBytes": sum(
                int(summary["bytes"]) for summary in summaries
            ),
        },
    }
    inventory_text = (
        json.dumps(inventory, indent=2, sort_keys=True) + "\n"
    )
    args.tracked_inventory.parent.mkdir(parents=True, exist_ok=True)
    args.tracked_inventory.write_text(inventory_text, encoding="ascii")
    (args.archive_root / "INVENTORY.json").write_text(
        inventory_text,
        encoding="ascii",
    )
    print(
        "Strength source archive created: "
        f"{inventory['totals']['archivedFiles']} files, "
        f"{operations['apfs-clone-or-copy']} APFS clone/copy sources, "
        f"{operations['independent-copy']} fallback copy sources."
    )
    return verify_archive(args.archive_root)


def main() -> int:
    args = parse_args()
    if args.verify_only:
        return verify_archive(args.archive_root)
    return create_archive(args)


if __name__ == "__main__":
    raise SystemExit(main())
