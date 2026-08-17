"""yt-dlp download logic with progress tracking."""

from __future__ import annotations

import asyncio
import importlib
import logging
import os
import re
import sys
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

# Languages we ask yt-dlp to fetch.
_SUBTITLE_LANGS = ["zh", "zh-Hant", "zh-Hans", "zh-TW", "zh-HK", "zh-CN", "en"]

# Subtitle selection priority. Traditional variants are used as-is; the
# "convertible" group (Simplified, or a bare/ambiguous "zh") is converted to
# Traditional with chinese-converter; English is the last-resort fallback.
_SUB_TRADITIONAL = ["zh-Hant", "zh-TW", "zh-HK"]
_SUB_CONVERTIBLE = ["zh-Hans", "zh-CN", "zh"]
_SUB_FALLBACK = ["en"]


def _find_subtitle(youtube_id: str, langs: list[str]) -> tuple[str, Path] | None:
    """Return (lang, path) of the first subtitle file present for these langs."""
    for lang in langs:
        candidate = AUDIO_DIR / f"{youtube_id}.{lang}.vtt"
        if candidate.exists():
            return lang, candidate
    return None


def _convert_subtitle_to_traditional(path: Path) -> None:
    """Convert a Simplified/ambiguous Chinese .vtt to Traditional in place.

    WebVTT timestamps and cue settings are ASCII, so converting the whole file
    only affects the Chinese text. Failures are swallowed: a Simplified subtitle
    is better than none.
    """
    try:
        import chinese_converter
    except ImportError:
        # Loud, not silent: a missing dependency is why "繁體化" silently fails.
        logger.error(
            "chinese-converter is not installed; subtitle %s kept Simplified. "
            "Install it (it is in requirements.txt) and rebuild the image.",
            path.name,
        )
        return

    try:
        text = path.read_text(encoding="utf-8")
        path.write_text(chinese_converter.to_traditional(text), encoding="utf-8")
        logger.info("Converted subtitle to Traditional Chinese: %s", path.name)
    except Exception:
        logger.exception("Subtitle s2t conversion failed for %s (kept original)", path.name)


def _select_subtitle(youtube_id: str) -> str | None:
    """Pick the best subtitle file, converting Simplified/ambiguous to Traditional.

    Preference order: existing Traditional -> convert Simplified/"zh" -> English.
    """
    found = _find_subtitle(youtube_id, _SUB_TRADITIONAL)
    if found:
        return str(found[1])

    found = _find_subtitle(youtube_id, _SUB_CONVERTIBLE)
    if found:
        _convert_subtitle_to_traditional(found[1])
        return str(found[1])

    found = _find_subtitle(youtube_id, _SUB_FALLBACK)
    if found:
        return str(found[1])

    return None

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
# yt-dlp self-update
# ---------------------------------------------------------------------------

# Refreshed together: yt-dlp plus the bundled JS challenge solver it needs.
_UPGRADE_PACKAGES = ["yt-dlp", "yt-dlp-ejs"]

# pip over the network; generous but bounded so a hung index can't wedge a worker.
_UPGRADE_TIMEOUT_SECONDS = 300

# Serializes upgrades so two callers can't pip-install over each other.
_upgrade_lock = asyncio.Lock()

# Statuses that mean a download is still using the currently-loaded yt-dlp.
_IN_FLIGHT_STATUSES = ("pending", "downloading", "converting")


def yt_dlp_version() -> str:
    """Version of the yt-dlp actually loaded in this process."""
    return yt_dlp.version.__version__


def downloads_in_flight() -> bool:
    return any(tp.status in _IN_FLIGHT_STATUSES for tp in progress_store.values())


