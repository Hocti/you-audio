"""FastAPI application -- YouTube audio downloader."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import secrets
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request, Response
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse, StreamingResponse
from sqlalchemy import inspect as sa_inspect, select
from sqlalchemy.ext.asyncio import AsyncSession
from yt_dlp.utils import DownloadError

from .database import async_session, engine, get_session
from .downloader import (
    AUDIO_DIR,
    THUMB_DIR,
    TaskProgress,
    extract_video_id,
    fetch_metadata,
    get_progress,
    progress_store,
    run_download,
    upgrade_yt_dlp,
    yt_dlp_version,
)
from .models import Base, RequestLog, User, Video
from .schemas import (
    ChannelResolveResponse,
    ChannelVideoOut,
    ChannelVideosResponse,
    DownloadRequest,
    DownloadResponse,
    MetadataResponse,
    ProgressResponse,
    UserCreate,
    UserListResponse,
    UserOut,
    UserUpdate,
    VideoListResponse,
    VideoOut,
)
from .youtube_api import (
    YouTubeApiError,
    fetch_latest_videos,
    get_cached,
    resolve_channel,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)

# ---------------------------------------------------------------------------
# Auth: every request is identified by its access token -> User
# ---------------------------------------------------------------------------

async def _user_for_token(session: AsyncSession, token: str | None) -> User | None:
    if not token:
        return None
    stmt = select(User).where(User.token == token)
    return (await session.execute(stmt)).scalar_one_or_none()


async def get_current_user(
    x_access_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
) -> User:
    """Resolve the caller from their X-Access-Token header (401 if unknown)."""
    user = await _user_for_token(session, x_access_token)
    if user is None:
        raise HTTPException(status_code=401, detail="Invalid or missing access token")
    return user


async def require_admin(user: User = Depends(get_current_user)) -> User:
    if not user.is_admin:
        raise HTTPException(status_code=403, detail="Admin privileges required")
    return user


async def ensure_admin() -> None:
    """Make the `admin` user match ACCESS_TOKEN (idempotent, runs every start).

    ACCESS_TOKEN is **authoritative when set**: a missing admin is created with
    it, and an existing admin whose token differs is updated to it. That is the
    only way to recover a deployment whose admin token is unknown — the old
    "never overwrite an existing admin" rule meant a container that booted once
    without ACCESS_TOKEN was stuck on a random token forever, locking the app
    out with no fix short of editing the database by hand.

    With ACCESS_TOKEN empty, an existing admin is left alone and a missing one
    gets a random token, which is logged.
    """
    async with async_session() as session:
        stmt = select(User).where(User.username == "admin")
        admin: User | None = (await session.execute(stmt)).scalar_one_or_none()
        env_token = os.getenv("ACCESS_TOKEN", "")

        if admin is not None:
            if env_token and admin.token != env_token:
                # Guard against handing admin a token another user already owns.
                clash = await _user_for_token(session, env_token)
                if clash is not None and clash.id != admin.id:
                    logger.error(
                        "ACCESS_TOKEN is already used by user %r; admin token "
                        "left unchanged.",
                        clash.username,
                    )
                    return
                admin.token = env_token
                await session.commit()
                logger.warning("Updated the admin token from ACCESS_TOKEN.")
            return

        token = env_token or secrets.token_urlsafe(24)
        session.add(User(username="admin", token=token, is_admin=True))
        await session.commit()
        if env_token:
            logger.info("Seeded default admin user from ACCESS_TOKEN.")
        else:
            logger.warning(
                "Seeded default admin user with generated token: %s "
                "(set ACCESS_TOKEN to control it)",
                token,
            )


# ---------------------------------------------------------------------------
# Request logging (expensive operations only)
# ---------------------------------------------------------------------------

@asynccontextmanager
async def log_operation(user: User, request: Request, argument: str | None):
    """Record an expensive operation in the `requests` table.

    Captures the final HTTP status (including failures) and writes via a fresh
    session so logging can never interfere with the request or be lost on error.
    """
    status_code = 200
    try:
        yield
    except HTTPException as exc:
        status_code = exc.status_code
        raise
    except Exception:
        status_code = 500
        raise
    finally:
        try:
            async with async_session() as session:
                session.add(
                    RequestLog(
                        user_id=user.id,
                        method=request.method,
                        path=request.url.path,
                        argument=argument,
                        status_code=status_code,
                    )
                )
                await session.commit()
        except Exception:
            logger.exception("Failed to write request log")


# ---------------------------------------------------------------------------
# Additive column migration
# ---------------------------------------------------------------------------

# Columns added to already-shipped tables. `create_all` only creates missing
# *tables*, so a database from an earlier release keeps its old `videos` shape
# and every query selecting a newer column dies with "no such column:
# videos.channel_id" — a 500 on /api/videos right after an upgrade. These are
# applied on every start: additive, idempotent, and valid on SQLite and
# PostgreSQL alike (`ADD COLUMN <name> TEXT`, nullable, no default).
_ADDED_COLUMNS: dict[str, dict[str, str]] = {
    "videos": {"channel_id": "TEXT"},
}


async def ensure_columns() -> None:
    """Add any missing column from `_ADDED_COLUMNS` to an existing database."""
    async with engine.begin() as conn:
        for table, columns in _ADDED_COLUMNS.items():
            present = await conn.run_sync(
                lambda sync_conn, t=table: {
                    col["name"] for col in sa_inspect(sync_conn).get_columns(t)
                }
            )
            for name, column_type in columns.items():
                if name in present:
                    continue
                await conn.exec_driver_sql(
                    f"ALTER TABLE {table} ADD COLUMN {name} {column_type}"
                )
                logger.warning("Added missing column %s.%s", table, name)


# ---------------------------------------------------------------------------
# Lifespan: create tables + migrate + seed admin on startup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("Database tables ensured.")
    await ensure_columns()
    await ensure_admin()
    yield


# ---------------------------------------------------------------------------
# App
# ---------------------------------------------------------------------------

app = FastAPI(
    title="YouTube Audio Downloader",
    version="1.0.0",
    lifespan=lifespan,
)

app.add_middleware(
    CORSMiddleware,
    allow_origins=["*"],
    allow_credentials=True,
    allow_methods=["*"],
    allow_headers=["*"],
)


# ---------------------------------------------------------------------------
# POST /api/download
# ---------------------------------------------------------------------------

@app.post("/api/download", response_model=DownloadResponse)
async def download(
    body: DownloadRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
):
    async with log_operation(user, request, body.url):
        video_id = extract_video_id(body.url)
        if not video_id:
            raise HTTPException(status_code=400, detail="Invalid YouTube URL")

        # Check cache
        stmt = select(Video).where(Video.youtube_id == video_id)
        existing: Video | None = (await session.execute(stmt)).scalar_one_or_none()

        if existing and existing.status == "done":
            task_id = str(existing.id)
            progress_store[task_id] = TaskProgress(
                status="done", progress_percent=100.0, message="Cached"
            )
            return DownloadResponse(
                cached=True, task_id=task_id, video=VideoOut.model_validate(existing)
            )

        # Attach to a download that is *really* running, so two clients asking
        # for the same video share one job.
        #
        # A non-terminal row is not proof of that. `/api/metadata` creates the
        # row as `pending` before any download starts, and a process restart
        # empties the in-memory `progress_store` while rows keep their status.
        # Treating those as in-flight returned a task id that nothing would ever
        # report on: the client polled `/api/progress` forever and sat at 0%,
        # with the video permanently un-downloadable. `progress_store` is the
        # only honest signal that a task exists.
        if (
            existing
            and existing.status in ("pending", "downloading", "converting")
            and progress_store.get(str(existing.id)) is not None
        ):
            return DownloadResponse(
                cached=False,
                task_id=str(existing.id),
                video=VideoOut.model_validate(existing),
            )

        # Reuse whatever row is there — metadata-only, errored, or abandoned by a
        # restart — and take it back to `pending` for this attempt.
        if existing:
            existing.status = "pending"
            existing.error_message = None
            await session.commit()
            await session.refresh(existing)
            video_row = existing
        else:
            video_row = Video(youtube_id=video_id, status="pending")
            session.add(video_row)
            await session.commit()
            await session.refresh(video_row)

        task_id = str(video_row.id)
        progress_store[task_id] = TaskProgress()

        # Fire-and-forget background task
        asyncio.create_task(run_download(video_id, task_id, video_row.id))

        return DownloadResponse(
            cached=False, task_id=task_id, video=VideoOut.model_validate(video_row)
        )


# ---------------------------------------------------------------------------
# POST /api/metadata  (quick title/channel/duration/thumbnail, no audio)
# ---------------------------------------------------------------------------

_ANSI_RE = re.compile(r"\x1b\[[0-9;]*m")


def _clean_yt_dlp_error(exc: Exception) -> str:
    """Strip yt-dlp's ANSI colour codes and "ERROR: " prefix for API responses."""
    return _ANSI_RE.sub("", str(exc)).removeprefix("ERROR: ")


