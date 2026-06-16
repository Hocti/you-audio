# YouTube Audio — Flutter App

An Android audio player that downloads YouTube videos as MP3 from the self-hosted backend.

## Prerequisites

- Flutter 3.x (`flutter --version`)
- Android device or emulator connected
- The backend running and accessible on your local network

## Setup

1. Install dependencies:
   ```bash
   flutter pub get
   ```

2. Connect an Android device (enable USB debugging) or start an Android emulator.

3. Run the app:
   ```bash
   flutter run
   ```

4. On first launch, enter your backend URL (e.g. `http://192.168.1.100:8000`) and optionally your access token.

## Debugging on an Android Emulator

You can develop and debug entirely on an Android emulator — no physical device needed.

1. List available emulators (AVDs):
   ```bash
   flutter emulators
   ```
   If none are listed, create one in Android Studio (Device Manager → Create
   Device), or `flutter emulators --create`.

2. Launch one (or just open it from Android Studio):
   ```bash
   flutter emulators --launch <emulator_id>
   ```

3. Confirm Flutter sees it, then run:
   ```bash
   flutter devices
   flutter run
   ```

4. While `flutter run` is attached, use hot reload/restart:
   - `r` — hot reload (keeps state)
   - `R` — hot restart
   - `q` — quit

**Reaching a backend running on your computer:** inside the emulator,
`localhost` refers to the emulator itself, not your machine. Use the special
host alias **`http://10.0.2.2:8000`** as the backend URL in the app's setup
screen (`10.0.2.2` maps to the host's `localhost` from the Android emulator).
For `make run` the backend listens on `0.0.0.0:8000`, so this works directly.

> Tip: the backend `Makefile`'s `run` target uses SQLite + your local `.env`, so
> `cd backend && make run` is the quickest way to have something for the emulator
> to talk to.

## How to Test Each Tab

**Download tab** — tap **Paste & Download** to download the clipboard's YouTube URL. The backend converts it, then the app pulls the files to the device; progress shows in the Downloaded tab.

**Channel tab** — paste a channel ID or `/channel/UC…` URL to list a channel's latest videos; videos already downloaded/downloading show a status icon. Tap the star to bookmark a channel; bookmarks appear under the paste button.

**Downloaded tab** — lists tracks stored on this device (works offline) plus any in-progress downloads. Tap to play; long-press for context menu (Play Next / Delete from device). Use filter chips (All / Unlistened / Listened) and the sort dropdown to organise.

**Play tab** — shows the current track with a seek bar and speed control (0.5–2.5×). If the track has subtitles, they appear below with the current line highlighted. Tap any line to seek.

## Background Playback

Audio continues in the background. The notification and lock screen show playback controls. Hardware media buttons (including Bluetooth headset buttons) for play/pause and ±30s skip work from any screen.

## App Architecture

See [flutter_app/CLAUDE.md](CLAUDE.md) for file structure and developer notes.
