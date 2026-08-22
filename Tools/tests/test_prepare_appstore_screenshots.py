from __future__ import annotations

import binascii
from pathlib import Path
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib


ROOT = Path(__file__).resolve().parents[2]
TOOL = ROOT / "Tools" / "prepare-appstore-screenshots.py"
PNG_SIGNATURE = b"\x89PNG\r\n\x1a\n"


def chunk(kind: bytes, payload: bytes) -> bytes:
    crc = binascii.crc32(kind + payload) & 0xFFFFFFFF
    return struct.pack(">I", len(payload)) + kind + payload + struct.pack(">I", crc)


def rgba_png(width: int, height: int, pixels: list[tuple[int, int, int, int]]) -> bytes:
    if len(pixels) != width * height:
        raise ValueError("pixel count does not match dimensions")
    raw = bytearray()
    for row in range(height):
        raw.append(0)
        for pixel in pixels[row * width : (row + 1) * width]:
            raw.extend(pixel)
    ihdr = struct.pack(">IIBBBBB", width, height, 8, 6, 0, 0, 0)
    return PNG_SIGNATURE + chunk(b"IHDR", ihdr) + chunk(b"IDAT", zlib.compress(raw)) + chunk(b"IEND", b"")


def png_color_type(payload: bytes) -> int:
    if not payload.startswith(PNG_SIGNATURE):
        raise ValueError("not PNG")
    return payload[len(PNG_SIGNATURE) + 8 + 9]


def decode_sub_filtered_rgb(payload: bytes, width: int, height: int) -> list[tuple[int, int, int]]:
    offset = len(PNG_SIGNATURE)
    idat = bytearray()
    while offset < len(payload):
        length = struct.unpack(">I", payload[offset : offset + 4])[0]
        kind = payload[offset + 4 : offset + 8]
        data = payload[offset + 8 : offset + 8 + length]
        if kind == b"IDAT":
            idat.extend(data)
        offset += 12 + length
        if kind == b"IEND":
            break
    raw = zlib.decompress(bytes(idat))
    stride = width * 3
    pixels: list[tuple[int, int, int]] = []
    for row_index in range(height):
        start = row_index * (stride + 1)
        if raw[start] != 1:
            raise ValueError("expected deterministic Sub filter")
        filtered = raw[start + 1 : start + 1 + stride]
        reconstructed = bytearray(stride)
        for index, value in enumerate(filtered):
            left = reconstructed[index - 3] if index >= 3 else 0
            reconstructed[index] = (value + left) & 0xFF
        pixels.extend(tuple(reconstructed[index : index + 3]) for index in range(0, stride, 3))
    return pixels


class PrepareAppStoreScreenshotsTests(unittest.TestCase):
    def run_tool(self, *arguments: str) -> subprocess.CompletedProcess[str]:
        return subprocess.run(
            [sys.executable, str(TOOL), *arguments],
            cwd=ROOT,
            check=False,
            capture_output=True,
            text=True,
        )

    def test_check_rejects_rgba_even_when_pixels_are_opaque(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "opaque-rgba.png"
            path.write_bytes(rgba_png(2, 1, [(1, 2, 3, 255), (4, 5, 6, 255)]))
            result = self.run_tool("--allow-size", "2x1", str(path))
            self.assertEqual(result.returncode, 1)
            self.assertIn("alpha channel", result.stdout)

    def test_fix_composites_to_rgb_and_is_idempotent(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "mixed-alpha.png"
            path.write_bytes(rgba_png(2, 1, [(255, 0, 0, 255), (255, 255, 255, 0)]))
            result = self.run_tool(
                "--fix",
                "--background",
                "#102030",
                "--allow-size",
                "2x1",
                str(path),
            )
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            first = path.read_bytes()
            self.assertEqual(png_color_type(first), 2)
            self.assertEqual(
                decode_sub_filtered_rgb(first, 2, 1),
                [(255, 0, 0), (16, 32, 48)],
            )

            second_result = self.run_tool("--fix", "--allow-size", "2x1", str(path))
            self.assertEqual(second_result.returncode, 0, second_result.stdout + second_result.stderr)
            self.assertEqual(path.read_bytes(), first)

    def test_invalid_dimension_fails(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "wrong-size.png"
            original = rgba_png(2, 1, [(0, 0, 0, 255), (0, 0, 0, 255)])
            path.write_bytes(original)
            result = self.run_tool("--fix", str(path))
            self.assertEqual(result.returncode, 1)
            self.assertIn("not accepted for iphone-6.9", result.stdout)
            self.assertEqual(path.read_bytes(), original)


if __name__ == "__main__":
    unittest.main()
