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
├── tests/                # pytest suite (httpx AsyncClient over temp SQLite)
├── Dockerfile            # Container image definition
├── docker-compose.yml    # Runs backend + PostgreSQL together
└── requirements.txt      # Python dependencies
```

Run tests with `cd backend && make test` (or `python -m pytest`).

**Use a virtualenv: `make venv`.** `make run` / `make test` then pick up
`.venv/bin/python` automatically. Installing these pinned dependencies into a
shared environment (a conda base that also has gradio, for instance) makes the
two fight over fastapi / starlette / python-multipart — pip installs one set and
silently breaks the other.

`requirements.txt` has two pins that exist purely so everything installs from a
**wheel** (see the comments there): `asyncpg` and `pydantic` floors for Python
3.13, below which pip builds from source and fails; and `yt-dlp-ejs` uses semver
(`0.8.0`), not yt-dlp's date scheme — pinning it to a date breaks the image build.

---

## Key Concepts

### Routes (`app/main.py`)
| Method | Path | What it does |
|--------|------|--------------|
| POST | `/api/download` | Accept a YouTube URL, check cache, start download |
| POST | `/api/metadata` | Quick title/channel/duration/thumbnail (no audio); upserts a `pending` row + saves the thumbnail so the client can show it before the audio download |
| GET | `/api/progress/{task_id}` | Poll download/conversion progress |
| GET | `/api/audio/{video_id}` | Send the whole MP3 file (download-to-device flow) |
| GET | `/api/stream/{video_id}` | Same MP3 with **real HTTP range support** (206), for the streaming player |
| GET | `/api/thumbnail/{video_id}` | Serve the thumbnail image |
| GET | `/api/videos` | Return all downloaded videos as JSON |
| GET | `/api/channel/resolve?q=…` | Resolve a channel ID from a URL / `@handle` / username / id |
| GET | `/api/channel/{channel_id}/videos` | Return a channel's latest videos (≤50) via YouTube Data API, cached 1h. Shorts (1–60s) and members-only/private videos are filtered out (see `youtube_api._filter_playable`). A **zero** duration means live/upcoming/premiere, not a Short, and is kept. |
| GET | `/api/yt-dlp/version` | yt-dlp version loaded in this process. |
| GET | `/api/yt-dlp/update` | **Admin only.** pip-upgrade yt-dlp + yt-dlp-ejs and hot-reload them. |
| GET | `/api/users` | **Admin only.** List users (incl. their tokens). |
| POST | `/api/users` | **Admin only.** Create a user `{username, token?}` (random token if omitted). 409 on duplicate username/token. |
| PATCH | `/api/users/{id}` | **Admin only.** Update `{username?, token?}`. The admin user cannot be renamed (400); its token can change. |
| DELETE | `/api/users/{id}` | **Admin only.** Delete a user. The admin user cannot be deleted (400). |
| GET | `/api/health` | Health + auth diagnostic — always 200, returns `{"status","token_required","token_valid"}` |

`video_id` in the URL path always means the **YouTube video ID** (11-character string like `dQw4w9WgXcQ`), not the database UUID.

### Access token / auth (token → user)
- Auth is **always on** and per-user. Every request must send an `X-Access-Token`
  header that matches a row in the `users` table; `Depends(get_current_user)`
  resolves it to a `User` (401 if missing/unknown). `/api/health` is the only
  open route — it never 401s (so a client can tell "server down" from "token
  wrong") and reports `token_required` (always true) + `token_valid` (token
  matches a real user).
- There is **no** hard-coded single token anymore. `ACCESS_TOKEN` is
  **authoritative when set**: `ensure_admin()` runs on every start and creates
  the `admin` user with that token, *or updates an existing admin whose token
  differs*. If empty, an existing admin is left alone and a missing one gets a
  random token printed to the logs.
  - The earlier "never overwrite an existing admin" rule was a trap: a container
    that booted once without `ACCESS_TOKEN` was stuck on a random token forever,
    with no way back except editing the DB by hand. Updating from env is the
    recovery path.
  - Guard: if `ACCESS_TOKEN` already belongs to a *different* user, admin is left
    unchanged and the clash is logged as an error (tokens are unique).
  - `make run` passes `ACCESS_TOKEN` from `.env`, same as `YOUTUBE_API_KEY`.
- Admin-only routes additionally depend on `require_admin` (403 for non-admins),
  identified by the `is_admin` flag.

### Request logging
- "Expensive" operations (anything hitting the YouTube API or downloading) are
  logged to the `requests` table, attributed to the calling user: `/api/download`,
  `/api/metadata`, `/api/channel/resolve`, `/api/channel/{id}/videos`. File
  serving, `/api/videos` listing, progress polling, and `/api/health` are **not**
  logged.
- Implemented with the `log_operation(user, request, argument)` async context
  manager wrapping each of those four handlers. It records method, path, the main
  argument (url / video id / channel id / query), and the final status code
  (including `HTTPException` failures), writing via a **fresh** session so logging
  can't interfere with the request.

### Keeping yt-dlp current (`downloader.py`)
- YouTube breaks stale yt-dlp builds every few months (typically HTTP 403 on the
  media URL, or "Sign in to confirm you're not a bot"). Two layers keep it fresh:
  `entrypoint.sh` pip-upgrades yt-dlp + yt-dlp-ejs on **every container start**,
  and `GET /api/yt-dlp/update` (admin) does the same on demand — a GET so it can
  be hit from a browser or a bookmark.
- `upgrade_yt_dlp()` = `_pip_upgrade()` (stubbed in tests) then `_reload_yt_dlp()`,
  which drops every `yt_dlp*` entry from `sys.modules`, re-imports, and rebinds
  this module's global — so the new version applies **without a restart**. The
  reload is skipped while a download is in flight (`downloads_in_flight()`),
  because the running `_sync_download` still holds the old module; the response
  then says `restart_required: true`.
- An `_upgrade_lock` serializes concurrent calls. `GET /api/yt-dlp/version`
  reports what is actually loaded — use it to check before/after.

### PO Token provider (`downloader.py`, `docker-compose.yml`)
- Separately from stale-version 403s above: YouTube now requires a **PO Token**
  for most googlevideo.com media URLs, or the download 403s even though
  extraction succeeded (the format is listed with a URL but not authorized to
  fetch). This is unrelated to `yt-dlp-ejs`/bun, which solves the URL-signing
  (nsig) challenge, not this.
- `bgutil-ytdlp-pot-provider` (pip package, kept current alongside yt-dlp —
  it's in `_UPGRADE_PACKAGES` and `entrypoint.sh`) is a yt-dlp plugin that
  fetches a token from a small sidecar HTTP server: the `pot-provider` service
  in `docker-compose.yml` (image `brainicism/bgutil-ytdlp-pot-provider`).
  `POT_PROVIDER_URL` env var points yt-dlp at it (`http://pot-provider:4416`
  in Compose); the plugin's own default (`127.0.0.1:4416`) only works when
  both processes share a host, which isn't true across Compose services.
  `make run`'s `pot-provider` target starts the same container locally via
  `docker run` for non-Docker dev.
