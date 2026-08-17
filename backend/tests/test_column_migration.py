"""Startup migration for columns added to already-shipped tables."""

import pytest

from conftest import ADMIN_TOKEN, auth


async def _videos_columns(app_module):
    from sqlalchemy import inspect

    from app.database import engine

    async with engine.begin() as conn:
        return await conn.run_sync(
            lambda c: {col["name"] for col in inspect(c).get_columns("videos")}
        )


async def _drop_channel_id(app_module):
    """Recreate the pre-`channel_id` shape an upgraded database arrives in."""
    from app.database import engine

    async with engine.begin() as conn:
        await conn.exec_driver_sql("ALTER TABLE videos DROP COLUMN channel_id")


async def test_missing_column_is_added_on_startup(client, app_module):
    await _drop_channel_id(app_module)
    assert "channel_id" not in await _videos_columns(app_module)

    await app_module.ensure_columns()

    assert "channel_id" in await _videos_columns(app_module)


async def test_listing_videos_fails_without_the_column_and_works_after(
    client, app_module
):
    await _drop_channel_id(app_module)

    # This is the post-upgrade 500 the migration exists to prevent.
    with pytest.raises(Exception):
        await client.get("/api/videos", headers=auth(ADMIN_TOKEN))

    await app_module.ensure_columns()

    resp = await client.get("/api/videos", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200


async def test_ensure_columns_is_idempotent(client, app_module):
    before = await _videos_columns(app_module)
    await app_module.ensure_columns()
    await app_module.ensure_columns()
    assert await _videos_columns(app_module) == before
