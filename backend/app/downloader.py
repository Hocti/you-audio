"""yt-dlp download logic with progress tracking."""

from __future__ import annotations

import asyncio
import importlib
import logging
import os
import re
import sys
import time
import uuid
from dataclasses import dataclass, field
from pathlib import Path
from typing import Any

import httpx
import yt_dlp
from sqlalchemy import select
from sqlalchemy.ext.asyncio import AsyncSession

from . import ytdlp_update
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

# YouTube now requires a PO Token for most googlevideo.com media URLs, or the
# download 403s even though extraction succeeded (the URL is listed but not
# authorized). bgutil-ytdlp-pot-provider is a yt-dlp plugin (installed via
# requirements.txt) that fetches one from a small sidecar HTTP server — see
# docker-compose.yml's `pot-provider` service. POT_PROVIDER_URL points yt-dlp
# at it; the plugin's own default (127.0.0.1:4416) only works when both run on
# the same host, which isn't true across Docker Compose services.
#
# A PO token alone isn't enough, though: yt-dlp's default client mix (web,
# web_safari, android_vr, ...) lists adaptive audio-only formats from clients
# whose PO token is scoped differently (GVS-bound to a client that YouTube
# then serves SABR-only, no direct URL, or plain rejects with 403 even with a
# token attached — see https://github.com/yt-dlp/yt-dlp/issues/12482).
# `web_music` (music.youtube.com's client) was the one client, of the dozen
# tried against a real 403 during debugging, whose adaptive audio URLs are
# actually authorized to download once bgutil supplies its token. But
# web_music's own catalog is narrower than a regular video client's — it 404s
# ("Video unavailable") on videos a plain client extracts fine, e.g. the very
# first YouTube video (jNQXAC9IVRw) — so it can't be the *only* client tried.
# `android` is the fallback: no PO token needed, and yt-dlp tries clients in
# the order listed here, falling back to the next when one client's
# extraction fails outright (not just when its formats 403 on download,
# unfortunately — a per-video 403 from a listed format still aborts the
# whole request, which is why web_music has to be first: its formats are the
# ones that actually download). android's muxed format also downloads, just
# at ~96kbps AAC, worse than web_music's ~118kbps opus audio-only, and worse
# still it's muxed with a video track we throw away — acceptable as a
# fallback, not as the default. Revisit if `web_music` ever stops working —
# check with `yt-dlp -v` which client's formats actually download, not just
# which are listed (formats can be listed and still 403 on fetch).
#
# Deliberately NOT applied to `_sync_metadata`: that call never touches a
# media URL (skip_download), so it never hit the 403 this exists for, and
# forcing web_music there only adds its narrower-catalog 404s for no benefit
# — plain yt-dlp defaults (all clients) are strictly more permissive for
# metadata-only lookups.
_POT_EXTRACTOR_ARGS = {
    "youtubepot-bgutilhttp": {
        "base_url": [ytdlp_update.POT_PROVIDER_URL]
    },
    "youtube": {"player_client": ["web_music", "android"]},
}

# JavaScript runtime yt-dlp-ejs runs YouTube's n/sig challenge solver in. Deno is
# yt-dlp's recommended runtime; bun is deprecated (yt-dlp#16766) and bun > 1.3.14
# is unsupported — with bun 1.4.x the solver failed and every client that needs
# it (web, web_music, mweb, ...) 403'd, leaving only `android`. The Dockerfile
# installs deno; for `make run`, install deno >= 2.3.0 on PATH.
_JS_RUNTIMES: dict[str, dict] = {"deno": {}}


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

# Serializes upgrades so two callers can't pip-install over each other.
_upgrade_lock = asyncio.Lock()

# Statuses that mean a download is still using the currently-loaded yt-dlp.
_IN_FLIGHT_STATUSES = ("pending", "downloading", "converting")

# Automatic upgrades (besides entrypoint.sh on every start and the admin
# endpoint): one after a download fails, then that download is retried once;
# and a periodic one, so a long-running container doesn't go stale.
#   AUTO_UPDATE_COOLDOWN_MINUTES — min gap between failure-triggered upgrades,
#     so a video that fails for its own reasons (private, region-locked, ...)
#     can't make every request run pip. 0 disables failure-triggered upgrades.
#   AUTO_UPDATE_INTERVAL_HOURS — periodic upgrade interval. 0 disables it.
AUTO_UPDATE_COOLDOWN_SECONDS = float(os.getenv("AUTO_UPDATE_COOLDOWN_MINUTES", "30")) * 60
AUTO_UPDATE_INTERVAL_SECONDS = float(os.getenv("AUTO_UPDATE_INTERVAL_HOURS", "24")) * 3600

