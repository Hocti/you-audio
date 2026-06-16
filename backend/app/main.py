"""FastAPI application -- YouTube audio downloader."""

from __future__ import annotations

import asyncio
import logging
import os
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, Header, HTTPException, Request
from fastapi.middleware.cors import CORSMiddleware
from fastapi.responses import FileResponse
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import engine, get_session
from .downloader import (
    AUDIO_DIR,
    THUMB_DIR,
    TaskProgress,
    extract_video_id,
    get_progress,
    progress_store,
    run_download,
)
from .models import Base, Video
from .schemas import (
    ChannelResolveResponse,
    ChannelVideoOut,
    ChannelVideosResponse,
    DownloadRequest,
    DownloadResponse,
    ProgressResponse,
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

_ACCESS_TOKEN = os.getenv("ACCESS_TOKEN", "")


async def _verify_token(x_access_token: str | None = Header(default=None)) -> None:
    if _ACCESS_TOKEN and x_access_token != _ACCESS_TOKEN:
        raise HTTPException(status_code=401, detail="Invalid access token")


# ---------------------------------------------------------------------------
# Lifespan: create tables on startup
# ---------------------------------------------------------------------------

@asynccontextmanager
async def lifespan(app: FastAPI):
    async with engine.begin() as conn:
        await conn.run_sync(Base.metadata.create_all)
    logger.info("Database tables ensured.")
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
    session: AsyncSession = Depends(get_session),
    _: None = Depends(_verify_token),
):
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
        return DownloadResponse(cached=True, task_id=task_id, video=VideoOut.model_validate(existing))

    # If there's already a pending/downloading/converting row, return that
    if existing and existing.status in ("pending", "downloading", "converting"):
        task_id = str(existing.id)
        tp = progress_store.get(task_id)
        if tp is None:
            tp = TaskProgress(status=existing.status, progress_percent=0.0, message="In progress")
            progress_store[task_id] = tp
        return DownloadResponse(cached=False, task_id=task_id, video=VideoOut.model_validate(existing))

    # If previous attempt errored, reuse the row; otherwise create new
    if existing and existing.status == "error":
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

    return DownloadResponse(cached=False, task_id=task_id, video=VideoOut.model_validate(video_row))


# ---------------------------------------------------------------------------
# GET /api/progress/{task_id}
# ---------------------------------------------------------------------------

@app.get("/api/progress/{task_id}", response_model=ProgressResponse)
async def get_task_progress(task_id: str, _: None = Depends(_verify_token)):
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
    _: None = Depends(_verify_token),
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
# GET /api/thumbnail/{video_id}
# ---------------------------------------------------------------------------

@app.get("/api/thumbnail/{video_id}")
async def serve_thumbnail(
    video_id: str,
    session: AsyncSession = Depends(get_session),
    _: None = Depends(_verify_token),
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
    _: None = Depends(_verify_token),
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
    _: None = Depends(_verify_token),
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
    _: None = Depends(_verify_token),
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
async def resolve_channel_route(q: str, _: None = Depends(_verify_token)):
    try:
        result = await resolve_channel(q)
    except YouTubeApiError as exc:
        raise HTTPException(status_code=exc.status_code, detail=exc.detail)
    return ChannelResolveResponse(**result)


# ---------------------------------------------------------------------------
# GET /api/channel/{channel_id}/videos
# ---------------------------------------------------------------------------

@app.get("/api/channel/{channel_id}/videos", response_model=ChannelVideosResponse)
async def channel_videos(channel_id: str, _: None = Depends(_verify_token)):
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
# Health check
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health():
    return {"status": "ok"}
