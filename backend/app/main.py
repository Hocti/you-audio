"""FastAPI application -- YouTube audio downloader."""

from __future__ import annotations

import asyncio
import logging
import os
import uuid
from contextlib import asynccontextmanager
from pathlib import Path

from fastapi import Depends, FastAPI, HTTPException, Request
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
    DownloadRequest,
    DownloadResponse,
    ProgressResponse,
    VideoListResponse,
    VideoOut,
)

logging.basicConfig(level=logging.INFO)
logger = logging.getLogger(__name__)


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
async def download(body: DownloadRequest, session: AsyncSession = Depends(get_session)):
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
async def get_task_progress(task_id: str):
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
async def serve_audio(video_id: str, session: AsyncSession = Depends(get_session)):
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
async def serve_thumbnail(video_id: str, session: AsyncSession = Depends(get_session)):
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
async def list_videos(session: AsyncSession = Depends(get_session)):
    stmt = select(Video).order_by(Video.created_at.desc())
    rows = (await session.execute(stmt)).scalars().all()
    return VideoListResponse(
        videos=[VideoOut.model_validate(r) for r in rows],
        total=len(rows),
    )


# ---------------------------------------------------------------------------
# Health check
# ---------------------------------------------------------------------------

@app.get("/api/health")
async def health():
    return {"status": "ok"}
