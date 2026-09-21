from __future__ import annotations

import inspect
from dataclasses import dataclass
from datetime import UTC, datetime
from typing import Any
from uuid import UUID, uuid4

import pytest

from app.ownership_deletion_lifecycle import (
    ManagedErasureRetryableError,
    ManagedErasureScheduleResult,
    ManagedErasureTerminalError,
    OwnershipDeletionLifecycleContractError,
    OwnershipDeletionLifecycleCoordinator,
    OwnershipManagedDeletionTarget,
    OwnershipManagedTargetTransition,
)


NOW = datetime(2026, 9, 18, 12, tzinfo=UTC)
SUBJECT_HASH = "a" * 64


def test_claim_serializes_with_cancellation_request_lock() -> None:
    from app.ownership_deletion_lifecycle import (
        PostgresOwnershipDeletionProgressRepository,
    )

    source = inspect.getsource(
        PostgresOwnershipDeletionProgressRepository.claim_due_managed_targets
    )
    assert "pg_try_advisory_xact_lock" in source
    assert "noop-ownership-account:" in source
    assert "FOR UPDATE OF progress SKIP LOCKED" in source
    assert "FOR UPDATE OF request" not in source
    assert source.index("LIMIT $2") < source.index("pg_try_advisory_xact_lock")
    assert "FROM due_candidates due" in source


def target(
    *,
    request_id: UUID | None = None,
    version: int = 1,
    attempt_count: int = 1,
    issuer: str = "https://identity.synthetic.invalid",
    provider_tenant: str = "tenant",
    subject_hash: str = SUBJECT_HASH,
    job_id: UUID | None = None,
) -> OwnershipManagedDeletionTarget:
    return OwnershipManagedDeletionTarget(
        deletion_request_id=request_id or uuid4(),
        progress_version=version,
        attempt_count=attempt_count,
        issuer=issuer,
        provider_tenant=provider_tenant,
        subject_hash=subject_hash,
        managed_erasure_job_id=job_id,
    )


class FakeProgressRepository:
    def __init__(
        self,
        *,
        due: list[OwnershipManagedDeletionTarget] | None = None,
        processing: list[OwnershipManagedDeletionTarget] | None = None,
    ) -> None:
        self.due = due or []
        self.processing = processing or []
        self.persist_results: list[bool] = []
        self.transitions: list[
            tuple[
                OwnershipManagedDeletionTarget,
                UUID | None,
                OwnershipManagedTargetTransition,
                datetime,
            ]
        ] = []
        self.claim_calls: list[dict[str, Any]] = []
        self.processing_calls: list[dict[str, Any]] = []

    async def claim_due_managed_targets(self, **kwargs):
        self.claim_calls.append(kwargs)
        return list(self.due)

    async def list_processing_managed_targets(self, **kwargs):
        self.processing_calls.append(kwargs)
        return list(self.processing)

    async def persist_managed_target_state(
        self,
        *,
        target,
        lease_owner,
        transition,
        now,
    ):
        self.transitions.append((target, lease_owner, transition, now))
        if self.persist_results:
            return self.persist_results.pop(0)
        return True


@dataclass
class FakeManagedErasureService:
    schedules: dict[UUID, ManagedErasureScheduleResult | Exception]
    statuses: dict[UUID, str | Exception]

    def __init__(self) -> None:
        self.schedules = {}
        self.statuses = {}
        self.schedule_calls: list[dict[str, Any]] = []
        self.status_calls: list[UUID] = []
        self.created_jobs: dict[UUID, UUID] = {}

    async def schedule_all_managed_data(self, **kwargs):
        self.schedule_calls.append(kwargs)
        request_key = kwargs["request_key"]
        configured = self.schedules.get(request_key)
        if isinstance(configured, Exception):
            raise configured
        if configured is not None:
            return configured
        job_id = self.created_jobs.setdefault(request_key, uuid4())
        return ManagedErasureScheduleResult(
            outcome="job",
            job_id=job_id,
            job_status="pending",
        )

    async def managed_erasure_status(self, *, job_id):
        self.status_calls.append(job_id)
        configured = self.statuses[job_id]
        if isinstance(configured, Exception):
            raise configured
        return configured


class CapturingSink:
    def __init__(self, *, fail: bool = False) -> None:
        self.fail = fail
        self.events: list[tuple[str, dict[str, Any]]] = []

    def __call__(self, event: str, **fields: Any) -> None:
        if self.fail:
            raise RuntimeError("synthetic sink failure")
        self.events.append((event, fields))


