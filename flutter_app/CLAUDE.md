# Flutter App – CLAUDE.md

This file explains the app structure so you can quickly find and change things.

---

## Project Overview

An Android audio player app that:
1. Connects to the backend server (URL + optional access token saved on first launch).
2. Lets the user paste a YouTube URL — the backend converts it to MP3, then the app **downloads the mp3 + thumbnail + subtitle to the device** (`DownloadManager`).
3. Shows a list of **locally downloaded** audio tracks with thumbnails, plus any in-progress downloads, with filter/sort controls. This list reads from the device only — no backend calls — so it works offline.
4. Plays the **local audio file** in the background with a persistent bottom player bar and subtitle display.
5. Saves and restores playback position across sessions, and tracks listen completion.

**Architecture note:** playback is local-first. The backend is only contacted to
(a) start/convert a download, (b) pull the finished files to the device, and
(c) browse a channel's videos. Once downloaded, tracks play offline.

---

## File Structure

```
flutter_app/
├── lib/
│   ├── main.dart                      # App entry point, MaterialApp setup
│   ├── models/
│   │   ├── video.dart                 # Video data model, JSON parsing
│   │   ├── local_video.dart           # A track stored on-device (library.json entry)
│   │   ├── channel_video.dart         # A video returned by the channel endpoint
│   │   └── subtitle_entry.dart        # Parsed subtitle line (text + start/end time)
│   ├── services/
│   │   ├── api_service.dart           # All HTTP calls to the backend
│   │   ├── local_library.dart         # On-device library: files + library.json index
│   │   ├── download_manager.dart      # Orchestrates backend convert + pull-to-device
│   │   ├── bookmark_service.dart      # Bookmarked channels (SharedPreferences) + URL→id
│   │   ├── share_handler.dart         # OS share-intent bridge + URL classification
│   │   ├── download_foreground_service.dart # Android foreground svc keeping downloads alive
│   │   └── audio_service.dart         # Background audio playback logic
│   ├── pages/
│   │   ├── server_setup_page.dart     # Setup screen: enter backend URL + access token
│   │   ├── main_scaffold.dart         # Bottom navigation host for the 4 tabs
│   │   ├── link_tab.dart              # Tab 1: paste YouTube URL, watch progress
│   │   ├── channel_tab.dart           # Tab 2: coming soon (YouTube channel browsing)
│   │   ├── downloaded_tab.dart        # Tab 3: browse, filter, sort downloaded tracks
│   │   └── play_tab.dart              # Tab 4: current track player + subtitle display
│   └── widgets/
│       ├── player_bar.dart            # Persistent bottom player bar (shown in tabs 1–3)
│       └── scrolling_text.dart        # Single-line, horizontally-scrollable text (long titles)
├── android/
│   └── app/src/main/
│       └── AndroidManifest.xml        # Permissions and audio service config
└── pubspec.yaml                       # Dependencies
```

---

## Pages

### Setup — `server_setup_page.dart`
- Shows text fields for the backend URL (e.g. `http://192.168.1.100:8000`) and optional access token.
- Saves both to `SharedPreferences` under keys `server_url` and `access_token`.
- On startup, if `server_url` is already saved, skips this page automatically.
- **Settings tab** (`settings_tab.dart`) has a **Test** button that probes `/api/health` with the *currently entered* URL/token (before saving) and reports reachability + token validity.

### Main scaffold — `main_scaffold.dart`
- Hosts the 4-tab `BottomNavigationBar`.
- Provides the `ApiService` and `AudioPlayerHandler` instances down the widget tree.

### Tab 1 — `link_tab.dart`
- Pastes a YouTube URL from the clipboard and hands it to `DownloadManager.instance.start(api, url)` (fire-and-forget).
- Progress and errors appear as rows in the Downloaded tab (not here).

### Tab 2 — `channel_tab.dart`
- Two views in one stateful widget:
  - **Paste view**: a "Paste Channel" button that reads the clipboard. A bare/embedded `UC…` id is used directly (`extractChannelId`); anything else (a `/channel/` URL, `@handle` URL, `/user/`, `/c/`) is resolved to a channel id via `ApiService.resolveChannel()` → `GET /api/channel/resolve`. Below the button is a scrollable list of bookmarked channels (`BookmarkService`, SharedPreferences).
    The paste header is part of the same scroll view as the bookmark list (one `ListView`), so on small screens the header scrolls away instead of permanently occupying the top half.
  - **Detail view**: lists the channel's latest videos via `ApiService.getChannelVideos(channelId)` (Shorts + members-only already filtered server-side). Back button + a star toggle (AppBar action) to bookmark the channel. Video titles use `ScrollingText`.
