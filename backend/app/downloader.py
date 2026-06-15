"""yt-dlp download logic with progress tracking."""

from __future__ import annotations

import asyncio
import logging
import os
import re
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import yt_dlp
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from .database import async_session
from .models import Video

logger = logging.getLogger(__name__)

_SUBTITLE_LANGS = ["zh", "zh-Hant", "zh-Hans", "zh-TW", "zh-HK", "zh-CN", "en"]

DATA_DIR = Path(os.getenv("DATA_DIR", "/data"))
AUDIO_DIR = DATA_DIR / "audio"
THUMB_DIR = DATA_DIR / "thumbnails"

AUDIO_DIR.mkdir(parents=True, exist_ok=True)
THUMB_DIR.mkdir(parents=True, exist_ok=True)


# ---------------------------------------------------------------------------
# In-memory progress store
# ---------------------------------------------------------------------------

@dataclass
class TaskProgress:
    status: str = "pending"
    progress_percent: float = 0.0
    message: str = "Queued"


# task_id -> TaskProgress
progress_store: dict[str, TaskProgress] = {}


def get_progress(task_id: str) -> TaskProgress | None:
    return progress_store.get(task_id)


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

_YT_RE = re.compile(
    r"(?:https?://)?(?:www\.|m\.|music\.)?(?:youtube\.com|youtu\.be)"
    r"(?:/(?:watch|embed|v|shorts))?(?:\?.*?v=|/)?"
    r"([A-Za-z0-9_-]{11})"
)


def extract_video_id(url: str) -> str | None:
    m = _YT_RE.search(url)
    return m.group(1) if m else None


async def _download_thumbnail(url: str, dest: Path) -> None:
    try:
        async with httpx.AsyncClient(follow_redirects=True, timeout=30) as client:
            resp = await client.get(url)
            resp.raise_for_status()
            dest.write_bytes(resp.content)
    except Exception:
        logger.exception("Failed to download thumbnail %s", url)


# ---------------------------------------------------------------------------
# Core download (runs in thread via asyncio.to_thread)
# ---------------------------------------------------------------------------

def _sync_download(youtube_id: str, task_id: str) -> dict[str, Any]:
    """Blocking download+conversion; meant to run inside asyncio.to_thread."""
    tp = progress_store[task_id]
    tp.status = "downloading"
    tp.message = "Extracting metadata..."
    tp.progress_percent = 0.0

    output_template = str(AUDIO_DIR / f"{youtube_id}.%(ext)s")

    def _progress_hook(d: dict[str, Any]) -> None:
        if d["status"] == "downloading":
            total = d.get("total_bytes") or d.get("total_bytes_estimate") or 0
            downloaded = d.get("downloaded_bytes", 0)
            if total > 0:
                pct = downloaded / total * 100
            else:
                pct = 0
            tp.progress_percent = min(round(pct, 1), 99.0)
            tp.message = f"Downloading: {tp.progress_percent}%"
            tp.status = "downloading"
        elif d["status"] == "finished":
            tp.status = "converting"
            tp.progress_percent = 95.0
            tp.message = "Converting to MP3..."

    def _postprocessor_hook(d: dict[str, Any]) -> None:
        if d.get("status") == "finished":
            tp.progress_percent = 99.0
            tp.message = "Post-processing done"

    ydl_opts: dict[str, Any] = {
        "format": "bestaudio/best",
        "outtmpl": output_template,
        "postprocessors": [
            {
                "key": "FFmpegExtractAudio",
                "preferredcodec": "mp3",
                "preferredquality": "192",
            }
        ],
        "progress_hooks": [_progress_hook],
        "postprocessor_hooks": [_postprocessor_hook],
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "overwrites": True,
    }

    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(
            f"https://www.youtube.com/watch?v={youtube_id}", download=True
        )

    mp3_path = AUDIO_DIR / f"{youtube_id}.mp3"
    file_size = mp3_path.stat().st_size if mp3_path.exists() else None

    # Subtitle download in a separate call so failures don't abort the main job
    subtitle_opts: dict[str, Any] = {
        "skip_download": True,
        "writesubtitles": True,
        "writeautomaticsub": True,
        "subtitleslangs": _SUBTITLE_LANGS,
        "subtitlesformat": "vtt",
        "outtmpl": output_template,
        "ignoreerrors": True,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
    }
    try:
        with yt_dlp.YoutubeDL(subtitle_opts) as ydl_sub:
            ydl_sub.extract_info(
                f"https://www.youtube.com/watch?v={youtube_id}", download=True
            )
    except Exception:
        logger.debug("Subtitle download failed for %s (ignored)", youtube_id)

    # Find subtitle file (prefer Chinese, fallback to English)
    subtitle_path: str | None = None
    for lang in _SUBTITLE_LANGS:
        candidate = AUDIO_DIR / f"{youtube_id}.{lang}.vtt"
        if candidate.exists():
            subtitle_path = str(candidate)
            break

    return {
        "title": info.get("title"),
        "channel_name": info.get("channel") or info.get("uploader"),
        "duration": info.get("duration"),
        "thumbnail_url": info.get("thumbnail"),
        "mp3_path": str(mp3_path),
        "file_size": file_size,
        "subtitle_path": subtitle_path,
    }


# ---------------------------------------------------------------------------
# Async entry-point
# ---------------------------------------------------------------------------

async def run_download(youtube_id: str, task_id: str, video_db_id: uuid.UUID) -> None:
    """Start the full download pipeline. Updates DB row when done."""
    tp = progress_store.setdefault(task_id, TaskProgress())

    try:
        result = await asyncio.to_thread(_sync_download, youtube_id, task_id)

        # Download thumbnail
        thumb_path: str | None = None
        if result.get("thumbnail_url"):
            dest = THUMB_DIR / f"{youtube_id}.jpg"
            await _download_thumbnail(result["thumbnail_url"], dest)
            if dest.exists():
                thumb_path = str(dest)

        # Persist to DB
        async with async_session() as session:
            async with session.begin():
                stmt = select(Video).where(Video.id == video_db_id)
                row = (await session.execute(stmt)).scalar_one()
                row.title = result["title"]
                row.channel_name = result["channel_name"]
                row.duration = result["duration"]
                row.thumbnail_url = result["thumbnail_url"]
                row.thumbnail_path = thumb_path
                row.subtitle_path = result.get("subtitle_path")
                row.mp3_path = result["mp3_path"]
                row.file_size = result["file_size"]
                row.status = "done"

        tp.status = "done"
        tp.progress_percent = 100.0
        tp.message = "Complete"
        logger.info("Download complete for %s", youtube_id)

    except Exception as exc:
        logger.exception("Download failed for %s", youtube_id)
        tp.status = "error"
        tp.message = str(exc)[:500]

        try:
            async with async_session() as session:
                async with session.begin():
                    stmt = select(Video).where(Video.id == video_db_id)
                    row = (await session.execute(stmt)).scalar_one()
                    row.status = "error"
                    row.error_message = str(exc)[:1000]
        except Exception:
            logger.exception("Failed to update error status in DB")
