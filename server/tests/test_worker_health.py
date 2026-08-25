from __future__ import annotations

from pathlib import Path

from app.worker_health import is_healthy


def test_worker_health_requires_a_fresh_local_heartbeat(tmp_path: Path) -> None:
    heartbeat = tmp_path / "heartbeat"
    assert not is_healthy(path=heartbeat, max_age_seconds=30, now=100)

    heartbeat.touch()
    timestamp = heartbeat.stat().st_mtime
    assert is_healthy(
        path=heartbeat,
        max_age_seconds=30,
        now=timestamp + 30,
    )
    assert not is_healthy(
        path=heartbeat,
        max_age_seconds=30,
        now=timestamp + 31,
    )
    assert not is_healthy(
        path=heartbeat,
        max_age_seconds=30,
        now=timestamp - 1,
    )
