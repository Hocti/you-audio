"""YouTube Data API v3 helper -- fetch a channel's latest videos with caching."""

from __future__ import annotations

import os
import re
import time

import httpx

YOUTUBE_API_BASE = "https://www.googleapis.com/youtube/v3"

# How long a channel's video list stays fresh, in seconds.
CACHE_TTL_SECONDS = 3600

# Max records returned per request (YouTube Data API caps maxResults at 50).
MAX_RESULTS = 50

# In-memory cache: { channel_id: (fetched_at_epoch, [video dicts]) }.
# Plain dict like progress_store -- cleared on server restart.
_channel_cache: dict[str, tuple[float, list[dict]]] = {}


class YouTubeApiError(Exception):
    """Raised when the YouTube Data API call fails or is misconfigured.

    `status_code` is the HTTP status the route should surface to the client.
    """

    def __init__(self, status_code: int, detail: str) -> None:
        super().__init__(detail)
        self.status_code = status_code
        self.detail = detail


def _api_key() -> str:
    key = os.getenv("YOUTUBE_API_KEY", "")
    if not key:
        raise YouTubeApiError(500, "YouTube API key not configured")
    return key


def get_cached(channel_id: str) -> list[dict] | None:
    """Return cached videos if present and still fresh, else None."""
    entry = _channel_cache.get(channel_id)
    if entry is None:
        return None
    fetched_at, videos = entry
    if time.time() - fetched_at >= CACHE_TTL_SECONDS:
        return None
    return videos


async def _get(client: httpx.AsyncClient, path: str, params: dict) -> dict:
    params = {**params, "key": _api_key()}
    resp = await client.get(f"{YOUTUBE_API_BASE}/{path}", params=params)
    if resp.status_code != 200:
        # Surface YouTube's own error message (e.g. quota exceeded, bad key).
        try:
            message = resp.json()["error"]["message"]
        except Exception:
            message = resp.text
        raise YouTubeApiError(502, f"YouTube API error: {message}")
    return resp.json()


async def _uploads_playlist_id(client: httpx.AsyncClient, channel_id: str) -> str:
    data = await _get(
        client,
        "channels",
        {"part": "contentDetails", "id": channel_id},
    )
    items = data.get("items") or []
    if not items:
        raise YouTubeApiError(404, "Channel not found")
    return items[0]["contentDetails"]["relatedPlaylists"]["uploads"]


def _best_thumbnail(thumbnails: dict) -> str | None:
    for quality in ("maxres", "standard", "high", "medium", "default"):
        thumb = thumbnails.get(quality)
        if thumb:
            return thumb.get("url")
    return None


async def fetch_latest_videos(channel_id: str) -> list[dict]:
    """Fetch up to MAX_RESULTS latest videos for a channel, using the cache.

    Returns a list of dicts: video_id, title, published_at, thumbnail_url,
    channel_name. Raises YouTubeApiError on misconfiguration or API failure.
    """
    cached = get_cached(channel_id)
    if cached is not None:
        return cached

    async with httpx.AsyncClient(timeout=15.0) as client:
        uploads_id = await _uploads_playlist_id(client, channel_id)
        data = await _get(
            client,
            "playlistItems",
            {
                "part": "snippet",
                "playlistId": uploads_id,
                "maxResults": MAX_RESULTS,
            },
        )

    videos: list[dict] = []
    for item in data.get("items", []):
        snippet = item.get("snippet", {})
        resource = snippet.get("resourceId", {})
        video_id = resource.get("videoId")
        if not video_id:
            continue
        videos.append(
            {
                "video_id": video_id,
                "title": snippet.get("title"),
                "published_at": snippet.get("publishedAt"),
                "thumbnail_url": _best_thumbnail(snippet.get("thumbnails", {})),
                "channel_name": snippet.get("channelTitle"),
            }
        )

    _channel_cache[channel_id] = (time.time(), videos)
    return videos


# ---------------------------------------------------------------------------
# Channel id resolution (bare id / URL / @handle / user / custom)
# ---------------------------------------------------------------------------

_UC_RE = re.compile(r"(UC[0-9A-Za-z_-]{22})")
_HANDLE_RE = re.compile(r"@([0-9A-Za-z._-]+)")
_USER_RE = re.compile(r"/user/([0-9A-Za-z._-]+)")
_CUSTOM_RE = re.compile(r"/c/([0-9A-Za-z._-]+)")


async def _channel_by(client: httpx.AsyncClient, params: dict) -> dict | None:
    data = await _get(client, "channels", {"part": "id,snippet", **params})
    items = data.get("items") or []
    if not items:
        return None
    item = items[0]
    return {"channel_id": item["id"], "channel_name": item["snippet"]["title"]}


async def _search_channel(client: httpx.AsyncClient, query: str) -> dict | None:
    data = await _get(
        client,
        "search",
        {"part": "snippet", "type": "channel", "q": query, "maxResults": 1},
    )
    items = data.get("items") or []
    if not items:
        return None
    item = items[0]
    return {
        "channel_id": item["snippet"]["channelId"],
        "channel_name": item["snippet"]["title"],
    }


async def resolve_channel(raw: str) -> dict:
    """Resolve a channel id from various inputs.

    Accepts a bare `UC…` id, a `/channel/UC…` URL, an `@handle` (or handle URL),
    a `/user/NAME` URL, a `/c/NAME` custom URL, or plain search text. Returns
    `{"channel_id": str, "channel_name": str | None}`.

    `@handle` and `/user/` cost 1 quota unit; the search fallback costs 100.
    """
    raw = (raw or "").strip()
    if not raw:
        raise YouTubeApiError(400, "Empty channel input")

    # Fast path: a channel id is present verbatim (no API call needed).
    m = _UC_RE.search(raw)
    if m:
        return {"channel_id": m.group(1), "channel_name": None}

    async with httpx.AsyncClient(timeout=15.0) as client:
        hm = _HANDLE_RE.search(raw)
        if hm:
            got = await _channel_by(client, {"forHandle": hm.group(1)})
            if got:
                return got

        um = _USER_RE.search(raw)
        if um:
            got = await _channel_by(client, {"forUsername": um.group(1)})
            if got:
                return got

        # /c/Custom URL, or plain text -> search as a best-effort fallback.
        cm = _CUSTOM_RE.search(raw)
        query = cm.group(1) if cm else raw
        got = await _search_channel(client, query)
        if got:
            return got

    raise YouTubeApiError(404, "Could not resolve a channel from that input")
