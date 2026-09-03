from __future__ import annotations

import asyncio

from app.config import Settings
from app.repository import PostgresRepository


async def run() -> None:
    settings = Settings.from_env()
    settings.validate_for_startup(needs_database=True, needs_api_token=False)
    repository = PostgresRepository(
        settings.database_url or "",
        pool_min_size=1,
        pool_max_size=1,
        statement_cache_size=settings.database_statement_cache_size,
        run_migrations=True,
        database_engine=settings.database_engine,
    )
    await repository.startup()
    await repository.shutdown()


if __name__ == "__main__":
    asyncio.run(run())