- Tapping a video acts by per-row state (`_RowState`): **none** → start a download; **downloading** → "already downloading"; **downloaded** → play it; **playing** → jump to the Play tab. Trailing icon reflects the state (download / spinner / download_done / equalizer / error). The list rebuilds from `DownloadManager.instance.jobs` so icons update live.
- Channel thumbnails are direct YouTube CDN URLs, so they need no access token.
- Not yet implemented: YouTube OAuth login / subscribed-channel browsing.

### Tab 3 — `downloaded_tab.dart`
- Reads the **local library** via `LocalLibrary.all()` (offline; no backend call) and listens to `DownloadManager.instance.jobs` to show in-progress download rows at the top.
- Thumbnails load from local files (`Image.file`).
- Filter dropdown: **All / Unlistened / Listened** (based on `completed_*` SharedPreferences keys).
- Sort dropdown: by date, channel, or listen status, plus an asc/desc arrow toggle (`_sortAsc`). Re-picking the current sort type or tapping the arrow flips direction; the default is descending (newest-first).
- Tap a track to play it (local file); long-press for a context menu with **Play Next** and **Delete from device**.
- **Swipe a row left** to delete: the red **Delete** background appears only once the drag passes a ~100px threshold; releasing past it removes the track (with a SnackBar, no confirm dialog), releasing before it snaps back. Implemented with `Dismissible` (`onUpdate` tracks drag progress; `dismissThresholds` ≈ 100px/width).
- **Play Next** calls `audioHandler.queueNext(video)`.
- **Delete from device** calls `LocalLibrary.remove(youtubeId)` (removes local files only; the backend copy is untouched).

### Tab 4 — `play_tab.dart`
- Displays current track title, channel, seek bar, and speed control.
- Speed control cycles through `AudioPlayerHandler.speedSteps` (0.5–2.5×).
- Subtitles are read from the **local** `.vtt` file (`LocalLibrary.subPath`), parsed into a `SubtitleEntry` list, and shown in a scrollable list below the player.
- The current subtitle line is highlighted based on `_player.positionStream` and **auto-scrolls** into view (centered) when it changes — a `GlobalKey` on the current line + `Scrollable.ensureVisible`, fired once per line change (`_autoScrolledIndex`).
- Tap any subtitle line to seek to that position.
- The AppBar title uses `ScrollingText` so long titles scroll horizontally.

---

## Audio Service (`lib/services/audio_service.dart`)

### Classes

- **`AudioPlayerHandler`** — extends `BaseAudioHandler` from `audio_service` package.
  - Wraps a `just_audio` `AudioPlayer` instance.
  - `playVideo(video)` — plays the **local file** via `_player.setFilePath(LocalLibrary.audioPath(id))` (offline, no token needed), restores saved position, calls `play()`. Sets `opened_*` flag in SharedPreferences. Media-notification art uses the local thumbnail file (`Uri.file`) when present.
  - `skipToNext()` / `skipToPrevious()` — **track navigation** (next/previous item in the playlist). `skipToPrevious` restarts the current track if >3s in. These back the notification + hardware/Bluetooth prev/next buttons.
  - `fastForward()` / `rewind()` — **±30 second seek** (the in-app ±30s buttons and the notification rewind/fast-forward controls).
  - `queueNext(video)` — stores a video to play immediately after the current track ends, taking priority over `playNextUnplayed()` (used for auto-advance on completion).
  - `playNextUnplayed()` — smart auto-advance on track end: prefers never-started + not-completed, then in-progress but not-completed, then the first non-current track.
  - `speedSteps` — `const List<double>` of valid speed values: `[0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5]`.
  - `setSpeed(speed)` — clamps to 0.5–2.5, sets player speed, and **persists it** (`playback_speed` in SharedPreferences). The saved speed is loaded at startup and re-applied in `playVideo` so every track uses the same speed.
  - `restoreLastSession()` — called at startup (`main.dart`). Reloads the last-played track (`last_played_youtube_id`) at its saved position, **paused** (does not call `play()`), so the app opens showing what was playing and where; the user resumes manually.
  - Position is saved to SharedPreferences as `progress_{youtubeId}` (integer seconds), throttled to ~once per 2s on the `positionStream` tick (pause/stop flush the exact final position immediately). `last_played_youtube_id` is written in `playVideo`.
  - **Completion tracking**: when playback position reaches 95% of duration, `_markedCompleted` is set to `true` and `completed_{youtubeId}` is written to SharedPreferences. On track end (`ProcessingState.completed`), resets the saved position to 0 and calls `playNextUnplayed()`.
  - `_markedCompleted` — prevents writing the `completed_*` flag multiple times per playback session.

- **`AudioManager`** — singleton that initializes `AudioPlayerHandler` via `AudioService.init()`.
  - Call `AudioManager.init()` once at app startup before using playback.
  - Access the handler via `AudioManager.handler`.