# time.monotonic() of the last failure-triggered upgrade attempt (cooldown), and
# of the last upgrade that actually loaded new packages into this process.
_last_auto_update_attempt: float | None = None
_last_reload_with_changes: float | None = None


def yt_dlp_version() -> str:
    """Version of the yt-dlp actually loaded in this process."""
    return yt_dlp.version.__version__


def downloads_in_flight(exclude: str | None = None) -> bool:
    """True if a download (other than task `exclude`) is using yt-dlp now."""
    return any(
        tp.status in _IN_FLIGHT_STATUSES
        for tid, tp in progress_store.items()
        if tid != exclude
    )


async def _pip_upgrade() -> str:
    """Run pip to upgrade the yt-dlp packages; return its combined output.

    The package list comes from `ytdlp_update.upgrade_specs()` (yt-dlp with its
    matching ejs, plus the PO Token plugin pinned to the sidecar's version).
    Raises RuntimeError if pip fails or takes longer than the timeout. Split out
    from `upgrade_yt_dlp` so tests can stub the network/pip half.
    """
    specs = await asyncio.to_thread(ytdlp_update.upgrade_specs)
    proc = await asyncio.create_subprocess_exec(
        *ytdlp_update.pip_command(specs),
        stdout=asyncio.subprocess.PIPE,
        stderr=asyncio.subprocess.STDOUT,
    )
    timeout = ytdlp_update.PIP_TIMEOUT_SECONDS
    try:
        raw, _ = await asyncio.wait_for(proc.communicate(), timeout=timeout)
    except asyncio.TimeoutError:
        proc.kill()
        raise RuntimeError(f"pip install timed out after {timeout}s") from None

    output = raw.decode(errors="replace").strip()
    if proc.returncode != 0:
        raise RuntimeError(
            f"pip install failed (exit {proc.returncode}): {output[-1000:]}"
        )
    return output


# Top-level packages dropped from sys.modules on reload: yt-dlp itself, its JS
# solver, and plugins (the PO Token provider lives under `yt_dlp_plugins`).
_RELOAD_PACKAGES = {"yt_dlp", "yt_dlp_ejs", "yt_dlp_plugins"}


def _reload_yt_dlp() -> str:
    """Re-import yt_dlp in place so an upgrade applies without a restart.

    Every module of `_RELOAD_PACKAGES` is dropped from `sys.modules` and yt_dlp
    imported again, then this module's global `yt_dlp` is rebound. Callers must
    only do this while no download is running: an in-flight `_sync_download`
    holds the old module objects and could still lazy-import a submodule from
    under it.
    """
    global yt_dlp
    for name in [n for n in sys.modules if n.split(".")[0] in _RELOAD_PACKAGES]:
        del sys.modules[name]
    importlib.invalidate_caches()
    yt_dlp = importlib.import_module("yt_dlp")
    return yt_dlp.version.__version__


async def upgrade_yt_dlp(exclude_task: str | None = None) -> dict[str, Any]:
    """Upgrade yt-dlp to the latest release and load it into this process.

    YouTube breaks stale yt-dlp builds every few months, so this exists to fix
    downloads without rebuilding or restarting the container. Reloading is
    skipped while a download is in flight — the new version is on disk and takes
    effect on the next restart (or the next upgrade that finds the server idle),
    reported as `restart_required`. `exclude_task` lets a failed download that
    is waiting on this upgrade not count as "in flight".
    """
    global _last_reload_with_changes
    async with _upgrade_lock:
        before = yt_dlp_version()
        output = await _pip_upgrade()
        changed = "Successfully installed" in output

        if downloads_in_flight(exclude=exclude_task):
            after, reloaded = before, False
            logger.info("yt-dlp upgraded on disk; reload deferred (download in flight)")
        else:
            after, reloaded = _reload_yt_dlp(), True
            logger.info("yt-dlp reloaded: %s -> %s", before, after)
            if changed:
                _last_reload_with_changes = time.monotonic()

        return {
            "previous_version": before,
            "current_version": after,
            "updated": after != before,
            "reloaded": reloaded,
            # pip installed something (yt-dlp, ejs or the PO Token plugin).
            "packages_changed": changed,
            # pip pulled a new build but we couldn't swap it in yet.
            "restart_required": not reloaded and changed,
            "pip_output": output[-2000:],
        }


