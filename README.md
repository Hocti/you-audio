# YouTube Audio

A self-hosted YouTube audio downloader and player. The backend runs in Docker on a NAS or local machine and converts YouTube videos to MP3. The Flutter Android app streams audio in the background with playback controls, subtitle display, and a library of downloaded tracks.

## Quick Start

**Step 1 — Start the backend:**

```bash
cd backend
docker compose up -d --build
```

See [backend/README.md](backend/README.md) for Synology NAS setup, Makefile targets, and configuration.

**Step 2 — Build and install the Flutter app:**

```bash
cd flutter_app
flutter pub get
flutter run
```

See [flutter_app/README.md](flutter_app/README.md) for prerequisites and how to connect to the backend.

## Project Structure

```
youtube-audio/
├── backend/          # FastAPI + yt-dlp + PostgreSQL
└── flutter_app/      # Flutter Android app
```

## Features

- Download YouTube videos as MP3 (audio only)
- Download subtitles (Chinese/English) automatically
- 4-tab Android app: Link, Channel (coming soon), Downloaded, Play
- Background playback with lock screen controls
- ±30s skip, playback speed 0.5–2.5×
- Subtitle display synced to playback with tap-to-seek
- Sort/filter downloaded library by date, channel, or listen status
- Optional access token authentication
