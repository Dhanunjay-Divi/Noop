#!/usr/bin/env python3
"""Interactively create the ignored one-way verifier used by NOOP's launch gate.

The access code is read with terminal echo disabled, accepted only interactively, and is never printed,
accepted as a command-line/environment value, or written to disk. The output file contains a random salt,
a PBKDF2-HMAC-SHA256 verifier, a rotation id, and the work factor.
"""

from __future__ import annotations

import getpass
import hashlib
import os
from pathlib import Path
import re
import secrets
import sys
import tempfile
import unicodedata


ITERATIONS = 310_000
ROOT = Path(__file__).resolve().parent.parent
DESTINATION = ROOT / "Config" / "LaunchGateSecrets.xcconfig"
VERSION_PATTERN = re.compile(r"[A-Za-z0-9][A-Za-z0-9._-]{0,127}\Z")


def fail(message: str) -> "NoReturn":
    print(f"launch-gate: {message}", file=sys.stderr)
    raise SystemExit(2)


def main() -> int:
    if len(sys.argv) != 2 or not VERSION_PATTERN.fullmatch(sys.argv[1]):
        fail("usage: generate-launch-gate-verifier.py <rotation-id>")
    if not sys.stdin.isatty():
        fail("run this command in an interactive terminal")

    first = getpass.getpass("New NOOP access code: ")
    second = getpass.getpass("Confirm NOOP access code: ")
    if first != second:
        fail("entries did not match")
    if len(first) < 12:
        fail("use at least 12 characters")

    normalized = unicodedata.normalize("NFC", first).encode("utf-8")
    del first, second
    salt = secrets.token_bytes(16)
    verifier = hashlib.pbkdf2_hmac("sha256", normalized, salt, ITERATIONS, dklen=32)
    content = (
        "// Generated locally. Never commit this file. Rotate by generating a new version.\n"
        f"NOOP_LAUNCH_GATE_VERSION = {sys.argv[1]}\n"
        f"NOOP_LAUNCH_GATE_SALT_HEX = {salt.hex()}\n"
        f"NOOP_LAUNCH_GATE_VERIFIER_HEX = {verifier.hex()}\n"
        f"NOOP_LAUNCH_GATE_ITERATIONS = {ITERATIONS}\n"
    )

    DESTINATION.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary_name = tempfile.mkstemp(
        prefix=".launch-gate-", dir=DESTINATION.parent, text=True
    )
    try:
        os.fchmod(descriptor, 0o600)
        with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
            handle.write(content)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary_name, DESTINATION)
        os.chmod(DESTINATION, 0o600)
    finally:
        if os.path.exists(temporary_name):
            os.unlink(temporary_name)

    # Do not print verifier material. The archive receives it through the ignored xcconfig only.
    print(f"launch-gate: wrote protected verifier configuration for {sys.argv[1]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