async def _auto_update_after_failure(task_id: str, started_at: float) -> bool:
    """Try to fix a failed download by upgrading yt-dlp; True = worth retrying.

    Retrying only makes sense if this process now runs different packages than
    the failed attempt did — either because another task already upgraded while
    this one was downloading, or because the upgrade done here changed something.
    """
    global _last_auto_update_attempt
    if AUTO_UPDATE_COOLDOWN_SECONDS <= 0:
        return False
    if _last_reload_with_changes is not None and _last_reload_with_changes > started_at:
        return True

    now = time.monotonic()
    if (
        _last_auto_update_attempt is not None
        and now - _last_auto_update_attempt < AUTO_UPDATE_COOLDOWN_SECONDS
    ):
        return False
    _last_auto_update_attempt = now

    try:
        result = await upgrade_yt_dlp(exclude_task=task_id)
    except Exception:
        logger.exception("Automatic yt-dlp upgrade after a failed download failed")
        return False
    logger.info(
        "Automatic yt-dlp upgrade after failure: %s -> %s (changed=%s, reloaded=%s)",
        result["previous_version"], result["current_version"],
        result["packages_changed"], result["reloaded"],
    )
    return result["packages_changed"] and result["reloaded"]


async def periodic_update_loop() -> None:
    """Upgrade yt-dlp every AUTO_UPDATE_INTERVAL_SECONDS (run from lifespan).

    The first run waits a full interval: entrypoint.sh already upgraded at start.
    """
    if AUTO_UPDATE_INTERVAL_SECONDS <= 0:
        return
    while True:
        await asyncio.sleep(AUTO_UPDATE_INTERVAL_SECONDS)
        try:
            result = await upgrade_yt_dlp()
            logger.info(
                "Periodic yt-dlp upgrade: %s -> %s (changed=%s, reloaded=%s)",
                result["previous_version"], result["current_version"],
                result["packages_changed"], result["reloaded"],
            )
        except Exception:
            logger.exception("Periodic yt-dlp upgrade failed")


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
        # Deno solves YouTube's JS challenges (solver bundled via yt-dlp-ejs).
        "js_runtimes": _JS_RUNTIMES,
        "extractor_args": _POT_EXTRACTOR_ARGS,
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
        "js_runtimes": _JS_RUNTIMES,
        "extractor_args": _POT_EXTRACTOR_ARGS,
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
    # No `extractor_args` override here on purpose — see the comment on
    # `_POT_EXTRACTOR_ARGS`. This never touches a media URL, so it never hits
    # the 403 that exists to fix, and the full default client mix is more
    # permissive for metadata-only lookups than the web_music/android pair.
    ydl_opts: dict[str, Any] = {
        "skip_download": True,
        "quiet": True,
        "no_warnings": True,
        "noplaylist": True,
        "js_runtimes": _JS_RUNTIMES,
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

async def _download_with_auto_update(youtube_id: str, task_id: str) -> dict[str, Any]:
    """`_sync_download`, upgrading yt-dlp and retrying once if it fails.

    A failure is the usual symptom of YouTube having broken the installed
    yt-dlp (403s, "Sign in to confirm you're not a bot", missing formats), so
    the first failure triggers an upgrade (rate-limited — see
    `_auto_update_after_failure`); if that loaded new packages, the download is
    retried once. The original error is re-raised when no retry happens.
    """
    started_at = time.monotonic()
    try:
        return await asyncio.to_thread(_sync_download, youtube_id, task_id)
    except Exception as exc:
        logger.warning("Download failed for %s (%s); checking for a yt-dlp update", youtube_id, exc)
        tp = progress_store[task_id]
        tp.status = "downloading"
        tp.progress_percent = 0.0
        tp.message = "Download failed, updating yt-dlp..."
        if not await _auto_update_after_failure(task_id, started_at):
            raise
        logger.info("Retrying %s with yt-dlp %s", youtube_id, yt_dlp_version())
        tp.message = "Retrying with updated yt-dlp..."
    return await asyncio.to_thread(_sync_download, youtube_id, task_id)


async def run_download(youtube_id: str, task_id: str, video_db_id: uuid.UUID) -> None:
    """Start the full download pipeline. Updates DB row when done."""
    tp = progress_store.setdefault(task_id, TaskProgress())

    try:
        result = await _download_with_auto_update(youtube_id, task_id)

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
