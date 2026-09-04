from __future__ import annotations

import os
import re
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


def _csv_values(name: str) -> frozenset[str]:
    raw = os.getenv(name, "")
    values = [value.strip() for value in raw.split(",") if value.strip()]
    if len(values) != len(set(values)):
        raise ValueError(f"{name} cannot contain duplicate values")
    return frozenset(values)


@dataclass(frozen=True, slots=True)
class Settings:
    """Runtime settings.

    Secrets intentionally have no built-in production defaults. Keeping settings
    in this small dataclass also lets the API tests run without a settings library
    or a database.
    """

    api_token: str | None
    database_url: str | None
    database_engine: str = "timescaledb"
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
    managed_storage_enabled: bool = False
    managed_entitlement_mode: str = "closed"
    managed_project_id: str | None = None
    managed_project_number: str | None = None
    managed_identity_api_key: str | None = None
    managed_apple_app_id: str | None = None
    managed_android_app_id: str | None = None
    managed_raw_bucket: str | None = None
    managed_signer_email: str | None = None
    managed_replay_secret: str | None = None
    managed_home_region: str = "asia-south1"
    managed_residency_policy_version: str = "staging-v1"
    managed_default_plan_code: str = "noop_plus_staging"
    managed_default_plan_revision: int = 1
    managed_consent_policy_kind: str = "managed_storage"
    managed_consent_policy_version: str | None = None
    managed_consent_policy_sha256: str | None = None
    managed_upload_ttl_seconds: int = 15 * 60
    managed_download_ttl_seconds: int = 10 * 60
    managed_identity_cache_seconds: int = 5 * 60
    managed_identity_cache_entries: int = 10_000
    managed_app_check_cache_seconds: int = 6 * 60 * 60
    public_base_url: str | None = None
    twilio_account_sid: str | None = None
    twilio_auth_token: str | None = None
    twilio_from_phone: str | None = None
    twilio_status_callback_secret: str | None = None
    safety_capability_secret: str | None = None
    safety_acknowledgement_timeout_seconds: int = 90
    safety_incident_ttl_seconds: int = 12 * 60 * 60
    safety_escalation_rounds: int = 4
    safety_escalation_interval_seconds: int = 15 * 60
    safety_automatic_paging_enabled: bool = False
    safety_approved_fall_detectors: frozenset[str] = frozenset()
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
            database_engine=_choice(
                "NOOP_DATABASE_ENGINE",
                "timescaledb",
                frozenset({"postgresql", "timescaledb"}),
            ),
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
            managed_storage_enabled=_boolean(
                "NOOP_MANAGED_STORAGE_ENABLED",
                False,
            ),
            managed_entitlement_mode=_choice(
                "NOOP_MANAGED_ENTITLEMENT_MODE",
                "closed",
                frozenset({"closed", "open_beta", "paid"}),
            ),
            managed_project_id=os.getenv("NOOP_MANAGED_PROJECT_ID"),
            managed_project_number=os.getenv("NOOP_MANAGED_PROJECT_NUMBER"),
            managed_identity_api_key=os.getenv("NOOP_MANAGED_IDENTITY_API_KEY"),
            managed_apple_app_id=os.getenv("NOOP_MANAGED_APPLE_APP_ID"),
            managed_android_app_id=os.getenv("NOOP_MANAGED_ANDROID_APP_ID"),
            managed_raw_bucket=os.getenv("NOOP_MANAGED_RAW_BUCKET"),
            managed_signer_email=os.getenv("NOOP_MANAGED_SIGNER_EMAIL"),
            managed_replay_secret=os.getenv("NOOP_MANAGED_REPLAY_SECRET"),
            managed_home_region=os.getenv(
                "NOOP_MANAGED_HOME_REGION",
                "asia-south1",
            ).strip(),
            managed_residency_policy_version=os.getenv(
                "NOOP_MANAGED_RESIDENCY_POLICY_VERSION",
                "staging-v1",
            ).strip(),
            managed_default_plan_code=os.getenv(
                "NOOP_MANAGED_DEFAULT_PLAN_CODE",
                "noop_plus_staging",
            ).strip(),
            managed_default_plan_revision=_positive_int(
                "NOOP_MANAGED_DEFAULT_PLAN_REVISION",
                1,
            ),
            managed_consent_policy_kind=os.getenv(
                "NOOP_MANAGED_CONSENT_POLICY_KIND",
                "managed_storage",
            ).strip(),
            managed_consent_policy_version=os.getenv(
                "NOOP_MANAGED_CONSENT_POLICY_VERSION"
            ),
            managed_consent_policy_sha256=os.getenv(
                "NOOP_MANAGED_CONSENT_POLICY_SHA256"
            ),
            managed_upload_ttl_seconds=_positive_int(
                "NOOP_MANAGED_UPLOAD_TTL_SECONDS",
                15 * 60,
            ),
            managed_download_ttl_seconds=_positive_int(
                "NOOP_MANAGED_DOWNLOAD_TTL_SECONDS",
                10 * 60,
            ),
            managed_identity_cache_seconds=_positive_int(
                "NOOP_MANAGED_IDENTITY_CACHE_SECONDS",
                5 * 60,
            ),
            managed_identity_cache_entries=_positive_int(
                "NOOP_MANAGED_IDENTITY_CACHE_ENTRIES",
                10_000,
            ),
            managed_app_check_cache_seconds=_positive_int(
                "NOOP_MANAGED_APP_CHECK_CACHE_SECONDS",
                6 * 60 * 60,
            ),
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
                "NOOP_SAFETY_INCIDENT_TTL_SECONDS", 12 * 60 * 60
            ),
            safety_escalation_rounds=_positive_int("NOOP_SAFETY_ESCALATION_ROUNDS", 4),
            safety_escalation_interval_seconds=_positive_int(
                "NOOP_SAFETY_ESCALATION_INTERVAL_SECONDS", 15 * 60
            ),
            safety_automatic_paging_enabled=_boolean(
                "NOOP_SAFETY_AUTOMATIC_PAGING_ENABLED", False
            ),
            safety_approved_fall_detectors=_csv_values(
                "NOOP_SAFETY_APPROVED_FALL_DETECTORS"
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
        if self.database_engine not in {"postgresql", "timescaledb"}:
            raise RuntimeError("NOOP_DATABASE_ENGINE must be postgresql or timescaledb")
        if self.auth_mode not in {"single_owner", "shared"}:
            raise RuntimeError("NOOP_AUTH_MODE must be single_owner or shared")
        if self.managed_entitlement_mode not in {"closed", "open_beta", "paid"}:
            raise RuntimeError(
                "NOOP_MANAGED_ENTITLEMENT_MODE must be closed, open_beta, or paid"
            )
        if self.managed_storage_enabled:
            required_managed = {
                "NOOP_MANAGED_PROJECT_ID": self.managed_project_id,
                "NOOP_MANAGED_PROJECT_NUMBER": self.managed_project_number,
                "NOOP_MANAGED_IDENTITY_API_KEY": self.managed_identity_api_key,
                "NOOP_MANAGED_APPLE_APP_ID": self.managed_apple_app_id,
                "NOOP_MANAGED_ANDROID_APP_ID": self.managed_android_app_id,
                "NOOP_MANAGED_RAW_BUCKET": self.managed_raw_bucket,
                "NOOP_MANAGED_SIGNER_EMAIL": self.managed_signer_email,
                "NOOP_MANAGED_REPLAY_SECRET": self.managed_replay_secret,
                "NOOP_MANAGED_CONSENT_POLICY_VERSION": (
                    self.managed_consent_policy_version
                ),
                "NOOP_MANAGED_CONSENT_POLICY_SHA256": (
                    self.managed_consent_policy_sha256
                ),
            }
            missing_managed = [
                name for name, value in required_managed.items() if not value
            ]
            if missing_managed:
                raise RuntimeError(
                    "managed storage requires: " + ", ".join(missing_managed)
                )
            if not re.fullmatch(
                r"[a-z][a-z0-9-]{4,28}[a-z0-9]",
                self.managed_project_id or "",
            ):
                raise RuntimeError("NOOP_MANAGED_PROJECT_ID must be a valid project ID")
            if not re.fullmatch(
                r"[1-9][0-9]{5,19}",
                self.managed_project_number or "",
            ):
                raise RuntimeError(
                    "NOOP_MANAGED_PROJECT_NUMBER must be a valid project number"
                )
            if not re.fullmatch(
                r"[A-Za-z0-9_-]{8,256}",
                self.managed_identity_api_key or "",
            ):
                raise RuntimeError("NOOP_MANAGED_IDENTITY_API_KEY is invalid")
            expected_app_prefix = f"1:{self.managed_project_number}:"
            for name, app_id, platform in (
                (
                    "NOOP_MANAGED_APPLE_APP_ID",
                    self.managed_apple_app_id,
                    "ios",
                ),
                (
                    "NOOP_MANAGED_ANDROID_APP_ID",
                    self.managed_android_app_id,
                    "android",
                ),
            ):
                if not re.fullmatch(
                    rf"{re.escape(expected_app_prefix)}{platform}:[0-9a-f]{{8,64}}",
                    app_id or "",
                ):
                    raise RuntimeError(
                        f"{name} must belong to the configured project and platform"
                    )
            if not re.fullmatch(
                r"[a-z0-9][a-z0-9._-]{1,61}[a-z0-9]",
                self.managed_raw_bucket or "",
            ):
                raise RuntimeError(
                    "NOOP_MANAGED_RAW_BUCKET must be a valid bucket name"
                )
            if not re.fullmatch(
                r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+",
                self.managed_signer_email or "",
            ):
                raise RuntimeError(
                    "NOOP_MANAGED_SIGNER_EMAIL must be a service-account email"
                )
            if len((self.managed_replay_secret or "").encode("utf-8")) < 32:
                raise RuntimeError(
                    "NOOP_MANAGED_REPLAY_SECRET must be at least 32 bytes"
                )
            if not re.fullmatch(
                r"[a-z][a-z0-9-]{1,31}",
                self.managed_home_region,
            ):
                raise RuntimeError(
                    "NOOP_MANAGED_HOME_REGION must be a region identifier"
                )
            if not re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}",
                self.managed_residency_policy_version,
            ):
                raise RuntimeError("NOOP_MANAGED_RESIDENCY_POLICY_VERSION is invalid")
            for name, value in (
                (
                    "NOOP_MANAGED_DEFAULT_PLAN_CODE",
                    self.managed_default_plan_code,
                ),
                (
                    "NOOP_MANAGED_CONSENT_POLICY_KIND",
                    self.managed_consent_policy_kind,
                ),
            ):
                if not re.fullmatch(r"[a-z][a-z0-9_]{1,63}", value):
                    raise RuntimeError(f"{name} has an invalid identifier")
            if not re.fullmatch(
                r"[A-Za-z0-9][A-Za-z0-9._-]{0,63}",
                self.managed_consent_policy_version or "",
            ):
                raise RuntimeError("NOOP_MANAGED_CONSENT_POLICY_VERSION is invalid")
            if not re.fullmatch(
                r"[0-9a-f]{64}",
                self.managed_consent_policy_sha256 or "",
            ):
                raise RuntimeError(
                    "NOOP_MANAGED_CONSENT_POLICY_SHA256 must be a lowercase "
                    "SHA-256 digest"
                )
            if not 60 <= self.managed_upload_ttl_seconds <= 3600:
                raise RuntimeError(
                    "NOOP_MANAGED_UPLOAD_TTL_SECONDS must be between 60 and 3600"
                )
            if not 60 <= self.managed_download_ttl_seconds <= 3600:
                raise RuntimeError(
                    "NOOP_MANAGED_DOWNLOAD_TTL_SECONDS must be between 60 and 3600"
                )
            if not 300 <= self.managed_app_check_cache_seconds <= 21_600:
                raise RuntimeError(
                    "NOOP_MANAGED_APP_CHECK_CACHE_SECONDS must be between 300 and 21600"
                )
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
        if self.safety_incident_ttl_seconds < 12 * 60 * 60:
            raise RuntimeError(
                "NOOP_SAFETY_INCIDENT_TTL_SECONDS must allow the 12-hour "
                "location-sharing option"
            )
        if not 1 <= self.safety_escalation_rounds <= 8:
            raise RuntimeError("NOOP_SAFETY_ESCALATION_ROUNDS must be between 1 and 8")
        if not 60 <= self.safety_escalation_interval_seconds <= 86_400:
            raise RuntimeError(
                "NOOP_SAFETY_ESCALATION_INTERVAL_SECONDS must be between 60 and 86400"
            )
        if (
            self.safety_escalation_interval_seconds
            <= self.safety_acknowledgement_timeout_seconds
        ):
            raise RuntimeError(
                "NOOP_SAFETY_ESCALATION_INTERVAL_SECONDS must exceed the "
                "voice acknowledgement timeout"
            )
        final_voice_offset = (
            (self.safety_escalation_rounds - 1)
            * self.safety_escalation_interval_seconds
            + self.safety_acknowledgement_timeout_seconds
        )
        if final_voice_offset >= 8 * 60 * 60:
            raise RuntimeError(
                "Safety escalation rounds must finish within the minimum "
                "8-hour incident window"
            )
        malformed_detectors = [
            value
            for value in self.safety_approved_fall_detectors
            if re.fullmatch(
                r"[a-z][a-z0-9_.-]{0,63}:(?:[1-9][0-9]{0,3}|10000)",
                value,
            )
            is None
        ]
        if malformed_detectors:
            raise RuntimeError(
                "NOOP_SAFETY_APPROVED_FALL_DETECTORS entries must use "
                "detector_id:version"
            )
        if (
            self.safety_automatic_paging_enabled
            and not self.safety_approved_fall_detectors
        ):
            raise RuntimeError(
                "Automatic paging requires at least one explicitly approved "
                "fall detector contract"
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
