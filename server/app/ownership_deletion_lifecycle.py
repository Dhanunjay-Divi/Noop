from __future__ import annotations

import re
import time
from collections.abc import Callable, Sequence
from dataclasses import asdict, dataclass
from datetime import UTC, datetime, timedelta
from typing import Any, Literal, Protocol
from uuid import UUID, uuid4

from app.observability import emit_operational_event


ManagedErasureJobStatus = Literal[
    "pending",
    "running",
    "completed",
    "retryable_failure",
    "terminal_failure",
]
OwnershipManagedTargetState = Literal[
    "waiting",
    "completed",
    "not_required",
    "retry_wait",
    "blocked",
]
OwnershipManagedTargetBlocker = Literal[
    "managed_erasure_pending",
    "retryable_failure",
    "managed_erasure_failed",
]
OwnershipManagedTargetFailure = Literal[
    "schedule_retryable",
    "schedule_terminal",
    "status_retryable",
    "status_terminal",
    "invalid_target",
    "retry_exhausted",
]

_SUBJECT_HASH_PATTERN = re.compile(r"^[0-9a-f]{64}$")
_MAX_IDENTITY_COMPONENT_LENGTH = 2_048
_MIN_BATCH_SIZE = 1
_MAX_BATCH_SIZE = 500
_MIN_LEASE_SECONDS = 30
_MAX_LEASE_SECONDS = 3_600
_MIN_RETRY_SECONDS = 1
_MAX_RETRY_SECONDS = 86_400
_MAX_ATTEMPTS = 20


class OwnershipDeletionLifecycleContractError(RuntimeError):
    """A lifecycle dependency violated its bounded coordination contract."""


class ManagedErasureRetryableError(RuntimeError):
    """Managed erasure is temporarily unavailable and may be retried."""


class ManagedErasureTerminalError(RuntimeError):
    """Managed erasure rejected the target and requires operator review."""


@dataclass(frozen=True, slots=True)
class OwnershipManagedDeletionTarget:
    deletion_request_id: UUID
    progress_version: int
    attempt_count: int
    issuer: str
    provider_tenant: str
    subject_hash: str
    managed_erasure_job_id: UUID | None = None


@dataclass(frozen=True, slots=True)
class OwnershipManagedTargetTransition:
    state: OwnershipManagedTargetState
    blocker: OwnershipManagedTargetBlocker | None = None
    managed_erasure_job_id: UUID | None = None
    retry_after: datetime | None = None
    failure_kind: OwnershipManagedTargetFailure | None = None


@dataclass(frozen=True, slots=True)
class ManagedErasureScheduleResult:
    outcome: Literal["absent", "already_completed", "job"]
    job_id: UUID | None = None
    job_status: ManagedErasureJobStatus | None = None

    def __post_init__(self) -> None:
        if self.outcome == "job":
            if self.job_id is None or self.job_status is None:
                raise ValueError("job outcome requires job_id and job_status")
            return
        if self.job_id is not None or self.job_status is not None:
            raise ValueError(
                "absent and already_completed outcomes cannot include job state"
            )


