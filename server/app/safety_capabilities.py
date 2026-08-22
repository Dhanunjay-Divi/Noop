from __future__ import annotations

import base64
import hashlib
import hmac
from datetime import UTC, datetime


class SafetyCapabilitySigner:
    """Creates short-lived responder capabilities without persisting secrets."""

    _DOMAIN = b"noop-safety-response:v1:"

    def __init__(self, secret: str) -> None:
        if len(secret.encode("utf-8")) < 32:
            raise ValueError("safety capability secret must be at least 32 bytes")
        self._secret = secret.encode("utf-8")

    def sign(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        expires_at_unix: int,
    ) -> str:
        message = self._message(dispatch_id, contact_id, expires_at_unix)
        digest = hmac.new(self._secret, message, hashlib.sha256).digest()
        return base64.urlsafe_b64encode(digest).rstrip(b"=").decode("ascii")

    def verify(
        self,
        *,
        dispatch_id: str,
        contact_id: str,
        expires_at_unix: int,
        signature: str,
        now: datetime | None = None,
    ) -> bool:
        reference = (now or datetime.now(UTC)).astimezone(UTC)
        if expires_at_unix <= int(reference.timestamp()):
            return False
        if len(signature) != 43 or not signature.isascii():
            return False
        expected = self.sign(
            dispatch_id=dispatch_id,
            contact_id=contact_id,
            expires_at_unix=expires_at_unix,
        )
        return hmac.compare_digest(
            signature.encode("ascii"),
            expected.encode("ascii"),
        )

    @classmethod
    def _message(
        cls,
        dispatch_id: str,
        contact_id: str,
        expires_at_unix: int,
    ) -> bytes:
        return cls._DOMAIN + (
            f"{dispatch_id}:{contact_id}:{expires_at_unix}".encode("ascii")
        )