### Media Notification
- Configured in `AudioServiceConfig` inside `AudioManager.init()`.
- The notification shows **Prev track / −30s / Play-Pause / +30s / Next track** controls (compact view: prev / play-pause / next).
- Channel ID: `com.example.flutter_app.audio` — change this if you rename the app package.

---

## Local Storage & Downloads

### `LocalLibrary` (`lib/services/local_library.dart`)
- Owns the on-device library under the app documents dir:
  `library/audio/{id}.mp3`, `library/thumbs/{id}.jpg`, `library/subs/{id}.vtt`,
  and `library/library.json` (the index of `LocalVideo` entries, newest first).
- `ensureInitialized()` must be awaited before use (called at startup in
  `main_scaffold._initAudio`). Path getters (`audioPath/thumbPath/subPath`) are
  synchronous afterward, so the audio handler can resolve files without async.
- `all()`, `contains(id)`, `get(id)`, `addEntry(localVideo)`, `remove(id)`
  (deletes files too).

### `DownloadManager` (`lib/services/download_manager.dart`)
- Singleton (`DownloadManager.instance`). `start(api, url)` is **metadata-first**:
  1. POST `/api/metadata` → set `job.title` + pull the thumbnail to the device
     (so the in-progress row shows title + art before the audio downloads).
  2. POST `/api/download` → poll `/api/progress` until backend `done`.
  3. Pull `/api/audio` (+ thumbnail + subtitle) to local files →
     `LocalLibrary.addEntry(...)` → remove the job.
  If `/api/metadata` is unavailable (older backend) step 1 is skipped and it
  falls back to the original download-first order.
- Wraps the whole run in an Android foreground service
  (`DownloadForegroundService`, see below) so downloads survive backgrounding.
- Exposes `ValueNotifier<List<DownloadJob>> jobs` (`{id, youtubeId, title, stage,
  percent, error}`); the Downloaded tab rebuilds from it. Failed jobs stay until
  `dismiss(jobId)`. This is the only library-side code that touches the backend.

### `DownloadForegroundService` (`lib/services/download_foreground_service.dart`)
- Thin wrapper over `flutter_foreground_task`. `DownloadManager` calls
  `start/update/stop` so an ongoing notification (and thus a foreground service)
  keeps the app process alive while downloads run in the main isolate. The
  service holds no logic — it's purely a process-lifetime anchor. Started when the
  active-job count goes 0→1, stopped when it returns to 0. Notification permission
  is requested once in `MainScaffold.initState`.

## API Service (`lib/services/api_service.dart`)

Constructor: `ApiService(serverUrl, {accessToken})`. All methods include `X-Access-Token` header when token is non-empty.

| Method | HTTP | Path |
|--------|------|------|
| `startDownload(url)` | POST | `/api/download` |
| `getMetadata(url)` | POST | `/api/metadata` (title/channel/duration/thumbnail before audio) |
| `checkHealth()` | GET | `/api/health` → `HealthResult(reachable, tokenRequired, tokenValid)` for the Settings Test button |
| `getProgress(taskId)` | GET | `/api/progress/{taskId}` |
| `getVideos()` | GET | `/api/videos` |
| `getVideoStatuses()` | GET | `/api/videos` (returns `youtube_id`→status map) |
| `getVideoMeta(youtubeId)` | GET | `/api/videos` (single video, filtered) |
| `getChannelVideos(channelId)` | GET | `/api/channel/{channelId}/videos` |
| `resolveChannel(input)` | GET | `/api/channel/resolve?q=…` (URL/@handle → id) |
| `downloadAudioBytes(youtubeId)` | GET | `/api/audio/{youtubeId}` (bytes, with token) |
| `downloadThumbnailBytes(youtubeId)` | GET | `/api/thumbnail/{youtubeId}` (bytes, with token) |
| `deleteVideo(youtubeId)` | DELETE | `/api/videos/{youtubeId}` (legacy; not used by the app) |
| `getSubtitleText(youtubeId)` | GET | `/api/subtitles/{youtubeId}` |
| `audioUrl(youtubeId)` | — | Returns full URL string |
| `thumbnailUrl(youtubeId)` | — | Returns full URL string |

---

## Data Models

### `Video` (`lib/models/video.dart`)
Fields from `GET /api/videos`:
- `youtubeId` — YouTube video ID (11-character string)
- `title`, `channel` — display strings
- `duration` — integer seconds
- `status` — `"done"` for playable tracks
- `createdAt` — `DateTime`

`Video.durationFormatted` returns a human-readable string like `3:45`.

