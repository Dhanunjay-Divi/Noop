from __future__ import annotations

import json
from datetime import date, datetime
from pathlib import Path
from uuid import UUID

import pytest

from app.managed_formula_executor import (
    ClientFormulaObservation,
    FormulaDayContext,
    FormulaInputContractError,
    FormulaProvenance,
    ManagedFormulaExecutor,
)

FIXTURE = (
    Path(__file__).resolve().parent / "data" / "managed_formula_shadow_golden_v1.json"
)


def _fixture() -> dict:
    return json.loads(FIXTURE.read_text(encoding="utf-8"))


def _provenance(raw: dict) -> FormulaProvenance:
    return FormulaProvenance(
        source_kind=raw["source_kind"],
        source_revision=raw["source_revision"],
        input_manifest_sha256=raw["input_manifest_sha256"],
        calibration_revision=raw["calibration_revision"],
    )


@pytest.mark.parametrize("case", _fixture()["cases"], ids=lambda case: case["id"])
def test_cross_language_golden_formula_cases(case: dict) -> None:
    fixture = _fixture()
    expected = case["expected"]
    context = FormulaDayContext.create(
        account_id=UUID(fixture["synthetic_account_id"]),
        local_day=date.fromisoformat(case["local_day"]),
        timezone_name=case["timezone_name"],
    )
    client = ClientFormulaObservation(
        status=expected["status"],
        formula_revision=case["formula_revision"],
        value=expected["value"],
    )
    result = ManagedFormulaExecutor().execute(
        metric_key=case["metric_key"],
        formula_revision=case["formula_revision"],
        context=context,
        inputs=case["inputs"],
        provenance=_provenance(fixture["provenance"]),
        client_observation=client,
    )

    assert result.server_status == expected["status"]
    if expected["value"] is None:
        assert result.server_value is None
    else:
        assert result.server_value == pytest.approx(expected["value"], abs=1e-12)
    assert result.missing_inputs == tuple(expected["missing_inputs"])
    assert result.parity_status == expected["parity_status"]
    if expected["status"] == "present":
        assert result.absolute_delta == 0
    else:
        assert result.absolute_delta is None
    assert context.day_start_at == datetime.fromisoformat(expected["day_start_at"])
    assert context.day_end_at == datetime.fromisoformat(expected["day_end_at"])


def test_dst_day_windows_preserve_civil_day_boundaries() -> None:
    account_id = UUID("00000000-0000-4000-8000-000000000001")
    spring = FormulaDayContext.create(
        account_id=account_id,
        local_day=date(2026, 3, 8),
        timezone_name="America/Chicago",
    )
    fall = FormulaDayContext.create(
        account_id=account_id,
        local_day=date(2026, 11, 1),
        timezone_name="America/Chicago",
    )
    assert (spring.day_end_at - spring.day_start_at).total_seconds() == 23 * 3600
    assert spring.utc_offset_start_minutes == -360
    assert spring.utc_offset_end_minutes == -300
    assert (fall.day_end_at - fall.day_start_at).total_seconds() == 25 * 3600
    assert fall.utc_offset_start_minutes == -300
    assert fall.utc_offset_end_minutes == -360


def test_maximum_local_day_is_rejected_as_a_contract_error() -> None:
    with pytest.raises(
        FormulaInputContractError,
        match="local_day is outside the supported range",
    ):
        FormulaDayContext.create(
            account_id=UUID("00000000-0000-4000-8000-000000000001"),
            local_day=date.max,
            timezone_name="UTC",
        )


def test_invalid_optional_recovery_inputs_drop_and_renormalize() -> None:
    common = {
        "hrv": 55.0,
        "rhr": 52.0,
        "hrv_baseline": {"mean": 50.0, "spread": 5.0, "usable": True},
    }
    executor = ManagedFormulaExecutor()
    context = FormulaDayContext.create(
        account_id=UUID("00000000-0000-4000-8000-000000000001"),
        local_day=date(2026, 2, 1),
        timezone_name="UTC",
    )
    provenance = FormulaProvenance(
        source_kind="synthetic_fixture",
        source_revision="fixture-v1",
        input_manifest_sha256="a" * 64,
    )
    omitted = executor.execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=context,
        inputs=common,
        provenance=provenance,
    )
    invalid = executor.execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=context,
        inputs={
            **common,
            "resp": float("nan"),
            "resp_baseline": {"mean": 14.0, "spread": -1.0},
            "sleep_performance_fraction": 75.0,
            "skin_temperature_deviation_c": 34.2,
        },
        provenance=provenance,
    )
    assert invalid.server_value == pytest.approx(omitted.server_value, abs=1e-12)


def test_extreme_finite_recovery_inputs_saturate_without_overflow() -> None:
    result = ManagedFormulaExecutor().execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=FormulaDayContext.create(
            account_id=UUID("00000000-0000-4000-8000-000000000001"),
            local_day=date(2026, 2, 1),
            timezone_name="UTC",
        ),
        inputs={
            "hrv": -1e300,
            "rhr": 55.0,
            "hrv_baseline": {
                "mean": 0.0,
                "spread": 1.0,
                "usable": True,
            },
        },
        provenance=FormulaProvenance(
            source_kind="synthetic_fixture",
            source_revision="fixture-v1",
            input_manifest_sha256="f" * 64,
        ),
    )
    assert result.server_status == "present"
    assert result.server_value == 0.0


