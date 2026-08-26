#!/usr/bin/env python3
"""Download and prepare the Walch 2019 wrist-motion sleep dataset for SleepStagerRealPSGTests.

The dataset is PhysioNet `sleep-accel`: Apple Watch motion + heart rate recorded alongside expert-scored
polysomnography. It is the dataset SleepStager.swift's own header cites for its "~65-73% epoch agreement"
ceiling, which is why it is the right reference for that engine.

Nothing here is committed: the prepared JSON is ~400 KB per subject and it is third-party research data.

    python3 Tools/validation/fetch_walch_sleep.py            # -> /tmp/walch/prepared
    NOOP_WALCH_DIR=/tmp/walch/prepared swift test --filter SleepStagerRealPSGTests

Only the standard library is required.
"""
from __future__ import annotations

import argparse
import json
import os
import urllib.request
from collections import defaultdict

BASE_URL = "https://physionet.org/files/sleep-accel/1.0.0"
DATASET_VERSION = "1.0.0"
MANIFEST_NAME = "_manifest.json"
# Arbitrary wall-clock anchor. Only RELATIVE time matters to the stager, but its inputs are unix seconds.
TIME_ANCHOR = 1_700_000_000


def fetch(path: str, dest: str) -> None:
    if os.path.exists(dest) and os.path.getsize(dest) > 0:
        return
    with urllib.request.urlopen(f"{BASE_URL}/{path}", timeout=120) as r, open(dest, "wb") as f:
        f.write(r.read())


def subject_ids(raw_dir: str, limit: int) -> list[str]:
    index = os.path.join(raw_dir, "labels_index.html")
    fetch("labels/", index)
    html = open(index, encoding="utf-8", errors="ignore").read()
    ids = sorted({
        part.split("_")[0]
        for part in html.split('href="')[1:]
        if part.split('"')[0].endswith("_labeled_sleep.txt")
        for part in [part.split('"')[0]]
    })
    return ids[:limit]


def prepare(subject: str, raw_dir: str, out_dir: str) -> dict | None:
    label_file = os.path.join(raw_dir, f"{subject}_labeled_sleep.txt")
    hr_file = os.path.join(raw_dir, f"{subject}_heartrate.txt")
    acc_file = os.path.join(raw_dir, f"{subject}_acceleration.txt")
    fetch(f"labels/{subject}_labeled_sleep.txt", label_file)
    fetch(f"heart_rate/{subject}_heartrate.txt", hr_file)
    fetch(f"motion/{subject}_acceleration.txt", acc_file)

    # PSG hypnogram, 30 s epochs. Codes: 0 wake, 1 N1, 2 N2, 3 N3, 4 N4, 5 REM, -1 unscored.
    labels: list[tuple[int, int]] = []
    for line in open(label_file):
        parts = line.split()
        if len(parts) == 2:
            labels.append((int(float(parts[0])), int(float(parts[1]))))
    if not labels:
        return None
    lo, hi = labels[0][0], labels[-1][0] + 30
    margin = 600

    # Heart rate: keep one sample per whole second, since HRSample.ts is an Int.
    hr: dict[int, int] = {}
    for line in open(hr_file):
        try:
            t_raw, bpm_raw = line.strip().split(",")
            t, bpm = float(t_raw), float(bpm_raw)
        except ValueError:
            continue
        if lo - margin <= t <= hi + margin and 20 <= bpm <= 240:
            hr[TIME_ANCHOR + int(t)] = int(round(bpm))

    # Motion: 50 Hz raw acceleration in g, averaged to 1 Hz. GravitySample.ts is an Int, so 1 Hz is the
    # maximum representable rate; averaging is the least-lossy way to get there. Verified adequate: during
    # PSG-scored sleep, 98.5-99.4% of resulting 1 Hz deltas fall below gravityStillThresholdG (0.01 g).
    acc: dict[int, list[float]] = defaultdict(lambda: [0.0, 0.0, 0.0, 0.0])
    for line in open(acc_file):
        parts = line.split()
        if len(parts) != 4:
            continue
        t = float(parts[0])
        if not (lo - margin <= t <= hi + margin):
            continue
        bucket = acc[TIME_ANCHOR + int(t)]
        bucket[0] += float(parts[1])
        bucket[1] += float(parts[2])
        bucket[2] += float(parts[3])
        bucket[3] += 1.0
    grav = [
        [ts, round(v[0] / v[3], 4), round(v[1] / v[3], 4), round(v[2] / v[3], 4)]
        for ts, v in sorted(acc.items())
        if v[3]
    ]

    record = {
        "subject": subject,
        "psgStart": TIME_ANCHOR + lo,
        "psgEnd": TIME_ANCHOR + hi,
        "labels": [[TIME_ANCHOR + t, stage] for t, stage in labels],
        "hr": [[t, b] for t, b in sorted(hr.items())],
        "grav": grav,
    }
    with open(os.path.join(out_dir, f"{subject}.json"), "w") as f:
        json.dump(record, f)
    return record


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--subjects", type=int, default=6, help="how many subjects to prepare")
    ap.add_argument("--raw", default="/tmp/walch", help="download cache")
    ap.add_argument("--out", default="/tmp/walch/prepared", help="prepared output directory")
    args = ap.parse_args()

    os.makedirs(args.raw, exist_ok=True)
    os.makedirs(args.out, exist_ok=True)

    ids = subject_ids(args.raw, args.subjects)
    # The test consumes the directory as one fixed fixture. Remove stale prepared subjects from an
    # earlier wider run so `--subjects 6` cannot silently evaluate 6 plus leftovers.
    for name in os.listdir(args.out):
        if name.endswith(".json"):
            os.remove(os.path.join(args.out, name))

    print(f"preparing {len(ids)} subject(s) into {args.out}")
    prepared: list[str] = []
    for subject in ids:
        record = prepare(subject, args.raw, args.out)
        if not record:
            print(f"  {subject}: no labels, skipped")
            continue
        prepared.append(subject)
        hours = (record["psgEnd"] - record["psgStart"]) / 3600
        print(f"  {subject}: {len(record['labels'])} epochs, {hours:.1f} h, "
              f"hr={len(record['hr'])} grav={len(record['grav'])}")
    manifest = {
        "dataset": "sleep-accel",
        "version": DATASET_VERSION,
        "requestedSubjects": args.subjects,
        "subjects": prepared,
        "timeAnchor": TIME_ANCHOR,
    }
    with open(os.path.join(args.out, MANIFEST_NAME), "w") as f:
        json.dump(manifest, f, sort_keys=True)
    print(f"\nNOOP_WALCH_DIR={args.out} swift test --filter SleepStagerRealPSGTests")


if __name__ == "__main__":
    main()