@app.post("/api/metadata", response_model=MetadataResponse)
async def metadata(
    body: DownloadRequest,
    request: Request,
    session: AsyncSession = Depends(get_session),
    user: User = Depends(get_current_user),
):
    """Fetch metadata + thumbnail up front so the client can show a title/art
    before the audio download begins. Upserts a `pending` DB row (leaving any
    existing `done` row untouched) and saves the thumbnail to disk so
    `/api/thumbnail/{id}` works immediately."""
    async with log_operation(user, request, body.url):
        video_id = extract_video_id(body.url)
        if not video_id:
            raise HTTPException(status_code=400, detail="Invalid YouTube URL")

        try:
            meta = await fetch_metadata(video_id)
        except DownloadError as exc:
            # yt-dlp raised a *definitive* answer about this video (unavailable,
            # private, removed, geo-blocked, ...) — a client-facing 4xx, not a
            # 502. 502 is reserved below for genuine backend/yt-dlp failures
            # (network blips, extractor breakage) where the video itself may be
            # fine.
            raise HTTPException(status_code=404, detail=_clean_yt_dlp_error(exc))
        except Exception as exc:
            raise HTTPException(status_code=502, detail=f"Metadata fetch failed: {exc}")

        stmt = select(Video).where(Video.youtube_id == video_id)
        existing: Video | None = (await session.execute(stmt)).scalar_one_or_none()

        if existing is None:
            existing = Video(youtube_id=video_id, status="pending")
            session.add(existing)

        # Don't clobber a finished download; only fill in display metadata.
        existing.title = meta.get("title") or existing.title
        existing.channel_name = meta.get("channel_name") or existing.channel_name
        existing.channel_id = meta.get("channel_id") or existing.channel_id
        existing.duration = meta.get("duration") or existing.duration
        existing.thumbnail_url = meta.get("thumbnail_url") or existing.thumbnail_url
        if meta.get("thumbnail_path"):
            existing.thumbnail_path = meta["thumbnail_path"]
        await session.commit()

        return MetadataResponse(
            youtube_id=video_id,
            title=meta.get("title"),
            channel_name=meta.get("channel_name"),
            channel_id=meta.get("channel_id"),
            duration=meta.get("duration"),
            thumbnail_url=meta.get("thumbnail_url"),
            has_thumbnail=bool(meta.get("thumbnail_path")),
        )


