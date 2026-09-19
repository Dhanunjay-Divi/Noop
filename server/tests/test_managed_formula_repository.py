from __future__ import annotations

import os
from dataclasses import replace
from datetime import UTC, date, datetime, timedelta
from pathlib import Path
from uuid import UUID, uuid4

import pytest

from app.managed_formula_executor import (
    ClientFormulaObservation,
    FormulaDayContext,
    FormulaProvenance,
    ManagedFormulaExecutor,
)
from app.managed_formula_registry import (
    CANONICAL_FORMULA_REGISTRY,
    FormulaRegistry,
)
from app.managed_formula_repository import (
    FormulaShadowConflictError,
    PostgresManagedFormulaRepository,
)
from app.repository import PostgresRepository

DATABASE_URL = os.getenv("NOOP_TEST_DATABASE_URL")
DATABASE_ENGINE = os.getenv("NOOP_TEST_DATABASE_ENGINE", "postgresql")
MIGRATION = (
    Path(__file__).resolve().parents[1]
    / "migrations"
    / "049_managed_formula_shadow.sql"
)


def test_shadow_migration_is_additive_and_cannot_flip_metric_authority() -> None:
    sql = MIGRATION.read_text(encoding="utf-8")
    assert "CREATE TABLE managed_formula_shadow_results" in sql
    assert "managed_formula_shadow_current_idx" in sql
    assert "DEFERRABLE INITIALLY DEFERRED" in sql
    assert "parity_status" in sql
    assert "rollback_source_result_id" in sql
    statements = [
        line.strip().upper()
        for line in sql.splitlines()
        if line.strip() and not line.lstrip().startswith("--")
    ]
    assert not any(
        line.startswith(
            (
                "INSERT INTO MANAGED_DAILY_AGGREGATES",
                "UPDATE MANAGED_DAILY_AGGREGATES",
            )
        )
        for line in statements
    )


def _primary() -> PostgresRepository:
    return PostgresRepository(
        DATABASE_URL or "",
        pool_min_size=1,
        pool_max_size=3,
        run_migrations=True,
        database_engine=DATABASE_ENGINE,
    )


async def _seed_account(primary: PostgresRepository, account_id: UUID) -> None:
    now = datetime.now(UTC)
    await primary._require_pool().execute(
        """
        INSERT INTO managed_accounts (
            account_id, storage_namespace, status, home_region,
            residency_policy_version, auth_valid_after, created_at, updated_at
        ) VALUES (
            $1, $2, 'active', 'test-region', 'synthetic-v1',
            $3, $3, $3
        )
        """,
        account_id,
        uuid4(),
        now,
    )


