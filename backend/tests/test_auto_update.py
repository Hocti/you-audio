"""Automatic yt-dlp upgrades: plugin/sidecar version pinning, and the
upgrade-then-retry-once path a failed download takes.

pip and the actual yt-dlp download are stubbed — no network.
"""

import uuid

import pytest

from app import downloader, ytdlp_update

INSTALLED = "Successfully installed yt-dlp-2099.1.1"
NOTHING = "Requirement already satisfied: yt-dlp"


# --- which packages get upgraded -----------------------------------------

def test_plugin_pinned_to_sidecar_version(monkeypatch):
    monkeypatch.setattr(ytdlp_update, "pot_server_version", lambda attempts=1: "1.3.1")
    assert ytdlp_update.upgrade_specs() == [
        "yt-dlp[default]",
        "bgutil-ytdlp-pot-provider==1.3.1",
    ]


def test_plugin_latest_when_sidecar_unreachable(monkeypatch):
    monkeypatch.setattr(ytdlp_update, "pot_server_version", lambda attempts=1: None)
    assert ytdlp_update.upgrade_specs() == ["yt-dlp[default]", "bgutil-ytdlp-pot-provider"]


# --- failed download -> upgrade -> retry ---------------------------------

@pytest.fixture
def auto_update(monkeypatch):
    """Reset the rate-limit state and stub pip + the download itself."""
    monkeypatch.setattr(downloader, "_last_auto_update_attempt", None)
    monkeypatch.setattr(downloader, "_last_reload_with_changes", None)
    monkeypatch.setattr(downloader, "AUTO_UPDATE_COOLDOWN_SECONDS", 1800.0)
    monkeypatch.setattr(downloader, "_reload_yt_dlp", lambda: downloader.yt_dlp_version())

    state = {"pip_calls": 0, "pip_output": INSTALLED, "outcomes": []}

    async def _fake_pip():
        state["pip_calls"] += 1
        return state["pip_output"]

    def _fake_download(youtube_id, task_id):
        outcome = state["outcomes"].pop(0)
        if isinstance(outcome, Exception):
            raise outcome
        return outcome

    monkeypatch.setattr(downloader, "_pip_upgrade", _fake_pip)
    monkeypatch.setattr(downloader, "_sync_download", _fake_download)
    downloader.progress_store.clear()
    yield state
    downloader.progress_store.clear()


def _task(status="downloading"):
    task_id = str(uuid.uuid4())
    downloader.progress_store[task_id] = downloader.TaskProgress(status=status)
    return task_id


async def test_failure_upgrades_and_retries_once(auto_update):
    auto_update["outcomes"] = [RuntimeError("HTTP Error 403"), {"ok": True}]

    result = await downloader._download_with_auto_update("vid", _task())

    assert result == {"ok": True}
    assert auto_update["pip_calls"] == 1


async def test_no_retry_when_upgrade_changed_nothing(auto_update):
    auto_update["pip_output"] = NOTHING
    auto_update["outcomes"] = [RuntimeError("Video unavailable")]

    with pytest.raises(RuntimeError, match="Video unavailable"):
        await downloader._download_with_auto_update("vid", _task())
    assert auto_update["pip_calls"] == 1


async def test_retry_failure_raises_retry_error(auto_update):
    auto_update["outcomes"] = [RuntimeError("first"), RuntimeError("second")]

    with pytest.raises(RuntimeError, match="second"):
        await downloader._download_with_auto_update("vid", _task())


async def test_cooldown_limits_upgrades(auto_update):
    auto_update["pip_output"] = NOTHING
    auto_update["outcomes"] = [RuntimeError("a"), RuntimeError("b")]

    for _ in range(2):
        with pytest.raises(RuntimeError):
            await downloader._download_with_auto_update("vid", _task())
    assert auto_update["pip_calls"] == 1


async def test_cooldown_zero_disables(auto_update, monkeypatch):
    monkeypatch.setattr(downloader, "AUTO_UPDATE_COOLDOWN_SECONDS", 0.0)
    auto_update["outcomes"] = [RuntimeError("a")]

    with pytest.raises(RuntimeError):
        await downloader._download_with_auto_update("vid", _task())
    assert auto_update["pip_calls"] == 0


async def test_failed_task_does_not_block_its_own_reload(auto_update, monkeypatch):
    """The failing task is still `downloading`; it must not defer the reload."""
    reloads = []
    monkeypatch.setattr(
        downloader, "_reload_yt_dlp", lambda: reloads.append(1) or downloader.yt_dlp_version()
    )
    auto_update["outcomes"] = [RuntimeError("403"), {"ok": True}]

    await downloader._download_with_auto_update("vid", _task())
    assert reloads == [1]


async def test_other_download_in_flight_defers_reload_and_skips_retry(auto_update):
    _task("downloading")  # someone else's download, still running
    auto_update["outcomes"] = [RuntimeError("403")]

    with pytest.raises(RuntimeError, match="403"):
        await downloader._download_with_auto_update("vid", _task())
    assert auto_update["pip_calls"] == 1


async def test_retries_without_pip_if_upgraded_meanwhile(auto_update, monkeypatch):
    """Another task already loaded new packages after this one started."""
    auto_update["outcomes"] = [RuntimeError("403"), {"ok": True}]
    task_id = _task()

    real_sync = downloader._sync_download

    def _fail_after_someone_upgrades(youtube_id, tid):
        downloader._last_reload_with_changes = downloader.time.monotonic()
        return real_sync(youtube_id, tid)

    monkeypatch.setattr(downloader, "_sync_download", _fail_after_someone_upgrades)
    assert await downloader._download_with_auto_update("vid", task_id) == {"ok": True}
    assert auto_update["pip_calls"] == 0
