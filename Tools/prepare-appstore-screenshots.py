#!/usr/bin/env python3
"""Validate and flatten App Store screenshot PNGs without third-party packages.

Apple accepts PNG screenshots only when their pixel dimensions match a supported
display class and the PNG has no alpha channel.  Simulator captures can be fully
opaque while still being encoded as RGBA, so checking visible transparency is
not enough.

The default target is the current required iPhone 6.9-inch class.  Use an
explicit target for iPad or Apple Watch assets.  ``--fix`` rewrites only 8-bit,
non-interlaced RGBA PNGs, compositing them onto the selected background and
encoding deterministic RGB PNG output.
"""

from __future__ import annotations

import argparse
import binascii
from dataclasses import dataclass
import os
from pathlib import Path
import struct
import sys
import tempfile
import zlib


PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"

# Current accepted pixel dimensions from Apple's Screenshot specifications:
# https://developer.apple.com/help/app-store-connect/reference/app-information/screenshot-specifications/
TARGET_SIZES: dict[str, frozenset[tuple[int, int]]] = {
    "iphone-6.9": frozenset(
        {
            (1260, 2736),
            (2736, 1260),
            (1290, 2796),
            (2796, 1290),
            (1320, 2868),
            (2868, 1320),
        }
    ),
    "ipad-13": frozenset(
        {
            (2064, 2752),
            (2752, 2064),
            (2048, 2732),
            (2732, 2048),
        }
    ),
    "watch": frozenset(
        {
            (422, 514),
            (410, 502),
            (416, 496),
            (396, 484),
            (368, 448),
            (312, 390),
        }
    ),
}


class PNGError(ValueError):
    """Raised when an input is not a supported, well-formed PNG."""


@dataclass(frozen=True)
class PNGImage:
    width: int
    height: int
    bit_depth: int
    color_type: int
    compression: int
    filter_method: int
    interlace: int
    idat: bytes
    has_trns: bool

    @property
    def has_alpha_channel(self) -> bool:
        return self.color_type in (4, 6) or self.has_trns


def _chunk(kind: bytes, payload: bytes) -> bytes:
    checksum = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", checksum)


def _read_png(path: Path) -> PNGImage:
    data = path.read_bytes()
    if not data.startswith(PNG_SIGNATURE):
        raise PNGError("not a PNG file")

    offset = len(PNG_SIGNATURE)
    ihdr: tuple[int, int, int, int, int, int, int] | None = None
    idat_parts: list[bytes] = []
    has_trns = False
    saw_iend = False

    while offset < len(data):
        if offset + 12 > len(data):
            raise PNGError("truncated PNG chunk")
        length = struct.unpack(">I", data[offset : offset + 4])[0]
        kind = data[offset + 4 : offset + 8]
        start = offset + 8
        end = start + length
        if end + 4 > len(data):
            raise PNGError("truncated PNG payload")
        payload = data[start:end]
        expected_crc = struct.unpack(">I", data[end : end + 4])[0]
        actual_crc = binascii.crc32(kind + payload) & 0xFFFFFFFF
        if expected_crc != actual_crc:
            raise PNGError(f"CRC mismatch in {kind.decode('ascii', errors='replace')} chunk")

        if kind == b"IHDR":
            if ihdr is not None or length != 13:
                raise PNGError("invalid IHDR")
            ihdr = struct.unpack(">IIBBBBB", payload)
        elif kind == b"IDAT":
            idat_parts.append(payload)
        elif kind == b"tRNS":
            has_trns = True
        elif kind == b"IEND":
            saw_iend = True
            break
        offset = end + 4

    if ihdr is None or not idat_parts or not saw_iend:
        raise PNGError("missing required PNG chunks")
    width, height, bit_depth, color_type, compression, filter_method, interlace = ihdr
    if width <= 0 or height <= 0:
        raise PNGError("invalid image dimensions")
    return PNGImage(
        width=width,
        height=height,
        bit_depth=bit_depth,
        color_type=color_type,
        compression=compression,
        filter_method=filter_method,
        interlace=interlace,
        idat=b"".join(idat_parts),
        has_trns=has_trns,
    )


