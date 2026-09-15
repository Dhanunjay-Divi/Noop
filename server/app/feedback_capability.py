from __future__ import annotations

import base64
import hashlib
import hmac
import re
from collections.abc import Mapping
from uuid import UUID


_KEY_VERSION_RE = re.compile(r"^v[0-9]{1,4}$")


class FeedbackCapabilityCodec:
    """Issue report-scoped capabilities from an explicit versioned key ring."""

    def __init__(
        self,
        secret: str,
        *,
        secret_version: str = "v1",
        previous_secrets: tuple[str, ...] = (),
        previous_secret_versions: tuple[str, ...] = (),
        verification_secrets: Mapping[str, str] | None = None,
        write_version: str = "legacy",
    ) -> None:
        if _KEY_VERSION_RE.fullmatch(secret_version) is None:
            raise ValueError("feedback capability secret version is invalid")
        if previous_secret_versions and (
            len(previous_secret_versions) != len(previous_secrets)
        ):
            raise ValueError(
                "feedback capability previous secret versions must match secrets"
            )
        if previous_secret_versions:
            derived_previous_versions = previous_secret_versions
        else:
            available_versions = (
                f"v{index}" for index in range(10_000) if f"v{index}" != secret_version
            )
            derived_previous_versions = tuple(
                next(available_versions) for _ in previous_secrets
            )
        configured_pairs = [
            (secret_version, secret),
            *zip(derived_previous_versions, previous_secrets, strict=True),
            *(verification_secrets or {}).items(),
        ]
        if len({version for version, _ in configured_pairs}) != len(configured_pairs):
            raise ValueError("feedback capability key versions must be unique")
        configured = dict(configured_pairs)
        if any(_KEY_VERSION_RE.fullmatch(version) is None for version in configured):
            raise ValueError("feedback capability key versions are invalid")
        encoded = {
            version: value.encode("utf-8")
            for version, value in configured.items()
            if value
        }
        if not encoded or any(len(value) < 32 for value in encoded.values()):
            raise ValueError("feedback capability secrets must be at least 32 bytes")
        if len(set(encoded.values())) != len(encoded):
            raise ValueError("feedback capability secrets must be unique")
        if len(encoded) != len(configured):
            raise ValueError("feedback capability secrets cannot be empty")
        if write_version != "legacy" and write_version not in encoded:
            raise ValueError(
                "feedback capability write version must be legacy or configured"
            )
        self._keys = encoded
        self._write_version = write_version
        self._write_secret = (
            encoded[secret_version]
            if write_version == "legacy"
            else encoded[write_version]
        )

    def issue(self, *, report_id: UUID, app_id: str) -> str:
        encoded = self._encode(
            self._digest(
                report_id=report_id,
                app_id=app_id,
                secret=self._write_secret,
            )
        )
        if self._write_version == "legacy":
            return encoded
        return f"{self._write_version}.{encoded}"

    def verify(self, token: str, *, report_id: UUID, app_id: str) -> bool:
        if not 40 <= len(token) <= 72 or not token.isascii():
            return False
        version: str | None = None
        encoded_token = token
        if "." in token:
            parts = token.split(".", 1)
            if len(parts) != 2 or _KEY_VERSION_RE.fullmatch(parts[0]) is None:
                return False
            version, encoded_token = parts
            if version not in self._keys:
                return False
        try:
            supplied = self._decode(encoded_token)
        except ValueError:
            return False
        candidate_secrets = (
            (self._keys[version],)
            if version is not None
            else tuple(self._keys.values())
        )
        return any(
            hmac.compare_digest(
                supplied,
                self._digest(
                    report_id=report_id,
                    app_id=app_id,
                    secret=secret,
                ),
            )
            for secret in candidate_secrets
        )

    def receipt(self, *, report_id: UUID, app_id: str) -> str:
        digest = hmac.new(
            self._write_secret,
            b"noop-feedback-receipt-v1\0"
            + report_id.bytes
            + b"\0"
            + app_id.encode("utf-8"),
            hashlib.sha256,
        ).digest()
        body = base64.b32encode(digest[:10]).decode("ascii").rstrip("=")
        return f"NF-{body}"

    def _digest(
        self,
        *,
        report_id: UUID,
        app_id: str,
        secret: bytes,
    ) -> bytes:
        return hmac.new(
            secret,
            b"noop-feedback-capability-v1\0"
            + report_id.bytes
            + b"\0"
            + app_id.encode("utf-8"),
            hashlib.sha256,
        ).digest()

    @staticmethod
    def _encode(value: bytes) -> str:
        return base64.urlsafe_b64encode(value).decode("ascii").rstrip("=")

    @staticmethod
    def _decode(value: str) -> bytes:
        padding = "=" * (-len(value) % 4)
        try:
            decoded = base64.b64decode(
                value + padding,
                altchars=b"-_",
                validate=True,
            )
        except (ValueError, TypeError):
            raise ValueError("invalid feedback capability") from None
        if len(decoded) != 32:
            raise ValueError("invalid feedback capability")
        return decoded
