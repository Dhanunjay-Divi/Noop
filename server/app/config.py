from __future__ import annotations

import os
from dataclasses import dataclass
from ipaddress import ip_network
from urllib.parse import urlsplit


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


def _boolean(name: str, default: bool) -> bool:
    raw = os.getenv(name)
    if raw is None:
        return default
    normalized = raw.casefold()
    if normalized not in {"true", "false", "1", "0", "yes", "no"}:
        raise ValueError(f"{name} must be true or false")
    return normalized in {"true", "1", "yes"}


def _nonnegative_int(name: str, default: int) -> int:
    raw = os.getenv(name)
    if raw is None:
        return default
    try:
        value = int(raw)
    except ValueError as exc:
        raise ValueError(f"{name} must be an integer") from exc
    if value < 0:
        raise ValueError(f"{name} cannot be negative")
    return value


def _choice(name: str, default: str, allowed: frozenset[str]) -> str:
    value = os.getenv(name, default).strip().casefold()
    if value not in allowed:
        raise ValueError(f"{name} must be one of: {', '.join(sorted(allowed))}")
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
    auth_mode: str = "single_owner"
    max_request_bytes: int = 10 * 1024 * 1024
    export_max_rows: int = 100_000
    pool_min_size: int = 1
    pool_max_size: int = 8
    database_statement_cache_size: int = 100
    run_migrations: bool = True
    retention_days: int | None = None
    retention_interval_hours: int = 24
    idempotency_replay_guard_days: int = 30
    rate_limit_requests_per_minute: int = 120
    rate_limit_origin_requests_per_minute: int = 300
    rate_limit_provider_callback_pre_auth_requests_per_minute: int = 12_000
    rate_limit_provider_callback_requests_per_minute: int = 6_000
    rate_limit_max_keys: int = 10_000
    forwarded_allow_ips: str = "127.0.0.1"
    dashboard_enabled: bool = True
    public_base_url: str | None = None
    twilio_account_sid: str | None = None
    twilio_auth_token: str | None = None
    twilio_from_phone: str | None = None
    twilio_status_callback_secret: str | None = None
    safety_capability_secret: str | None = None
    safety_acknowledgement_timeout_seconds: int = 90
    safety_incident_ttl_seconds: int = 30 * 60
    safety_worker_poll_seconds: int = 2
    safety_worker_heartbeat_timeout_seconds: int = 30
    safety_delivery_lease_seconds: int = 30
    safety_retry_base_seconds: int = 5
    safety_provider_request_timeout_seconds: int = 15
    safety_provider_receipt_timeout_seconds: int = 5 * 60
    safety_worker_enabled: bool = True
    safety_worker_batch_size: int = 20
    safety_worker_max_concurrency: int = 6
    safety_maintenance_batch_size: int = 200
    safety_provider_max_requests_per_second: int = 5
    safety_monitoring_window_seconds: int = 24 * 60 * 60
    safety_incident_retention_days: int | None = None
    safety_contact_retention_days: int | None = None
    safety_retention_interval_hours: int = 24
    safety_retention_max_batches_per_run: int = 20

    @classmethod
    def from_env(cls) -> "Settings":
        retention_raw = os.getenv("NOOP_RETENTION_DAYS", "0")
        try:
            retention_value = int(retention_raw)
        except ValueError as exc:
            raise ValueError("NOOP_RETENTION_DAYS must be an integer") from exc
        if retention_value < 0:
            raise ValueError("NOOP_RETENTION_DAYS cannot be negative")
        return cls(
            api_token=os.getenv("NOOP_API_TOKEN"),
            database_url=os.getenv("NOOP_DATABASE_URL"),
            auth_mode=_choice(
                "NOOP_AUTH_MODE",
                "single_owner",
                frozenset({"single_owner", "shared"}),
            ),
            max_request_bytes=_positive_int("NOOP_MAX_REQUEST_BYTES", 10 * 1024 * 1024),
            export_max_rows=_positive_int("NOOP_EXPORT_MAX_ROWS", 100_000),
            pool_min_size=_positive_int("NOOP_DB_POOL_MIN_SIZE", 1),
            pool_max_size=_positive_int("NOOP_DB_POOL_MAX_SIZE", 8),
            database_statement_cache_size=_nonnegative_int(
                "NOOP_DB_STATEMENT_CACHE_SIZE", 100
            ),
            run_migrations=_boolean("NOOP_RUN_MIGRATIONS", True),
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
            rate_limit_provider_callback_pre_auth_requests_per_minute=_positive_int(
                "NOOP_RATE_LIMIT_PROVIDER_CALLBACK_PRE_AUTH_REQUESTS_PER_MINUTE",
                12_000,
            ),
            rate_limit_provider_callback_requests_per_minute=_positive_int(
                "NOOP_RATE_LIMIT_PROVIDER_CALLBACK_REQUESTS_PER_MINUTE",
                6_000,
            ),
            rate_limit_max_keys=_positive_int("NOOP_RATE_LIMIT_MAX_KEYS", 10_000),
            forwarded_allow_ips=os.getenv(
                "NOOP_FORWARDED_ALLOW_IPS",
                "127.0.0.1",
            ).strip(),
            dashboard_enabled=_boolean("NOOP_DASHBOARD_ENABLED", True),
            public_base_url=os.getenv("NOOP_PUBLIC_BASE_URL"),
            twilio_account_sid=os.getenv("NOOP_TWILIO_ACCOUNT_SID"),
            twilio_auth_token=os.getenv("NOOP_TWILIO_AUTH_TOKEN"),
            twilio_from_phone=os.getenv("NOOP_TWILIO_FROM_PHONE"),
            twilio_status_callback_secret=os.getenv(
                "NOOP_TWILIO_STATUS_CALLBACK_SECRET"
            ),
            safety_capability_secret=os.getenv("NOOP_SAFETY_CAPABILITY_SECRET"),
            safety_acknowledgement_timeout_seconds=_positive_int(
                "NOOP_SAFETY_ACKNOWLEDGEMENT_TIMEOUT_SECONDS", 90
            ),
            safety_incident_ttl_seconds=_positive_int(
                "NOOP_SAFETY_INCIDENT_TTL_SECONDS", 30 * 60
            ),
            safety_worker_poll_seconds=_positive_int(
                "NOOP_SAFETY_WORKER_POLL_SECONDS", 2
            ),
            safety_worker_heartbeat_timeout_seconds=_positive_int(
                "NOOP_SAFETY_WORKER_HEARTBEAT_TIMEOUT_SECONDS", 30
            ),
            safety_delivery_lease_seconds=_positive_int(
                "NOOP_SAFETY_DELIVERY_LEASE_SECONDS", 30
            ),
            safety_retry_base_seconds=_positive_int(
                "NOOP_SAFETY_RETRY_BASE_SECONDS", 5
            ),
            safety_provider_request_timeout_seconds=_positive_int(
                "NOOP_SAFETY_PROVIDER_REQUEST_TIMEOUT_SECONDS", 15
            ),
            safety_provider_receipt_timeout_seconds=_positive_int(
                "NOOP_SAFETY_PROVIDER_RECEIPT_TIMEOUT_SECONDS", 5 * 60
            ),
            safety_worker_enabled=_boolean("NOOP_SAFETY_WORKER_ENABLED", True),
            safety_worker_batch_size=_positive_int("NOOP_SAFETY_WORKER_BATCH_SIZE", 20),
            safety_worker_max_concurrency=_positive_int(
                "NOOP_SAFETY_WORKER_MAX_CONCURRENCY", 6
            ),
            safety_maintenance_batch_size=_positive_int(
                "NOOP_SAFETY_MAINTENANCE_BATCH_SIZE", 200
            ),
            safety_provider_max_requests_per_second=_positive_int(
                "NOOP_SAFETY_PROVIDER_MAX_REQUESTS_PER_SECOND", 5
            ),
            safety_monitoring_window_seconds=_positive_int(
                "NOOP_SAFETY_MONITORING_WINDOW_SECONDS", 24 * 60 * 60
            ),
            safety_incident_retention_days=(
                _nonnegative_int("NOOP_SAFETY_INCIDENT_RETENTION_DAYS", 0) or None
            ),
            safety_contact_retention_days=(
                _nonnegative_int("NOOP_SAFETY_CONTACT_RETENTION_DAYS", 0) or None
            ),
            safety_retention_interval_hours=_positive_int(
                "NOOP_SAFETY_RETENTION_INTERVAL_HOURS", 24
            ),
            safety_retention_max_batches_per_run=_positive_int(
                "NOOP_SAFETY_RETENTION_MAX_BATCHES_PER_RUN", 20
            ),
        )

    @property
    def paging_configured(self) -> bool:
        return all(
            (
                self.public_base_url,
                self.twilio_account_sid,
                self.twilio_auth_token,
                self.twilio_from_phone,
                self.twilio_status_callback_secret,
                self.safety_capability_secret,
            )
        )

    def validate_for_startup(
        self,
        *,
        needs_database: bool,
        needs_api_token: bool = True,
    ) -> None:
        if needs_api_token:
            if not self.api_token:
                raise RuntimeError("NOOP_API_TOKEN is required")
            if len(self.api_token.encode("utf-8")) < 32:
                raise RuntimeError("NOOP_API_TOKEN must be at least 32 bytes")
        if needs_database and not self.database_url:
            raise RuntimeError("NOOP_DATABASE_URL is required")
        if self.auth_mode not in {"single_owner", "shared"}:
            raise RuntimeError("NOOP_AUTH_MODE must be single_owner or shared")
        if self.pool_min_size > self.pool_max_size:
            raise RuntimeError(
                "NOOP_DB_POOL_MIN_SIZE cannot exceed NOOP_DB_POOL_MAX_SIZE"
            )
        trusted_proxies = [
            value.strip() for value in self.forwarded_allow_ips.split(",")
        ]
        if not trusted_proxies or any(not value for value in trusted_proxies):
            raise RuntimeError(
                "NOOP_FORWARDED_ALLOW_IPS must list exact proxy IPs or CIDRs"
            )
        for trusted_proxy in trusted_proxies:
            if trusted_proxy == "*":
                raise RuntimeError(
                    "NOOP_FORWARDED_ALLOW_IPS cannot trust arbitrary forwarded headers"
                )
            try:
                network = ip_network(trusted_proxy)
            except ValueError as exc:
                raise RuntimeError(
                    "NOOP_FORWARDED_ALLOW_IPS must list exact proxy IPs or CIDRs"
                ) from exc
            if network.prefixlen == 0:
                raise RuntimeError(
                    "NOOP_FORWARDED_ALLOW_IPS cannot trust every network address"
                )
        if self.safety_worker_max_concurrency > self.safety_worker_batch_size:
            raise RuntimeError(
                "NOOP_SAFETY_WORKER_MAX_CONCURRENCY cannot exceed "
                "NOOP_SAFETY_WORKER_BATCH_SIZE"
            )
        if (
            self.safety_worker_enabled
            and self.safety_worker_max_concurrency >= self.pool_max_size
        ):
            raise RuntimeError(
                "NOOP_DB_POOL_MAX_SIZE must exceed "
                "NOOP_SAFETY_WORKER_MAX_CONCURRENCY so paging retains a "
                "database connection for lifecycle work"
            )
        paging_values = (
            self.public_base_url,
            self.twilio_account_sid,
            self.twilio_auth_token,
            self.twilio_from_phone,
            self.twilio_status_callback_secret,
            self.safety_capability_secret,
        )
        if any(paging_values) and not all(paging_values):
            raise RuntimeError(
                "paging requires NOOP_PUBLIC_BASE_URL and every NOOP_TWILIO_* setting"
            )
        if self.paging_configured:
            public = urlsplit(self.public_base_url or "")
            if (
                public.scheme != "https"
                or not public.hostname
                or public.username is not None
                or public.password is not None
                or public.query
                or public.fragment
            ):
                raise RuntimeError("NOOP_PUBLIC_BASE_URL must be a public HTTPS origin")
            if not (self.twilio_account_sid or "").startswith("AC"):
                raise RuntimeError("NOOP_TWILIO_ACCOUNT_SID must start with AC")
            phone = self.twilio_from_phone or ""
            if not (
                phone.startswith("+")
                and phone[1:].isdigit()
                and 8 <= len(phone[1:]) <= 15
                and phone[1] != "0"
            ):
                raise RuntimeError("NOOP_TWILIO_FROM_PHONE must use E.164 format")
            if len((self.twilio_auth_token or "").encode("utf-8")) < 16:
                raise RuntimeError("NOOP_TWILIO_AUTH_TOKEN is too short")
            if len((self.twilio_status_callback_secret or "").encode("utf-8")) < 32:
                raise RuntimeError(
                    "NOOP_TWILIO_STATUS_CALLBACK_SECRET must be at least 32 bytes"
                )
            if len((self.safety_capability_secret or "").encode("utf-8")) < 32:
                raise RuntimeError(
                    "NOOP_SAFETY_CAPABILITY_SECRET must be at least 32 bytes"
                )
        if (
            self.safety_acknowledgement_timeout_seconds
            >= self.safety_incident_ttl_seconds
        ):
            raise RuntimeError(
                "NOOP_SAFETY_ACKNOWLEDGEMENT_TIMEOUT_SECONDS must be shorter "
                "than NOOP_SAFETY_INCIDENT_TTL_SECONDS"
            )
        if self.safety_delivery_lease_seconds <= self.safety_worker_poll_seconds:
            raise RuntimeError(
                "NOOP_SAFETY_DELIVERY_LEASE_SECONDS must exceed "
                "NOOP_SAFETY_WORKER_POLL_SECONDS"
            )
        if (
            self.safety_worker_heartbeat_timeout_seconds
            <= self.safety_worker_poll_seconds
        ):
            raise RuntimeError(
                "NOOP_SAFETY_WORKER_HEARTBEAT_TIMEOUT_SECONDS must exceed "
                "NOOP_SAFETY_WORKER_POLL_SECONDS"
            )
        if self.safety_delivery_lease_seconds <= (
            self.safety_provider_request_timeout_seconds
            + self.safety_worker_poll_seconds
        ):
            raise RuntimeError(
                "NOOP_SAFETY_DELIVERY_LEASE_SECONDS must exceed the provider "
                "request timeout plus the worker poll interval"
            )
