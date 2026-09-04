from __future__ import annotations

import asyncio
import base64
import hashlib
import json
import threading
import urllib.error
import urllib.parse
import urllib.request
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta
from typing import Callable, Protocol


class ManagedObjectStoreError(Exception):
    """A managed object capability or metadata operation failed."""


class ManagedObjectNotFoundError(ManagedObjectStoreError):
    """The requested immutable object generation does not exist."""


@dataclass(frozen=True, slots=True)
class ManagedObjectCapability:
    method: str
    url: str
    headers: dict[str, str]
    expires_at: datetime


@dataclass(frozen=True, slots=True)
class ManagedObjectMetadata:
    object_key: str
    generation: int
    metageneration: int
    crc32c: str
    size: int
    content_type: str
    metadata: dict[str, str]


class ManagedObjectStoring(Protocol):
    async def upload_capability(
        self,
        *,
        object_key: str,
        content_type: str,
        content_sha256: str,
        content_length: int,
        expires_in_seconds: int,
    ) -> ManagedObjectCapability: ...

    async def download_capability(
        self,
        *,
        object_key: str,
        generation: int,
        expires_in_seconds: int,
    ) -> ManagedObjectCapability: ...

    async def metadata(
        self,
        *,
        object_key: str,
        generation: int,
    ) -> ManagedObjectMetadata: ...

    async def read(
        self,
        *,
        object_key: str,
        generation: int,
        maximum_bytes: int,
    ) -> bytes: ...

    async def delete(
        self,
        *,
        object_key: str,
        generation: int | None,
    ) -> None: ...


class BlobSigning(Protocol):
    @property
    def service_account_email(self) -> str: ...

    async def sign(self, payload: bytes) -> bytes: ...


class StaticBlobSigner:
    """Deterministic signer seam for canonical-request unit tests."""

    def __init__(
        self,
        service_account_email: str,
        signature: bytes = b"test-signature",
    ) -> None:
        self._service_account_email = service_account_email
        self.signature = signature
        self.payloads: list[bytes] = []

    @property
    def service_account_email(self) -> str:
        return self._service_account_email

    async def sign(self, payload: bytes) -> bytes:
        self.payloads.append(payload)
        return self.signature


