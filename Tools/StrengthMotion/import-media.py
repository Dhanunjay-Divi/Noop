#!/usr/bin/env python3
"""Validate and locally install mapped strength media for iOS and Android QA."""

from __future__ import annotations

import argparse
import csv
import json
import shutil
import struct
import subprocess
import sys
import tempfile
from pathlib import Path


TOOL_DIR = Path(__file__).resolve().parent
REPO_ROOT = TOOL_DIR.parent.parent
MANIFEST_PATHS = (
    TOOL_DIR / "exercise-media.json",
    REPO_ROOT / "Strand/Resources/StrengthMotion/exercise-media.json",
    REPO_ROOT / "android/app/src/main/assets/strength-motion/exercise-media.json",
)
IOS_DEBUG_OUTPUT_DIR = REPO_ROOT / "build/strength-motion-media"
ANDROID_DEMO_DEBUG_OUTPUT_DIR = (
    REPO_ROOT / "android/app/src/demoDebug/assets/strength-motion/media"
)
OUTPUT_DIRS = (IOS_DEBUG_OUTPUT_DIR, ANDROID_DEMO_DEBUG_OUTPUT_DIR)
GIF_FRAME_DURATION_PERCENT = 125
GIF_MINIMUM_FRAME_DELAY_HUNDREDTHS = 5
GIF_MAXIMUM_FRAME_DELAY_HUNDREDTHS = 40


def parse_args() -> argparse.Namespace:
    downloads = Path.home() / "Downloads"
    archive_sources = REPO_ROOT / "LocalAssets/StrengthMotion/sources"
    archived_gifs = archive_sources / "exercises-gifs-main"
    archived_vital = archive_sources / "VitalAnimations"
    gif_root = (
        archived_gifs
        if archived_gifs.is_dir()
        else downloads / "exercises-gifs-main"
    )
    vital_root = (
        archived_vital
        if archived_vital.is_dir()
        else downloads / "VitalAnimations"
    )
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--gif-assets",
        type=Path,
        default=gif_root / "assets",
    )
    parser.add_argument(
        "--gif-csv",
        type=Path,
        default=gif_root / "exercises.csv",
    )
    parser.add_argument(
        "--video-assets",
        type=Path,
        default=vital_root / "Free50/Free50",
    )
    parser.add_argument(
        "--video-json",
        type=Path,
        default=vital_root / "Free50/50gymworkouts.json",
    )
    parser.add_argument("--audit-output", type=Path)
    parser.add_argument("--install", action="store_true")
    parser.add_argument(
        "--acknowledge-local-qa-only",
        action="store_true",
        help="Required with --install because source-media redistribution rights are unverified.",
    )
    return parser.parse_args()


def load_manifest() -> dict[str, dict[str, str]]:
    manifests = [json.loads(path.read_text()) for path in MANIFEST_PATHS]
    if manifests[1:] != manifests[:-1]:
        raise ValueError("iOS, Android, and tool media manifests differ")
    catalog = json.loads((TOOL_DIR / "manifest.json").read_text())
    expected = {item["id"] for item in catalog["exercises"]}
    actual = set(manifests[0])
    if actual != expected:
        missing = sorted(expected - actual)
        extra = sorted(actual - expected)
        raise ValueError(f"manifest coverage differs: missing={missing}, extra={extra}")
    return manifests[0]


def load_csv(path: Path) -> dict[str, dict[str, str]]:
    with path.open(newline="", encoding="utf-8-sig") as handle:
        return {row["id"]: row for row in csv.DictReader(handle)}


def gif_dimensions(path: Path) -> tuple[int, int]:
    header = path.read_bytes()[:10]
    if len(header) != 10 or header[:6] not in (b"GIF87a", b"GIF89a"):
        raise ValueError(f"{path} is not a GIF")
    return struct.unpack("<HH", header[6:10])


def _skip_gif_sub_blocks(data: bytearray, start: int) -> int | None:
    offset = start
    while offset < len(data):
        block_size = data[offset]
        offset += 1
        if block_size == 0:
            return offset
        offset += block_size
        if offset > len(data):
            return None
    return None


