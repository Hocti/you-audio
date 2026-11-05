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

# In-memory caches, cleared on server restart (like progress_store).
# Pages: { (channel_id, page_token): (fetched_at, page dict) }.
_page_cache: dict[tuple[str, str], tuple[float, dict]] = {}
# Auto-generated filter playlists: { (channel_id, prefix): (fetched_at, _AuxPlaylist) }.
_aux_cache: dict[tuple[str, str], tuple[float, "_AuxPlaylist"]] = {}


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


def get_cached(channel_id: str, page_token: str | None = None) -> dict | None:
    """Return a cached page if present and still fresh, else None."""
    entry = _page_cache.get((channel_id, page_token or ""))
    if entry is None:
        return None
    fetched_at, page = entry
    if time.time() - fetched_at >= CACHE_TTL_SECONDS:
        return None
    return page


async def _get(client: httpx.AsyncClient, path: str, params: dict) -> dict:
    params = {**params, "key": _api_key()}
    resp = await client.get(f"{YOUTUBE_API_BASE}/{path}", params=params)
    if resp.status_code != 200:
        # Surface YouTube's own error message (e.g. quota exceeded, bad key).
        try:
            message = resp.json()["error"]["message"]
        except Exception:
            message = resp.text
        status = 404 if resp.status_code == 404 else 502
        raise YouTubeApiError(status, f"YouTube API error: {message}")
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


# ---------------------------------------------------------------------------
# Shorts / members-only detection via YouTube's auto-generated playlists
# ---------------------------------------------------------------------------
#
# Every channel has hidden system playlists next to its uploads list (UU…):
#   UUSH… = Shorts (YouTube's own classification: vertical + short)
#   UUMO… = members-only videos
# A members-only video is returned by videos.list like any public video, so
# these playlists are the only reliable signal for an unauthenticated key.
# A channel with no Shorts / members content returns 404 for that playlist.

SHORTS_PREFIX = "UUSH"
MEMBERS_PREFIX = "UUMO"

# Fallback when the Shorts playlist can't be read: at/under this length = Short.
_SHORTS_MAX_SECONDS = 60

# The system playlists are only roughly date-ordered, so keep reading until
# their oldest entry is this much older than the page being filtered.
_AUX_MARGIN_SECONDS = 30 * 86400
# Hard cap on aux pages read per request (each costs 1 quota unit).
_AUX_MAX_PAGES_PER_CALL = 10


def _aux_playlist_id(channel_id: str, prefix: str) -> str:
    return prefix + channel_id[2:]


