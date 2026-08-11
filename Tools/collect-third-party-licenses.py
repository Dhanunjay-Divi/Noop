#!/usr/bin/env python3
"""Collect exact runtime dependency license texts into a checked-in bundle.

This is an intentional maintainer command, not a network-dependent CI step.  It
copies license material from the exact Swift, Gradle, and Python artifacts that
were resolved for a release.  ``release-legal-gate.py`` subsequently verifies
the checked-in files and fails if the resolved graph drifts.
"""

from __future__ import annotations

import argparse
import email
import re
import urllib.request
import zipfile
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
OUT = ROOT / "ThirdPartyNotices" / "licenses"
APPLE_LICENSE_FILES = {
    "grdb.swift": ("GRDB.swift", "LICENSE"),
    "networkimage": ("NetworkImage", "LICENSE"),
    "swift-cmark": ("swift-cmark", "COPYING"),
    "swift-markdown-ui": ("swift-markdown-ui", "LICENSE"),
    "zipfoundation": ("ZIPFoundation", "LICENSE"),
}
PYTHON_RUNTIME = {
    "annotated-doc",
    "annotated-types",
    "anyio",
    "asyncpg",
    "click",
    "fastapi",
    "h11",
    "httptools",
    "idna",
    "pydantic",
    "pydantic-core",
    "python-dotenv",
    "pyyaml",
    "starlette",
    "typing-extensions",
    "typing-inspection",
    "uvicorn",
    "uvloop",
    "watchfiles",
    "websockets",
}
APACHE_URL = "https://www.apache.org/licenses/LICENSE-2.0.txt"
APACHE_SHA256 = "cfc7749b96f63bd31c3c42b5c471bf756814053e847c10f3eb003417bc523d30"


def normalized(name: str) -> str:
    return re.sub(r"[-_.]+", "-", name).lower()


def write(path: Path, data: bytes) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(data.rstrip() + b"\n")


def collect_apple(checkouts: Path) -> None:
    for identity, (directory, filename) in APPLE_LICENSE_FILES.items():
        source = checkouts / directory / filename
        if not source.is_file():
            raise SystemExit(f"missing Swift license source: {source}")
        write(OUT / "apple" / f"{identity}.txt", source.read_bytes())


