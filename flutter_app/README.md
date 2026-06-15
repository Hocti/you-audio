# YouTube Audio Player — Flutter App

An Android app that plays audio from your self-hosted YouTube Audio Downloader backend.

---

## Features

- Paste a YouTube URL and download it as MP3 through your own server.
- Browse downloaded tracks with thumbnails, titles, and channel names.
- Background playback — audio continues when you switch to another app.
- Media notification with play/pause and ±15-second jump controls.
- Saves your playback position, so you can continue where you left off.
- Auto-plays the next unplayed track when the current one finishes.

---

## Requirements

- [Flutter SDK](https://docs.flutter.dev/get-started/install) version 3.0 or higher.
- Android Studio or VS Code with the Flutter plugin.
- A running backend server (see the backend README).
- An Android device or emulator (Android 6.0 / API 23 or higher).

> This app is built for Android only. iOS is not configured.

---

## Project Setup

**Step 1 — Get the code**

```bash
git clone <your-repo-url>
cd youtube-audio/flutter_app
```

**Step 2 — Install dependencies**

```bash
flutter pub get
```

**Step 3 — Verify Flutter is ready**

```bash
flutter doctor
```

Fix any issues shown in red before continuing.

---

## No Files Need Editing

Unlike the backend, you do **not** need to edit any files before running the app.

The server URL (e.g. `http://192.168.1.100:8000`) is entered inside the app on the first screen, and saved to the device. If you need to change it, just clear the app storage and restart.

---

## Running on an Emulator

**Step 1 — Create an emulator in Android Studio**

Open Android Studio → `Tools` → `Device Manager` → `Create Device`.

Choose a phone model (e.g. Pixel 6), then choose a system image (API 33 or 34 is recommended).

**Step 2 — Start the emulator**

Click the play button next to your device in Device Manager, or run:

```bash
flutter emulators --launch <emulator-id>
```

To see available emulators:

```bash
flutter emulators
```

**Step 3 — Run the app**

```bash
flutter run
```

Flutter will detect the running emulator and install the app automatically.

> **Note on connecting to the backend from an emulator:**
> The emulator runs on its own virtual network. You cannot use `localhost` or `127.0.0.1` to reach your computer's backend. Use your computer's real local IP address instead (e.g. `http://192.168.1.50:8000`). Find your IP with `ipconfig` (Windows) or `ifconfig` / `ip a` (Mac/Linux).

---

## Running on a Real Android Device

**Step 1 — Enable Developer Options on the device**

Go to `Settings` → `About phone` → tap `Build number` 7 times.

**Step 2 — Enable USB Debugging**

Go to `Settings` → `Developer options` → turn on `USB debugging`.

**Step 3 — Connect the device**

Connect the phone to your computer with a USB cable.

Accept the "Allow USB debugging" prompt on the phone.

**Step 4 — Verify the device is detected**

```bash
flutter devices
```

Your phone should appear in the list.

**Step 5 — Run the app**

```bash
flutter run
```

**Step 6 — Enter the backend URL in the app**

On the first screen, enter your backend server address. Examples:
- `http://192.168.1.100:8000` — if the backend is on your NAS or home server.
- `http://192.168.1.50:8000` — if the backend is running on your laptop.

The phone and the server must be on the same Wi-Fi network.

---

## Building a Release APK

To install the app on a phone without a computer connection:

```bash
flutter build apk --release
```

The APK file will be at:

```
build/app/outputs/flutter-apk/app-release.apk
```

Transfer this file to your phone (via Google Drive, USB, etc.) and open it to install.

> You may need to allow installation from unknown sources in `Settings` → `Security`.

---

## App Structure (3 Pages)

### Page 1 — Server Setup
Enter your backend URL. The app saves it and skips this page next time.

### Page 2 — Download
Paste a YouTube URL. The app automatically sends it to the backend and shows download progress. When done, the track appears in the list.

### Page 3 — Audio List
Browse all downloaded tracks. Tap any track to start playing. The bottom player bar is always visible on this page.

### Bottom Player Bar
Shows the current track title. Buttons:
- **◀◀** — jump back 15 seconds
- **⏸ / ▶** — pause or resume
- **▶▶** — jump forward 15 seconds
- **⏭** — play the next unplayed track

---

## Troubleshooting

**"Cannot connect to server" or loading fails**

- Make sure the backend is running (`http://your-server-ip:8000/api/health` should return `{"status":"ok"}`).
- Make sure your phone is on the same Wi-Fi as the server.
- Make sure the URL in the app does **not** have a trailing slash.

**App cannot find Flutter SDK**

Make sure `flutter` is in your PATH. Run `flutter doctor` to check.

**Audio does not play in background**

This requires Android to allow background activity for the app. On some Android skins (MIUI, One UI, etc.), you may need to go to `Settings` → `Battery` → find the app → disable battery optimization.

**"Cleartext HTTP traffic not permitted" error**

The `AndroidManifest.xml` already includes `android:usesCleartextTraffic="true"` which allows HTTP connections. If you see this error, make sure you are running a debug or release build from this repository, not from a default Flutter template.