def normalized_gif_playback_data(path: Path) -> bytes:
    """Match Android's CDN playback timing for a locally bundled QA GIF."""
    data = bytearray(path.read_bytes())
    if len(data) < 14 or data[:6] not in (b"GIF87a", b"GIF89a"):
        raise ValueError(f"{path} is not a GIF")

    global_color_table_bytes = 0
    logical_screen_packed = data[10]
    if logical_screen_packed & 0x80:
        global_color_table_bytes = 3 * (1 << ((logical_screen_packed & 0x07) + 1))
    offset = 13 + global_color_table_bytes

    while offset < len(data):
        marker = data[offset]
        if marker == 0x3B:
            break
        if marker == 0x21:
            if offset + 2 >= len(data):
                raise ValueError(f"{path} has a truncated GIF extension")
            label = data[offset + 1]
            block_start = offset + 2
            if label == 0xF9:
                block_size = data[block_start]
                terminator = block_start + block_size + 1
                if (
                    block_size != 4
                    or terminator >= len(data)
                    or data[terminator] != 0
                ):
                    raise ValueError(f"{path} has an invalid graphics control block")
                delay_offset = block_start + 2
                source_delay = struct.unpack_from("<H", data, delay_offset)[0]
                normalized_delay = min(
                    GIF_MAXIMUM_FRAME_DELAY_HUNDREDTHS,
                    max(
                        GIF_MINIMUM_FRAME_DELAY_HUNDREDTHS,
                        (
                            source_delay * GIF_FRAME_DURATION_PERCENT + 50
                        )
                        // 100,
                    ),
                )
                struct.pack_into("<H", data, delay_offset, normalized_delay)
                offset = terminator + 1
            else:
                next_offset = _skip_gif_sub_blocks(data, block_start)
                if next_offset is None:
                    raise ValueError(f"{path} has a truncated GIF extension")
                offset = next_offset
            continue
        if marker == 0x2C:
            if offset + 9 >= len(data):
                raise ValueError(f"{path} has a truncated image descriptor")
            local_color_table_bytes = 0
            image_packed = data[offset + 9]
            if image_packed & 0x80:
                local_color_table_bytes = 3 * (1 << ((image_packed & 0x07) + 1))
            image_data_start = offset + 10 + local_color_table_bytes
            if image_data_start >= len(data):
                raise ValueError(f"{path} has truncated image data")
            next_offset = _skip_gif_sub_blocks(data, image_data_start + 1)
            if next_offset is None:
                raise ValueError(f"{path} has truncated image data")
            offset = next_offset
            continue
        raise ValueError(f"{path} has an unexpected GIF block marker")

    return bytes(data)


def video_dimensions(path: Path) -> tuple[int, int]:
    command = [
        "ffprobe",
        "-v",
        "error",
        "-select_streams",
        "v:0",
        "-show_entries",
        "stream=width,height",
        "-of",
        "json",
        str(path),
    ]
    result = subprocess.run(command, check=True, capture_output=True, text=True)
    stream = json.loads(result.stdout)["streams"][0]
    return int(stream["width"]), int(stream["height"])


def validate(
    manifest: dict[str, dict[str, str]],
    args: argparse.Namespace,
) -> list[dict[str, object]]:
    gif_rows = load_csv(args.gif_csv)
    video_rows = {
        row["id"]: row for row in json.loads(args.video_json.read_text())
    }
    audit: list[dict[str, object]] = []
    for exercise_id, descriptor in manifest.items():
        item: dict[str, object] = {
            "exercise": exercise_id,
        }
        gif_id = descriptor.get("gif")
        if gif_id:
            gif_row = gif_rows.get(gif_id)
            gif_path = args.gif_assets / f"{gif_id}.gif"
            if gif_row is None or not gif_path.is_file():
                raise ValueError(
                    f"{exercise_id}: missing GIF metadata or file {gif_id}"
                )
            gif_size = gif_dimensions(gif_path)
            if min(gif_size) < 360:
                raise ValueError(f"{exercise_id}: GIF {gif_id} is only {gif_size}")
            item["gif"] = {
                "id": gif_id,
                "name": gif_row["name"],
                "equipment": gif_row["equipment"],
                "dimensions": list(gif_size),
            }
        else:
            reason = descriptor.get("unmappedGifReason", "").strip()
            if not reason:
                raise ValueError(
                    f"{exercise_id}: missing GIF mapping without an audit reason"
                )
            item["gif"] = None
            item["unmappedGifReason"] = reason

        if not gif_id and not descriptor.get("video"):
            item["fallback"] = "native instruction"
        video_id = descriptor.get("video")
        if video_id:
            video_row = video_rows.get(video_id)
            video_path = args.video_assets / f"{video_id}.mp4"
            if video_row is None or not video_path.is_file():
                raise ValueError(
                    f"{exercise_id}: missing video metadata or file {video_id}"
                )
            video_size = video_dimensions(video_path)
            if min(video_size) < 720:
                raise ValueError(f"{exercise_id}: video {video_id} is only {video_size}")
            item["video"] = {
                "id": video_id,
                "name": video_row["name"],
                "equipment": video_row["equipment"],
                "dimensions": list(video_size),
            }
        audit.append(item)
    return audit