# ---------------------------------------------------------------------------
# GET /api/progress/{task_id}
# ---------------------------------------------------------------------------

@app.get("/api/progress/{task_id}", response_model=ProgressResponse)
async def get_task_progress(task_id: str, _: User = Depends(get_current_user)):
    tp = get_progress(task_id)
    if tp is None:
        raise HTTPException(status_code=404, detail="Task not found")
    return ProgressResponse(
        task_id=task_id,
        status=tp.status,
        progress_percent=tp.progress_percent,
        message=tp.message,
    )


# ---------------------------------------------------------------------------
# GET /api/audio/{video_id}   (video_id = youtube_id)
# ---------------------------------------------------------------------------

@app.get("/api/audio/{video_id}")
async def serve_audio(
    video_id: str,
    session: AsyncSession = Depends(get_session),
    _: User = Depends(get_current_user),
):
    stmt = select(Video).where(Video.youtube_id == video_id, Video.status == "done")
    row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
    if not row or not row.mp3_path:
        raise HTTPException(status_code=404, detail="Audio not found")

    path = Path(row.mp3_path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Audio file missing from disk")

    return FileResponse(
        path=path,
        media_type="audio/mpeg",
        filename=f"{row.title or video_id}.mp3",
        headers={"Accept-Ranges": "bytes"},
    )


# ---------------------------------------------------------------------------
# GET /api/stream/{video_id}   (range-capable MP3 delivery)
# ---------------------------------------------------------------------------

# Bytes per chunk when streaming a range off disk.
_STREAM_CHUNK = 64 * 1024


def parse_byte_range(header: str | None, file_size: int) -> tuple[int, int] | None:
    """Parse a single-range `Range: bytes=…` header into inclusive (start, end).

    Returns None when there is no range to honour (absent/unparsable/multi-range
    header — the caller then serves the whole file, which is what RFC 9110 asks
    for). Raises `ValueError` when the range is syntactically fine but cannot be
    satisfied, so the caller can answer 416.
    """
    if not header:
        return None
    header = header.strip()
    if not header.startswith("bytes=") or "," in header:
        return None  # unsupported unit or multi-range: ignore, serve it all

    spec = header[len("bytes=") :].strip()
    start_text, _, end_text = spec.partition("-")
    if not _:
        return None

    # Parse the numbers first and keep it separate from deciding whether the
    # range is satisfiable — otherwise the `raise ValueError` below is caught by
    # this very `except` and reported as "no range" instead of a 416.
    try:
        suffix_length = int(end_text) if not start_text else None
        start = int(start_text) if start_text else 0
        end = int(end_text) if (start_text and end_text) else file_size - 1
    except ValueError:
        return None

    if suffix_length is not None:
        # `bytes=-500` = the final 500 bytes. A zero-length suffix asks for
        # nothing, which RFC 9110 makes unsatisfiable.
        if suffix_length <= 0:
            raise ValueError("unsatisfiable suffix range")
        start = max(file_size - suffix_length, 0)
        end = file_size - 1

    if start < 0 or start >= file_size or end < start:
        raise ValueError("range not satisfiable")
    return start, min(end, file_size - 1)


async def _file_chunks(path: Path, start: int, end: int):
    """Yield `path[start:end]` (inclusive) in bounded chunks."""
    remaining = end - start + 1
    with path.open("rb") as handle:
        handle.seek(start)
        while remaining > 0:
            chunk = handle.read(min(_STREAM_CHUNK, remaining))
            if not chunk:
                break
            remaining -= len(chunk)
            yield chunk


@app.get("/api/stream/{video_id}")
async def stream_audio(
    video_id: str,
    request: Request,
    session: AsyncSession = Depends(get_session),
    _: User = Depends(get_current_user),
):
    """Serve the MP3 with real HTTP range support, for the streaming player.

    Additive: `/api/audio/{video_id}` is untouched and still backs the
    download-to-device flow. It exists because that route returns a Starlette
    `FileResponse`, which **ignores** `Range` and answers 200 with the entire
    file while still advertising `Accept-Ranges: bytes`. A client that believes
    that header (just_audio's caching source does) asks for a range on seek,
    gets the whole file back, and plays it as if it started at the offset.
    """
    stmt = select(Video).where(Video.youtube_id == video_id, Video.status == "done")
    row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
    if not row or not row.mp3_path:
        raise HTTPException(status_code=404, detail="Audio not found")

    path = Path(row.mp3_path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Audio file missing from disk")

    file_size = path.stat().st_size
    try:
        byte_range = parse_byte_range(request.headers.get("range"), file_size)
    except ValueError:
        return Response(
            status_code=416,
            headers={
                "Content-Range": f"bytes */{file_size}",
                "Accept-Ranges": "bytes",
            },
        )

    if byte_range is None:
        start, end, status_code = 0, file_size - 1, 200
        headers = {
            "Accept-Ranges": "bytes",
            "Content-Length": str(file_size),
        }
    else:
        start, end = byte_range
        status_code = 206
        headers = {
            "Accept-Ranges": "bytes",
            "Content-Length": str(end - start + 1),
            "Content-Range": f"bytes {start}-{end}/{file_size}",
        }

    return StreamingResponse(
        _file_chunks(path, start, end),
        status_code=status_code,
        media_type="audio/mpeg",
        headers=headers,
    )


# ---------------------------------------------------------------------------
# GET /api/thumbnail/{video_id}
# ---------------------------------------------------------------------------

@app.get("/api/thumbnail/{video_id}")
async def serve_thumbnail(
    video_id: str,
    session: AsyncSession = Depends(get_session),
    _: User = Depends(get_current_user),
):
    stmt = select(Video).where(Video.youtube_id == video_id)
    row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
    if not row or not row.thumbnail_path:
        raise HTTPException(status_code=404, detail="Thumbnail not found")

    path = Path(row.thumbnail_path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Thumbnail file missing from disk")

    return FileResponse(path=path, media_type="image/jpeg")


# ---------------------------------------------------------------------------
# GET /api/videos
# ---------------------------------------------------------------------------

@app.get("/api/videos", response_model=VideoListResponse)
async def list_videos(
    session: AsyncSession = Depends(get_session),
    _: User = Depends(get_current_user),
):
    stmt = select(Video).order_by(Video.created_at.desc())
    rows = (await session.execute(stmt)).scalars().all()
    return VideoListResponse(
        videos=[VideoOut.model_validate(r) for r in rows],
        total=len(rows),
    )


# ---------------------------------------------------------------------------
# DELETE /api/videos/{youtube_id}
# ---------------------------------------------------------------------------

@app.delete("/api/videos/{youtube_id}", status_code=204)
async def delete_video(
    youtube_id: str,
    session: AsyncSession = Depends(get_session),
    _: User = Depends(get_current_user),
):
    stmt = select(Video).where(Video.youtube_id == youtube_id)
    row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
    if not row:
        raise HTTPException(status_code=404, detail="Video not found")

    # Collect paths before deleting the row
    paths_to_delete = [row.mp3_path, row.thumbnail_path, row.subtitle_path]

    await session.delete(row)
    await session.commit()

    for path_attr in paths_to_delete:
        if path_attr:
            p = Path(path_attr)
            if p.exists():
                p.unlink()


# ---------------------------------------------------------------------------
# GET /api/subtitles/{youtube_id}
# ---------------------------------------------------------------------------

@app.get("/api/subtitles/{youtube_id}")
async def serve_subtitles(
    youtube_id: str,
    session: AsyncSession = Depends(get_session),
    _: User = Depends(get_current_user),
):
    stmt = select(Video).where(Video.youtube_id == youtube_id)
    row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
    if not row or not row.subtitle_path:
        raise HTTPException(status_code=404, detail="Subtitles not found")

    path = Path(row.subtitle_path)
    if not path.exists():
        raise HTTPException(status_code=404, detail="Subtitle file missing from disk")

    return FileResponse(path=path, media_type="text/vtt")


# ---------------------------------------------------------------------------
# GET /api/channel/resolve?q=...  (URL / @handle / id -> channel id)
# ---------------------------------------------------------------------------

@app.get("/api/channel/resolve", response_model=ChannelResolveResponse)
async def resolve_channel_route(
    q: str,
    request: Request,
    user: User = Depends(get_current_user),
):
    async with log_operation(user, request, q):
        try:
            result = await resolve_channel(q)
        except YouTubeApiError as exc:
            raise HTTPException(status_code=exc.status_code, detail=exc.detail)
        return ChannelResolveResponse(**result)


# ---------------------------------------------------------------------------
# GET /api/channel/{channel_id}/videos
# ---------------------------------------------------------------------------

@app.get("/api/channel/{channel_id}/videos", response_model=ChannelVideosResponse)
async def channel_videos(
    channel_id: str,
    request: Request,
    user: User = Depends(get_current_user),
):
    async with log_operation(user, request, channel_id):
        cached = get_cached(channel_id) is not None
        try:
            videos = await fetch_latest_videos(channel_id)
        except YouTubeApiError as exc:
            raise HTTPException(status_code=exc.status_code, detail=exc.detail)

        return ChannelVideosResponse(
            channel_id=channel_id,
            cached=cached,
            total=len(videos),
            videos=[ChannelVideoOut(**v) for v in videos],
        )


# ---------------------------------------------------------------------------
# User management (admin only)
# ---------------------------------------------------------------------------

@app.get("/api/users", response_model=UserListResponse)
async def list_users(
    session: AsyncSession = Depends(get_session),
    _admin: User = Depends(require_admin),
):
    rows = (await session.execute(select(User).order_by(User.id))).scalars().all()
    return UserListResponse(
        users=[UserOut.model_validate(r) for r in rows], total=len(rows)
    )


@app.post("/api/users", response_model=UserOut, status_code=201)
async def create_user(
    body: UserCreate,
    session: AsyncSession = Depends(get_session),
    _admin: User = Depends(require_admin),
):
    token = body.token or secrets.token_urlsafe(24)
    if (await _user_for_token(session, token)) is not None:
        raise HTTPException(status_code=409, detail="Token already in use")
    dup_name = (
        await session.execute(select(User).where(User.username == body.username))
    ).scalar_one_or_none()
    if dup_name is not None:
        raise HTTPException(status_code=409, detail="Username already exists")

    user = User(username=body.username, token=token, is_admin=False)
    session.add(user)
    await session.commit()
    await session.refresh(user)
    return UserOut.model_validate(user)


@app.patch("/api/users/{user_id}", response_model=UserOut)
async def update_user(
    user_id: int,
    body: UserUpdate,
    session: AsyncSession = Depends(get_session),
    _admin: User = Depends(require_admin),
):
    user = (
        await session.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")

    if body.username is not None and body.username != user.username:
        if user.is_admin:
            raise HTTPException(status_code=400, detail="The admin user cannot be renamed")
        dup = (
            await session.execute(select(User).where(User.username == body.username))
        ).scalar_one_or_none()
        if dup is not None:
            raise HTTPException(status_code=409, detail="Username already exists")
        user.username = body.username

    if body.token is not None and body.token != user.token:
        if (await _user_for_token(session, body.token)) is not None:
            raise HTTPException(status_code=409, detail="Token already in use")
        user.token = body.token

    await session.commit()
    await session.refresh(user)
    return UserOut.model_validate(user)


@app.delete("/api/users/{user_id}", status_code=204)
async def delete_user(
    user_id: int,
    session: AsyncSession = Depends(get_session),
    _admin: User = Depends(require_admin),
):
    user = (
        await session.execute(select(User).where(User.id == user_id))
    ).scalar_one_or_none()
    if user is None:
        raise HTTPException(status_code=404, detail="User not found")
    if user.is_admin:
        raise HTTPException(status_code=400, detail="The admin user cannot be deleted")
    await session.delete(user)
    await session.commit()


# ---------------------------------------------------------------------------
# yt-dlp version / self-update
# ---------------------------------------------------------------------------

@app.get("/api/yt-dlp/version")
async def yt_dlp_version_route(_: User = Depends(get_current_user)):
    """Report the yt-dlp version this process is actually running."""
    return {"version": yt_dlp_version()}


@app.get("/api/yt-dlp/update")
async def yt_dlp_update_route(
    request: Request,
    user: User = Depends(require_admin),
):
    """Upgrade yt-dlp to the latest release and reload it (admin only).

    A GET (not a POST) on purpose: YouTube breaks stale yt-dlp builds every few
    months, and this is meant to be triggerable from a browser or a bookmark
    without rebuilding or restarting the container. `restart_required` is true
    when a new build was installed but a download in flight blocked the reload.
    """
    async with log_operation(user, request, "yt-dlp update"):
        try:
            return await upgrade_yt_dlp()
        except Exception as exc:
            logger.exception("yt-dlp upgrade failed")
            raise HTTPException(status_code=502, detail=str(exc))


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health(
    x_access_token: str | None = Header(default=None),
    session: AsyncSession = Depends(get_session),
):
    """Health + auth diagnostic.

    Always returns 200 (even with a wrong/missing token) so the app's Settings
    "Test" button can distinguish "server unreachable" from "token wrong".
    """
    valid = (await _user_for_token(session, x_access_token)) is not None
    return {
        "status": "ok",
        "token_required": True,
        "token_valid": valid,
    }
