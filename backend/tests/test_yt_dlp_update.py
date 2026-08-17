"""The yt-dlp version + self-update endpoints.

`_pip_upgrade` is stubbed throughout — these tests cover the wiring (auth,
reload gating, error surfacing), never a real network install.
"""

import pytest

from conftest import ADMIN_TOKEN, auth

from app import downloader


@pytest.fixture
def fake_pip(monkeypatch):
    """Replace the pip half of the upgrade with a canned output string."""

    def _install(output="Successfully installed yt-dlp-2099.1.1"):
        async def _fake():
            return output

        monkeypatch.setattr(downloader, "_pip_upgrade", _fake)

    return _install


async def _make_plain_user(client, username="plain"):
    resp = await client.post(
        "/api/users", json={"username": username}, headers=auth(ADMIN_TOKEN)
    )
    assert resp.status_code == 201
    return resp.json()["token"]


# --- version ------------------------------------------------------------

async def test_version_requires_token(client):
    assert (await client.get("/api/yt-dlp/version")).status_code == 401


async def test_version_reports_loaded_version(client):
    resp = await client.get("/api/yt-dlp/version", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200
    assert resp.json()["version"] == downloader.yt_dlp_version()


# --- update -------------------------------------------------------------

async def test_update_requires_admin(client, fake_pip):
    fake_pip()
    token = await _make_plain_user(client)

    assert (await client.get("/api/yt-dlp/update")).status_code == 401
    resp = await client.get("/api/yt-dlp/update", headers=auth(token))
    assert resp.status_code == 403


async def test_update_reloads_and_reports_versions(client, fake_pip):
    fake_pip()
    resp = await client.get("/api/yt-dlp/update", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200
    body = resp.json()

    # Nothing actually changed on disk, so the version is stable — but the
    # module was re-imported and the response describes what happened.
    assert body["current_version"] == downloader.yt_dlp_version()
    assert body["reloaded"] is True
    assert body["updated"] is False
    assert body["restart_required"] is False
    assert "Successfully installed" in body["pip_output"]


async def test_update_defers_reload_while_a_download_runs(client, fake_pip):
    fake_pip()
    downloader.progress_store["task-in-flight"] = downloader.TaskProgress(
        status="downloading"
    )
    try:
        resp = await client.get("/api/yt-dlp/update", headers=auth(ADMIN_TOKEN))
    finally:
        del downloader.progress_store["task-in-flight"]

    assert resp.status_code == 200
    body = resp.json()
    assert body["reloaded"] is False
    assert body["restart_required"] is True


async def test_update_surfaces_pip_failure_as_502(client, monkeypatch):
    async def _boom():
        raise RuntimeError("pip install failed (exit 1): no network")

    monkeypatch.setattr(downloader, "_pip_upgrade", _boom)

    resp = await client.get("/api/yt-dlp/update", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 502
    assert "no network" in resp.json()["detail"]


async def test_update_is_request_logged(client, fake_pip):
    fake_pip()
    await client.get("/api/yt-dlp/update", headers=auth(ADMIN_TOKEN))

    from sqlalchemy import select

    from app.database import async_session
    from app.models import RequestLog

    async with async_session() as session:
        rows = (await session.execute(select(RequestLog))).scalars().all()
        logged = [(r.path, r.argument, r.status_code) for r in rows]

    assert ("/api/yt-dlp/update", "yt-dlp update", 200) in logged