@pytest.mark.asyncio
async def test_claimed_targets_map_to_bounded_persisted_outcomes() -> None:
    absent = target()
    complete = target()
    pending = target()
    job_id = uuid4()
    repository = FakeProgressRepository(due=[absent, complete, pending])
    service = FakeManagedErasureService()
    service.schedules = {
        absent.deletion_request_id: ManagedErasureScheduleResult(outcome="absent"),
        complete.deletion_request_id: ManagedErasureScheduleResult(
            outcome="already_completed"
        ),
        pending.deletion_request_id: ManagedErasureScheduleResult(
            outcome="job",
            job_id=job_id,
            job_status="pending",
        ),
    }
    owner = uuid4()

    result = await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
        claim_limit=3,
    ).run_once(now=NOW, lease_owner=owner)

    assert result.claimed == 3
    assert result.not_required == 1
    assert result.completed == 1
    assert result.waiting == 1
    assert result.has_partial_failure is False
    assert [entry[2].state for entry in repository.transitions] == [
        "not_required",
        "completed",
        "waiting",
    ]
    assert repository.transitions[2][2].managed_erasure_job_id == job_id
    assert all(entry[1] == owner for entry in repository.transitions)
    assert repository.claim_calls == [
        {
            "now": NOW,
            "lease_owner": owner,
            "lease_seconds": 300,
            "limit": 3,
        }
    ]
    assert [call["request_key"] for call in service.schedule_calls] == [
        absent.deletion_request_id,
        complete.deletion_request_id,
        pending.deletion_request_id,
    ]
    assert all(
        set(call) == {"request_key", "issuer", "provider_tenant", "subject_hash"}
        for call in service.schedule_calls
    )


@pytest.mark.asyncio
async def test_processing_targets_poll_job_state_and_preserve_job_reference() -> None:
    pending_job = uuid4()
    running_job = uuid4()
    complete_job = uuid4()
    retry_job = uuid4()
    failed_job = uuid4()
    processing = [
        target(job_id=pending_job),
        target(job_id=running_job),
        target(job_id=complete_job),
        target(job_id=retry_job, attempt_count=2),
        target(job_id=failed_job),
    ]
    repository = FakeProgressRepository(processing=processing)
    service = FakeManagedErasureService()
    service.statuses = {
        pending_job: "pending",
        running_job: "running",
        complete_job: "completed",
        retry_job: "retryable_failure",
        failed_job: "terminal_failure",
    }

    result = await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
        processing_limit=5,
        retry_base_seconds=10,
    ).run_once(now=NOW)

    assert result.processing_examined == 5
    assert result.waiting == 2
    assert result.completed == 1
    assert result.retry_scheduled == 1
    assert result.blocked == 1
    assert result.has_partial_failure is True
    transitions = [entry[2] for entry in repository.transitions]
    assert [transition.state for transition in transitions] == [
        "waiting",
        "waiting",
        "completed",
        "retry_wait",
        "blocked",
    ]
    assert transitions[3].retry_after == NOW.replace(second=20)
    assert transitions[3].managed_erasure_job_id == retry_job
    assert transitions[4].managed_erasure_job_id == failed_job
    assert all(entry[1] is None for entry in repository.transitions)


@pytest.mark.asyncio
async def test_service_errors_use_fixed_retry_and_blocked_categories() -> None:
    retry = target(attempt_count=1)
    capped_retry = target(attempt_count=20)
    terminal = target()
    repository = FakeProgressRepository(due=[retry, capped_retry, terminal])
    service = FakeManagedErasureService()
    service.schedules = {
        retry.deletion_request_id: ManagedErasureRetryableError("temporary"),
        capped_retry.deletion_request_id: ManagedErasureRetryableError("temporary"),
        terminal.deletion_request_id: ManagedErasureTerminalError("rejected"),
    }

    result = await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
        claim_limit=3,
        retry_base_seconds=30,
        retry_max_seconds=3_600,
    ).run_once(now=NOW)

    assert result.retry_scheduled == 1
    assert result.blocked == 2
    first, second, third = [entry[2] for entry in repository.transitions]
    assert first.retry_after == NOW.replace(second=30)
    assert second.retry_after is None
    assert second.failure_kind == "retry_exhausted"
    assert first.failure_kind == "schedule_retryable"
    assert third.failure_kind == "schedule_terminal"
    assert third.blocker == "managed_erasure_failed"


@pytest.mark.asyncio
async def test_retryable_job_result_retains_job_for_idempotent_retry() -> None:
    due = target(attempt_count=2)
    job_id = uuid4()
    repository = FakeProgressRepository(due=[due])
    service = FakeManagedErasureService()
    service.schedules[due.deletion_request_id] = ManagedErasureScheduleResult(
        outcome="job",
        job_id=job_id,
        job_status="retryable_failure",
    )

    result = await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
        retry_base_seconds=10,
    ).run_once(now=NOW)

    assert result.retry_scheduled == 1
    transition = repository.transitions[0][2]
    assert transition.managed_erasure_job_id == job_id
    assert transition.retry_after == NOW.replace(second=20)
    assert transition.failure_kind == "schedule_retryable"