def _execution(
    *,
    account_id: UUID,
    local_day: date,
    hrv: float = 50.0,
    registry: FormulaRegistry = CANONICAL_FORMULA_REGISTRY,
    formula_revision: str = "noop-charge-v2",
    source_revision: str = "synthetic-v1",
):
    executor = ManagedFormulaExecutor(registry)
    return executor.execute(
        metric_key="recovery",
        formula_revision=formula_revision,
        context=FormulaDayContext.create(
            account_id=account_id,
            local_day=local_day,
            timezone_name="America/Chicago",
        ),
        inputs={
            "hrv": hrv,
            "rhr": 55.0,
            "hrv_baseline": {
                "mean": 50.0,
                "spread": 5.0,
                "usable": True,
            },
        },
        provenance=FormulaProvenance(
            source_kind="synthetic_test",
            source_revision=source_revision,
            input_manifest_sha256="d" * 64,
            calibration_revision="baseline-v1",
        ),
        client_observation=ClientFormulaObservation(
            status="present",
            formula_revision=formula_revision,
            value=ManagedFormulaExecutor(registry)
            .execute(
                metric_key="recovery",
                formula_revision=formula_revision,
                context=FormulaDayContext.create(
                    account_id=account_id,
                    local_day=local_day,
                    timezone_name="America/Chicago",
                ),
                inputs={
                    "hrv": hrv,
                    "rhr": 55.0,
                    "hrv_baseline": {
                        "mean": 50.0,
                        "spread": 5.0,
                        "usable": True,
                    },
                },
                provenance=FormulaProvenance(
                    source_kind="synthetic_test",
                    source_revision=source_revision,
                    input_manifest_sha256="d" * 64,
                    calibration_revision="baseline-v1",
                ),
            )
            .server_value,
        ),
    )


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_shadow_publication_is_idempotent_and_atomically_supersedes() -> None:
    primary = _primary()
    await primary.startup()
    try:
        account_id = uuid4()
        await _seed_account(primary, account_id)
        repository = PostgresManagedFormulaRepository(primary)
        day = date(2026, 9, 1)
        request_id = uuid4()
        now = datetime.now(UTC)
        first_execution = _execution(account_id=account_id, local_day=day)
        first = await repository.publish_shadow(
            request_id=request_id,
            execution=first_execution,
            now=now,
        )
        replay = await repository.publish_shadow(
            request_id=request_id,
            execution=first_execution,
            now=now + timedelta(seconds=1),
        )
        assert replay.shadow_result_id == first.shadow_result_id

        with pytest.raises(FormulaShadowConflictError):
            await repository.publish_shadow(
                request_id=request_id,
                execution=_execution(
                    account_id=account_id,
                    local_day=day,
                    hrv=60.0,
                ),
                now=now + timedelta(seconds=2),
            )

        second = await repository.publish_shadow(
            request_id=uuid4(),
            execution=_execution(
                account_id=account_id,
                local_day=day,
                hrv=60.0,
            ),
            now=now + timedelta(seconds=3),
        )
        current = await repository.current_result(
            account_id=account_id,
            metric_key="recovery",
            local_day=day,
        )
        history = await repository.result_history(
            account_id=account_id,
            metric_key="recovery",
            local_day=day,
        )
        assert current is not None
        assert current.shadow_result_id == second.shadow_result_id
        assert len(history) == 2
        prior = next(
            row for row in history if row.shadow_result_id == first.shadow_result_id
        )
        assert not prior.is_current
        assert prior.superseded_by_result_id == second.shadow_result_id
        assert first.account_id == account_id
        assert first.timezone_name == "America/Chicago"
        assert first.source_kind == "synthetic_test"
        assert first.parity_status == "match"
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_shadow_reads_are_account_scoped() -> None:
    primary = _primary()
    await primary.startup()
    try:
        first_account = uuid4()
        second_account = uuid4()
        await _seed_account(primary, first_account)
        await _seed_account(primary, second_account)
        repository = PostgresManagedFormulaRepository(primary)
        day = date(2026, 9, 2)
        now = datetime.now(UTC)
        first = await repository.publish_shadow(
            request_id=uuid4(),
            execution=_execution(account_id=first_account, local_day=day),
            now=now,
        )
        second = await repository.publish_shadow(
            request_id=uuid4(),
            execution=_execution(
                account_id=second_account,
                local_day=day,
                hrv=65.0,
            ),
            now=now,
        )
        first_read = await repository.current_result(
            account_id=first_account,
            metric_key="recovery",
            local_day=day,
        )
        second_read = await repository.current_result(
            account_id=second_account,
            metric_key="recovery",
            local_day=day,
        )
        assert first_read is not None and second_read is not None
        assert first_read.shadow_result_id == first.shadow_result_id
        assert second_read.shadow_result_id == second.shadow_result_id
        assert first_read.shadow_result_id != second_read.shadow_result_id
        assert await repository.result_history(
            account_id=uuid4(),
            metric_key="recovery",
            local_day=day,
        ) == ()
    finally:
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_failed_replacement_transaction_keeps_prior_current() -> None:
    primary = _primary()
    await primary.startup()
    trigger_name = f"formula_shadow_fail_{uuid4().hex}"
    function_name = f"formula_shadow_fail_fn_{uuid4().hex}"
    try:
        account_id = uuid4()
        await _seed_account(primary, account_id)
        repository = PostgresManagedFormulaRepository(primary)
        day = date(2026, 9, 3)
        now = datetime.now(UTC)
        prior = await repository.publish_shadow(
            request_id=uuid4(),
            execution=_execution(account_id=account_id, local_day=day),
            now=now,
        )
        pool = primary._require_pool()
        await pool.execute(
            f"""
            CREATE FUNCTION {function_name}() RETURNS trigger
            LANGUAGE plpgsql AS $$
            BEGIN
                IF NEW.source_revision = 'force_failure' THEN
                    RAISE EXCEPTION 'synthetic formula transaction failure';
                END IF;
                RETURN NEW;
            END;
            $$;
            CREATE TRIGGER {trigger_name}
            BEFORE INSERT ON managed_formula_shadow_results
            FOR EACH ROW EXECUTE FUNCTION {function_name}();
            """
        )
        with pytest.raises(Exception, match="synthetic formula transaction failure"):
            await repository.publish_shadow(
                request_id=uuid4(),
                execution=_execution(
                    account_id=account_id,
                    local_day=day,
                    hrv=60.0,
                    source_revision="force_failure",
                ),
                now=now + timedelta(seconds=1),
            )
        current = await repository.current_result(
            account_id=account_id,
            metric_key="recovery",
            local_day=day,
        )
        assert current is not None
        assert current.shadow_result_id == prior.shadow_result_id
        assert current.is_current
        assert current.superseded_by_result_id is None
    finally:
        if primary._pool is not None:
            await primary._require_pool().execute(
                f"""
                DROP TRIGGER IF EXISTS {trigger_name}
                    ON managed_formula_shadow_results;
                DROP FUNCTION IF EXISTS {function_name}();
                """
            )
        await primary.shutdown()


