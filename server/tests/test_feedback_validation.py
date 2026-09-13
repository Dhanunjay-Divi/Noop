from __future__ import annotations

import asyncio
import threading

import pytest

from app.feedback_archive import (
    BoundedFeedbackArchiveValidator,
    FeedbackArchiveSummary,
    FeedbackArchiveValidationUnavailableError,
)


def _summary() -> FeedbackArchiveSummary:
    return FeedbackArchiveSummary(
        file_count=2,
        uncompressed_bytes=32,
        includes_user_note=False,
        includes_screenshot=False,
    )


async def test_timed_out_validation_holds_slot_until_worker_exits() -> None:
    entered = threading.Event()
    release = threading.Event()
    calls = 0

    def blocking_validator(*_args, **_kwargs) -> FeedbackArchiveSummary:
        nonlocal calls
        calls += 1
        entered.set()
        release.wait(timeout=2)
        return _summary()

    validator = BoundedFeedbackArchiveValidator(
        max_concurrency=1,
        timeout_seconds=0.05,
        validator=blocking_validator,
    )
    arguments = {
        "expected_platform": "ios",
        "expected_app_version": "9.2.0",
        "includes_user_note": False,
        "includes_screenshot": False,
    }

    with pytest.raises(FeedbackArchiveValidationUnavailableError):
        await validator.validate(b"archive", **arguments)
    assert entered.is_set()

    with pytest.raises(FeedbackArchiveValidationUnavailableError):
        await validator.validate(b"second", **arguments)
    assert calls == 1

    release.set()
    for _ in range(50):
        await asyncio.sleep(0.01)
        if calls == 1:
            try:
                summary = await validator.validate(b"third", **arguments)
            except FeedbackArchiveValidationUnavailableError:
                continue
            assert summary == _summary()
            break
    else:
        raise AssertionError("validation slot was not released after worker exit")


async def test_archive_validation_does_not_block_async_event_loop() -> None:
    entered = threading.Event()
    release = threading.Event()

    def blocking_validator(*_args, **_kwargs) -> FeedbackArchiveSummary:
        entered.set()
        release.wait(timeout=2)
        return _summary()

    validator = BoundedFeedbackArchiveValidator(
        max_concurrency=1,
        timeout_seconds=1,
        validator=blocking_validator,
    )
    task = asyncio.create_task(
        validator.validate(
            b"archive",
            expected_platform="ios",
            expected_app_version="9.2.0",
            includes_user_note=False,
            includes_screenshot=False,
        )
    )
    for _ in range(50):
        await asyncio.sleep(0.01)
        if entered.is_set():
            break
    assert entered.is_set()

    ticked = False

    async def tick() -> None:
        nonlocal ticked
        await asyncio.sleep(0)
        ticked = True

    await tick()
    assert ticked
    release.set()
    assert await task == _summary()