def collect_android(gradle_cache: Path) -> None:
    import hashlib

    with urllib.request.urlopen(APACHE_URL, timeout=30) as response:
        apache = response.read()
    if hashlib.sha256(apache).hexdigest() != APACHE_SHA256:
        raise SystemExit("Apache-2.0 canonical text changed; inspect before refreshing")
    write(OUT / "android" / "Apache-2.0.txt", apache)

    checker_root = gradle_cache / "org.checkerframework" / "checker-qual" / "3.12.0"
    checker_jars = sorted(checker_root.glob("*/*.jar"))
    if not checker_jars:
        raise SystemExit(f"checker-qual artifact not found under {checker_root}")
    with zipfile.ZipFile(checker_jars[0]) as archive:
        write(
            OUT / "android" / "checker-qual-3.12.0.txt",
            archive.read("META-INF/LICENSE.txt"),
        )

    okhttp_root = gradle_cache / "com.squareup.okhttp3" / "okhttp" / "4.12.0"
    okhttp_jars = sorted(okhttp_root.glob("*/*.jar"))
    if not okhttp_jars:
        raise SystemExit(f"OkHttp artifact not found under {okhttp_root}")
    with zipfile.ZipFile(okhttp_jars[0]) as archive:
        write(
            OUT / "android" / "okhttp-publicsuffix-4.12.0-NOTICE.txt",
            archive.read("okhttp3/internal/publicsuffix/NOTICE"),
        )

    # androidx.glance repackages protobuf-lite and declares BSD-3-Clause in its
    # exact 1.1.1 POM.  Keep the relevant upstream copyright with the terms.
    glance_bsd = b"""Copyright 2008 Google Inc.  All rights reserved.

Redistribution and use in source and binary forms, with or without
modification, are permitted provided that the following conditions are met:

    * Redistributions of source code must retain the above copyright
notice, this list of conditions and the following disclaimer.
    * Redistributions in binary form must reproduce the above
copyright notice, this list of conditions and the following disclaimer
in the documentation and/or other materials provided with the
distribution.
    * Neither the name of Google Inc. nor the names of its
contributors may be used to endorse or promote products derived from
this software without specific prior written permission.

THIS SOFTWARE IS PROVIDED BY THE COPYRIGHT HOLDERS AND CONTRIBUTORS
"AS IS" AND ANY EXPRESS OR IMPLIED WARRANTIES, INCLUDING, BUT NOT
LIMITED TO, THE IMPLIED WARRANTIES OF MERCHANTABILITY AND FITNESS FOR
A PARTICULAR PURPOSE ARE DISCLAIMED. IN NO EVENT SHALL THE COPYRIGHT
OWNER OR CONTRIBUTORS BE LIABLE FOR ANY DIRECT, INDIRECT, INCIDENTAL,
SPECIAL, EXEMPLARY, OR CONSEQUENTIAL DAMAGES (INCLUDING, BUT NOT
LIMITED TO, PROCUREMENT OF SUBSTITUTE GOODS OR SERVICES; LOSS OF USE,
DATA, OR PROFITS; OR BUSINESS INTERRUPTION) HOWEVER CAUSED AND ON ANY
THEORY OF LIABILITY, WHETHER IN CONTRACT, STRICT LIABILITY, OR TORT
(INCLUDING NEGLIGENCE OR OTHERWISE) ARISING IN ANY WAY OUT OF THE USE
OF THIS SOFTWARE, EVEN IF ADVISED OF THE POSSIBILITY OF SUCH DAMAGE.
"""
    write(OUT / "android" / "glance-external-protobuf-1.1.1.txt", glance_bsd)


def collect_python(site_packages: Path) -> None:
    found: set[str] = set()
    for dist_info in sorted(site_packages.glob("*.dist-info")):
        metadata_path = dist_info / "METADATA"
        if not metadata_path.is_file():
            continue
        metadata = email.message_from_bytes(metadata_path.read_bytes())
        name = normalized(metadata.get("Name", ""))
        if name not in PYTHON_RUNTIME:
            continue
        version = metadata.get("Version", "")
        candidates = sorted(
            {
                *dist_info.glob("LICENSE*"),
                *dist_info.glob("COPYING*"),
                *dist_info.glob("NOTICE*"),
                *dist_info.glob("licenses/LICENSE*"),
                *dist_info.glob("licenses/COPYING*"),
                *dist_info.glob("licenses/NOTICE*"),
            },
            key=lambda item: item.relative_to(dist_info).as_posix(),
        )
        if not candidates:
            raise SystemExit(f"no license text found for {name}=={version}")
        chunks = []
        for candidate in candidates:
            label = candidate.relative_to(dist_info).as_posix()
            chunks.append(f"===== {label} =====\n".encode())
            chunks.append(candidate.read_bytes().rstrip() + b"\n\n")
        write(
            OUT / "python" / f"{name}-{version}.txt",
            b"".join(chunks),
        )
        found.add(name)
    missing = sorted(PYTHON_RUNTIME - found)
    if missing:
        raise SystemExit("missing Python runtime distributions: " + ", ".join(missing))


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--swift-checkouts", type=Path, required=True)
    parser.add_argument("--gradle-cache", type=Path, required=True)
    parser.add_argument("--python-site-packages", type=Path, required=True)
    args = parser.parse_args()

    collect_apple(args.swift_checkouts)
    collect_android(args.gradle_cache)
    collect_python(args.python_site_packages)
    print(f"Collected runtime license texts under {OUT}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
