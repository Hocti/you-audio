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

## How to Test Each Tab

**Link tab** — paste a YouTube URL and tap the send icon. The app downloads the audio from the backend and shows progress.

**Downloaded tab** — lists all downloaded tracks. Tap to play; long-press for context menu (Play Next / Delete). Use filter chips (All / Unlistened / Listened) and the sort dropdown to organise.

**Play tab** — shows the current track with a seek bar and speed control (0.5–2.5×). If the video has subtitles, they appear below with the current line highlighted. Tap any line to seek.

**Channel tab** — coming soon (YouTube OAuth login and subscribed channel browsing).

## Background Playback

Audio continues in the background. The notification and lock screen show playback controls. Hardware media buttons (including Bluetooth headset buttons) for play/pause and ±30s skip work from any screen.

## App Architecture

See [flutter_app/CLAUDE.md](CLAUDE.md) for file structure and developer notes.
