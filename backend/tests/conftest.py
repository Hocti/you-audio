"""Test fixtures.

Environment must be set *before* `app.*` is imported, because
`app.database` reads `DATABASE_URL` and `app.downloader` reads `DATA_DIR`
at import time. We point both at a throwaway temp directory.
"""

import os
import tempfile
from pathlib import Path

_TMP = Path(tempfile.mkdtemp(prefix="ytaudio-test-"))
os.environ["DATABASE_URL"] = f"sqlite+aiosqlite:///{_TMP / 'test.db'}"
os.environ["DATA_DIR"] = str(_TMP / "data")
os.environ["ACCESS_TOKEN"] = "admin-seed-token"
os.environ.setdefault("YOUTUBE_API_KEY", "test-key")

import pytest
import pytest_asyncio
from httpx import ASGITransport, AsyncClient

ADMIN_TOKEN = "admin-seed-token"


@pytest_asyncio.fixture
async def app_module():
    """Fresh schema + seeded admin for each test, using the real engine."""
    from app import main as main_mod
    from app.database import engine
    from app.models import Base

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)
        await conn.run_sync(Base.metadata.create_all)
    # `progress_store` is a module-level dict that outlives a test; a download
    # left in it makes the next test think one is still running.
    main_mod.progress_store.clear()
    await main_mod.ensure_admin()

    yield main_mod

    main_mod.progress_store.clear()

    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.drop_all)


@pytest_asyncio.fixture
async def client(app_module):
    transport = ASGITransport(app=app_module.app)
    async with AsyncClient(transport=transport, base_url="http://test") as ac:
        yield ac


def auth(token: str) -> dict[str, str]:
    return {"X-Access-Token": token}
