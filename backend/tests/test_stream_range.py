"""`/api/stream/{id}`: real HTTP range support for the streaming player.

`/api/audio` advertises `Accept-Ranges: bytes` but Starlette's FileResponse
ignores `Range` and returns the whole file — a client that seeks would play the
wrong audio. These tests pin the new route's behaviour.
"""

import pytest

from conftest import ADMIN_TOKEN, auth

from app.main import parse_byte_range

VIDEO_ID = "streamtest1"
CONTENT = bytes(range(256)) * 40  # 10240 bytes, every value distinguishable


@pytest.fixture
async def stored_audio(app_module):
    """A `done` video row whose mp3 exists on disk."""
    from app.database import async_session
    from app.downloader import AUDIO_DIR
    from app.models import Video

    path = AUDIO_DIR / f"{VIDEO_ID}.mp3"
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_bytes(CONTENT)

    async with async_session() as session:
        async with session.begin():
            session.add(
                Video(
                    youtube_id=VIDEO_ID,
                    title="Stream test",
                    status="done",
                    mp3_path=str(path),
                    file_size=len(CONTENT),
                )
            )
    yield path
    path.unlink(missing_ok=True)


# --- header parsing -----------------------------------------------------

@pytest.mark.parametrize(
    "header,expected",
    [
        ("bytes=0-99", (0, 99)),
        ("bytes=100-", (100, 10239)),
        ("bytes=-500", (9740, 10239)),
        ("bytes=0-99999", (0, 10239)),        # end clamped to the file
        (" bytes=5-10 ", (5, 10)),            # tolerate whitespace
        (None, None),                          # no range -> whole file
        ("", None),
        ("items=0-9", None),                   # unknown unit -> whole file
        ("bytes=0-9,20-29", None),             # multi-range -> whole file
        ("bytes=abc-def", None),               # unparsable -> whole file
        ("bytes=", None),
    ],
)
def test_parse_byte_range(header, expected):
    assert parse_byte_range(header, len(CONTENT)) == expected


@pytest.mark.parametrize("header", ["bytes=10240-", "bytes=99999-100000", "bytes=-0"])
def test_unsatisfiable_ranges_raise(header):
    with pytest.raises(ValueError):
        parse_byte_range(header, len(CONTENT))


# --- route --------------------------------------------------------------

async def test_requires_token(client, stored_audio):
    assert (await client.get(f"/api/stream/{VIDEO_ID}")).status_code == 401


async def test_whole_file_without_a_range(client, stored_audio):
    resp = await client.get(f"/api/stream/{VIDEO_ID}", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200
    assert resp.headers["accept-ranges"] == "bytes"
    assert resp.headers["content-length"] == str(len(CONTENT))
    assert resp.content == CONTENT


async def test_range_returns_206_with_the_right_bytes(client, stored_audio):
    resp = await client.get(
        f"/api/stream/{VIDEO_ID}",
        headers={**auth(ADMIN_TOKEN), "Range": "bytes=1000-2000"},
    )
    assert resp.status_code == 206
    assert resp.headers["content-range"] == f"bytes 1000-2000/{len(CONTENT)}"
    assert resp.headers["content-length"] == "1001"
    # The actual bytes must come from the requested offset — the bug in
    # /api/audio is that they came from 0.
    assert resp.content == CONTENT[1000:2001]


async def test_open_ended_range_reaches_the_end(client, stored_audio):
    resp = await client.get(
        f"/api/stream/{VIDEO_ID}",
        headers={**auth(ADMIN_TOKEN), "Range": "bytes=10000-"},
    )
    assert resp.status_code == 206
    assert resp.content == CONTENT[10000:]
    assert resp.headers["content-range"] == f"bytes 10000-10239/{len(CONTENT)}"


async def test_suffix_range(client, stored_audio):
    resp = await client.get(
        f"/api/stream/{VIDEO_ID}",
        headers={**auth(ADMIN_TOKEN), "Range": "bytes=-256"},
    )
    assert resp.status_code == 206
    assert resp.content == CONTENT[-256:]


async def test_unsatisfiable_range_returns_416(client, stored_audio):
    resp = await client.get(
        f"/api/stream/{VIDEO_ID}",
        headers={**auth(ADMIN_TOKEN), "Range": "bytes=99999-"},
    )
    assert resp.status_code == 416
    assert resp.headers["content-range"] == f"bytes */{len(CONTENT)}"


async def test_missing_video_is_404(client, stored_audio):
    resp = await client.get("/api/stream/nosuchvideo", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 404


async def test_unfinished_video_is_404(client, app_module, stored_audio):
    """Only a `done` row can be streamed — nothing to serve before that."""
    from sqlalchemy import select

    from app.database import async_session
    from app.models import Video

    async with async_session() as session:
        async with session.begin():
            row = (
                await session.execute(
                    select(Video).where(Video.youtube_id == VIDEO_ID)
                )
            ).scalar_one()
            row.status = "downloading"

    resp = await client.get(f"/api/stream/{VIDEO_ID}", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 404


async def test_api_audio_is_unchanged(client, stored_audio):
    """The old route keeps its behaviour — this feature is additive."""
    resp = await client.get(f"/api/audio/{VIDEO_ID}", headers=auth(ADMIN_TOKEN))
    assert resp.status_code == 200
    assert resp.content == CONTENT