class OwnershipDeletionProgressRepository(Protocol):
    async def claim_due_managed_targets(
        self,
        *,
        now: datetime,
        lease_owner: UUID,
        lease_seconds: int,
        limit: int,
    ) -> Sequence[OwnershipManagedDeletionTarget]: ...

    async def list_processing_managed_targets(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> Sequence[OwnershipManagedDeletionTarget]: ...

    async def persist_managed_target_state(
        self,
        *,
        target: OwnershipManagedDeletionTarget,
        lease_owner: UUID | None,
        transition: OwnershipManagedTargetTransition,
        now: datetime,
    ) -> bool: ...


class PostgresOwnershipDeletionProgressRepository:
    """Restricted ownership-side state adapter for the managed lifecycle job."""

    def __init__(self, primary_repository: Any) -> None:
        self.primary_repository = primary_repository

    def _pool(self) -> Any:
        return self.primary_repository._require_pool()

    async def configuration_ready(self) -> bool:
        row = await self._pool().fetchrow(
            """
            WITH allowed_table (table_name, privilege) AS (
                VALUES
                    (
                        'ownership_account_deletion_target_progress',
                        'SELECT'
                    ),
                    ('ownership_account_deletion_requests', 'SELECT'),
                    ('ownership_external_identities', 'SELECT')
            ),
            allowed_column (table_name, column_name, privilege) AS (
                VALUES
                    (
                        'ownership_account_deletion_target_progress',
                        'current_state',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'blocker',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'progress_version',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'attempt_count',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'lease_owner',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'lease_expires_at',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'retry_after',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'managed_erasure_job_id',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'last_error_kind',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'updated_at',
                        'UPDATE'
                    ),
                    (
                        'ownership_account_deletion_target_progress',
                        'completed_at',
                        'UPDATE'
                    )
            ),
            relation_privilege (privilege) AS (
                VALUES
                    ('SELECT'),
                    ('INSERT'),
                    ('UPDATE'),
                    ('DELETE'),
                    ('TRUNCATE'),
                    ('REFERENCES'),
                    ('TRIGGER')
            ),
            non_system_sequences (sequence_oid) AS MATERIALIZED (
                SELECT candidate.oid
                FROM pg_class candidate
                JOIN pg_namespace namespace
                  ON namespace.oid = candidate.relnamespace
                WHERE candidate.relkind = 'S'
                  AND namespace.nspname <> 'information_schema'
                  AND namespace.nspname !~ '^pg_'
            )
            SELECT
                EXISTS (
                    SELECT 1
                    FROM pg_roles
                    WHERE rolname = current_user
                      AND NOT rolsuper
                      AND NOT rolcreaterole
                      AND NOT rolcreatedb
                      AND NOT rolreplication
                      AND NOT rolbypassrls
                      AND NOT rolinherit
                ) AS principal_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_auth_members membership
                    JOIN pg_roles member_role
                      ON member_role.oid = membership.member
                    WHERE member_role.rolname = current_user
                ) AS memberships_bounded,
                (
                    has_schema_privilege('public', 'USAGE')
                    AND NOT has_schema_privilege('public', 'CREATE')
                ) AS schema_bounded,
                (
                    has_database_privilege(current_database(), 'CONNECT')
                    AND NOT has_database_privilege(
                        current_database(),
                        'CREATE'
                    )
                ) AS database_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_class
                    WHERE relowner = (
                        SELECT oid
                        FROM pg_roles
                        WHERE rolname = current_user
                    )
                    UNION ALL
                    SELECT 1
                    FROM pg_namespace
                    WHERE nspowner = (
                        SELECT oid
                        FROM pg_roles
                        WHERE rolname = current_user
                    )
                    UNION ALL
                    SELECT 1
                    FROM pg_database
                    WHERE datdba = (
                        SELECT oid
                        FROM pg_roles
                        WHERE rolname = current_user
                    )
                ) AS ownership_bounded,
                (
                    NOT EXISTS (
                        SELECT 1
                        FROM allowed_table allowed
                        WHERE NOT has_table_privilege(
                            format('public.%I', allowed.table_name),
                            allowed.privilege
                        )
                    )
                    AND NOT EXISTS (
                        SELECT 1
                        FROM allowed_column allowed
                        WHERE NOT has_column_privilege(
                            format('public.%I', allowed.table_name),
                            allowed.column_name,
                            allowed.privilege
                        )
                    )
                ) AS privileges_ready,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_class candidate
                    JOIN pg_namespace namespace
                      ON namespace.oid = candidate.relnamespace
                    CROSS JOIN relation_privilege permission
                    WHERE candidate.relkind IN ('r', 'p', 'v', 'm', 'f')
                      AND namespace.nspname = 'public'
                      AND (
                          (
                              has_table_privilege(
                                  candidate.oid,
                                  permission.privilege
                              )
                              AND NOT EXISTS (
                                  SELECT 1
                                  FROM allowed_table allowed
                                  WHERE allowed.table_name = candidate.relname
                                    AND allowed.privilege =
                                        permission.privilege
                              )
                          )
                          OR (
                              permission.privilege IN (
                                  'SELECT',
                                  'INSERT',
                                  'UPDATE',
                                  'REFERENCES'
                              )
                              AND NOT has_table_privilege(
                                  candidate.oid,
                                  permission.privilege
                              )
                              AND EXISTS (
                                  SELECT 1
                                  FROM pg_attribute attribute
                                  WHERE attribute.attrelid = candidate.oid
                                    AND attribute.attnum > 0
                                    AND NOT attribute.attisdropped
                                    AND has_column_privilege(
                                        candidate.oid,
                                        attribute.attname,
                                        permission.privilege
                                    )
                                    AND NOT EXISTS (
                                        SELECT 1
                                        FROM allowed_column allowed
                                        WHERE allowed.table_name =
                                              candidate.relname
                                          AND allowed.column_name =
                                              attribute.attname
                                          AND allowed.privilege =
                                              permission.privilege
                                    )
                              )
                          )
                      )
                ) AS privileges_exact,
                NOT EXISTS (
                    SELECT 1
                    FROM non_system_sequences candidate
                    WHERE has_sequence_privilege(
                        candidate.sequence_oid,
                        'SELECT,UPDATE,USAGE'
                    )
                ) AS sequences_bounded,
                NOT EXISTS (
                    SELECT 1
                    FROM pg_proc candidate
                    JOIN pg_namespace namespace
                      ON namespace.oid = candidate.pronamespace
                    WHERE candidate.prosecdef
                      AND namespace.nspname <> 'information_schema'
                      AND namespace.nspname !~ '^pg_'
                      AND has_function_privilege(
                          candidate.oid,
                          'EXECUTE'
                      )
                ) AS security_definer_bounded
            """
        )
        return bool(
            row is not None
            and row["principal_bounded"]
            and row["memberships_bounded"]
            and row["schema_bounded"]
            and row["database_bounded"]
            and row["ownership_bounded"]
            and row["privileges_ready"]
            and row["privileges_exact"]
            and row["sequences_bounded"]
            and row["security_definer_bounded"]
        )

    async def claim_due_managed_targets(
        self,
        *,
        now: datetime,
        lease_owner: UUID,
        lease_seconds: int,
        limit: int,
    ) -> Sequence[OwnershipManagedDeletionTarget]:
        claimed: list[Any] = []
        async with self._pool().acquire() as connection:
            async with connection.transaction():
                candidates = await connection.fetch(
                    """
                    SELECT progress.deletion_request_id,
                           request.account_id
                    FROM ownership_account_deletion_target_progress progress
                    JOIN ownership_account_deletion_requests request
                      USING (deletion_request_id)
                    JOIN ownership_external_identities identity
                      ON identity.account_id = request.account_id
                     AND encode(
                            sha256(
                                convert_to(identity.identity_id::text, 'UTF8')
                            ),
                            'hex'
                         ) = request.requester_identity_hash
                    WHERE progress.target_kind = 'managed_cloud_data'
                      AND request.canceled_at IS NULL
                      AND request.cancel_before <= $1
                      AND progress.attempt_count < $3
                      AND (
                            (
                                progress.current_state = 'scheduled'
                                AND (
                                    progress.retry_after IS NULL
                                    OR progress.retry_after <= $1
                                )
                            )
                            OR (
                                progress.current_state = 'processing'
                                AND progress.managed_erasure_job_id IS NULL
                                AND progress.lease_expires_at <= $1
                            )
                      )
                    ORDER BY
                        request.cancel_before,
                        progress.updated_at,
                        progress.deletion_request_id
                    LIMIT $2
                    """,
                    now,
                    limit,
                    _MAX_ATTEMPTS,
                )
                for candidate in candidates:
                    account_lock = await connection.fetchval(
                        """
                        SELECT pg_try_advisory_xact_lock(
                            hashtextextended($1, 0)
                        )
                        """,
                        f"noop-ownership-account:{candidate['account_id']}",
                    )
                    if not account_lock:
                        continue
                    row = await connection.fetchrow(
                        """
                        UPDATE ownership_account_deletion_target_progress progress
                        SET current_state = 'processing',
                            blocker = NULL,
                            progress_version = progress.progress_version + 1,
                            attempt_count = progress.attempt_count + 1,
                            lease_owner = $5,
                            lease_expires_at =
                                $3::timestamptz
                                + make_interval(secs => $6::integer),
                            retry_after = NULL,
                            last_error_kind = NULL,
                            updated_at = $3,
                            completed_at = NULL
                        FROM ownership_account_deletion_requests request
                        JOIN ownership_external_identities identity
                          ON identity.account_id = request.account_id
                         AND encode(
                                sha256(
                                    convert_to(identity.identity_id::text, 'UTF8')
                                ),
                                'hex'
                             ) = request.requester_identity_hash
                        WHERE progress.deletion_request_id = $1
                          AND progress.target_kind = 'managed_cloud_data'
                          AND request.deletion_request_id =
                                progress.deletion_request_id
                          AND request.account_id = $2
                          AND request.canceled_at IS NULL
                          AND request.cancel_before <= $3
                          AND progress.attempt_count < $4
                          AND (
                                (
                                    progress.current_state = 'scheduled'
                                    AND (
                                        progress.retry_after IS NULL
                                        OR progress.retry_after <= $3
                                    )
                                )
                                OR (
                                    progress.current_state = 'processing'
                                    AND progress.managed_erasure_job_id IS NULL
                                    AND progress.lease_expires_at <= $3
                                )
                          )
                        RETURNING
                            progress.deletion_request_id,
                            progress.progress_version,
                            progress.attempt_count,
                            identity.issuer,
                            identity.provider_tenant,
                            identity.subject_hash,
                            progress.managed_erasure_job_id
                        """,
                        candidate["deletion_request_id"],
                        candidate["account_id"],
                        now,
                        _MAX_ATTEMPTS,
                        lease_owner,
                        lease_seconds,
                    )
                    if row is not None:
                        claimed.append(row)
        return [_managed_target(row) for row in claimed]

    async def list_processing_managed_targets(
        self,
        *,
        now: datetime,
        limit: int,
    ) -> Sequence[OwnershipManagedDeletionTarget]:
        del now
        rows = await self._pool().fetch(
            """
            SELECT progress.deletion_request_id,
                   progress.progress_version,
                   progress.attempt_count,
                   identity.issuer,
                   identity.provider_tenant,
                   identity.subject_hash,
                   progress.managed_erasure_job_id
            FROM ownership_account_deletion_target_progress progress
            JOIN ownership_account_deletion_requests request
              USING (deletion_request_id)
            JOIN ownership_external_identities identity
              ON identity.account_id = request.account_id
             AND encode(
                    sha256(convert_to(identity.identity_id::text, 'UTF8')),
                    'hex'
                 ) = request.requester_identity_hash
            WHERE progress.target_kind = 'managed_cloud_data'
              AND progress.current_state = 'processing'
              AND progress.managed_erasure_job_id IS NOT NULL
              AND progress.lease_owner IS NULL
              AND request.canceled_at IS NULL
            ORDER BY progress.updated_at, progress.deletion_request_id
            LIMIT $1
            """,
            limit,
        )
        return [_managed_target(row) for row in rows]

    async def persist_managed_target_state(
        self,
        *,
        target: OwnershipManagedDeletionTarget,
        lease_owner: UUID | None,
        transition: OwnershipManagedTargetTransition,
        now: datetime,
    ) -> bool:
        (
            current_state,
            retry_after,
            completed_at,
            last_error_kind,
        ) = _persisted_transition(transition=transition, now=now)
        job_id = transition.managed_erasure_job_id or target.managed_erasure_job_id
        status = await self._pool().execute(
            """
            UPDATE ownership_account_deletion_target_progress
            SET current_state = $4,
                blocker = NULL,
                progress_version = progress_version + 1,
                lease_owner = NULL,
                lease_expires_at = NULL,
                retry_after = $5,
                managed_erasure_job_id = $6,
                last_error_kind = $7,
                updated_at = $8,
                completed_at = $9
            WHERE deletion_request_id = $1
              AND target_kind = 'managed_cloud_data'
              AND progress_version = $2
              AND current_state = 'processing'
              AND (
                    ($3::uuid IS NULL AND lease_owner IS NULL)
                    OR lease_owner = $3
              )
              AND NOT EXISTS (
                    SELECT 1
                    FROM ownership_account_deletion_requests request
                    WHERE request.deletion_request_id = $1
                      AND request.canceled_at IS NOT NULL
              )
            """,
            target.deletion_request_id,
            target.progress_version,
            lease_owner,
            current_state,
            retry_after,
            job_id,
            last_error_kind,
            now,
            completed_at,
        )
        return status == "UPDATE 1"


class ManagedErasureService(Protocol):
    async def schedule_all_managed_data(
        self,
        *,
        request_key: UUID,
        issuer: str,
        provider_tenant: str,
        subject_hash: str,
    ) -> ManagedErasureScheduleResult: ...

    async def managed_erasure_status(
        self,
        *,
        job_id: UUID,
    ) -> ManagedErasureJobStatus: ...


@dataclass(frozen=True, slots=True)
class OwnershipDeletionLifecycleResult:
    claimed: int = 0
    processing_examined: int = 0
    not_required: int = 0
    completed: int = 0
    waiting: int = 0
    retry_scheduled: int = 0
    blocked: int = 0
    state_conflicts: int = 0

    @property
    def has_partial_failure(self) -> bool:
        return bool(self.retry_scheduled or self.blocked or self.state_conflicts)


class OwnershipDeletionLifecycleCoordinator:
    """Coordinate ownership deletion with the separately privileged managed plane."""

    def __init__(
        self,
        repository: OwnershipDeletionProgressRepository,
        managed_erasure: ManagedErasureService,
        *,
        claim_limit: int = 100,
        processing_limit: int = 100,
        lease_seconds: int = 300,
        retry_base_seconds: int = 30,
        retry_max_seconds: int = 3_600,
        event_sink: Callable[..., None] = emit_operational_event,
    ) -> None:
        if not _MIN_BATCH_SIZE <= claim_limit <= _MAX_BATCH_SIZE:
            raise ValueError("claim_limit must be between 1 and 500")
        if not _MIN_BATCH_SIZE <= processing_limit <= _MAX_BATCH_SIZE:
            raise ValueError("processing_limit must be between 1 and 500")
        if not _MIN_LEASE_SECONDS <= lease_seconds <= _MAX_LEASE_SECONDS:
            raise ValueError("lease_seconds must be between 30 and 3600")
        if not _MIN_RETRY_SECONDS <= retry_base_seconds <= _MAX_RETRY_SECONDS:
            raise ValueError("retry_base_seconds must be between 1 and 86400")
        if not retry_base_seconds <= retry_max_seconds <= _MAX_RETRY_SECONDS:
            raise ValueError(
                "retry_max_seconds must be between retry_base_seconds and 86400"
            )
        self.repository = repository
        self.managed_erasure = managed_erasure
        self.claim_limit = claim_limit
        self.processing_limit = processing_limit
        self.lease_seconds = lease_seconds
        self.retry_base_seconds = retry_base_seconds
        self.retry_max_seconds = retry_max_seconds
        self.event_sink = event_sink

    async def run_once(
        self,
        *,
        now: datetime | None = None,
        lease_owner: UUID | None = None,
        claim_due: bool = True,
    ) -> OwnershipDeletionLifecycleResult:
        reference = _utc_reference(now)
        owner = lease_owner or uuid4()
        started = time.monotonic()
        counters = _MutableResult()
        try:
            processing = await self.repository.list_processing_managed_targets(
                now=reference,
                limit=self.processing_limit,
            )
            _require_bounded_batch(
                processing,
                limit=self.processing_limit,
                source="processing",
            )
            counters.processing_examined = len(processing)
            for target in processing:
                await self._refresh_processing_target(
                    target=target,
                    now=reference,
                    counters=counters,
                )

            if claim_due:
                claimed = await self.repository.claim_due_managed_targets(
                    now=reference,
                    lease_owner=owner,
                    lease_seconds=self.lease_seconds,
                    limit=self.claim_limit,
                )
                _require_bounded_batch(
                    claimed,
                    limit=self.claim_limit,
                    source="claimed",
                )
                counters.claimed = len(claimed)
                for target in claimed:
                    await self._schedule_claimed_target(
                        target=target,
                        lease_owner=owner,
                        now=reference,
                        counters=counters,
                    )
        except OwnershipDeletionLifecycleContractError:
            self._emit_result(
                outcome="failed",
                duration_ms=_duration_ms(started),
                result=counters.freeze(),
                failure_kind="contract",
            )
            raise
        except Exception:
            self._emit_result(
                outcome="failed",
                duration_ms=_duration_ms(started),
                result=counters.freeze(),
                failure_kind="repository",
            )
            raise

        result = counters.freeze()
        self._emit_result(
            outcome="partial" if result.has_partial_failure else "completed",
            duration_ms=_duration_ms(started),
            result=result,
        )
        return result

    async def _schedule_claimed_target(
        self,
        *,
        target: OwnershipManagedDeletionTarget,
        lease_owner: UUID,
        now: datetime,
        counters: _MutableResult,
    ) -> None:
        if not _valid_target(target, require_job=False):
            await self._persist(
                target=target,
                lease_owner=lease_owner,
                transition=_blocked_transition("invalid_target"),
                now=now,
                counters=counters,
            )
            return

        try:
            resolution = await self.managed_erasure.schedule_all_managed_data(
                request_key=target.deletion_request_id,
                issuer=target.issuer,
                provider_tenant=target.provider_tenant,
                subject_hash=target.subject_hash,
            )
        except ManagedErasureRetryableError:
            await self._persist(
                target=target,
                lease_owner=lease_owner,
                transition=self._retry_transition(
                    target=target,
                    now=now,
                    failure_kind="schedule_retryable",
                ),
                now=now,
                counters=counters,
            )
            return
        except ManagedErasureTerminalError:
            await self._persist(
                target=target,
                lease_owner=lease_owner,
                transition=_blocked_transition("schedule_terminal"),
                now=now,
                counters=counters,
            )
            return

        try:
            transition = _schedule_transition(resolution)
        except ManagedErasureRetryableError:
            transition = self._retry_transition(
                target=target,
                now=now,
                failure_kind="schedule_retryable",
                managed_erasure_job_id=resolution.job_id,
            )
        await self._persist(
            target=target,
            lease_owner=lease_owner,
            transition=transition,
            now=now,
            counters=counters,
        )

    async def _refresh_processing_target(
        self,
        *,
        target: OwnershipManagedDeletionTarget,
        now: datetime,
        counters: _MutableResult,
    ) -> None:
        if not _valid_target(target, require_job=True):
            await self._persist(
                target=target,
                lease_owner=None,
                transition=_blocked_transition("invalid_target"),
                now=now,
                counters=counters,
            )
            return

        job_id = target.managed_erasure_job_id
        if job_id is None:
            raise OwnershipDeletionLifecycleContractError(
                "validated processing target is missing a job id"
            )
        try:
            status = await self.managed_erasure.managed_erasure_status(job_id=job_id)
            transition = _job_transition(job_id=job_id, status=status)
        except ManagedErasureRetryableError:
            transition = self._retry_transition(
                target=target,
                now=now,
                failure_kind="status_retryable",
            )
        except ManagedErasureTerminalError:
            transition = _blocked_transition("status_terminal")

        await self._persist(
            target=target,
            lease_owner=None,
            transition=transition,
            now=now,
            counters=counters,
        )

    async def _persist(
        self,
        *,
        target: OwnershipManagedDeletionTarget,
        lease_owner: UUID | None,
        transition: OwnershipManagedTargetTransition,
        now: datetime,
        counters: _MutableResult,
    ) -> None:
        persisted = await self.repository.persist_managed_target_state(
            target=target,
            lease_owner=lease_owner,
            transition=transition,
            now=now,
        )
        if not persisted:
            counters.state_conflicts += 1
            return
        if transition.state == "not_required":
            counters.not_required += 1
        elif transition.state == "completed":
            counters.completed += 1
        elif transition.state == "waiting":
            counters.waiting += 1
        elif transition.state == "retry_wait":
            counters.retry_scheduled += 1
        elif transition.state == "blocked":
            counters.blocked += 1

    def _retry_transition(
        self,
        *,
        target: OwnershipManagedDeletionTarget,
        now: datetime,
        failure_kind: Literal["schedule_retryable", "status_retryable"],
        managed_erasure_job_id: UUID | None = None,
    ) -> OwnershipManagedTargetTransition:
        if target.attempt_count >= _MAX_ATTEMPTS:
            return _blocked_transition("retry_exhausted")
        attempt = max(1, min(target.attempt_count, 31))
        delay = min(
            self.retry_max_seconds,
            self.retry_base_seconds * (2 ** (attempt - 1)),
        )
        return OwnershipManagedTargetTransition(
            state="retry_wait",
            blocker="retryable_failure",
            managed_erasure_job_id=(
                managed_erasure_job_id or target.managed_erasure_job_id
            ),
            retry_after=now + timedelta(seconds=delay),
            failure_kind=failure_kind,
        )

    def _emit_result(
        self,
        *,
        outcome: Literal["completed", "partial", "failed"],
        duration_ms: int,
        result: OwnershipDeletionLifecycleResult,
        failure_kind: Literal["contract", "repository"] | None = None,
    ) -> None:
        fields: dict[str, object] = {
            "service": "noop-ownership-deletion-lifecycle",
            "outcome": outcome,
            "duration_ms": duration_ms,
            **asdict(result),
        }
        if failure_kind is not None:
            fields["failure_kind"] = failure_kind
        try:
            self.event_sink(
                "ownership_deletion.lifecycle",
                severity="ERROR" if outcome == "failed" else "INFO",
                **fields,
            )
        except Exception:
            return


@dataclass(slots=True)
class _MutableResult:
    claimed: int = 0
    processing_examined: int = 0
    not_required: int = 0
    completed: int = 0
    waiting: int = 0
    retry_scheduled: int = 0
    blocked: int = 0
    state_conflicts: int = 0

    def freeze(self) -> OwnershipDeletionLifecycleResult:
        return OwnershipDeletionLifecycleResult(**asdict(self))


def _schedule_transition(
    result: ManagedErasureScheduleResult,
) -> OwnershipManagedTargetTransition:
    if result.outcome == "absent":
        return OwnershipManagedTargetTransition(state="not_required")
    if result.outcome == "already_completed":
        return OwnershipManagedTargetTransition(state="completed")
    if result.job_id is None or result.job_status is None:
        raise OwnershipDeletionLifecycleContractError(
            "managed erasure returned an incomplete job result"
        )
    return _job_transition(job_id=result.job_id, status=result.job_status)


def _job_transition(
    *,
    job_id: UUID,
    status: ManagedErasureJobStatus,
) -> OwnershipManagedTargetTransition:
    if status in {"pending", "running"}:
        return OwnershipManagedTargetTransition(
            state="waiting",
            blocker="managed_erasure_pending",
            managed_erasure_job_id=job_id,
        )
    if status == "completed":
        return OwnershipManagedTargetTransition(
            state="completed",
            managed_erasure_job_id=job_id,
        )
    if status == "retryable_failure":
        raise ManagedErasureRetryableError("managed erasure job may be retried")
    if status == "terminal_failure":
        return _blocked_transition(
            "status_terminal",
            managed_erasure_job_id=job_id,
        )
    raise OwnershipDeletionLifecycleContractError(
        "managed erasure returned an unsupported job status"
    )


def _blocked_transition(
    failure_kind: Literal[
        "schedule_terminal",
        "status_terminal",
        "invalid_target",
        "retry_exhausted",
    ],
    *,
    managed_erasure_job_id: UUID | None = None,
) -> OwnershipManagedTargetTransition:
    return OwnershipManagedTargetTransition(
        state="blocked",
        blocker="managed_erasure_failed",
        managed_erasure_job_id=managed_erasure_job_id,
        failure_kind=failure_kind,
    )


def _valid_target(
    target: OwnershipManagedDeletionTarget,
    *,
    require_job: bool,
) -> bool:
    if target.progress_version < 0 or not 0 <= target.attempt_count <= _MAX_ATTEMPTS:
        return False
    if not 1 <= len(target.issuer) <= _MAX_IDENTITY_COMPONENT_LENGTH:
        return False
    if len(target.provider_tenant) > _MAX_IDENTITY_COMPONENT_LENGTH:
        return False
    if _SUBJECT_HASH_PATTERN.fullmatch(target.subject_hash) is None:
        return False
    return not require_job or target.managed_erasure_job_id is not None


def _require_bounded_batch(
    rows: Sequence[OwnershipManagedDeletionTarget],
    *,
    limit: int,
    source: str,
) -> None:
    if len(rows) > limit:
        raise OwnershipDeletionLifecycleContractError(
            f"{source} repository result exceeded its configured limit"
        )


def _utc_reference(value: datetime | None) -> datetime:
    reference = value or datetime.now(UTC)
    if reference.tzinfo is None or reference.utcoffset() is None:
        raise ValueError("now must be timezone-aware")
    return reference.astimezone(UTC)


def _duration_ms(started: float) -> int:
    return max(0, min(86_400_000, int((time.monotonic() - started) * 1_000)))


def _managed_target(row: Any) -> OwnershipManagedDeletionTarget:
    return OwnershipManagedDeletionTarget(
        deletion_request_id=row["deletion_request_id"],
        progress_version=int(row["progress_version"]),
        attempt_count=int(row["attempt_count"]),
        issuer=str(row["issuer"]),
        provider_tenant=str(row["provider_tenant"]),
        subject_hash=str(row["subject_hash"]).strip(),
        managed_erasure_job_id=row["managed_erasure_job_id"],
    )


def _persisted_transition(
    *,
    transition: OwnershipManagedTargetTransition,
    now: datetime,
) -> tuple[str, datetime | None, datetime | None, str | None]:
    if transition.state == "waiting":
        if transition.managed_erasure_job_id is None:
            raise OwnershipDeletionLifecycleContractError(
                "waiting transition is missing its managed erasure job"
            )
        return ("processing", None, None, None)
    if transition.state == "retry_wait":
        if transition.retry_after is None or transition.retry_after <= now:
            raise OwnershipDeletionLifecycleContractError(
                "retry transition is missing a future retry time"
            )
        return (
            "scheduled",
            transition.retry_after,
            None,
            _persisted_failure_kind(transition.failure_kind),
        )
    if transition.state == "completed":
        return ("completed", None, now, None)
    if transition.state == "not_required":
        return ("not_required", None, now, None)
    if transition.state == "blocked":
        return (
            "failed",
            None,
            now,
            _persisted_failure_kind(transition.failure_kind),
        )
    raise OwnershipDeletionLifecycleContractError(
        "unsupported ownership deletion transition"
    )


def _persisted_failure_kind(
    failure_kind: OwnershipManagedTargetFailure | None,
) -> str:
    mapping = {
        "schedule_retryable": "managed_erasure_unavailable",
        "status_retryable": "managed_erasure_unavailable",
        "schedule_terminal": "managed_account_conflict",
        "status_terminal": "managed_erasure_failed",
        "invalid_target": "invalid_target",
        "retry_exhausted": "retry_exhausted",
    }
    if failure_kind not in mapping:
        raise OwnershipDeletionLifecycleContractError(
            "failure transition is missing its bounded category"
        )
    return mapping[failure_kind]
