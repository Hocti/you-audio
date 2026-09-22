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