def transcode_video(source: Path, destination: Path) -> None:
    subprocess.run(
        [
            "ffmpeg",
            "-y",
            "-loglevel",
            "error",
            "-i",
            str(source),
            "-an",
            "-vf",
            "scale=720:720:flags=lanczos",
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "23",
            "-pix_fmt",
            "yuv420p",
            "-movflags",
            "+faststart",
            str(destination),
        ],
        check=True,
    )


def install(
    manifest: dict[str, dict[str, str]],
    args: argparse.Namespace,
) -> None:
    for output in OUTPUT_DIRS:
        if output.exists():
            shutil.rmtree(output)
        output.mkdir(parents=True, exist_ok=True)

    for descriptor in manifest.values():
        gif_id = descriptor.get("gif")
        if not gif_id:
            continue
        source = args.gif_assets / f"{gif_id}.gif"
        shutil.copy2(source, IOS_DEBUG_OUTPUT_DIR / source.name)
        (ANDROID_DEMO_DEBUG_OUTPUT_DIR / source.name).write_bytes(
            normalized_gif_playback_data(source)
        )

    with tempfile.TemporaryDirectory(prefix="noop-strength-media-") as temporary:
        temporary_dir = Path(temporary)
        video_ids = sorted(
            {item["video"] for item in manifest.values() if item.get("video")}
        )
        for index, video_id in enumerate(video_ids, start=1):
            source = args.video_assets / f"{video_id}.mp4"
            encoded = temporary_dir / source.name
            print(f"Transcoding video {index}/{len(video_ids)}: {video_id}")
            transcode_video(source, encoded)
            for output in OUTPUT_DIRS:
                shutil.copy2(encoded, output / encoded.name)


def main() -> int:
    args = parse_args()
    if args.install and not args.acknowledge_local_qa_only:
        print(
            "--install requires --acknowledge-local-qa-only; these binaries are "
            "git-ignored and must not ship until redistribution rights are documented.",
            file=sys.stderr,
        )
        return 2
    try:
        manifest = load_manifest()
        audit = validate(manifest, args)
        if args.audit_output:
            args.audit_output.parent.mkdir(parents=True, exist_ok=True)
            args.audit_output.write_text(
                json.dumps(audit, indent=2, ensure_ascii=True) + "\n"
            )
        if args.install:
            install(manifest, args)
    except (KeyError, OSError, ValueError, subprocess.CalledProcessError) as error:
        print(f"Media validation failed: {error}", file=sys.stderr)
        return 1

    gif_count = sum(item.get("gif") is not None for item in audit)
    video_count = sum("video" in item for item in audit)
    action = "installed locally" if args.install else "validated"
    print(
        f"Strength media {action}: {gif_count}/{len(audit)} reviewed GIF mappings and "
        f"{video_count}/19 HD video mappings."
    )
    if args.install:
        print("Local media remains git-ignored and is not approved for redistribution.")
        print(
            "For iOS simulator QA set NOOP_STRENGTH_LOCAL_MEDIA_DIR="
            f"{IOS_DEBUG_OUTPUT_DIR}"
        )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