def _epoch(iso: str | None) -> float | None:
    if not iso:
        return None
    try:
        from datetime import datetime

        return datetime.fromisoformat(iso.replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


class _AuxPlaylist:
    """Incrementally-read id set of one system playlist (UUSH / UUMO)."""

    def __init__(self, playlist_id: str) -> None:
        self.playlist_id = playlist_id
        self.ids: set[str] = set()
        self.next_token: str | None = None
        self.started = False
        self.exhausted = False
        self.failed = False  # read error other than 404 -> caller falls back
        self.oldest: float | None = None

    def covers(self, cutoff: float | None) -> bool:
        if self.exhausted or self.failed:
            return True
        if not self.started or cutoff is None or self.oldest is None:
            return False
        return self.oldest < cutoff - _AUX_MARGIN_SECONDS

    async def ensure(self, client: httpx.AsyncClient, cutoff: float | None) -> None:
        """Read pages until entries older than `cutoff` (minus margin) are seen.

        `cutoff=None` means "read everything" (bounded by the per-call cap).
        """
        pages = 0
        while not self.covers(cutoff) and pages < _AUX_MAX_PAGES_PER_CALL:
            params = {
                "part": "contentDetails",
                "playlistId": self.playlist_id,
                "maxResults": MAX_RESULTS,
            }
            if self.next_token:
                params["pageToken"] = self.next_token
            try:
                data = await _get(client, "playlistItems", params)
            except YouTubeApiError as exc:
                if exc.status_code == 404:
                    self.exhausted = True  # channel has no such playlist
                else:
                    self.failed = True
                return
            self.started = True
            pages += 1
            for item in data.get("items", []):
                cd = item.get("contentDetails", {})
                vid = cd.get("videoId")
                if vid:
                    self.ids.add(vid)
                ts = _epoch(cd.get("videoPublishedAt"))
                if ts is not None and (self.oldest is None or ts < self.oldest):
                    self.oldest = ts
            self.next_token = data.get("nextPageToken")
            if not self.next_token:
                self.exhausted = True


def _aux_for(channel_id: str, prefix: str) -> _AuxPlaylist:
    key = (channel_id, prefix)
    entry = _aux_cache.get(key)
    if entry is not None and time.time() - entry[0] < CACHE_TTL_SECONDS:
        return entry[1]
    aux = _AuxPlaylist(_aux_playlist_id(channel_id, prefix))
    _aux_cache[key] = (time.time(), aux)
    return aux


_ISO8601_DURATION_RE = re.compile(
    r"P(?:(?P<days>\d+)D)?T?(?:(?P<hours>\d+)H)?(?:(?P<minutes>\d+)M)?(?:(?P<seconds>\d+)S)?"
)


def _parse_iso8601_duration(value: str | None) -> int | None:
    """Convert an ISO-8601 duration (e.g. 'PT1M30S') to whole seconds."""
    if not value:
        return None
    m = _ISO8601_DURATION_RE.fullmatch(value)
    if not m:
        return None
    parts = {k: int(v) if v else 0 for k, v in m.groupdict().items()}
    return parts["days"] * 86400 + parts["hours"] * 3600 + parts["minutes"] * 60 + parts["seconds"]


async def _filter_playable(
    client: httpx.AsyncClient,
    videos: list[dict],
    shorts_ids: set[str] | None = None,
    members_ids: set[str] | None = None,
) -> list[dict]:
    """Drop Shorts and private/deleted videos; attach duration, live status, members flag.

    A batched `videos.list` (1 quota unit) returns `contentDetails.duration` and
    `snippet.liveBroadcastContent` for every accessible video. Videos missing
    from the response are private or deleted and are dropped.

    Shorts: `shorts_ids` (from the channel's UUSH playlist) is authoritative.
    When it is None (playlist unreadable) fall back to a length threshold.

    Members-only videos (`members_ids`, from UUMO) are kept but flagged
    `members_only` so the client can collapse them.

    A zero duration is *not* a Short: live streams, upcoming videos, and
    premieres report `P0D`. Those stay in the payload (with `duration` and
    `live_broadcast` set) so the client can collapse them.
    """
    if shorts_ids is not None:
        videos = [v for v in videos if v.get("video_id") not in shorts_ids]
    ids = [v["video_id"] for v in videos if v.get("video_id")]
    if not ids:
        return videos

    extras: dict[str, dict] = {}
    for start in range(0, len(ids), 50):
        chunk = ids[start : start + 50]
        data = await _get(
            client,
            "videos",
            {"part": "contentDetails,snippet", "id": ",".join(chunk)},
        )
        for item in data.get("items", []):
            extras[item["id"]] = {
                "duration": _parse_iso8601_duration(
                    item.get("contentDetails", {}).get("duration")
                ),
                "live_broadcast": item.get("snippet", {}).get("liveBroadcastContent")
                or "none",
            }

    members_ids = members_ids or set()
    result: list[dict] = []
    for v in videos:
        vid = v.get("video_id")
        if vid not in extras:
            continue  # private / deleted -> not accessible
        info = extras[vid]
        secs = info["duration"]
        if shorts_ids is None and secs is not None and 0 < secs <= _SHORTS_MAX_SECONDS:
            continue  # fallback Short heuristic (0 = live/upcoming, not a Short)
        result.append(
            {
                **v,
                "duration": secs,
                "live_broadcast": info["live_broadcast"],
                "members_only": vid in members_ids,
            }
        )
    return result


async def fetch_channel_page(channel_id: str, page_token: str | None = None) -> dict:
    """Fetch one page (up to MAX_RESULTS uploads, before filtering) of a channel.

    Returns `{"videos": [...], "next_page_token": str | None}`. Each video is a
    dict: video_id, title, published_at, thumbnail_url, channel_name, duration,
    live_broadcast, members_only. Shorts are dropped. Raises YouTubeApiError on
    misconfiguration or API failure.
    """
    cached = get_cached(channel_id, page_token)
    if cached is not None:
        return cached

    async with httpx.AsyncClient(timeout=15.0) as client:
        uploads_id = await _uploads_playlist_id(client, channel_id)
        params = {
            "part": "snippet",
            "playlistId": uploads_id,
            "maxResults": MAX_RESULTS,
        }
        if page_token:
            params["pageToken"] = page_token
        data = await _get(client, "playlistItems", params)

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

        # Oldest upload on this page: the system playlists must be read at
        # least that far back to classify every video here.
        stamps = [t for t in (_epoch(v["published_at"]) for v in videos) if t]
        cutoff = min(stamps) if stamps else None

        shorts = _aux_for(channel_id, SHORTS_PREFIX)
        members = _aux_for(channel_id, MEMBERS_PREFIX)
        await shorts.ensure(client, cutoff)
        await members.ensure(client, cutoff)

        videos = await _filter_playable(
            client,
            videos,
            shorts_ids=None if shorts.failed else shorts.ids,
            members_ids=members.ids,
        )

    page = {"videos": videos, "next_page_token": data.get("nextPageToken")}
    _page_cache[(channel_id, page_token or "")] = (time.time(), page)
    return page


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