class IAMBlobSigner:
    """Use the Cloud Run identity and IAM Credentials signBlob API.

    No service-account private key is created or stored. The runtime identity
    requires only token creation on itself, which the OpenTofu stack grants.
    """

    def __init__(
        self,
        service_account_email: str,
        *,
        timeout_seconds: float = 10,
        metadata_token_url: str = (
            "http://metadata.google.internal/computeMetadata/v1/"
            "instance/service-accounts/default/token"
        ),
        iam_base_url: str = "https://iamcredentials.googleapis.com/v1",
    ) -> None:
        self._service_account_email = service_account_email
        self.timeout_seconds = timeout_seconds
        self.metadata_token_url = metadata_token_url
        self.iam_base_url = iam_base_url.rstrip("/")
        self._token: str | None = None
        self._token_expires_at = 0.0
        self._token_lock = threading.Lock()

    @property
    def service_account_email(self) -> str:
        return self._service_account_email

    async def sign(self, payload: bytes) -> bytes:
        return await asyncio.to_thread(self._sign, payload)

    def _sign(self, payload: bytes) -> bytes:
        access_token = self._access_token()
        email = urllib.parse.quote(self.service_account_email, safe="")
        endpoint = f"{self.iam_base_url}/projects/-/serviceAccounts/{email}:signBlob"
        request = urllib.request.Request(
            endpoint,
            data=json.dumps(
                {
                    "payload": base64.b64encode(payload).decode("ascii"),
                },
                separators=(",", ":"),
            ).encode("utf-8"),
            method="POST",
            headers={
                "Authorization": f"Bearer {access_token}",
                "Content-Type": "application/json",
                "Accept": "application/json",
                "User-Agent": "NOOP-managed-object-signer/1",
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout_seconds,
            ) as response:
                result = json.load(response)
            signed = result.get("signedBlob") if isinstance(result, dict) else None
            if not isinstance(signed, str):
                raise ManagedObjectStoreError(
                    "IAM signing returned an invalid response"
                )
            return base64.b64decode(signed, validate=True)
        except ManagedObjectStoreError:
            raise
        except (
            OSError,
            TimeoutError,
            ValueError,
            json.JSONDecodeError,
            urllib.error.HTTPError,
        ):
            raise ManagedObjectStoreError(
                "managed object signing is unavailable"
            ) from None

    def _access_token(self) -> str:
        import time

        with self._token_lock:
            now = time.monotonic()
            if self._token is not None and self._token_expires_at > now + 60:
                return self._token
            request = urllib.request.Request(
                self.metadata_token_url,
                headers={
                    "Metadata-Flavor": "Google",
                    "Accept": "application/json",
                },
            )
            try:
                with urllib.request.urlopen(
                    request,
                    timeout=self.timeout_seconds,
                ) as response:
                    payload = json.load(response)
                token = payload.get("access_token")
                expires_in = int(payload.get("expires_in", 0))
            except (
                OSError,
                TimeoutError,
                TypeError,
                ValueError,
                json.JSONDecodeError,
                urllib.error.HTTPError,
            ):
                raise ManagedObjectStoreError(
                    "managed object credentials are unavailable"
                ) from None
            if not isinstance(token, str) or not token or expires_in <= 0:
                raise ManagedObjectStoreError(
                    "managed object credentials returned an invalid response"
                )
            self._token = token
            self._token_expires_at = now + expires_in
            return token


class GCSV4ObjectStore:
    """Issue generation-bound GCS V4 capabilities and read object metadata."""

    def __init__(
        self,
        *,
        bucket: str,
        signer: BlobSigning,
        timeout_seconds: float = 15,
        clock: Callable[[], datetime] | None = None,
        storage_origin: str = "https://storage.googleapis.com",
    ) -> None:
        self.bucket = bucket
        self.signer = signer
        self.timeout_seconds = timeout_seconds
        self.clock = clock or (lambda: datetime.now(UTC))
        self.storage_origin = storage_origin.rstrip("/")

    async def upload_capability(
        self,
        *,
        object_key: str,
        content_type: str,
        content_sha256: str,
        content_length: int,
        expires_in_seconds: int,
    ) -> ManagedObjectCapability:
        if not 60 <= expires_in_seconds <= 3600:
            raise ValueError("upload capability expiry must be 60 through 3600")
        headers = {
            "content-length": str(content_length),
            "content-type": content_type,
            "host": urllib.parse.urlsplit(self.storage_origin).netloc,
            "x-goog-content-sha256": content_sha256,
            "x-goog-if-generation-match": "0",
            "x-goog-meta-noop-sha256": content_sha256,
        }
        return await self._capability(
            method="PUT",
            object_key=object_key,
            headers=headers,
            payload_sha256=content_sha256,
            expires_in_seconds=expires_in_seconds,
            extra_query={},
        )

    async def download_capability(
        self,
        *,
        object_key: str,
        generation: int,
        expires_in_seconds: int,
    ) -> ManagedObjectCapability:
        if generation <= 0:
            raise ValueError("generation must be positive")
        if not 60 <= expires_in_seconds <= 3600:
            raise ValueError("download capability expiry must be 60 through 3600")
        return await self._capability(
            method="GET",
            object_key=object_key,
            headers={
                "host": urllib.parse.urlsplit(self.storage_origin).netloc,
            },
            payload_sha256="UNSIGNED-PAYLOAD",
            expires_in_seconds=expires_in_seconds,
            extra_query={"generation": str(generation)},
        )

    async def metadata(
        self,
        *,
        object_key: str,
        generation: int,
    ) -> ManagedObjectMetadata:
        return await asyncio.to_thread(
            self._metadata,
            object_key,
            generation,
        )

    async def read(
        self,
        *,
        object_key: str,
        generation: int,
        maximum_bytes: int,
    ) -> bytes:
        if generation <= 0:
            raise ValueError("generation must be positive")
        if maximum_bytes <= 0:
            raise ValueError("maximum_bytes must be positive")
        return await asyncio.to_thread(
            self._read,
            object_key,
            generation,
            maximum_bytes,
        )

    async def delete(
        self,
        *,
        object_key: str,
        generation: int | None,
    ) -> None:
        if generation is not None and generation <= 0:
            raise ValueError("generation must be positive")
        await asyncio.to_thread(self._delete, object_key, generation)

    async def _capability(
        self,
        *,
        method: str,
        object_key: str,
        headers: dict[str, str],
        payload_sha256: str,
        expires_in_seconds: int,
        extra_query: dict[str, str],
    ) -> ManagedObjectCapability:
        now = self.clock().astimezone(UTC).replace(microsecond=0)
        date = now.strftime("%Y%m%d")
        timestamp = now.strftime("%Y%m%dT%H%M%SZ")
        credential_scope = f"{date}/auto/storage/goog4_request"
        credential = f"{self.signer.service_account_email}/{credential_scope}"
        signed_headers = ";".join(sorted(headers))
        query = {
            "X-Goog-Algorithm": "GOOG4-RSA-SHA256",
            "X-Goog-Credential": credential,
            "X-Goog-Date": timestamp,
            "X-Goog-Expires": str(expires_in_seconds),
            "X-Goog-SignedHeaders": signed_headers,
            **extra_query,
        }
        canonical_uri = self._canonical_uri(object_key)
        canonical_query = self._canonical_query(query)
        canonical_headers = "".join(
            f"{name}:{self._normalise_header(headers[name])}\n"
            for name in sorted(headers)
        )
        canonical_request = "\n".join(
            (
                method,
                canonical_uri,
                canonical_query,
                canonical_headers,
                signed_headers,
                payload_sha256,
            )
        )
        string_to_sign = "\n".join(
            (
                "GOOG4-RSA-SHA256",
                timestamp,
                credential_scope,
                hashlib.sha256(canonical_request.encode("utf-8")).hexdigest(),
            )
        ).encode("utf-8")
        signature = (await self.signer.sign(string_to_sign)).hex()
        url = (
            f"{self.storage_origin}{canonical_uri}?"
            f"{canonical_query}&X-Goog-Signature={signature}"
        )
        return ManagedObjectCapability(
            method=method,
            url=url,
            headers={name: value for name, value in headers.items() if name != "host"},
            expires_at=now + timedelta(seconds=expires_in_seconds),
        )

    def _metadata(
        self,
        object_key: str,
        generation: int,
    ) -> ManagedObjectMetadata:
        # Metadata reads use a short-lived access token. Reuse IAMBlobSigner's
        # metadata credential path when available without exposing that token.
        if not isinstance(self.signer, IAMBlobSigner):
            raise ManagedObjectStoreError(
                "object metadata requires a runtime IAM signer"
            )
        token = self.signer._access_token()
        bucket = urllib.parse.quote(self.bucket, safe="")
        name = urllib.parse.quote(object_key, safe="")
        query = urllib.parse.urlencode(
            {
                "generation": str(generation),
                "fields": (
                    "name,generation,metageneration,crc32c,size,contentType,metadata"
                ),
            }
        )
        request = urllib.request.Request(
            (f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/{name}?{query}"),
            headers={
                "Authorization": f"Bearer {token}",
                "Accept": "application/json",
                "User-Agent": "NOOP-managed-object-metadata/1",
            },
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout_seconds,
            ) as response:
                payload = json.load(response)
            if not isinstance(payload, dict):
                raise ValueError
            metadata = payload.get("metadata") or {}
            if not isinstance(metadata, dict) or not all(
                isinstance(key, str) and isinstance(value, str)
                for key, value in metadata.items()
            ):
                raise ValueError
            result = ManagedObjectMetadata(
                object_key=str(payload["name"]),
                generation=int(payload["generation"]),
                metageneration=int(payload["metageneration"]),
                crc32c=str(payload["crc32c"]),
                size=int(payload["size"]),
                content_type=str(payload["contentType"]),
                metadata=metadata,
            )
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise ManagedObjectNotFoundError(
                    "managed object was not found"
                ) from None
            raise ManagedObjectStoreError(
                "managed object metadata is unavailable"
            ) from None
        except (
            KeyError,
            OSError,
            TimeoutError,
            TypeError,
            ValueError,
            json.JSONDecodeError,
        ):
            raise ManagedObjectStoreError(
                "managed object metadata is unavailable"
            ) from None
        return result

    def _read(
        self,
        object_key: str,
        generation: int,
        maximum_bytes: int,
    ) -> bytes:
        request = urllib.request.Request(
            self._json_api_url(
                object_key,
                {
                    "alt": "media",
                    "generation": str(generation),
                },
            ),
            headers=self._authorized_headers(user_agent="NOOP-managed-object-reader/1"),
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout_seconds,
            ) as response:
                payload = response.read(maximum_bytes + 1)
        except urllib.error.HTTPError as error:
            if error.code == 404:
                raise ManagedObjectNotFoundError(
                    "managed object was not found"
                ) from None
            raise ManagedObjectStoreError(
                "managed object read is unavailable"
            ) from None
        except (OSError, TimeoutError):
            raise ManagedObjectStoreError(
                "managed object read is unavailable"
            ) from None
        if len(payload) > maximum_bytes:
            raise ManagedObjectStoreError(
                "managed object exceeds its bounded read contract"
            )
        return payload

    def _delete(
        self,
        object_key: str,
        generation: int | None,
    ) -> None:
        query = {"ifGenerationMatch": str(generation)} if generation is not None else {}
        request = urllib.request.Request(
            self._json_api_url(object_key, query),
            method="DELETE",
            headers=self._authorized_headers(
                user_agent="NOOP-managed-object-deleter/1"
            ),
        )
        try:
            with urllib.request.urlopen(
                request,
                timeout=self.timeout_seconds,
            ):
                return
        except urllib.error.HTTPError as error:
            if error.code == 404:
                return
            raise ManagedObjectStoreError(
                "managed object deletion is unavailable"
            ) from None
        except (OSError, TimeoutError):
            raise ManagedObjectStoreError(
                "managed object deletion is unavailable"
            ) from None

    def _authorized_headers(self, *, user_agent: str) -> dict[str, str]:
        if not isinstance(self.signer, IAMBlobSigner):
            raise ManagedObjectStoreError(
                "object operation requires a runtime IAM signer"
            )
        return {
            "Authorization": f"Bearer {self.signer._access_token()}",
            "Accept": "application/json",
            "User-Agent": user_agent,
        }

    def _json_api_url(
        self,
        object_key: str,
        query: dict[str, str],
    ) -> str:
        self._canonical_uri(object_key)
        bucket = urllib.parse.quote(self.bucket, safe="")
        name = urllib.parse.quote(object_key, safe="")
        encoded_query = urllib.parse.urlencode(query)
        base = f"https://storage.googleapis.com/storage/v1/b/{bucket}/o/{name}"
        return f"{base}?{encoded_query}" if encoded_query else base

    def _canonical_uri(self, object_key: str) -> str:
        if (
            not object_key
            or object_key.startswith("/")
            or "//" in object_key
            or any(ord(character) < 32 for character in object_key)
        ):
            raise ValueError("object_key is invalid")
        return "/" + urllib.parse.quote(
            f"{self.bucket}/{object_key}",
            safe="/~",
        )

    @staticmethod
    def _canonical_query(values: dict[str, str]) -> str:
        return "&".join(
            f"{urllib.parse.quote(key, safe='~')}={urllib.parse.quote(value, safe='~')}"
            for key, value in sorted(values.items())
        )

    @staticmethod
    def _normalise_header(value: str) -> str:
        return " ".join(value.strip().split())
