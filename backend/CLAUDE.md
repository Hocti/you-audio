# Backend – CLAUDE.md

This file explains the codebase so you can quickly understand how everything works and where to make changes.

---

## Project Overview

A FastAPI backend that:
1. Accepts a YouTube URL from a client.
2. Downloads the audio using **yt-dlp** and converts it to MP3 via **ffmpeg**.
3. Saves metadata (title, channel, duration, thumbnail) to **PostgreSQL**.
4. Serves the MP3 and thumbnail files over HTTP.
5. Caches downloads — if the same video is requested again, the stored record is returned immediately.

---

## File Structure

```
backend/
├── app/
│   ├── __init__.py       # Empty, marks app/ as a Python package
│   ├── main.py           # FastAPI app, all route handlers
│   ├── database.py       # SQLAlchemy async engine and session factory
│   ├── models.py         # ORM model for the `videos` table
│   ├── schemas.py        # Pydantic request/response models
│   └── downloader.py     # yt-dlp download logic, progress tracking
├── Dockerfile            # Container image definition
├── docker-compose.yml    # Runs backend + PostgreSQL together
└── requirements.txt      # Python dependencies
```

---

## Key Concepts

### Routes (`app/main.py`)
| Method | Path | What it does |
|--------|------|--------------|
| POST | `/api/download` | Accept a YouTube URL, check cache, start download |
| POST | `/api/metadata` | Quick title/channel/duration/thumbnail (no audio); upserts a `pending` row + saves the thumbnail so the client can show it before the audio download |
| GET | `/api/progress/{task_id}` | Poll download/conversion progress |
| GET | `/api/audio/{video_id}` | Stream the MP3 file |
| GET | `/api/thumbnail/{video_id}` | Serve the thumbnail image |
| GET | `/api/videos` | Return all downloaded videos as JSON |
| GET | `/api/channel/resolve?q=…` | Resolve a channel ID from a URL / `@handle` / username / id |
| GET | `/api/channel/{channel_id}/videos` | Return a channel's latest videos (≤50) via YouTube Data API, cached 1h. Shorts (≤60s) and members-only/private videos are filtered out (see `youtube_api._filter_playable`). |
| GET | `/api/health` | Health + auth diagnostic — always 200, returns `{"status","token_required","token_valid"}` |

`video_id` in the URL path always means the **YouTube video ID** (11-character string like `dQw4w9WgXcQ`), not the database UUID.

### Access token / auth
- An `ACCESS_TOKEN` env var enables auth. Every route requires a matching
  `X-Access-Token` header via `Depends(_verify_token)` (401 on mismatch) — **except**
  `/api/health`, which never 401s so a client can tell "server down" from "token
  wrong". Health reports `token_required` and `token_valid` instead.

### Subtitle language handling (`downloader.py`)
- yt-dlp fetches several Chinese variants + English. `_select_subtitle()` prefers
  an existing Traditional subtitle (`zh-Hant`/`zh-TW`/`zh-HK`) as-is; otherwise it
  takes a Simplified or ambiguous bare-`zh` subtitle and converts it to Traditional
  in place with `chinese-converter` (s2t); English is the last-resort fallback.

### Database (`app/models.py` + `app/database.py`)
- One table: **`videos`**
- Primary key: UUID (auto-generated)
- Unique key: `youtube_id` — prevents duplicate downloads
- `channel_id` (nullable) — the `UC…` id from yt-dlp metadata, captured on download/metadata so the app can "open channel" from a downloaded video. Only on rows created after this column was added (no migration for old rows).
- `status` field values: `pending` → `downloading` → `converting` → `done` | `error`
- Tables are created automatically on startup inside the `lifespan` function in `main.py`.
- The DB URL is read from the `DATABASE_URL` environment variable.

### Download Flow (`app/downloader.py`)
1. `run_download()` is called as an `asyncio` background task (non-blocking).
2. It calls `asyncio.to_thread(_sync_download, ...)` to run blocking yt-dlp code in a thread pool.
3. `_sync_download()` uses yt-dlp with a progress hook (`_progress_hook`) that updates `progress_store[task_id]`.
4. After audio download, yt-dlp post-processor runs ffmpeg to convert to MP3 at 192kbps.
5. The thumbnail URL from yt-dlp metadata is downloaded using `httpx`.
6. DB row is updated with all metadata and `status = "done"`.

### Progress Tracking
- `progress_store` is a plain Python dict: `{ task_id: TaskProgress }`.
- `TaskProgress` has: `status`, `progress_percent` (0–100), `message`.
- This is in-memory only — progress is lost if the server restarts.
- `task_id` equals `str(video.id)` (the database UUID as a string).

### Caching Logic (in `main.py` `download` route)
1. Extract YouTube video ID from URL using regex in `extract_video_id()`.
2. Query DB for a row with that `youtube_id`.
3. If `status == "done"` → return cached result immediately, no download.
4. If `status` is `pending/downloading/converting` → return the existing task ID.
5. If `status == "error"` → reset and retry.
6. If no row exists → create new row and start download.

### File Storage
- Audio files: `/data/audio/{youtube_id}.mp3`
- Thumbnails: `/data/thumbnails/{youtube_id}.jpg`
- The `/data` directory is a Docker volume — files survive container restarts.
- `DATA_DIR` can be changed with the `DATA_DIR` environment variable.

---

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DATABASE_URL` | — | Required. PostgreSQL async URL, e.g. `postgresql+asyncpg://user:pass@host/db` |
| `DATA_DIR` | `/data` | Directory to store audio and thumbnail files |
| `YOUTUBE_API_KEY` | — | YouTube Data API v3 key, required for `/api/channel/{id}/videos` |

---

## Adding a New Endpoint

1. Add a new route function in `app/main.py`.
2. Add matching Pydantic schemas in `app/schemas.py` if you need new request/response shapes.
3. If the endpoint needs DB access, add `session: AsyncSession = Depends(get_session)` as a parameter.

## Changing MP3 Quality

In `app/downloader.py`, find `_sync_download()` and change `"preferredquality": "192"` to another value like `"320"` or `"128"`.

## Adding a New DB Column

1. Add the column to the `Video` class in `app/models.py`.
2. Because tables are created with `create_all`, the new column only appears in a **fresh** database. For an existing database, run an `ALTER TABLE` SQL command manually, or use Alembic for migrations.
