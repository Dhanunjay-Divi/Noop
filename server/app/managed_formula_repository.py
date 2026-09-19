from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass
from datetime import date, datetime
from typing import Any
from uuid import UUID, uuid4

from app.managed_formula_executor import FormulaExecution


class FormulaShadowConflictError(Exception):
    """Raised when an idempotency key is reused for different shadow work."""


class FormulaShadowNotFoundError(Exception):
    """Raised when a requested shadow result or rollback revision is absent."""


@dataclass(frozen=True, slots=True)
class FormulaShadowRecord:
    shadow_result_id: UUID
    account_id: UUID
    request_id: UUID
    metric_key: str
    formula_revision: str
    input_schema_revision: int
    output_unit: str
    local_day: date
    timezone_name: str
    day_start_at: datetime
    day_end_at: datetime
    utc_offset_start_minutes: int
    utc_offset_end_minutes: int
    source_kind: str
    source_revision: str
    input_manifest_sha256: str
    input_set_sha256: str
    calibration_revision: str | None
    server_status: str
    server_value: float | None
    client_status: str
    client_formula_revision: str | None
    client_value: float | None
    parity_status: str
    absolute_delta: float | None
    parity_tolerance: float
    missing_inputs: tuple[str, ...]
    execution_sha256: str
    publication_kind: str
    rollback_source_result_id: UUID | None
    is_current: bool
    created_at: datetime
    superseded_by_result_id: UUID | None
    superseded_at: datetime | None