def test_huge_numeric_input_is_rejected_as_a_contract_error() -> None:
    with pytest.raises(FormulaInputContractError, match="supported range"):
        ManagedFormulaExecutor().execute(
            metric_key="recovery",
            formula_revision="noop-charge-v2",
            context=FormulaDayContext.create(
                account_id=UUID("00000000-0000-4000-8000-000000000001"),
                local_day=date(2026, 2, 1),
                timezone_name="UTC",
            ),
            inputs={
                "hrv": 10**400,
                "rhr": 55.0,
                "hrv_baseline": {
                    "mean": 50.0,
                    "spread": 1.0,
                    "usable": True,
                },
            },
            provenance=FormulaProvenance(
                source_kind="synthetic_fixture",
                source_revision="fixture-v1",
                input_manifest_sha256="f" * 64,
            ),
        )


def test_effort_step_evidence_precedes_gravity_and_gaps_are_not_bridged() -> None:
    executor = ManagedFormulaExecutor()
    context = FormulaDayContext.create(
        account_id=UUID("00000000-0000-4000-8000-000000000001"),
        local_day=date(2026, 2, 2),
        timezone_name="UTC",
    )
    provenance = FormulaProvenance(
        source_kind="synthetic_fixture",
        source_revision="fixture-v1",
        input_manifest_sha256="b" * 64,
    )
    result = executor.execute(
        metric_key="daily_effort",
        formula_revision="noop-effort-v2",
        context=context,
        inputs={
            "steps": 100,
            "gravity_samples": [
                {"ts": 0, "x": 0.0, "y": 0.0, "z": 1.0},
                {"ts": 60, "x": 1.0, "y": 0.0, "z": 1.0},
            ],
        },
        provenance=provenance,
    )
    steps_only = executor.execute(
        metric_key="daily_effort",
        formula_revision="noop-effort-v2",
        context=context,
        inputs={"steps": 100},
        provenance=provenance,
    )
    gap = executor.execute(
        metric_key="daily_effort",
        formula_revision="noop-effort-v2",
        context=context,
        inputs={
            "gravity_samples": [
                {"ts": 0, "x": 0.0, "y": 0.0, "z": 1.0},
                {"ts": 121, "x": 0.3, "y": 0.0, "z": 1.0},
            ]
        },
        provenance=provenance,
    )
    assert result.server_value == steps_only.server_value
    assert gap.server_status == "missing"


def test_out_of_range_cardio_effort_does_not_create_a_score() -> None:
    result = ManagedFormulaExecutor().execute(
        metric_key="daily_effort",
        formula_revision="noop-effort-v2",
        context=FormulaDayContext.create(
            account_id=UUID("00000000-0000-4000-8000-000000000001"),
            local_day=date(2026, 2, 2),
            timezone_name="UTC",
        ),
        inputs={"cardio_effort": 101.0},
        provenance=FormulaProvenance(
            source_kind="synthetic_fixture",
            source_revision="fixture-v1",
            input_manifest_sha256="e" * 64,
        ),
    )
    assert result.server_status == "missing"
    assert result.server_value is None


def test_input_hash_is_order_independent_and_unknown_inputs_fail_closed() -> None:
    executor = ManagedFormulaExecutor()
    context = FormulaDayContext.create(
        account_id=UUID("00000000-0000-4000-8000-000000000001"),
        local_day=date(2026, 2, 3),
        timezone_name="UTC",
    )
    provenance = FormulaProvenance(
        source_kind="synthetic_fixture",
        source_revision="fixture-v1",
        input_manifest_sha256="c" * 64,
    )
    first = executor.execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=context,
        inputs={
            "hrv": 50.0,
            "rhr": 55.0,
            "hrv_baseline": {"mean": 50.0, "spread": 5.0, "usable": True},
        },
        provenance=provenance,
    )
    second = executor.execute(
        metric_key="recovery",
        formula_revision="noop-charge-v2",
        context=context,
        inputs={
            "hrv_baseline": {"usable": True, "spread": 5.0, "mean": 50.0},
            "rhr": 55.0,
            "hrv": 50.0,
        },
        provenance=provenance,
    )
    assert first.input_set_sha256 == second.input_set_sha256
    with pytest.raises(FormulaInputContractError, match="unregistered"):
        executor.execute(
            metric_key="recovery",
            formula_revision="noop-charge-v2",
            context=context,
            inputs={
                "hrv": 50.0,
                "rhr": 55.0,
                "hrv_baseline": {
                    "mean": 50.0,
                    "spread": 5.0,
                    "usable": True,
                },
                "future_driver": 1.0,
            },
            provenance=provenance,
        )


def test_client_revision_mismatch_is_not_numeric_parity() -> None:
    fixture = _fixture()
    case = fixture["cases"][0]
    context = FormulaDayContext.create(
        account_id=UUID(fixture["synthetic_account_id"]),
        local_day=date.fromisoformat(case["local_day"]),
        timezone_name=case["timezone_name"],
    )
    result = ManagedFormulaExecutor().execute(
        metric_key=case["metric_key"],
        formula_revision=case["formula_revision"],
        context=context,
        inputs=case["inputs"],
        provenance=_provenance(fixture["provenance"]),
        client_observation=ClientFormulaObservation(
            status="present",
            formula_revision="noop-charge-v1",
            value=case["expected"]["value"],
        ),
    )
    assert result.parity_status == "revision_mismatch"
    assert result.absolute_delta is None