@pytest.mark.skipif(
    not DATABASE_URL,
    reason="NOOP_TEST_DATABASE_URL is required for PostgreSQL integration tests",
)
@pytest.mark.asyncio
async def test_revision_rollback_copies_prior_shadow_without_reexecution() -> None:
    primary = _primary()
    await primary.startup()
    try:
        account_id = uuid4()
        await _seed_account(primary, account_id)
        repository = PostgresManagedFormulaRepository(primary)
        day = date(2026, 9, 4)
        now = datetime.now(UTC)
        current_contract = CANONICAL_FORMULA_REGISTRY.require(
            "recovery",
            "noop-charge-v2",
        )
        prior_contract = replace(
            current_contract,
            formula_revision="synthetic-charge-v1",
        )
        prior_registry = FormulaRegistry.build((prior_contract,))
        prior = await repository.publish_shadow(
            request_id=uuid4(),
            execution=_execution(
                account_id=account_id,
                local_day=day,
                registry=prior_registry,
                formula_revision="synthetic-charge-v1",
            ),
            now=now,
        )
        current = await repository.publish_shadow(
            request_id=uuid4(),
            execution=_execution(
                account_id=account_id,
                local_day=day,
                hrv=62.0,
            ),
            now=now + timedelta(seconds=1),
        )
        rollback_request_id = uuid4()
        rolled_back = await repository.rollback_to_revision(
            account_id=account_id,
            request_id=rollback_request_id,
            metric_key="recovery",
            local_day=day,
            target_formula_revision="synthetic-charge-v1",
            now=now + timedelta(seconds=2),
        )
        replay = await repository.rollback_to_revision(
            account_id=account_id,
            request_id=rollback_request_id,
            metric_key="recovery",
            local_day=day,
            target_formula_revision="synthetic-charge-v1",
            now=now + timedelta(seconds=3),
        )
        assert replay.shadow_result_id == rolled_back.shadow_result_id
        assert rolled_back.publication_kind == "rollback"
        assert rolled_back.rollback_source_result_id == prior.shadow_result_id
        assert rolled_back.formula_revision == "synthetic-charge-v1"
        assert rolled_back.server_value == prior.server_value
        after = await repository.current_result(
            account_id=account_id,
            metric_key="recovery",
            local_day=day,
        )
        assert after is not None
        assert after.shadow_result_id == rolled_back.shadow_result_id
        history = await repository.result_history(
            account_id=account_id,
            metric_key="recovery",
            local_day=day,
        )
        superseded_current = next(
            row for row in history if row.shadow_result_id == current.shadow_result_id
        )
        assert superseded_current.superseded_by_result_id == (
            rolled_back.shadow_result_id
        )
    finally:
        await primary.shutdown()