- A token alone isn't sufficient — yt-dlp's default client mix (web,
  web_safari, android_vr, ...) lists adaptive audio-only formats from clients
  whose token is scoped differently and still 403s on fetch (see
  https://github.com/yt-dlp/yt-dlp/issues/12482). Debugging against a real
  403 found `web_music` (music.youtube.com's client) to be the one client
  whose adaptive audio URLs actually download once bgutil supplies its token,
  so `_POT_EXTRACTOR_ARGS` in `downloader.py` pins `youtube:player_client` to
  it for all three yt-dlp calls (download, subtitles, metadata). If this ever
  regresses, check *which* client's formats actually download with
  `yt-dlp -v`, not just which are listed — listed-but-403 is the normal
  failure mode here.

### Streaming vs. downloading (`/api/stream` vs `/api/audio`)
- `/api/audio` returns a Starlette `FileResponse`. That response **ignores the
  `Range` header** — it answers 200 with the entire file while still advertising
  `Accept-Ranges: bytes`. Verified against a live server: `Range: bytes=1000-2000`
  came back as 200 with all 15 MB.
- A client that believes the header (just_audio's caching source does) asks for a
  range on seek, gets the whole file, and plays it as if it began at the offset.
  So **`/api/stream/{video_id}`** exists: it parses `Range` itself
  (`parse_byte_range`) and answers a proper `206` with `Content-Range`, a plain
  `200` when there is no range, and `416` when the range can't be satisfied.
- `/api/audio` is deliberately left exactly as it was — the download flow uses it
  and does a plain GET. Only the new streaming path uses `/api/stream`.
- Both require a finished (`status == "done"`) row: the endpoint serves a file
  that already exists. Streaming removes the *device transfer* from the wait, not
  the yt-dlp/ffmpeg conversion.

### Subtitle language handling (`downloader.py`)
- yt-dlp fetches several Chinese variants + English. `_select_subtitle()` prefers
  an existing Traditional subtitle (`zh-Hant`/`zh-TW`/`zh-HK`) as-is; otherwise it
  takes a Simplified or ambiguous bare-`zh` subtitle and converts it to Traditional
  in place with `chinese-converter` (s2t); English is the last-resort fallback.
- If `chinese-converter` is **not installed in the running image**, conversion is
  skipped and the subtitle stays Simplified — this was the cause of "繁體化未生效".
  `_convert_subtitle_to_traditional` now logs this loudly (`logger.error`) instead
  of swallowing it. `chinese-converter` is in `requirements.txt`; rebuild the image
  if you see that error.

### Database (`app/models.py` + `app/database.py`)
- Three tables: **`videos`**, **`users`**, **`requests`**.
  - `users`: `id` (int PK), `username` (unique), `token` (unique, indexed),
    `is_admin` (bool), `created_at`. Default `admin` row is seeded on startup.
  - `requests`: `id` (int PK), `user_id` (FK users.id), `method`, `path`,
    `argument` (main arg), `status_code`, `created_at`. One row per logged op.
- All tables use `create_all` (create-if-not-exist), so adding `users`/`requests`
  preserves existing `videos` data in the Docker SQLite volume.
- **New columns on existing tables need `ensure_columns()`.** `create_all` only
  creates missing *tables* — it never alters one that already exists, so a
  database from an earlier release kept its old `videos` shape and every query
  selecting a newer column died with `no such column: videos.channel_id` (a 500
  on `/api/videos` straight after an upgrade). `_ADDED_COLUMNS` in `main.py` lists
  such columns and `ensure_columns()` (in `lifespan`, after `create_all`) issues
  an additive, idempotent `ALTER TABLE … ADD COLUMN`, valid on both SQLite and
  PostgreSQL. **Add an entry there whenever you add a column to a shipped table.**
- **`videos`** details:
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
4. If `status` is `pending/downloading/converting` **and `progress_store` still
   holds that task** → attach to the running job and return its task id.
5. Otherwise reuse whatever row exists (metadata-only, errored, or abandoned),
   reset it to `pending`, and start a download. If no row exists, create one.

**Step 4's `progress_store` check is load-bearing.** A non-terminal `status` is
not proof that a download is running: `/api/metadata` creates the row as
`pending` before any download starts, and a process restart empties the
in-memory `progress_store` while rows keep their status. Without the check, the
route returned a task id that nothing would ever report on — the client polled
`/api/progress` forever and sat at **0%**, and the video could never be
downloaded again. `tests/test_download_start.py` covers both cases.

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
| `POT_PROVIDER_URL` | `http://127.0.0.1:4416` | Base URL of the `bgutil-ytdlp-pot-provider` sidecar (see PO Token section above). Compose sets this to `http://pot-provider:4416`. |

---

## Adding a New Endpoint

1. Add a new route function in `app/main.py`.
2. Add matching Pydantic schemas in `app/schemas.py` if you need new request/response shapes.
3. If the endpoint needs DB access, add `session: AsyncSession = Depends(get_session)` as a parameter.

## Changing MP3 Quality

In `app/downloader.py`, find `_sync_download()` and change `"preferredquality": "192"` to another value like `"320"` or `"128"`.

## Adding a New DB Column

1. Add the column to the model in `app/models.py`.
2. Add it to `_ADDED_COLUMNS` in `app/main.py` so `ensure_columns()` back-fills it
   into databases created before the change. Skipping this step means every query
   touching the new column 500s on existing deployments.
