from __future__ import annotations

import pytest

from app.config import Settings


def test_database_engine_defaults_to_timescaledb(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.delenv("NOOP_DATABASE_ENGINE", raising=False)

    assert Settings.from_env().database_engine == "timescaledb"


def test_database_engine_accepts_standard_postgresql(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("NOOP_DATABASE_ENGINE", "PostgreSQL")

    assert Settings.from_env().database_engine == "postgresql"


def test_database_engine_rejects_unknown_values(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv("NOOP_DATABASE_ENGINE", "cloudsql")

    with pytest.raises(ValueError, match="NOOP_DATABASE_ENGINE"):
        Settings.from_env()


def test_non_api_process_can_validate_without_global_administrator_token() -> None:
    Settings(
        api_token=None,
        database_url="postgresql://noop:test@db/noop",
    ).validate_for_startup(
        needs_database=True,
        needs_api_token=False,
    )


def test_delivery_lease_must_outlast_provider_timeout_with_poll_margin() -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        safety_worker_poll_seconds=2,
        safety_provider_request_timeout_seconds=15,
        safety_delivery_lease_seconds=17,
    )

    with pytest.raises(RuntimeError, match="provider request timeout"):
        settings.validate_for_startup(needs_database=False)


def test_worker_heartbeat_timeout_must_exceed_poll_interval() -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        safety_worker_poll_seconds=2,
        safety_worker_heartbeat_timeout_seconds=2,
    )

    with pytest.raises(RuntimeError, match="HEARTBEAT_TIMEOUT"):
        settings.validate_for_startup(needs_database=False)


def test_worker_concurrency_reserves_a_database_connection() -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        pool_max_size=6,
        safety_worker_max_concurrency=6,
    )

    with pytest.raises(RuntimeError, match="DB_POOL_MAX_SIZE"):
        settings.validate_for_startup(needs_database=False)


def test_automatic_paging_requires_an_approved_fall_contract() -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        safety_automatic_paging_enabled=True,
    )

    with pytest.raises(RuntimeError, match="approved fall detector"):
        settings.validate_for_startup(needs_database=False)

    Settings(
        api_token="a" * 32,
        database_url=None,
        safety_automatic_paging_enabled=True,
        safety_approved_fall_detectors=frozenset({"noop_band_fall:1"}),
    ).validate_for_startup(needs_database=False)


def test_safety_escalation_must_finish_inside_eight_hour_window() -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        safety_escalation_rounds=8,
        safety_escalation_interval_seconds=70 * 60,
    )

    with pytest.raises(RuntimeError, match="8-hour incident window"):
        settings.validate_for_startup(needs_database=False)


@pytest.mark.parametrize("interval_seconds", [59, 86_401])
def test_safety_escalation_interval_matches_database_contract(
    interval_seconds: int,
) -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        safety_acknowledgement_timeout_seconds=1,
        safety_escalation_interval_seconds=interval_seconds,
    )

    with pytest.raises(RuntimeError, match="between 60 and 86400"):
        settings.validate_for_startup(needs_database=False)


def test_fall_detector_allowlist_rejects_duplicates_and_bad_versions(
    monkeypatch: pytest.MonkeyPatch,
) -> None:
    monkeypatch.setenv(
        "NOOP_SAFETY_APPROVED_FALL_DETECTORS",
        "noop_band_fall:1,noop_band_fall:1",
    )
    with pytest.raises(ValueError, match="duplicate"):
        Settings.from_env()

    monkeypatch.setenv(
        "NOOP_SAFETY_APPROVED_FALL_DETECTORS",
        "noop_band_fall:zero",
    )
    with pytest.raises(RuntimeError, match="detector_id:version"):
        Settings.from_env().validate_for_startup(
            needs_database=False,
            needs_api_token=False,
        )

    monkeypatch.setenv(
        "NOOP_SAFETY_APPROVED_FALL_DETECTORS",
        "noop_band_fall:10000",
    )
    Settings.from_env().validate_for_startup(
        needs_database=False,
        needs_api_token=False,
    )


def test_retention_is_explicitly_opt_in(monkeypatch: pytest.MonkeyPatch) -> None:
    for name in (
        "NOOP_RETENTION_DAYS",
        "NOOP_SAFETY_INCIDENT_RETENTION_DAYS",
        "NOOP_SAFETY_CONTACT_RETENTION_DAYS",
    ):
        monkeypatch.delenv(name, raising=False)

    disabled = Settings.from_env()

    assert disabled.retention_days is None
    assert disabled.safety_incident_retention_days is None
    assert disabled.safety_contact_retention_days is None

    monkeypatch.setenv("NOOP_RETENTION_DAYS", "30")
    monkeypatch.setenv("NOOP_SAFETY_INCIDENT_RETENTION_DAYS", "90")
    monkeypatch.setenv("NOOP_SAFETY_CONTACT_RETENTION_DAYS", "45")
    enabled = Settings.from_env()

    assert enabled.retention_days == 30
    assert enabled.safety_incident_retention_days == 90
    assert enabled.safety_contact_retention_days == 45


@pytest.mark.parametrize(
    "trusted_proxies",
    ("*", "0.0.0.0/0", "::/0", "", "127.0.0.1,", "10.20.0.1/24"),
)
def test_forwarded_headers_never_trust_arbitrary_sources(
    trusted_proxies: str,
) -> None:
    settings = Settings(
        api_token="a" * 32,
        database_url=None,
        forwarded_allow_ips=trusted_proxies,
    )

    with pytest.raises(RuntimeError, match="NOOP_FORWARDED_ALLOW_IPS"):
        settings.validate_for_startup(needs_database=False)


def test_forwarded_headers_accept_explicit_proxy_addresses() -> None:
    Settings(
        api_token="a" * 32,
        database_url=None,
        forwarded_allow_ips="127.0.0.1,10.20.0.0/24,2001:db8::1",
    ).validate_for_startup(needs_database=False)
