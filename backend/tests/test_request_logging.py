"""Request logging: only expensive ops are logged, with details + status."""

import pytest
from sqlalchemy import select

from conftest import ADMIN_TOKEN, auth


async def _request_rows(app_module):
    from app.database import async_session
    from app.models import RequestLog

    async with async_session() as session:
        rows = (await session.execute(select(RequestLog))).scalars().all()
        # detach by reading fields now
        return [
            {
                "user_id": r.user_id,
                "method": r.method,
                "path": r.path,
                "argument": r.argument,
                "status_code": r.status_code,
            }
            for r in rows
        ]


async def test_expensive_op_is_logged(client, app_module, monkeypatch):
    async def fake_resolve(q):
        return {"channel_id": "UC123", "channel_name": "Test"}

    monkeypatch.setattr(app_module, "resolve_channel", fake_resolve)

    resp = await client.get(
        "/api/channel/resolve", params={"q": "abc"}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 200

    rows = await _request_rows(app_module)
    assert len(rows) == 1
    row = rows[0]
    assert row["path"] == "/api/channel/resolve"
    assert row["method"] == "GET"
    assert row["argument"] == "abc"
    assert row["status_code"] == 200
    assert row["user_id"] is not None


async def test_listing_is_not_logged(client, app_module):
    resp = await client.get("/api/videos", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200
    assert await _request_rows(app_module) == []


async def test_health_is_not_logged(client, app_module):
    await client.get("/api/health", headers=auth(ADMIN_TOKEN))
    assert await _request_rows(app_module) == []


async def test_failed_op_logs_error_status(client, app_module, monkeypatch):
    from app.youtube_api import YouTubeApiError

    async def boom(q):
        raise YouTubeApiError(404, "not found")

    monkeypatch.setattr(app_module, "resolve_channel", boom)

    resp = await client.get(
        "/api/channel/resolve", params={"q": "missing"}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 404

    rows = await _request_rows(app_module)
    assert len(rows) == 1
    assert rows[0]["status_code"] == 404
    assert rows[0]["argument"] == "missing"
