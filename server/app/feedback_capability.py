from __future__ import annotations

import base64
import hashlib
import hmac
from uuid import UUID


class FeedbackCapabilityCodec:
    """Issue report-scoped capabilities with one bounded rotation fallback."""

    def __init__(
        self,
        secret: str,
        *,
        previous_secrets: tuple[str, ...] = (),
    ) -> None:
        secrets = (secret, *previous_secrets)
        encoded = tuple(value.encode("utf-8") for value in secrets if value)
        if not encoded or any(len(value) < 32 for value in encoded):
            raise ValueError("feedback capability secrets must be at least 32 bytes")
        if len(set(encoded)) != len(encoded):
            raise ValueError("feedback capability secrets must be unique")
        self._secrets = encoded
        self._secret = encoded[0]

    def issue(self, *, report_id: UUID, app_id: str) -> str:
        return self._encode(self._digest(report_id=report_id, app_id=app_id))

    def verify(self, token: str, *, report_id: UUID, app_id: str) -> bool:
        if not 40 <= len(token) <= 64 or not token.isascii():
            return False
        try:
            supplied = self._decode(token)
        except ValueError:
            return False
        return any(
            hmac.compare_digest(
                supplied,
                self._digest(
                    report_id=report_id,
                    app_id=app_id,
                    secret=secret,
                ),
            )
            for secret in self._secrets
        )

    def receipt(self, *, report_id: UUID, app_id: str) -> str:
        digest = hmac.new(
            self._secret,
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
        secret: bytes | None = None,
    ) -> bytes:
        return hmac.new(
            secret or self._secret,
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