@pytest.mark.asyncio
async def test_stable_request_key_makes_replay_idempotent_after_state_conflict() -> (
    None
):
    request_id = uuid4()
    due = target(request_id=request_id)
    repository = FakeProgressRepository(due=[due])
    repository.persist_results = [False, True]
    service = FakeManagedErasureService()
    coordinator = OwnershipDeletionLifecycleCoordinator(repository, service)

    first = await coordinator.run_once(now=NOW, lease_owner=uuid4())
    second = await coordinator.run_once(now=NOW, lease_owner=uuid4())

    assert first.state_conflicts == 1
    assert first.waiting == 0
    assert second.waiting == 1
    assert [call["request_key"] for call in service.schedule_calls] == [
        request_id,
        request_id,
    ]
    assert len(service.created_jobs) == 1
    transitions = [entry[2] for entry in repository.transitions]
    assert (
        transitions[0].managed_erasure_job_id == transitions[1].managed_erasure_job_id
    )


@pytest.mark.asyncio
async def test_invalid_identity_is_blocked_without_cross_plane_call() -> None:
    malformed = target(subject_hash="not-a-hash")
    repository = FakeProgressRepository(due=[malformed])
    service = FakeManagedErasureService()

    result = await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
    ).run_once(now=NOW)

    assert result.blocked == 1
    assert service.schedule_calls == []
    transition = repository.transitions[0][2]
    assert transition.state == "blocked"
    assert transition.failure_kind == "invalid_target"


@pytest.mark.asyncio
async def test_observability_contains_only_bounded_aggregate_fields() -> None:
    deletion_request_id = uuid4()
    job_id = uuid4()
    due = target(request_id=deletion_request_id)
    repository = FakeProgressRepository(due=[due])
    service = FakeManagedErasureService()
    service.schedules[deletion_request_id] = ManagedErasureScheduleResult(
        outcome="job",
        job_id=job_id,
        job_status="pending",
    )
    sink = CapturingSink()

    await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
        event_sink=sink,
    ).run_once(now=NOW)

    assert len(sink.events) == 1
    event, fields = sink.events[0]
    assert event == "ownership_deletion.lifecycle"
    assert fields["outcome"] == "completed"
    assert fields["claimed"] == 1
    assert set(fields) == {
        "severity",
        "service",
        "outcome",
        "duration_ms",
        "claimed",
        "processing_examined",
        "not_required",
        "completed",
        "waiting",
        "retry_scheduled",
        "blocked",
        "state_conflicts",
    }
    rendered = repr((event, fields))
    assert str(deletion_request_id) not in rendered
    assert str(job_id) not in rendered
    assert due.issuer not in rendered
    assert due.provider_tenant not in rendered
    assert due.subject_hash not in rendered


@pytest.mark.asyncio
async def test_repository_batch_overrun_fails_closed_with_bounded_event() -> None:
    repository = FakeProgressRepository(
        processing=[target(job_id=uuid4()), target(job_id=uuid4())]
    )
    service = FakeManagedErasureService()
    sink = CapturingSink()

    with pytest.raises(
        OwnershipDeletionLifecycleContractError,
        match="processing repository result exceeded",
    ):
        await OwnershipDeletionLifecycleCoordinator(
            repository,
            service,
            processing_limit=1,
            event_sink=sink,
        ).run_once(now=NOW)

    assert service.status_calls == []
    assert len(sink.events) == 1
    _, fields = sink.events[0]
    assert fields["outcome"] == "failed"
    assert fields["failure_kind"] == "contract"
    assert fields["processing_examined"] == 0


@pytest.mark.asyncio
async def test_observability_failure_never_changes_lifecycle_result() -> None:
    due = target()
    repository = FakeProgressRepository(due=[due])
    service = FakeManagedErasureService()

    result = await OwnershipDeletionLifecycleCoordinator(
        repository,
        service,
        event_sink=CapturingSink(fail=True),
    ).run_once(now=NOW)

    assert result.claimed == 1
    assert result.waiting == 1


@pytest.mark.parametrize(
    ("kwargs", "message"),
    [
        ({"claim_limit": 0}, "claim_limit"),
        ({"processing_limit": 501}, "processing_limit"),
        ({"lease_seconds": 29}, "lease_seconds"),
        ({"retry_base_seconds": 0}, "retry_base_seconds"),
        (
            {"retry_base_seconds": 60, "retry_max_seconds": 30},
            "retry_max_seconds",
        ),
    ],
)
def test_configuration_bounds(kwargs: dict[str, int], message: str) -> None:
    with pytest.raises(ValueError, match=message):
        OwnershipDeletionLifecycleCoordinator(
            FakeProgressRepository(),
            FakeManagedErasureService(),
            **kwargs,
        )


def test_schedule_result_rejects_ambiguous_shapes() -> None:
    with pytest.raises(ValueError, match="requires job_id"):
        ManagedErasureScheduleResult(outcome="job")
    with pytest.raises(ValueError, match="cannot include job state"):
        ManagedErasureScheduleResult(
            outcome="absent",
            job_id=uuid4(),
            job_status="pending",
        )
