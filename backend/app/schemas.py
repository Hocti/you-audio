from __future__ import annotations

import datetime
import uuid
from pathlib import Path

from pydantic import BaseModel, model_validator


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
    has_subtitle: bool = False
    subtitle_path: str | None = None
    mp3_path: str | None = None
    file_size: int | None = None
    status: str
    error_message: str | None = None
    created_at: datetime.datetime

    model_config = {"from_attributes": True}

    @model_validator(mode="after")
    def compute_has_subtitle(self) -> "VideoOut":
        if self.subtitle_path:
            self.has_subtitle = Path(self.subtitle_path).exists()
        return self


class DownloadResponse(BaseModel):
    cached: bool
    task_id: str
    video: VideoOut


class MetadataResponse(BaseModel):
    youtube_id: str
    title: str | None = None
    channel_name: str | None = None
    duration: int | None = None
    thumbnail_url: str | None = None
    has_thumbnail: bool = False


class ProgressResponse(BaseModel):
    task_id: str
    status: str  # pending / downloading / converting / done / error
    progress_percent: float
    message: str


class VideoListResponse(BaseModel):
    videos: list[VideoOut]
    total: int


# --- channel latest videos ---
class ChannelVideoOut(BaseModel):
    video_id: str
    title: str | None = None
    published_at: str | None = None
    thumbnail_url: str | None = None
    channel_name: str | None = None


class ChannelVideosResponse(BaseModel):
    channel_id: str
    cached: bool
    total: int
    videos: list[ChannelVideoOut]


class ChannelResolveResponse(BaseModel):
    channel_id: str
    channel_name: str | None = None