### `SubtitleEntry` (`lib/models/subtitle_entry.dart`)
Parsed from the raw subtitle text returned by `/api/subtitles/{youtubeId}`:
- `text` — subtitle line text
- `start`, `end` — `Duration` values for the line's time range

---

## Player Bar (`lib/widgets/player_bar.dart`)

Shown at the bottom of tabs 1–3.
- Reads state from `AudioManager.handler` using `StreamBuilder` on `playbackState` and `mediaItem`.
- Buttons:
  - **−30s** → calls `handler.skipToPrevious()`
  - **Play/Pause** → calls `handler.play()` or `handler.pause()`
  - **+30s** → calls `handler.skipToNext()`
  - **Next track** → calls `handler.playNextUnplayed()`
- Seek slider uses `handler.seek(Duration(...))`.
- Tapping the bar navigates to Tab 4 (Play tab).

---

## Key Dependencies (`pubspec.yaml`)

| Package | Purpose |
|---------|---------|
| `just_audio` | Audio playback engine |
| `audio_service` | Background playback + media notification |
| `audio_session` | Handles audio focus (pauses on phone call, etc.) |
| `cached_network_image` | Loads and caches thumbnail images |
| `shared_preferences` | Stores server URL, access token, and playback state |
| `http` | HTTP client for API calls |
| `provider` | State management (available but minimal use) |
| `flutter_foreground_task` | Android foreground service keeping downloads alive in the background |

---

## OS Share Integration (`lib/services/share_handler.dart` + `MainActivity.kt`)

The app registers for the Android share sheet via an `ACTION_SEND` (`text/plain`)
`<intent-filter>` on `MainActivity`. Sharing a YouTube link routes by type:

- **Video link** (`watch?v=`, `youtu.be/`, `/shorts/`, `/live/`) → starts the
  normal `DownloadManager.instance.start(...)` download, then calls
  `moveTaskToBack(true)` so the app drops to the background — the user stays in
  whatever app they shared from. (The download runs in the Flutter isolate while
  backgrounded; very long downloads risk the OS killing the process — an accepted
  trade-off of not using a native foreground service.)
- **Channel link** (`/channel/UC…`, `/@handle`, `/c/`, `/user/`) → opens the app,
  switches to the Channel tab, and opens that channel's detail view (resolving the
  id via the same path as a pasted channel).
- **Anything else** → opens the app normally on the Link tab.

Mechanics: `MainActivity.kt` reads the shared text (cold start via
`getInitialShare`, while-running via `onShare` over the `app/share`
`MethodChannel`) and exposes `moveToBackground`. `MainScaffold` wires the handler
in `initState`, classifies the URL with `share_handler.dart`, and hands channel
links to `ChannelTab` through a `ValueNotifier<String?> openRequest`.

## Android Manifest Notes (`android/app/src/main/AndroidManifest.xml`)

- `android:usesCleartextTraffic="true"` — allows HTTP (not just HTTPS) connections. Required for connecting to the NAS over a local network without a certificate.
- `FOREGROUND_SERVICE` + `FOREGROUND_SERVICE_MEDIA_PLAYBACK` — required for background audio on Android 14+.
- `FOREGROUND_SERVICE_DATA_SYNC` + `POST_NOTIFICATIONS` and the `com.pravera.flutter_foreground_task.service.ForegroundService` entry — required by `flutter_foreground_task` so downloads continue while the app is backgrounded.
- The `AudioService` and `MediaButtonReceiver` entries are required by the `audio_service` package.
- The second `<intent-filter>` on `MainActivity` (`ACTION_SEND` / `text/plain`) puts the app in the OS share sheet; `launchMode="singleTop"` means an in-flight share reaches `onNewIntent` instead of restarting the activity.
- **`MainActivity` must extend `com.ryanheise.audioservice.AudioServiceActivity`** (see `MainActivity.kt`), not the plain `FlutterActivity`. Otherwise `AudioService.init()` throws `PlatformException("The Activity class declared in your AndroidManifest.xml is wrong…")` and playback silently never starts. `MainActivity` also overrides `configureFlutterEngine` to register the `app/share` MethodChannel.

---

## Common Changes

### Change the app name
Edit `android/app/src/main/AndroidManifest.xml`: `android:label="YouTube Audio"`.

### Change the app package name
1. Rename the package in `AndroidManifest.xml`.
2. Update `androidNotificationChannelId` in `AudioManager.init()` in `audio_service.dart`.
3. Run `flutter pub get` again.

### Add a new API call
Add a new method to `ApiService` in `lib/services/api_service.dart`, following the same pattern as existing methods. Pass the `ApiService` instance from `main_scaffold.dart` down to the widget that needs it.

### Reset saved state on device
Clear the app's storage via Android Settings → Apps → YouTube Audio → Storage → Clear Data. This resets the server URL, access token, and all playback positions.
