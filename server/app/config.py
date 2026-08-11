from __future__ import annotations

import os
from dataclasses import dataclass


def _positive_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if value <= 0:
        raise ValueError(f"{name} must be greater than zero")
    return value


@dataclass(frozen=True, slots=True)
class Settings:
    """Runtime settings.

    Secrets intentionally have no built-in production defaults. Keeping settings
    in this small dataclass also lets the API tests run without a settings library
    or a database.
    """

    api_token: str | None
    database_url: str | None
    max_request_bytes: int = 10 * 1024 * 1024
    pool_min_size: int = 1
    pool_max_size: int = 8
    retention_days: int | None = None
    retention_interval_hours: int = 24
    idempotency_replay_guard_days: int = 30
    rate_limit_requests_per_minute: int = 120
    rate_limit_origin_requests_per_minute: int = 300
    rate_limit_max_keys: int = 10_000
    dashboard_enabled: bool = True

    @classmethod
    def from_env(cls) -> "Settings":
        retention_raw = os.getenv("NOOP_RETENTION_DAYS", "0")
        try:
            retention_value = int(retention_raw)
        except ValueError as exc:
            raise ValueError("NOOP_RETENTION_DAYS must be an integer") from exc
        if retention_value < 0:
            raise ValueError("NOOP_RETENTION_DAYS cannot be negative")
        dashboard_raw = os.getenv("NOOP_DASHBOARD_ENABLED", "true").casefold()
        if dashboard_raw not in {"true", "false", "1", "0", "yes", "no"}:
            raise ValueError("NOOP_DASHBOARD_ENABLED must be true or false")
        return cls(
            api_token=os.getenv("NOOP_API_TOKEN"),
            database_url=os.getenv("NOOP_DATABASE_URL"),
            max_request_bytes=_positive_int("NOOP_MAX_REQUEST_BYTES", 10 * 1024 * 1024),
            pool_min_size=_positive_int("NOOP_DB_POOL_MIN_SIZE", 1),
            pool_max_size=_positive_int("NOOP_DB_POOL_MAX_SIZE", 8),
            retention_days=retention_value or None,
            retention_interval_hours=_positive_int("NOOP_RETENTION_INTERVAL_HOURS", 24),
            idempotency_replay_guard_days=_positive_int(
                "NOOP_IDEMPOTENCY_REPLAY_GUARD_DAYS", 30
            ),
            rate_limit_requests_per_minute=_positive_int(
                "NOOP_RATE_LIMIT_REQUESTS_PER_MINUTE", 120
            ),
            rate_limit_origin_requests_per_minute=_positive_int(
                "NOOP_RATE_LIMIT_ORIGIN_REQUESTS_PER_MINUTE", 300
            ),
            rate_limit_max_keys=_positive_int("NOOP_RATE_LIMIT_MAX_KEYS", 10_000),
            dashboard_enabled=dashboard_raw in {"true", "1", "yes"},
        )

    def validate_for_startup(self, *, needs_database: bool) -> None:
        if not self.api_token:
            raise RuntimeError("NOOP_API_TOKEN is required")
        if len(self.api_token.encode("utf-8")) < 32:
            raise RuntimeError("NOOP_API_TOKEN must be at least 32 bytes")
        if needs_database and not self.database_url:
            raise RuntimeError("NOOP_DATABASE_URL is required")
        if self.pool_min_size > self.pool_max_size:
            raise RuntimeError(
                "NOOP_DB_POOL_MIN_SIZE cannot exceed NOOP_DB_POOL_MAX_SIZE"
            )
