# Flutter App – CLAUDE.md

This file explains the app structure so you can quickly find and change things.

---

## Project Overview

An Android audio player app that:
1. Connects to the backend server (URL saved on first launch).
2. Lets the user paste a YouTube URL — the backend downloads it and the app shows progress.
3. Shows a list of downloaded audio tracks with thumbnails.
4. Plays audio in the background with a persistent bottom player bar.
5. Saves and restores playback position across sessions.

---

## File Structure

```
flutter_app/
├── lib/
│   ├── main.dart                      # App entry point, MaterialApp setup
│   ├── models/
│   │   └── video.dart                 # Video data model, JSON parsing
│   ├── services/
│   │   ├── api_service.dart           # All HTTP calls to the backend
│   │   └── audio_service.dart         # Background audio playback logic
│   ├── pages/
│   │   ├── server_setup_page.dart     # Page 1: enter backend URL
│   │   ├── download_page.dart         # Page 2: paste YouTube URL, watch progress
│   │   └── audio_list_page.dart       # Page 3: browse and play downloaded tracks
│   └── widgets/
│       └── player_bar.dart            # Persistent bottom player bar
├── android/
│   └── app/src/main/
│       └── AndroidManifest.xml        # Permissions and audio service config
└── pubspec.yaml                       # Dependencies
```

---

## Pages

### Page 1 — `server_setup_page.dart`
- Shows a text field for the backend URL (e.g. `http://192.168.1.100:8000`).
- Saves the URL to `SharedPreferences` under the key `server_url`.
- On startup, if `server_url` is already saved, skips this page automatically.
- To reset the server URL, clear `SharedPreferences` (no UI for this yet).

### Page 2 — `download_page.dart`
- Calls `ApiService.download(url)` → `POST /api/download`.
- Polls `GET /api/progress/{task_id}` every 1 second using a `Timer.periodic`.
- Stops polling when `status == "done"` or `status == "error"`.
- If the server returns `cached: true`, shows "Already downloaded!" immediately.
- Has a button to navigate to Page 3.

### Page 3 — `audio_list_page.dart`
- Calls `ApiService.getVideos()` → `GET /api/videos`.
- Renders each item with a thumbnail, title, channel name, duration, and last-played position.
- Last-played position is read from `SharedPreferences` using key `progress_{videoId}`.
- Tapping an item calls `audioHandler.playVideo(video)`.

---

## Audio Service (`lib/services/audio_service.dart`)

### Classes
- **`AudioPlayerHandler`** — extends `BaseAudioHandler` from `audio_service` package.
  - Wraps a `just_audio` `AudioPlayer` instance.
  - `playVideo(video)` — sets the audio URL, restores saved position, calls `play()`.
  - `skipToNext()` — jumps **forward 15 seconds** (this is intentional — not a track skip).
  - `skipToPrevious()` — jumps **backward 15 seconds** (also intentional).
  - `playNextUnplayed()` — finds the first video in `_playlist` with no saved position, plays it. If all have been played, falls back to the first track that isn't the current one.
  - Position is saved to `SharedPreferences` as `progress_{videoId}` (integer seconds) every time `positionStream` emits.
  - On track completion (`ProcessingState.completed`), resets that track's saved position to `0`, then calls `playNextUnplayed()`.

- **`AudioManager`** — singleton that initializes `AudioPlayerHandler` via `AudioService.init()`.
  - Call `AudioManager.init()` once at app startup before using playback.
  - Access the handler via `AudioManager.handler`.

### Media Notification
- Configured in `AudioServiceConfig` inside `AudioManager.init()`.
- The notification shows **Previous (−15s) / Play-Pause / Next (+15s)** controls.
- Channel ID: `com.example.flutter_app.audio` — change this if you rename the app package.

---

## API Service (`lib/services/api_service.dart`)

All methods read `server_url` from `SharedPreferences` before making requests.

| Method | HTTP | Path |
|--------|------|------|
| `download(url)` | POST | `/api/download` |
| `getProgress(taskId)` | GET | `/api/progress/{taskId}` |
| `getVideos()` | GET | `/api/videos` |
| `audioUrl(videoId)` | — | Returns full URL string |
| `thumbnailUrl(videoId)` | — | Returns full URL string |

---

## Data Model (`lib/models/video.dart`)

`Video` fields (all from the backend `GET /api/videos` response):
- `id` — YouTube video ID (11-character string), used in audio/thumbnail URLs
- `title`, `channel` — display strings
- `duration` — integer seconds
- `status` — `"done"` for playable tracks
- `createdAt` — `DateTime`

`Video.durationFormatted` returns a human-readable string like `3:45`.

---

## Player Bar (`lib/widgets/player_bar.dart`)

Always shown at the bottom of Page 2 and Page 3.
- Reads state from `AudioManager.handler` using `StreamBuilder` on `playbackState` and `mediaItem`.
- Buttons:
  - **−15s** → calls `handler.skipToPrevious()`
  - **Play/Pause** → calls `handler.play()` or `handler.pause()`
  - **+15s** → calls `handler.skipToNext()`
  - **Next track** → calls `handler.playNextUnplayed()`
- Seek slider uses `handler.seek(Duration(...))`.

---

## Key Dependencies (`pubspec.yaml`)

| Package | Purpose |
|---------|---------|
| `just_audio` | Audio playback engine |
| `audio_service` | Background playback + media notification |
| `audio_session` | Handles audio focus (pauses on phone call, etc.) |
| `cached_network_image` | Loads and caches thumbnail images |
| `shared_preferences` | Stores server URL and playback positions |
| `http` | HTTP client for API calls |
| `provider` | State management (available but minimal use) |

---

## Android Manifest Notes (`android/app/src/main/AndroidManifest.xml`)

- `android:usesCleartextTraffic="true"` — allows HTTP (not just HTTPS) connections. Required for connecting to the NAS over a local network without a certificate.
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` — required for background audio on Android 14+.
- The `AudioService` and `MediaButtonReceiver` entries are required by the `audio_service` package.

---

## Common Changes

### Change the app name
Edit `android/app/src/main/AndroidManifest.xml`: `android:label="YouTube Audio"`.

### Change the app package name
1. Rename the package in `AndroidManifest.xml`.
2. Update `androidNotificationChannelId` in `AudioManager.init()` in `audio_service.dart`.
3. Run `flutter pub get` again.

### Add a new API call
Add a new method to `ApiService` in `lib/services/api_service.dart`, following the same pattern as existing methods.
