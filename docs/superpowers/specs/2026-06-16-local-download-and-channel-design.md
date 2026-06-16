# Local Download + Channel Improvements — Design

Date: 2026-06-16

Four pieces, implemented in order B → D → C → A.

## A. Local download & offline playback (core change)

**Goal:** The app downloads the backend's MP3 + thumbnail + subtitles to device
storage and plays the local file. The Downloaded tab becomes a local library
that never contacts the backend (so server errors are impossible there), except
to show/poll records still downloading.

**Decisions:** auto-download right after backend finishes; store the index as a
JSON file (no sqflite).

**New Flutter pieces (focused files):**
- `models/local_video.dart` — `LocalVideo {youtubeId, title, channel, duration,
  hasSubtitle, downloadedAt}` + local path helpers.
- `services/local_library.dart` — owns `getApplicationDocumentsDirectory()/library/`
  with `audio/{id}.mp3`, `thumbs/{id}.jpg`, `subs/{id}.vtt`, and `library.json`
  (the index). API: `load()`, `contains(id)`, `all()`, `remove(id)`,
  `audioPath/thumbPath/subPath(id)`, `addEntry(meta)`.
- `services/download_manager.dart` — singleton orchestrating one job at a time:
  POST `/api/download` → poll `/api/progress` → on backend `done`, GET
  `/api/audio|thumbnail|subtitles/{id}` (with `X-Access-Token`) → write files →
  add to `LocalLibrary`. Exposes a `ValueNotifier<List<DownloadJob>>`
  (`{id, title, stage, percent}`) so the UI shows in-progress rows. This is the
  ONLY part that touches the backend from the library side.

**Flow changes:**
- Link tab: calls `DownloadManager.start(url)`; status text follows the stages
  (checking → downloading → converting → saving → done).
- Downloaded tab: renders `LocalLibrary.all()` (offline) + active jobs from
  `DownloadManager`. Drops `GET /api/videos`. Delete removes local files only.
- Playback: `playVideo` uses `_player.setFilePath(localLibrary.audioPath(id))`
  (local, no token, offline). Subtitles read the local `.vtt`; thumbnails use
  `Image.file`.

**Out of scope:** resuming interrupted downloads across app restarts; backend
copy management (backend keeps its own cache, unchanged).

## B. backend/example.md — channel endpoint

Add a documented, verified `curl` example for
`GET /api/channel/{channel_id}/videos` (works with a bare `UC…` id; returns up
to 50 latest videos; cached 1h). Note that a URL or `@handle` is NOT accepted.

## C. Channel page

- Paste accepts a bare `UC…` id or any URL containing `/channel/UC…`; extract
  via regex `UC[\w-]{22}`. No match → friendly error. (`@handle` / `/c/` /
  `/user/` not supported yet — would need backend resolution.)
- Below the paste button: a scrollable list of bookmarked channels stored in
  `shared_preferences` key `bookmarked_channels` (JSON `[{id, name}]`); tap →
  detail.
- Detail AppBar: channel name on the left, star toggle on the right (enabled
  once videos load and the channel name is known) to add/remove the bookmark.

## D. Android emulator + README

Yes, the Android emulator works for debugging. Add a README section:
`flutter emulators`, `flutter emulators --launch <id>`, `flutter run`, hot
reload (`r`/`R`), and using `http://10.0.2.2:8000` to reach a backend on the
host machine.