def _paeth(left: int, above: int, upper_left: int) -> int:
    estimate = left + above - upper_left
    left_distance = abs(estimate - left)
    above_distance = abs(estimate - above)
    upper_left_distance = abs(estimate - upper_left)
    if left_distance <= above_distance and left_distance <= upper_left_distance:
        return left
    if above_distance <= upper_left_distance:
        return above
    return upper_left


def _decode_rgba_rows(image: PNGImage) -> list[bytes]:
    if image.bit_depth != 8 or image.color_type != 6:
        raise PNGError("flattening supports only 8-bit RGBA PNGs")
    if image.compression != 0 or image.filter_method != 0 or image.interlace != 0:
        raise PNGError("flattening supports only standard, non-interlaced PNGs")

    try:
        raw = zlib.decompress(image.idat)
    except zlib.error as error:
        raise PNGError(f"invalid compressed image data: {error}") from error

    bytes_per_pixel = 4
    stride = image.width * bytes_per_pixel
    expected = (stride + 1) * image.height
    if len(raw) != expected:
        raise PNGError(f"unexpected decoded byte count: expected {expected}, got {len(raw)}")

    rows: list[bytes] = []
    previous = bytes(stride)
    offset = 0
    for _ in range(image.height):
        filter_type = raw[offset]
        filtered = raw[offset + 1 : offset + 1 + stride]
        reconstructed = bytearray(stride)
        for index, value in enumerate(filtered):
            left = reconstructed[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            above = previous[index]
            upper_left = previous[index - bytes_per_pixel] if index >= bytes_per_pixel else 0
            if filter_type == 0:
                predictor = 0
            elif filter_type == 1:
                predictor = left
            elif filter_type == 2:
                predictor = above
            elif filter_type == 3:
                predictor = (left + above) // 2
            elif filter_type == 4:
                predictor = _paeth(left, above, upper_left)
            else:
                raise PNGError(f"unsupported PNG filter type {filter_type}")
            reconstructed[index] = (value + predictor) & 0xFF
        row = bytes(reconstructed)
        rows.append(row)
        previous = row
        offset += stride + 1
    return rows


def _parse_background(value: str) -> tuple[int, int, int]:
    normalized = value.removeprefix("#")
    if len(normalized) != 6:
        raise argparse.ArgumentTypeError("background must be #RRGGBB")
    try:
        channels = tuple(int(normalized[index : index + 2], 16) for index in (0, 2, 4))
    except ValueError as error:
        raise argparse.ArgumentTypeError("background must be #RRGGBB") from error
    return channels  # type: ignore[return-value]


def _flatten_rgba(image: PNGImage, background: tuple[int, int, int]) -> tuple[bytes, tuple[int, int]]:
    rows = _decode_rgba_rows(image)
    encoded_rows = bytearray()
    alpha_min = 255
    alpha_max = 0

    for row in rows:
        rgb = bytearray(image.width * 3)
        for pixel in range(image.width):
            source = pixel * 4
            destination = pixel * 3
            alpha = row[source + 3]
            alpha_min = min(alpha_min, alpha)
            alpha_max = max(alpha_max, alpha)
            for channel in range(3):
                foreground = row[source + channel]
                backdrop = background[channel]
                rgb[destination + channel] = (
                    foreground * alpha + backdrop * (255 - alpha) + 127
                ) // 255

        # Deterministic Sub filtering keeps screenshot output compact without a
        # platform image encoder or mutable metadata.
        encoded_rows.append(1)
        for index, value in enumerate(rgb):
            left = rgb[index - 3] if index >= 3 else 0
            encoded_rows.append((value - left) & 0xFF)

    ihdr = struct.pack(">IIBBBBB", image.width, image.height, 8, 2, 0, 0, 0)
    output = bytearray(PNG_SIGNATURE)
    output.extend(_chunk(b"IHDR", ihdr))
    output.extend(_chunk(b"sRGB", b"\x00"))
    output.extend(_chunk(b"IDAT", zlib.compress(bytes(encoded_rows), level=9)))
    output.extend(_chunk(b"IEND", b""))
    return bytes(output), (alpha_min, alpha_max)


def _write_atomically(path: Path, payload: bytes) -> None:
    mode = path.stat().st_mode
    with tempfile.NamedTemporaryFile(prefix=f".{path.name}.", dir=path.parent, delete=False) as handle:
        temporary = Path(handle.name)
        handle.write(payload)
        handle.flush()
        os.fsync(handle.fileno())
    try:
        os.chmod(temporary, mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def _parse_size(value: str) -> tuple[int, int]:
    try:
        width, height = value.lower().split("x", maxsplit=1)
        parsed = (int(width), int(height))
    except (ValueError, TypeError) as error:
        raise argparse.ArgumentTypeError("size must be WIDTHxHEIGHT") from error
    if parsed[0] <= 0 or parsed[1] <= 0:
        raise argparse.ArgumentTypeError("size dimensions must be positive")
    return parsed


def _expand_paths(values: list[Path]) -> list[Path]:
    inputs = values or [Path("marketing/screenshots")]
    files: set[Path] = set()
    for value in inputs:
        if value.is_dir():
            files.update(path for path in value.glob("*.png") if path.is_file())
        else:
            files.add(value)
    return sorted(files)


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("paths", nargs="*", type=Path, help="PNG files or directories (default: marketing/screenshots)")
    parser.add_argument(
        "--target",
        choices=sorted(TARGET_SIZES),
        default="iphone-6.9",
        help="Apple display class whose accepted pixel sizes are enforced",
    )
    parser.add_argument(
        "--allow-size",
        action="append",
        default=[],
        type=_parse_size,
        metavar="WIDTHxHEIGHT",
        help="additional accepted size (repeatable; useful for controlled tooling tests)",
    )
    parser.add_argument("--fix", action="store_true", help="rewrite supported RGBA PNGs as opaque RGB in place")
    parser.add_argument(
        "--background",
        type=_parse_background,
        default=(0, 0, 0),
        metavar="#RRGGBB",
        help="background used when compositing transparent pixels (default: #000000)",
    )
    return parser


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    files = _expand_paths(args.paths)
    if not files:
        print("FAIL: no PNG screenshots found", file=sys.stderr)
        return 1

    accepted_sizes = set(TARGET_SIZES[args.target])
    accepted_sizes.update(args.allow_size)
    failures = 0

    for path in files:
        if path.suffix.lower() != ".png":
            print(f"FAIL {path}: expected a .png screenshot")
            failures += 1
            continue
        if not path.is_file():
            print(f"FAIL {path}: file does not exist")
            failures += 1
            continue
        try:
            image = _read_png(path)
        except (OSError, PNGError) as error:
            print(f"FAIL {path}: {error}")
            failures += 1
            continue

        size = (image.width, image.height)
        reasons: list[str] = []
        if size not in accepted_sizes:
            reasons.append(f"{image.width}x{image.height} is not accepted for {args.target}")

        alpha_note = ""
        if image.has_alpha_channel:
            if args.fix and not reasons and image.color_type == 6 and not image.has_trns:
                try:
                    flattened, alpha_range = _flatten_rgba(image, args.background)
                    _write_atomically(path, flattened)
                    image = _read_png(path)
                    alpha_note = f"; source alpha range {alpha_range[0]}...{alpha_range[1]}"
                    if image.has_alpha_channel:
                        reasons.append("alpha channel remained after rewrite")
                except (OSError, PNGError) as error:
                    reasons.append(str(error))
            else:
                reasons.append("PNG contains an alpha channel or transparency")

        if image.bit_depth != 8:
            reasons.append(f"unsupported bit depth {image.bit_depth}; expected 8")

        if reasons:
            print(f"FAIL {path}: {'; '.join(reasons)}")
            failures += 1
        elif args.fix and alpha_note:
            print(f"FIXED {path}: {image.width}x{image.height}, opaque RGB{alpha_note}")
        else:
            print(f"OK {path}: {image.width}x{image.height}, opaque PNG")

    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