class PostgresManagedFormulaRepository:
    """Account-scoped persistence for non-authoritative formula shadow results."""

    def __init__(self, primary_repository: Any) -> None:
        self._primary = primary_repository

    async def publish_shadow(
        self,
        *,
        request_id: UUID,
        execution: FormulaExecution,
        now: datetime,
    ) -> FormulaShadowRecord:
        _require_aware(now)
        pool = self._primary._require_pool()
        account_id = execution.context.account_id
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_request(
                    connection,
                    account_id=account_id,
                    request_id=request_id,
                )
                existing = await self._by_request(
                    connection,
                    account_id=account_id,
                    request_id=request_id,
                )
                if existing is not None:
                    if existing.execution_sha256 != execution.execution_sha256:
                        raise FormulaShadowConflictError(
                            "formula shadow request was reused with different content"
                        )
                    return existing

                await self._lock_metric_day(
                    connection,
                    account_id=account_id,
                    metric_key=execution.metric_key,
                    local_day=execution.context.local_day,
                )
                result_id = uuid4()
                await self._supersede_current(
                    connection,
                    account_id=account_id,
                    metric_key=execution.metric_key,
                    local_day=execution.context.local_day,
                    replacement_result_id=result_id,
                    now=now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_formula_shadow_results (
                        shadow_result_id, account_id, request_id,
                        metric_key, formula_revision, input_schema_revision,
                        output_unit, local_day, timezone_name,
                        day_start_at, day_end_at,
                        utc_offset_start_minutes, utc_offset_end_minutes,
                        source_kind, source_revision,
                        input_manifest_sha256, input_set_sha256,
                        calibration_revision,
                        server_status, server_value,
                        client_status, client_formula_revision, client_value,
                        parity_status, absolute_delta, parity_tolerance,
                        missing_inputs, execution_sha256,
                        publication_kind, rollback_source_result_id,
                        is_current, created_at
                    ) VALUES (
                        $1, $2, $3,
                        $4, $5, $6,
                        $7, $8, $9,
                        $10, $11,
                        $12, $13,
                        $14, $15,
                        $16, $17,
                        $18,
                        $19, $20,
                        $21, $22, $23,
                        $24, $25, $26,
                        $27::text[], $28,
                        'shadow', NULL,
                        true, $29
                    )
                    """,
                    result_id,
                    account_id,
                    request_id,
                    execution.metric_key,
                    execution.formula_revision,
                    execution.input_schema_revision,
                    execution.output_unit,
                    execution.context.local_day,
                    execution.context.timezone_name,
                    execution.context.day_start_at,
                    execution.context.day_end_at,
                    execution.context.utc_offset_start_minutes,
                    execution.context.utc_offset_end_minutes,
                    execution.provenance.source_kind,
                    execution.provenance.source_revision,
                    execution.provenance.input_manifest_sha256,
                    execution.input_set_sha256,
                    execution.provenance.calibration_revision,
                    execution.server_status,
                    execution.server_value,
                    execution.client_status,
                    execution.client_formula_revision,
                    execution.client_value,
                    execution.parity_status,
                    execution.absolute_delta,
                    execution.parity_tolerance,
                    list(execution.missing_inputs),
                    execution.execution_sha256,
                    now,
                )
                return await self._require_result(
                    connection,
                    account_id=account_id,
                    result_id=result_id,
                )

    async def rollback_to_revision(
        self,
        *,
        account_id: UUID,
        request_id: UUID,
        metric_key: str,
        local_day: date,
        target_formula_revision: str,
        now: datetime,
    ) -> FormulaShadowRecord:
        _require_aware(now)
        pool = self._primary._require_pool()
        async with pool.acquire() as connection:
            async with connection.transaction():
                await self._lock_request(
                    connection,
                    account_id=account_id,
                    request_id=request_id,
                )
                existing = await self._by_request(
                    connection,
                    account_id=account_id,
                    request_id=request_id,
                )
                if existing is not None:
                    if (
                        existing.publication_kind != "rollback"
                        or existing.metric_key != metric_key
                        or existing.local_day != local_day
                        or existing.formula_revision
                        != target_formula_revision
                    ):
                        raise FormulaShadowConflictError(
                            "formula rollback request was reused with different content"
                        )
                    return existing

                await self._lock_metric_day(
                    connection,
                    account_id=account_id,
                    metric_key=metric_key,
                    local_day=local_day,
                )
                target = await connection.fetchrow(
                    """
                    SELECT *
                    FROM managed_formula_shadow_results
                    WHERE account_id = $1
                      AND metric_key = $2
                      AND local_day = $3
                      AND formula_revision = $4
                    ORDER BY created_at DESC, shadow_result_id DESC
                    LIMIT 1
                    """,
                    account_id,
                    metric_key,
                    local_day,
                    target_formula_revision,
                )
                if target is None:
                    raise FormulaShadowNotFoundError(
                        "formula rollback revision was not found"
                    )

                result_id = uuid4()
                execution_sha256 = _rollback_sha256(
                    account_id=account_id,
                    metric_key=metric_key,
                    local_day=local_day,
                    target_result_id=target["shadow_result_id"],
                )
                await self._supersede_current(
                    connection,
                    account_id=account_id,
                    metric_key=metric_key,
                    local_day=local_day,
                    replacement_result_id=result_id,
                    now=now,
                )
                await connection.execute(
                    """
                    INSERT INTO managed_formula_shadow_results (
                        shadow_result_id, account_id, request_id,
                        metric_key, formula_revision, input_schema_revision,
                        output_unit, local_day, timezone_name,
                        day_start_at, day_end_at,
                        utc_offset_start_minutes, utc_offset_end_minutes,
                        source_kind, source_revision,
                        input_manifest_sha256, input_set_sha256,
                        calibration_revision,
                        server_status, server_value,
                        client_status, client_formula_revision, client_value,
                        parity_status, absolute_delta, parity_tolerance,
                        missing_inputs, execution_sha256,
                        publication_kind, rollback_source_result_id,
                        is_current, created_at
                    )
                    SELECT
                        $1, account_id, $2,
                        metric_key, formula_revision, input_schema_revision,
                        output_unit, local_day, timezone_name,
                        day_start_at, day_end_at,
                        utc_offset_start_minutes, utc_offset_end_minutes,
                        source_kind, source_revision,
                        input_manifest_sha256, input_set_sha256,
                        calibration_revision,
                        server_status, server_value,
                        client_status, client_formula_revision, client_value,
                        parity_status, absolute_delta, parity_tolerance,
                        missing_inputs, $3,
                        'rollback', shadow_result_id,
                        true, $4
                    FROM managed_formula_shadow_results
                    WHERE account_id = $5 AND shadow_result_id = $6
                    """,
                    result_id,
                    request_id,
                    execution_sha256,
                    now,
                    account_id,
                    target["shadow_result_id"],
                )
                return await self._require_result(
                    connection,
                    account_id=account_id,
                    result_id=result_id,
                )

    async def current_result(
        self,
        *,
        account_id: UUID,
        metric_key: str,
        local_day: date,
    ) -> FormulaShadowRecord | None:
        pool = self._primary._require_pool()
        row = await pool.fetchrow(
            """
            SELECT *
            FROM managed_formula_shadow_results
            WHERE account_id = $1
              AND metric_key = $2
              AND local_day = $3
              AND is_current
            """,
            account_id,
            metric_key,
            local_day,
        )
        return _record(row) if row is not None else None

    async def result_history(
        self,
        *,
        account_id: UUID,
        metric_key: str,
        local_day: date,
        limit: int = 100,
    ) -> tuple[FormulaShadowRecord, ...]:
        if not 1 <= limit <= 100:
            raise ValueError("limit must be between 1 and 100")
        pool = self._primary._require_pool()
        rows = await pool.fetch(
            """
            SELECT *
            FROM managed_formula_shadow_results
            WHERE account_id = $1
              AND metric_key = $2
              AND local_day = $3
            ORDER BY created_at DESC, shadow_result_id DESC
            LIMIT $4
            """,
            account_id,
            metric_key,
            local_day,
            limit,
        )
        return tuple(_record(row) for row in rows)

    @staticmethod
    async def _lock_request(
        connection: Any,
        *,
        account_id: UUID,
        request_id: UUID,
    ) -> None:
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            f"noop-formula-request:{account_id}:{request_id}",
        )

    @staticmethod
    async def _lock_metric_day(
        connection: Any,
        *,
        account_id: UUID,
        metric_key: str,
        local_day: date,
    ) -> None:
        await connection.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            f"noop-formula-day:{account_id}:{metric_key}:{local_day.isoformat()}",
        )

    @staticmethod
    async def _supersede_current(
        connection: Any,
        *,
        account_id: UUID,
        metric_key: str,
        local_day: date,
        replacement_result_id: UUID,
        now: datetime,
    ) -> None:
        await connection.execute(
            """
            UPDATE managed_formula_shadow_results
            SET is_current = false,
                superseded_by_result_id = $4,
                superseded_at = $5
            WHERE account_id = $1
              AND metric_key = $2
              AND local_day = $3
              AND is_current
            """,
            account_id,
            metric_key,
            local_day,
            replacement_result_id,
            now,
        )

    @staticmethod
    async def _by_request(
        connection: Any,
        *,
        account_id: UUID,
        request_id: UUID,
    ) -> FormulaShadowRecord | None:
        row = await connection.fetchrow(
            """
            SELECT *
            FROM managed_formula_shadow_results
            WHERE account_id = $1 AND request_id = $2
            """,
            account_id,
            request_id,
        )
        return _record(row) if row is not None else None

    @staticmethod
    async def _require_result(
        connection: Any,
        *,
        account_id: UUID,
        result_id: UUID,
    ) -> FormulaShadowRecord:
        row = await connection.fetchrow(
            """
            SELECT *
            FROM managed_formula_shadow_results
            WHERE account_id = $1 AND shadow_result_id = $2
            """,
            account_id,
            result_id,
        )
        if row is None:  # pragma: no cover - insert and read share a transaction
            raise FormulaShadowNotFoundError("formula shadow result was not found")
        return _record(row)


def _record(row: Any) -> FormulaShadowRecord:
    return FormulaShadowRecord(
        shadow_result_id=row["shadow_result_id"],
        account_id=row["account_id"],
        request_id=row["request_id"],
        metric_key=str(row["metric_key"]),
        formula_revision=str(row["formula_revision"]),
        input_schema_revision=int(row["input_schema_revision"]),
        output_unit=str(row["output_unit"]),
        local_day=row["local_day"],
        timezone_name=str(row["timezone_name"]),
        day_start_at=row["day_start_at"],
        day_end_at=row["day_end_at"],
        utc_offset_start_minutes=int(row["utc_offset_start_minutes"]),
        utc_offset_end_minutes=int(row["utc_offset_end_minutes"]),
        source_kind=str(row["source_kind"]),
        source_revision=str(row["source_revision"]),
        input_manifest_sha256=str(row["input_manifest_sha256"]).strip(),
        input_set_sha256=str(row["input_set_sha256"]).strip(),
        calibration_revision=(
            str(row["calibration_revision"])
            if row["calibration_revision"] is not None
            else None
        ),
        server_status=str(row["server_status"]),
        server_value=(
            float(row["server_value"])
            if row["server_value"] is not None
            else None
        ),
        client_status=str(row["client_status"]),
        client_formula_revision=(
            str(row["client_formula_revision"])
            if row["client_formula_revision"] is not None
            else None
        ),
        client_value=(
            float(row["client_value"])
            if row["client_value"] is not None
            else None
        ),
        parity_status=str(row["parity_status"]),
        absolute_delta=(
            float(row["absolute_delta"])
            if row["absolute_delta"] is not None
            else None
        ),
        parity_tolerance=float(row["parity_tolerance"]),
        missing_inputs=tuple(row["missing_inputs"]),
        execution_sha256=str(row["execution_sha256"]).strip(),
        publication_kind=str(row["publication_kind"]),
        rollback_source_result_id=row["rollback_source_result_id"],
        is_current=bool(row["is_current"]),
        created_at=row["created_at"],
        superseded_by_result_id=row["superseded_by_result_id"],
        superseded_at=row["superseded_at"],
    )


def _require_aware(value: datetime) -> None:
    if value.tzinfo is None or value.utcoffset() is None:
        raise ValueError("repository timestamps must be timezone-aware")


def _rollback_sha256(
    *,
    account_id: UUID,
    metric_key: str,
    local_day: date,
    target_result_id: UUID,
) -> str:
    payload = json.dumps(
        {
            "account_id": str(account_id),
            "local_day": local_day.isoformat(),
            "metric_key": metric_key,
            "publication_kind": "rollback",
            "target_result_id": str(target_result_id),
        },
        ensure_ascii=True,
        separators=(",", ":"),
        sort_keys=True,
    ).encode("ascii")
    return hashlib.sha256(payload).hexdigest()
