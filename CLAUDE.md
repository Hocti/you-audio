# YouTube Audio — CLAUDE.md

## Project Structure

```
youtube-audio/
├── backend/          # Python/FastAPI backend (see backend/CLAUDE.md)
└── flutter_app/      # Flutter Android app (see flutter_app/CLAUDE.md)
```

## Backend

FastAPI + yt-dlp + PostgreSQL in Docker. See [backend/CLAUDE.md](backend/CLAUDE.md).

Key commands:
- `cd backend && make run` — run locally without Docker
- `cd backend && make run-docker` — run with Docker
- `cd backend && make build` — build Docker image

## Flutter App

Android app with 4 tabs. See [flutter_app/CLAUDE.md](flutter_app/CLAUDE.md).

Key commands:
- `cd flutter_app && flutter pub get` — install dependencies
- `cd flutter_app && flutter run` — run on connected Android device/emulator

## Architecture

The app and backend communicate over HTTP. The backend URL and optional access token are entered in the app's setup screen on first launch and saved to SharedPreferences. All API requests include an `X-Access-Token` header when a token is configured.

Playback is **local-first**: the backend converts a video to MP3, then the app downloads the mp3/thumbnail/subtitle to the device and plays the local file. The Downloaded tab reads only from device storage (works offline); the backend is contacted only to start a download, pull finished files, or browse a channel.

## What Is Not Implemented Yet

- Channel tab: browsing a channel's latest videos works (with bookmarks). Input can be a channel ID, a `/channel/UC…` URL, an `@handle`/handle URL, a `/user/` URL, or a `/c/` custom URL — the backend's `/api/channel/resolve` turns these into a channel id. YouTube OAuth login and subscribed-channel browsing are not implemented.
- Auto-scroll to current subtitle line in Play tab
