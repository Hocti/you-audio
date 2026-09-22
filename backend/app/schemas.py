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
    channel_id: str | None = None
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
    channel_id: str | None = None
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
    duration: int | None = None  # seconds; 0 = live / upcoming / premiere
    live_broadcast: str | None = None  # none | upcoming | live


class ChannelVideosResponse(BaseModel):
    channel_id: str
    cached: bool
    total: int
    videos: list[ChannelVideoOut]


class ChannelResolveResponse(BaseModel):
    channel_id: str
    channel_name: str | None = None


# --- users ---
class UserOut(BaseModel):
    id: int
    username: str
    token: str
    is_admin: bool
    created_at: datetime.datetime

    model_config = {"from_attributes": True}


class UserCreate(BaseModel):
    username: str
    token: str | None = None


class UserUpdate(BaseModel):
    username: str | None = None
    token: str | None = None


class UserListResponse(BaseModel):
    users: list[UserOut]
    total: int
