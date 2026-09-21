from __future__ import annotations

from dataclasses import FrozenInstanceError

import pytest

from app.managed_formula_registry import CANONICAL_FORMULA_REGISTRY


def test_canonical_registry_pins_current_client_revisions_and_contracts() -> None:
    contracts = {
        (contract.metric_key, contract.formula_revision): contract
        for contract in CANONICAL_FORMULA_REGISTRY.contracts
    }
    assert set(contracts) == {
        ("recovery", "noop-charge-v2"),
        ("daily_effort", "noop-effort-v2"),
    }
    assert contracts[("recovery", "noop-charge-v2")].input_schema_revision == 1
    assert contracts[("daily_effort", "noop-effort-v2")].output_unit == ("score_0_100")
    assert {
        name
        for name, field in contracts[
            ("recovery", "noop-charge-v2")
        ].input_by_name.items()
        if field.required
    } == {"hrv", "rhr", "hrv_baseline"}


def test_registry_and_contracts_are_immutable() -> None:
    contract = CANONICAL_FORMULA_REGISTRY.require(
        "recovery",
        "noop-charge-v2",
    )
    with pytest.raises(TypeError):
        contract.input_by_name["future_input"] = contract.inputs[0]  # type: ignore[index]
    with pytest.raises(FrozenInstanceError):
        contract.metric_key = "changed"  # type: ignore[misc]


def test_unknown_metric_revision_fails_closed() -> None:
    with pytest.raises(KeyError, match="unregistered formula contract"):
        CANONICAL_FORMULA_REGISTRY.require("recovery", "future-revision")
