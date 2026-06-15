from __future__ import annotations

import datetime
import uuid

from pydantic import BaseModel, HttpUrl


# --- request ---
class DownloadRequest(BaseModel):
    url: str


# --- response ---
class VideoOut(BaseModel):
    id: uuid.UUID
    youtube_id: str
    title: str | None = None
    channel_name: str | None = None
    duration: int | None = None
    thumbnail_url: str | None = None
    mp3_path: str | None = None
    file_size: int | None = None
    status: str
    error_message: str | None = None
    created_at: datetime.datetime

    model_config = {"from_attributes": True}


class DownloadResponse(BaseModel):
    cached: bool
    task_id: str
    video: VideoOut


class ProgressResponse(BaseModel):
    task_id: str
    status: str  # pending / downloading / converting / done / error
    progress_percent: float
    message: str


class VideoListResponse(BaseModel):
    videos: list[VideoOut]
    total: int
