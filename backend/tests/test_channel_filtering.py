"""`youtube_api._filter_playable`: what gets dropped from a channel list."""

import pytest

from app import youtube_api


def _video(vid):
    return {"video_id": vid, "title": vid, "channel_name": "Test"}


@pytest.fixture
def fake_videos_list(monkeypatch):
    """Stub the `videos.list` call with duration (+ optional liveBroadcast) maps."""

    def _install(durations, live=None):
        live = live or {}

        async def _get(client, path, params):
            assert path == "videos"
            requested = params["id"].split(",")
            return {
                "items": [
                    {
                        "id": vid,
                        "contentDetails": {"duration": durations[vid]},
                        "snippet": {
                            "liveBroadcastContent": live.get(vid, "none"),
                        },
                    }
                    for vid in requested
                    if vid in durations
                ]
            }

        monkeypatch.setattr(youtube_api, "_get", _get)

    return _install


async def test_shorts_are_dropped(fake_videos_list):
    fake_videos_list({"short": "PT45S", "normal": "PT12M3S"})
    kept = await youtube_api._filter_playable(
        None, [_video("short"), _video("normal")]
    )
    assert [v["video_id"] for v in kept] == ["normal"]


async def test_inaccessible_videos_are_dropped(fake_videos_list):
    # "members" is absent from the videos.list response (members-only/private).
    fake_videos_list({"normal": "PT12M3S"})
    kept = await youtube_api._filter_playable(
        None, [_video("members"), _video("normal")]
    )
    assert [v["video_id"] for v in kept] == ["normal"]


async def test_zero_duration_live_or_upcoming_is_kept(fake_videos_list):
    # Live streams / premieres report P0D. They are not Shorts; the API keeps
    # them (with duration + live_broadcast) so the client can collapse them.
    fake_videos_list({"live": "P0D", "normal": "PT12M3S"}, live={"live": "live"})
    kept = await youtube_api._filter_playable(
        None, [_video("live"), _video("normal")]
    )
    assert [v["video_id"] for v in kept] == ["live", "normal"]
    by_id = {v["video_id"]: v for v in kept}
    assert by_id["live"]["duration"] == 0
    assert by_id["live"]["live_broadcast"] == "live"
    assert by_id["normal"]["duration"] == 723
    assert by_id["normal"]["live_broadcast"] == "none"


async def test_boundary_60s_is_a_short_61s_is_not(fake_videos_list):
    fake_videos_list({"sixty": "PT1M", "sixtyone": "PT1M1S"})
    kept = await youtube_api._filter_playable(
        None, [_video("sixty"), _video("sixtyone")]
    )
    assert [v["video_id"] for v in kept] == ["sixtyone"]


async def test_shorts_playlist_is_authoritative(fake_videos_list):
    # With the UUSH id set, length doesn't matter: a 63s Short is dropped and a
    # 45s regular (horizontal) clip is kept.
    fake_videos_list({"short63": "PT1M3S", "clip45": "PT45S"})
    kept = await youtube_api._filter_playable(
        None, [_video("short63"), _video("clip45")], shorts_ids={"short63"}
    )
    assert [v["video_id"] for v in kept] == ["clip45"]


async def test_members_only_is_kept_and_flagged(fake_videos_list):
    # videos.list returns members-only videos like public ones; only UUMO
    # membership marks them.
    fake_videos_list({"members": "PT1H", "normal": "PT12M"})
    kept = await youtube_api._filter_playable(
        None,
        [_video("members"), _video("normal")],
        shorts_ids=set(),
        members_ids={"members"},
    )
    flags = {v["video_id"]: v["members_only"] for v in kept}
    assert flags == {"members": True, "normal": False}


# --- fetch_channel_page: paging + system playlists -------------------------

CH = "UC" + "x" * 22


@pytest.fixture
def fake_channel(monkeypatch):
    """Stub every YouTube call fetch_channel_page makes.

    Uploads: two pages (p1 -> token "T2" -> p2). UUSH holds "s1"; the channel
    has no UUMO playlist (404).
    """
    youtube_api._page_cache.clear()
    youtube_api._aux_cache.clear()
    calls: list[tuple[str, str]] = []

    def item(vid, day):
        return {
            "snippet": {
                "resourceId": {"videoId": vid},
                "title": vid,
                "publishedAt": f"2026-10-{day:02d}T00:00:00Z",
                "channelTitle": "Test",
                "thumbnails": {},
            },
            "contentDetails": {
                "videoId": vid,
                "videoPublishedAt": f"2026-10-{day:02d}T00:00:00Z",
            },
        }

    uploads = {
        None: ({"items": [item("v1", 20), item("s1", 19)], "nextPageToken": "T2"}),
        "T2": ({"items": [item("v2", 10)]}),
    }

    async def _get(client, path, params):
        if path == "channels":
            return {"items": [{"contentDetails": {"relatedPlaylists": {"uploads": "UU" + CH[2:]}}}]}
        if path == "playlistItems":
            pl = params["playlistId"]
            calls.append((pl[:4], params.get("pageToken")))
            if pl.startswith("UUSH"):
                return {"items": [item("s1", 19)]}
            if pl.startswith("UUMO"):
                raise youtube_api.YouTubeApiError(404, "not found")
            return uploads[params.get("pageToken")]
        if path == "videos":
            return {
                "items": [
                    {"id": vid, "contentDetails": {"duration": "PT10M"}, "snippet": {}}
                    for vid in params["id"].split(",")
                ]
            }
        raise AssertionError(path)

    monkeypatch.setattr(youtube_api, "_get", _get)
    return calls


async def test_channel_pages_follow_token_and_drop_shorts(fake_channel):
    p1 = await youtube_api.fetch_channel_page(CH)
    assert [v["video_id"] for v in p1["videos"]] == ["v1"]
    assert p1["next_page_token"] == "T2"

    p2 = await youtube_api.fetch_channel_page(CH, "T2")
    assert [v["video_id"] for v in p2["videos"]] == ["v2"]
    assert p2["next_page_token"] is None

    # The exhausted UUSH / missing UUMO playlists are read once, not per page.
    assert sum(1 for c in fake_channel if c[0] == "UUSH") == 1
    assert sum(1 for c in fake_channel if c[0] == "UUMO") == 1


async def test_channel_page_is_cached_per_token(fake_channel):
    await youtube_api.fetch_channel_page(CH)
    n = len(fake_channel)
    await youtube_api.fetch_channel_page(CH)
    assert len(fake_channel) == n
    assert youtube_api.get_cached(CH) is not None
    assert youtube_api.get_cached(CH, "T2") is None
