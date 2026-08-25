from __future__ import annotations

import os
import time
from pathlib import Path


def is_healthy(
    *,
    path: Path,
    max_age_seconds: int,
    now: float | None = None,
) -> bool:
    if max_age_seconds <= 0:
        return False
    try:
        age = (time.time() if now is None else now) - path.stat().st_mtime
    except OSError:
        return False
    return 0 <= age <= max_age_seconds


def main() -> int:
    path = Path(
        os.getenv(
            "NOOP_SAFETY_WORKER_HEARTBEAT_FILE",
            "/tmp/noop-safety-worker-heartbeat",
        )
    )
    try:
        max_age = int(os.getenv("NOOP_SAFETY_WORKER_HEARTBEAT_TIMEOUT_SECONDS", "30"))
    except ValueError:
        return 1
    return 0 if is_healthy(path=path, max_age_seconds=max_age) else 1


if __name__ == "__main__":
    raise SystemExit(main())
