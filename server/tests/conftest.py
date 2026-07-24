from __future__ import annotations

import sys
from pathlib import Path

import pytest
from fastapi.testclient import TestClient

SERVER_ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(SERVER_ROOT))

from app.config import Settings  # noqa: E402
from app.main import create_app  # noqa: E402
from app.repository import MemoryRepository  # noqa: E402

TOKEN = "test-token-abcdefghijklmnopqrstuvwxyz-0123456789"


@pytest.fixture
def repository() -> MemoryRepository:
    return MemoryRepository()


@pytest.fixture
def client(repository: MemoryRepository):
    settings = Settings(
        api_token=TOKEN,
        database_url=None,
        max_request_bytes=1_000_000,
        retention_days=30,
    )
    app = create_app(settings=settings, repository=repository)
    with TestClient(app) as test_client:
        yield test_client


@pytest.fixture
def auth_headers() -> dict[str, str]:
    return {"Authorization": f"Bearer {TOKEN}"}