async def _pip_upgrade() -> str:
    """Run pip to upgrade the yt-dlp packages; return its combined output.

    Raises RuntimeError if pip fails or takes longer than
    `_UPGRADE_TIMEOUT_SECONDS`. Split out from `upgrade_yt_dlp` so tests can
    stub the network/pip half.
    """
    proc = await asyncio.create_subprocess_exec(
        sys.executable, "-m", "pip", "install", "--no-cache-dir", "--upgrade",
        *_UPGRADE_PACKAGES,
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    try:
        raw, _ = await asyncio.wait_for(
            proc.communicate(), timeout=_UPGRADE_TIMEOUT_SECONDS
        )
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError(
            f"pip install timed out after {_UPGRADE_TIMEOUT_SECONDS}s"
        ) from None

    output = raw.decode(errors="replace").strip()
    if proc.returncode != 0:
        raise RuntimeError(
            f"pip install failed (exit {proc.returncode}): {output[-1000:]}"
        )
    return output


def _reload_yt_dlp() -> str:
    """Re-import yt_dlp in place so an upgrade applies without a restart.

    Every `yt_dlp*` entry is dropped from `sys.modules` and the package imported
    again, then this module's global `yt_dlp` is rebound. Callers must only do
    this while no download is running: an in-flight `_sync_download` holds the
    old module objects and could still lazy-import a submodule from under it.
    """
    global yt_dlp
    for name in [n for n in sys.modules if n == "yt_dlp" or n.startswith("yt_dlp.")]:
        del sys.modules[name]
    yt_dlp = importlib.import_module("yt_dlp")
    return yt_dlp.version.__version__


async def upgrade_yt_dlp() -> dict[str, Any]:
    """Upgrade yt-dlp to the latest release and load it into this process.

    YouTube breaks stale yt-dlp builds every few months, so this exists to fix
    downloads without rebuilding or restarting the container. Reloading is
    skipped while a download is in flight — the new version is on disk and takes
    effect on the next restart, reported as `restart_required`.
    """
    async with _upgrade_lock:
        before = yt_dlp_version()
        output = await _pip_upgrade()

        if downloads_in_flight():
            after, reloaded = before, False
            logger.info("yt-dlp upgraded on disk; reload deferred (download in flight)")
        else:
            after, reloaded = _reload_yt_dlp(), True
            logger.info("yt-dlp reloaded: %s -> %s", before, after)

        return {
            "previous_version": before,
            "current_version": after,
            "updated": after != before,
            "reloaded": reloaded,
            # pip pulled a new build but we couldn't swap it in yet.
            "restart_required": not reloaded and "Successfully installed" in output,
            "pip_output": output[-2000:],
        }


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
        # Use bun to solve YouTube's JS challenges (solver bundled via yt-dlp-ejs).
        "js_runtimes": {"bun": {}},
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
        "js_runtimes": {"bun": {}},
    }
    try:
        with yt_dlp.YoutubeDL(subtitle_opts) as ydl_sub:
            ydl_sub.extract_info(
                f"https://www.youtube.com/watch?v={youtube_id}", download=True
            )
    except Exception:
        logger.debug("Subtitle download failed for %s (ignored)", youtube_id)

    # Pick the best subtitle (Traditional as-is, Simplified/"zh" -> Traditional,
    # English as last resort).
    subtitle_path: str | None = _select_subtitle(youtube_id)

    return {
        "title": info.get("title"),
        "channel_name": info.get("channel") or info.get("uploader"),
        "channel_id": info.get("channel_id") or info.get("uploader_id"),
        "duration": info.get("duration"),
        "thumbnail_url": info.get("thumbnail"),
        "mp3_path": str(mp3_path),
        "file_size": file_size,
        "subtitle_path": subtitle_path,
    }


# ---------------------------------------------------------------------------
# Metadata-only extraction (no audio download)
# ---------------------------------------------------------------------------

def _sync_metadata(youtube_id: str) -> dict[str, Any]:
    """Quick metadata extraction with no media download (runs in a thread)."""
    ydl_opts: dict[str, Any] = {
        "skip_download": True,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "js_runtimes": {"bun": {}},
    }
    with yt_dlp.YoutubeDL(ydl_opts) as ydl:
        info = ydl.extract_info(
            f"https://www.youtube.com/watch?v={youtube_id}", download=False
        )
    return {
        "title": info.get("title"),
        "channel_name": info.get("channel") or info.get("uploader"),
        "channel_id": info.get("channel_id") or info.get("uploader_id"),
        "duration": info.get("duration"),
        "thumbnail_url": info.get("thumbnail"),
    }


async def fetch_metadata(youtube_id: str) -> dict[str, Any]:
    """Extract title/channel/duration/thumbnail and save the thumbnail to disk.

    Returns the metadata dict plus `thumbnail_path` (None if the thumbnail
    couldn't be fetched). Lets the client show a title + thumbnail before the
    (slower) audio download even starts.
    """
    result = await asyncio.to_thread(_sync_metadata, youtube_id)

    thumb_path: str | None = None
    if result.get("thumbnail_url"):
        dest = THUMB_DIR / f"{youtube_id}.jpg"
        await _download_thumbnail(result["thumbnail_url"], dest)
        if dest.exists():
            thumb_path = str(dest)
    result["thumbnail_path"] = thumb_path
    return result


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
                row.channel_id = result.get("channel_id")
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
