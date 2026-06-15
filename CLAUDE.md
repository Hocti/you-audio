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

## What Is Not Implemented Yet

- Channel tab (YouTube OAuth login and subscribed-channel browsing)
- Auto-scroll to current subtitle line in Play tab
