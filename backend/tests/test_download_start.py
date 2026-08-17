"""`/api/download` must actually start a download.

The metadata-first client flow calls `/api/metadata` before `/api/download`, and
metadata creates the row as `pending`. If `/api/download` reads that as "already
in flight" it returns a task id that no task will ever report on, and the client
polls 0% forever.
"""

import pytest

from conftest import ADMIN_TOKEN, auth

VIDEO_ID = "Ob4UXGNHX4g"
URL = f"https://www.youtube.com/watch?v={VIDEO_ID}"


@pytest.fixture
def captured_downloads(app_module, monkeypatch):
    """Replace run_download so nothing touches YouTube; record the calls."""
    calls = []

    async def fake_run_download(youtube_id, task_id, video_db_id):
        calls.append({"youtube_id": youtube_id, "task_id": task_id})

    monkeypatch.setattr(app_module, "run_download", fake_run_download)
    return calls


@pytest.fixture
def stub_metadata(app_module, monkeypatch):
    async def fake_fetch_metadata(video_id):
        return {
            "title": "Test title",
            "channel_name": "Test channel",
            "channel_id": "UC123",
            "duration": 1234,
            "thumbnail_url": "https://example.invalid/t.jpg",
            "thumbnail_path": None,
        }

    monkeypatch.setattr(app_module, "fetch_metadata", fake_fetch_metadata)


async def _wait_for_task(calls):
    """run_download is fired via asyncio.create_task; let it be scheduled."""
    import asyncio

    for _ in range(20):
        if calls:
            return
        await asyncio.sleep(0)


async def test_download_starts_after_metadata_created_the_row(
    client, app_module, stub_metadata, captured_downloads
):
    meta = await client.post(
        "/api/metadata", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    assert meta.status_code == 200

    resp = await client.post(
        "/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 200
    assert resp.json()["cached"] is False

    await _wait_for_task(captured_downloads)
    assert captured_downloads, (
        "no download was started — the pending row from /api/metadata was "
        "mistaken for an in-flight task"
    )
    assert captured_downloads[0]["youtube_id"] == VIDEO_ID
    # The client must poll the task that is actually running.
    assert captured_downloads[0]["task_id"] == resp.json()["task_id"]


async def test_download_starts_with_no_prior_row(
    client, app_module, captured_downloads
):
    resp = await client.post(
        "/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 200
    await _wait_for_task(captured_downloads)
    assert captured_downloads


async def test_a_genuinely_live_task_is_not_restarted(
    client, app_module, captured_downloads
):
    """Two clients asking for the same video share one download."""
    first = await client.post(
        "/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    await _wait_for_task(captured_downloads)
    assert len(captured_downloads) == 1

    # The task is registered in progress_store, so this must attach to it.
    second = await client.post(
        "/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    assert second.json()["task_id"] == first.json()["task_id"]
    assert len(captured_downloads) == 1


async def test_abandoned_row_is_restarted_after_a_restart(
    client, app_module, captured_downloads
):
    """A restart empties progress_store; a `pending` row must not be permanent."""
    await client.post("/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN))
    await _wait_for_task(captured_downloads)
    assert len(captured_downloads) == 1

    app_module.progress_store.clear()  # what a process restart looks like

    resp = await client.post(
        "/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 200
    await _wait_for_task(captured_downloads)
    assert len(captured_downloads) == 2, "abandoned download was never retried"


async def test_finished_video_is_still_served_from_cache(
    client, app_module, captured_downloads
):
    from sqlalchemy import select

    from app.database import async_session
    from app.models import Video

    await client.post("/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN))
    await _wait_for_task(captured_downloads)

    async with async_session() as session:
        async with session.begin():
            row = (
                await session.execute(
                    select(Video).where(Video.youtube_id == VIDEO_ID)
                )
            ).scalar_one()
            row.status = "done"

    resp = await client.post(
        "/api/download", json={"url": URL}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.json()["cached"] is True
    assert len(captured_downloads) == 1, "a cached video must not re-download"
