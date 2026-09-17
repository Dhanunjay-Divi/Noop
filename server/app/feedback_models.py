from __future__ import annotations

from datetime import datetime
from typing import Literal
from uuid import UUID

from pydantic import BaseModel, ConfigDict, Field


FeedbackPlatform = Literal["ios", "android"]
FeedbackStatus = Literal[
    "reserved",
    "sent",
    "rejected",
    "deleting",
    "deleted",
]


class FeedbackReservationRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")

    schema_version: Literal[1]
    platform: FeedbackPlatform
    app_version: str = Field(
        min_length=1,
        max_length=32,
        pattern=r"^[A-Za-z0-9][A-Za-z0-9.+_-]{0,31}$",
    )
    archive_bytes: int = Field(gt=0)
    archive_sha256: str = Field(pattern=r"^[0-9a-f]{64}$")
    includes_user_note: bool
    includes_screenshot: bool


class FeedbackUploadCapability(BaseModel):
    model_config = ConfigDict(extra="forbid")

    method: Literal["PUT"]
    url: str
    headers: dict[str, str]
    expires_at: datetime


class FeedbackReservationResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    report_id: UUID
    report_token: str
    status: FeedbackStatus
    upload: FeedbackUploadCapability | None
    retained_until: datetime


class FeedbackCompletionRequest(BaseModel):
    model_config = ConfigDict(extra="forbid")


class FeedbackStatusResponse(BaseModel):
    model_config = ConfigDict(extra="forbid")

    status: FeedbackStatus
    receipt: str | None = Field(
        default=None,
        pattern=r"^NF-[A-Z2-7]{16}$",
    )
    retained_until: datetime
