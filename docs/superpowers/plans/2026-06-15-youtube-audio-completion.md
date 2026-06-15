# YouTube Audio — Completion Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Complete the YouTube Audio project — fix critical bugs, add missing backend endpoints, restructure the Flutter app into a proper 4-tab layout, and add all missing playback/management features.

**Architecture:** Backend is a FastAPI + yt-dlp + PostgreSQL service inside Docker. Frontend is a Flutter Android app using `just_audio` + `audio_service` for background playback. The Channel tab (YouTube login) is deferred — skip it for now.

**Tech Stack:** Python/FastAPI/yt-dlp/SQLAlchemy (backend); Flutter/Dart, just_audio, audio_service (frontend)

---

## File Map

### Backend (new/modified files)
| File | Change |
|------|--------|
| `backend/app/downloader.py` | Add subtitle download in `_sync_download` |
| `backend/app/models.py` | Add `subtitle_path` column |
| `backend/app/schemas.py` | Add `subtitle_path`, `has_subtitle` to `VideoOut` |
| `backend/app/main.py` | Add `DELETE /api/videos/{youtube_id}`, `GET /api/subtitles/{youtube_id}`, access token middleware |
| `backend/Makefile` | run-dev, build-image, run-image targets |
| `backend/.env.example` | `ACCESS_TOKEN`, `DATA_DIR`, `DATABASE_URL` |
| `backend/docker-compose.yml` | Add `ACCESS_TOKEN` env var |

### Frontend (new/modified files)
| File | Change |
|------|--------|
| `flutter_app/lib/models/video.dart` | Fix id→youtube_id; add hasSubtitle, isOpened, isCompleted, playProgress fields |
| `flutter_app/lib/services/api_service.dart` | Fix getVideos() parsing; add deleteVideo(), getSubtitle(); add access token header |
| `flutter_app/lib/services/audio_service.dart` | Change skip to ±30s; add speed control; add 95%-completion detection |
| `flutter_app/lib/config/app_config.dart` | NEW — read server URL + token from SharedPreferences/env |
| `flutter_app/lib/main.dart` | Replace ServerSetupPage home with 4-tab scaffold |
| `flutter_app/lib/pages/main_scaffold.dart` | NEW — BottomNavigationBar with 4 tabs |
| `flutter_app/lib/pages/link_tab.dart` | Rename/refactor from download_page.dart |
| `flutter_app/lib/pages/channel_tab.dart` | NEW — placeholder "Coming soon" page |
| `flutter_app/lib/pages/downloaded_tab.dart` | Refactor from audio_list_page.dart + add delete/context-menu/sort/filter |
| `flutter_app/lib/pages/play_tab.dart` | NEW — full-screen player with speed control + subtitle display |
| `flutter_app/lib/pages/server_setup_page.dart` | Minor: also ask for access token |
| `flutter_app/lib/widgets/player_bar.dart` | Add speed button that opens Play tab |
| `flutter_app/lib/models/subtitle_entry.dart` | NEW — parse SRT/VTT cue into {start, end, text} |
| `flutter_app/pubspec.yaml` | No new deps needed |

---

## Task 1: Fix Backend — Video ID Bug in Schemas

The frontend needs to distinguish between the DB UUID (`id`) and the YouTube video ID (`youtube_id`). The audio/thumbnail URL paths use the YouTube ID. Currently `VideoOut.id` is the UUID — rename to avoid confusion.

**Files:**
- Modify: `backend/app/schemas.py`

- [ ] **Step 1: Update `VideoOut` to expose `youtube_id` as the primary client-facing ID**

  In `backend/app/schemas.py`, change `VideoOut` so clients get a clear `youtube_id` field and the UUID is still present but renamed:

  ```python
  class VideoOut(BaseModel):
      db_id: uuid.UUID = Field(alias=None)        # internal DB UUID
      youtube_id: str                              # used in all URL paths
      title: str | None = None
      channel_name: str | None = None
      duration: int | None = None
      thumbnail_url: str | None = None
      has_subtitle: bool = False
      subtitle_path: str | None = None
      file_size: int | None = None
      status: str
      error_message: str | None = None
      created_at: datetime.datetime

      model_config = {"from_attributes": True, "populate_by_name": True}

      @classmethod
      def model_validate(cls, obj, *args, **kwargs):
          data = super().model_validate(obj, *args, **kwargs)
          return data
  ```

  Actually simpler — just add `youtube_id` field explicitly (it's already on the model) and keep `id` as UUID but also expose it. The key fix is: make sure `youtube_id` is present so the frontend can use it:

  ```python
  # backend/app/schemas.py
  from __future__ import annotations

  import datetime
  import uuid

  from pydantic import BaseModel


  class DownloadRequest(BaseModel):
      url: str


  class VideoOut(BaseModel):
      id: uuid.UUID
      youtube_id: str
      title: str | None = None
      channel_name: str | None = None
      duration: int | None = None
      thumbnail_url: str | None = None
      has_subtitle: bool = False
      subtitle_path: str | None = None
      mp3_path: str | None = None
      file_size: int | None = None
      status: str
      error_message: str | None = None
      created_at: datetime.datetime

      model_config = {"from_attributes": True}


  class DownloadResponse(BaseModel):
      cached: bool
      task_id: str
      video: VideoOut


  class ProgressResponse(BaseModel):
      task_id: str
      status: str
      progress_percent: float
      message: str


  class VideoListResponse(BaseModel):
      videos: list[VideoOut]
      total: int
  ```

- [ ] **Step 2: Commit**
  ```bash
  git add backend/app/schemas.py
  git commit -m "fix: add has_subtitle field to VideoOut schema"
  ```

---

## Task 2: Add `subtitle_path` Column to DB Model

**Files:**
- Modify: `backend/app/models.py`

- [ ] **Step 1: Add `subtitle_path` column**

  In `backend/app/models.py`, add after `thumbnail_path`:

  ```python
  subtitle_path: Mapped[str | None] = mapped_column(Text, nullable=True)
  ```

  Full updated `Video` class:

  ```python
  class Video(Base):
      __tablename__ = "videos"

      id: Mapped[uuid.UUID] = mapped_column(
          UUID(as_uuid=True), primary_key=True, default=uuid.uuid4
      )
      youtube_id: Mapped[str] = mapped_column(String(20), unique=True, index=True, nullable=False)
      title: Mapped[str | None] = mapped_column(Text, nullable=True)
      channel_name: Mapped[str | None] = mapped_column(Text, nullable=True)
      duration: Mapped[int | None] = mapped_column(Integer, nullable=True)
      thumbnail_url: Mapped[str | None] = mapped_column(Text, nullable=True)
      thumbnail_path: Mapped[str | None] = mapped_column(Text, nullable=True)
      subtitle_path: Mapped[str | None] = mapped_column(Text, nullable=True)
      mp3_path: Mapped[str | None] = mapped_column(Text, nullable=True)
      file_size: Mapped[int | None] = mapped_column(BigInteger, nullable=True)
      status: Mapped[str] = mapped_column(
          String(20), nullable=False, default="pending"
      )
      error_message: Mapped[str | None] = mapped_column(Text, nullable=True)
      created_at: Mapped[datetime.datetime] = mapped_column(
          DateTime(timezone=True), server_default=func.now(), nullable=False
      )
  ```

- [ ] **Step 2: Commit**
  ```bash
  git add backend/app/models.py
  git commit -m "feat: add subtitle_path column to Video model"
  ```

---

## Task 3: Download Subtitles in `downloader.py`

yt-dlp can download subtitles. We want: Chinese (zh, zh-Hant, zh-Hans, zh-TW, zh-HK, zh-CN) and English (en). Download as `.vtt` (WebVTT) — Flutter will parse this.

**Files:**
- Modify: `backend/app/downloader.py`

- [ ] **Step 1: Add subtitle download options to `_sync_download`**

  In `_sync_download`, add subtitle options to `ydl_opts`:

  ```python
  ydl_opts: dict[str, Any] = {
      "format": "bestaudio/best",
      "outtmpl": output_template,
      "postprocessors": [
          {
              "key": "FFmpegExtractAudio",
              "preferredcodec": "mp3",
              "preferredquality": "192",
          }
      ],
      # Subtitles
      "writesubtitles": True,
      "writeautomaticsub": True,
      "subtitleslangs": ["zh", "zh-Hant", "zh-Hans", "zh-TW", "zh-HK", "zh-CN", "en"],
      "subtitlesformat": "vtt",
      "progress_hooks": [_progress_hook],
      "postprocessor_hooks": [_postprocessor_hook],
      "quiet": True,
      "no_warnings": True,
      "noplaylist": True,
      "overwrites": True,
  }
  ```

  Then after `mp3_path` is calculated, find the first subtitle file that exists:

  ```python
  # Find subtitle file (prefer Chinese, fallback to English)
  subtitle_langs = ["zh", "zh-Hant", "zh-Hans", "zh-TW", "zh-HK", "zh-CN", "en"]
  subtitle_path: str | None = None
  for lang in subtitle_langs:
      candidate = AUDIO_DIR / f"{youtube_id}.{lang}.vtt"
      if candidate.exists():
          subtitle_path = str(candidate)
          break

  return {
      "title": info.get("title"),
      "channel_name": info.get("channel") or info.get("uploader"),
      "duration": info.get("duration"),
      "thumbnail_url": info.get("thumbnail"),
      "mp3_path": str(mp3_path),
      "file_size": file_size,
      "subtitle_path": subtitle_path,
  }
  ```

- [ ] **Step 2: Save `subtitle_path` in `run_download`**

  In `run_download`, inside the DB update block, add:

  ```python
  row.subtitle_path = result.get("subtitle_path")
  ```

  So the full update block becomes:

  ```python
  row.title = result["title"]
  row.channel_name = result["channel_name"]
  row.duration = result["duration"]
  row.thumbnail_url = result["thumbnail_url"]
  row.thumbnail_path = thumb_path
  row.subtitle_path = result.get("subtitle_path")
  row.mp3_path = result["mp3_path"]
  row.file_size = result["file_size"]
  row.status = "done"
  ```

- [ ] **Step 3: Compute `has_subtitle` for `VideoOut`**

  `has_subtitle` is a computed property — it's `True` when `subtitle_path` is not None and the file exists. Add this to `schemas.py`:

  ```python
  class VideoOut(BaseModel):
      ...
      has_subtitle: bool = False

      @classmethod
      def model_validate(cls, obj, *args, **kwargs):
          instance = super().model_validate(obj, *args, **kwargs)
          if instance.subtitle_path:
              from pathlib import Path
              instance.has_subtitle = Path(instance.subtitle_path).exists()
          return instance
  ```

- [ ] **Step 4: Commit**
  ```bash
  git add backend/app/downloader.py backend/app/schemas.py
  git commit -m "feat: download subtitles (zh/en) with yt-dlp, expose has_subtitle"
  ```

---

## Task 4: Add Delete and Subtitle Endpoints + Access Token Auth

**Files:**
- Modify: `backend/app/main.py`
- Create: `backend/.env.example`

- [ ] **Step 1: Add access token middleware**

  At the top of `main.py`, after imports, add:

  ```python
  import os
  from fastapi import Header

  ACCESS_TOKEN = os.getenv("ACCESS_TOKEN", "")

  async def verify_token(x_access_token: str | None = Header(default=None)):
      if ACCESS_TOKEN and x_access_token != ACCESS_TOKEN:
          raise HTTPException(status_code=401, detail="Invalid access token")
  ```

  Then add `Depends(verify_token)` to every route that should be protected. For simplicity, add it to all routes except `/api/health`:

  Example for `/api/download`:
  ```python
  @app.post("/api/download", response_model=DownloadResponse)
  async def download(
      body: DownloadRequest,
      session: AsyncSession = Depends(get_session),
      _: None = Depends(verify_token),
  ):
  ```

  Repeat for `/api/progress/{task_id}`, `/api/audio/{video_id}`, `/api/thumbnail/{video_id}`, `/api/videos`, and the new endpoints below.

  If `ACCESS_TOKEN` is empty (not set), the check is skipped — so existing deployments without auth still work.

- [ ] **Step 2: Add `DELETE /api/videos/{youtube_id}` endpoint**

  Add after the `/api/videos` route:

  ```python
  @app.delete("/api/videos/{youtube_id}", status_code=204)
  async def delete_video(
      youtube_id: str,
      session: AsyncSession = Depends(get_session),
      _: None = Depends(verify_token),
  ):
      stmt = select(Video).where(Video.youtube_id == youtube_id)
      row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
      if not row:
          raise HTTPException(status_code=404, detail="Video not found")

      # Delete files from disk
      for path_attr in (row.mp3_path, row.thumbnail_path, row.subtitle_path):
          if path_attr:
              p = Path(path_attr)
              if p.exists():
                  p.unlink()

      await session.delete(row)
      await session.commit()
  ```

- [ ] **Step 3: Add `GET /api/subtitles/{youtube_id}` endpoint**

  ```python
  @app.get("/api/subtitles/{youtube_id}")
  async def serve_subtitles(
      youtube_id: str,
      session: AsyncSession = Depends(get_session),
      _: None = Depends(verify_token),
  ):
      stmt = select(Video).where(Video.youtube_id == youtube_id)
      row: Video | None = (await session.execute(stmt)).scalar_one_or_none()
      if not row or not row.subtitle_path:
          raise HTTPException(status_code=404, detail="Subtitles not found")

      path = Path(row.subtitle_path)
      if not path.exists():
          raise HTTPException(status_code=404, detail="Subtitle file missing from disk")

      return FileResponse(path=path, media_type="text/vtt")
  ```

- [ ] **Step 4: Create `.env.example`**

  ```
  # backend/.env.example
  DATABASE_URL=postgresql+asyncpg://ytaudio:ytaudio@db:5432/ytaudio
  DATA_DIR=/data
  ACCESS_TOKEN=change_me_to_a_random_secret
  ```

- [ ] **Step 5: Add `ACCESS_TOKEN` to `docker-compose.yml`**

  In `backend/docker-compose.yml`, add to the `backend` service environment:

  ```yaml
  environment:
    DATABASE_URL: "postgresql+asyncpg://ytaudio:ytaudio@db:5432/ytaudio"
    DATA_DIR: "/data"
    ACCESS_TOKEN: ""   # Set this to a secret string to enable auth
  ```

- [ ] **Step 6: Commit**
  ```bash
  git add backend/app/main.py backend/.env.example backend/docker-compose.yml
  git commit -m "feat: add delete/subtitle endpoints and optional access token auth"
  ```

---

## Task 5: Add Backend Run Scripts (Makefile)

**Files:**
- Create: `backend/Makefile`

- [ ] **Step 1: Create `backend/Makefile`**

  ```makefile
  .PHONY: run build run-docker stop

  # Run directly without Docker (requires Python 3.11+, ffmpeg, yt-dlp installed locally)
  run:
  	DATABASE_URL=sqlite+aiosqlite:///./ytaudio.db \
  	DATA_DIR=./data \
  	uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

  # Build the Docker image
  build:
  	docker compose build

  # Run with Docker (builds if needed, runs in foreground so you see logs)
  run-docker:
  	docker compose up --build

  # Stop Docker containers
  stop:
  	docker compose down
  ```

  Note: The `run` target uses SQLite for local dev (aiosqlite). This requires adding `aiosqlite` to `requirements.txt`.

- [ ] **Step 2: Add `aiosqlite` to `requirements.txt`**

  Open `backend/requirements.txt` and add `aiosqlite` so the local dev run works:

  ```
  aiosqlite
  ```

- [ ] **Step 3: Commit**
  ```bash
  git add backend/Makefile backend/requirements.txt
  git commit -m "feat: add Makefile with run/build/run-docker targets"
  ```

---

## Task 6: Fix Flutter `Video` Model and `ApiService`

These are the two critical runtime crashes.

**Files:**
- Modify: `flutter_app/lib/models/video.dart`
- Modify: `flutter_app/lib/services/api_service.dart`

- [ ] **Step 1: Fix `Video` model**

  Replace `flutter_app/lib/models/video.dart` entirely:

  ```dart
  class Video {
    final String youtubeId;   // used in all URL paths
    final String title;
    final String channel;
    final int duration;       // seconds
    final String? thumbnailUrl;
    final bool hasSubtitle;

    const Video({
      required this.youtubeId,
      required this.title,
      required this.channel,
      required this.duration,
      this.thumbnailUrl,
      this.hasSubtitle = false,
    });

    factory Video.fromJson(Map<String, dynamic> json) {
      return Video(
        youtubeId: json['youtube_id'] as String? ?? '',
        title: json['title'] as String? ?? 'Unknown',
        channel: json['channel_name'] as String? ?? 'Unknown',
        duration: json['duration'] as int? ?? 0,
        thumbnailUrl: json['thumbnail_url'] as String?,
        hasSubtitle: json['has_subtitle'] as bool? ?? false,
      );
    }

    String get durationFormatted {
      final h = duration ~/ 3600;
      final m = (duration % 3600) ~/ 60;
      final s = duration % 60;
      if (h > 0) {
        return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      }
      return '$m:${s.toString().padLeft(2, '0')}';
    }
  }
  ```

- [ ] **Step 2: Fix `ApiService`**

  Replace `flutter_app/lib/services/api_service.dart` entirely:

  ```dart
  import 'dart:convert';
  import 'package:http/http.dart' as http;
  import '../models/video.dart';

  class ApiService {
    final String serverUrl;
    final String accessToken;

    ApiService(this.serverUrl, {this.accessToken = ''});

    String get _base => serverUrl.endsWith('/')
        ? serverUrl.substring(0, serverUrl.length - 1)
        : serverUrl;

    Map<String, String> get _headers => {
          'Content-Type': 'application/json',
          if (accessToken.isNotEmpty) 'X-Access-Token': accessToken,
        };

    Future<Map<String, dynamic>> startDownload(String youtubeUrl) async {
      final resp = await http.post(
        Uri.parse('$_base/api/download'),
        headers: _headers,
        body: jsonEncode({'url': youtubeUrl}),
      );
      if (resp.statusCode == 200) return jsonDecode(resp.body);
      throw Exception('Download failed: ${resp.statusCode}');
    }

    Future<Map<String, dynamic>> getProgress(String taskId) async {
      final resp = await http.get(
        Uri.parse('$_base/api/progress/$taskId'),
        headers: _headers,
      );
      if (resp.statusCode == 200) return jsonDecode(resp.body);
      throw Exception('Progress failed: ${resp.statusCode}');
    }

    Future<List<Video>> getVideos() async {
      final resp = await http.get(
        Uri.parse('$_base/api/videos'),
        headers: _headers,
      );
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        final list = body['videos'] as List<dynamic>;
        return list.map((j) => Video.fromJson(j as Map<String, dynamic>)).toList();
      }
      throw Exception('getVideos failed: ${resp.statusCode}');
    }

    Future<void> deleteVideo(String youtubeId) async {
      final resp = await http.delete(
        Uri.parse('$_base/api/videos/$youtubeId'),
        headers: _headers,
      );
      if (resp.statusCode != 204) {
        throw Exception('Delete failed: ${resp.statusCode}');
      }
    }

    Future<String> getSubtitleText(String youtubeId) async {
      final resp = await http.get(
        Uri.parse('$_base/api/subtitles/$youtubeId'),
        headers: _headers,
      );
      if (resp.statusCode == 200) return resp.body;
      throw Exception('No subtitles: ${resp.statusCode}');
    }

    String audioUrl(String youtubeId) => '$_base/api/audio/$youtubeId';
    String thumbnailUrl(String youtubeId) => '$_base/api/thumbnail/$youtubeId';
  }
  ```

- [ ] **Step 3: Update all call sites that used `video.id` to use `video.youtubeId`**

  In `flutter_app/lib/services/audio_service.dart`:
  - `final url = '$_serverUrl/api/audio/${video.id}'` → `final url = '$_serverUrl/api/audio/${video.youtubeId}'`
  - `artUri: Uri.parse('$_serverUrl/api/thumbnail/${video.id}')` → `...'${video.youtubeId}'`
  - `id: video.id` in `MediaItem` → `id: video.youtubeId`
  - `_savePosition(_currentVideo!.id, ...)` → `_savePosition(_currentVideo!.youtubeId, ...)`
  - `_getSavedPosition(video.id)` → `_getSavedPosition(video.youtubeId)`
  - `prefs.getInt('progress_${video.id}')` → `prefs.getInt('progress_${video.youtubeId}')`
  - `currentVideo?.id == video.id` → `currentVideo?.youtubeId == video.youtubeId`

  In `flutter_app/lib/pages/audio_list_page.dart`:
  - `prefs.getInt('progress_${v.id}')` → `prefs.getInt('progress_${v.youtubeId}')`
  - `progressMap[v.id]` → `progressMap[v.youtubeId]`
  - `_apiService.getThumbnailUrl(video.id)` → `_apiService.thumbnailUrl(video.youtubeId)`
  - `AudioManager.handler.currentVideo?.id == video.id` → `...youtubeId == video.youtubeId`

- [ ] **Step 4: Commit**
  ```bash
  git add flutter_app/lib/models/video.dart flutter_app/lib/services/api_service.dart \
      flutter_app/lib/services/audio_service.dart flutter_app/lib/pages/audio_list_page.dart
  git commit -m "fix: use youtube_id for URLs, fix getVideos() JSON parsing"
  ```

---

## Task 7: Add `ServerSetupPage` Access Token Field

The server setup page should also collect the access token.

**Files:**
- Modify: `flutter_app/lib/pages/server_setup_page.dart`

- [ ] **Step 1: Read the current server_setup_page.dart**

  Read the file to understand current implementation before editing.

- [ ] **Step 2: Add token text field and save/load it**

  Add a second `TextEditingController` for the token. Save it to `SharedPreferences` under key `access_token`. Load it on `initState`. Pass both values when navigating to `DownloadPage`.

  Key changes:
  1. Add `_tokenController = TextEditingController()`
  2. In `initState`, load `prefs.getString('access_token') ?? ''` into the controller
  3. Add a `TextField` below the URL field: label "Access Token (optional)", obscure text
  4. On submit/save: `prefs.setString('access_token', _tokenController.text.trim())`
  5. Navigate to `DownloadPage(serverUrl: url, accessToken: token)`

- [ ] **Step 3: Update `DownloadPage` constructor to accept `accessToken`**

  In `download_page.dart`, add `final String accessToken;` to the widget, pass it to `ApiService(widget.serverUrl, accessToken: widget.accessToken)`, and pass it to `AudioListPage`.

- [ ] **Step 4: Commit**
  ```bash
  git add flutter_app/lib/pages/server_setup_page.dart flutter_app/lib/pages/download_page.dart
  git commit -m "feat: collect access token in setup page, pass to API calls"
  ```

---

## Task 8: Restructure to 4-Tab Layout

Replace the current page-navigation structure with a `BottomNavigationBar` with 4 tabs: Link, Channel, Downloaded, Play.

**Files:**
- Create: `flutter_app/lib/pages/main_scaffold.dart`
- Create: `flutter_app/lib/pages/channel_tab.dart`
- Create: `flutter_app/lib/pages/play_tab.dart` (stub — full implementation in Task 10)
- Modify: `flutter_app/lib/main.dart`
- Modify: `flutter_app/lib/pages/download_page.dart` (strip Scaffold, become a tab body)
- Modify: `flutter_app/lib/pages/audio_list_page.dart` (strip Scaffold, become a tab body)

- [ ] **Step 1: Create `main_scaffold.dart`**

  ```dart
  // flutter_app/lib/pages/main_scaffold.dart
  import 'package:flutter/material.dart';
  import '../services/audio_service.dart';
  import '../services/api_service.dart';
  import '../widgets/player_bar.dart';
  import 'link_tab.dart';
  import 'channel_tab.dart';
  import 'downloaded_tab.dart';
  import 'play_tab.dart';

  class MainScaffold extends StatefulWidget {
    final String serverUrl;
    final String accessToken;

    const MainScaffold({
      super.key,
      required this.serverUrl,
      required this.accessToken,
    });

    @override
    State<MainScaffold> createState() => _MainScaffoldState();
  }

  class _MainScaffoldState extends State<MainScaffold> {
    int _currentIndex = 0;
    late final ApiService _api;

    @override
    void initState() {
      super.initState();
      _api = ApiService(widget.serverUrl, accessToken: widget.accessToken);
      _initAudio();
    }

    Future<void> _initAudio() async {
      final handler = await AudioManager.init();
      handler.setServerUrl(widget.serverUrl);
    }

    void _goToPlay() => setState(() => _currentIndex = 3);

    @override
    Widget build(BuildContext context) {
      final tabs = [
        LinkTab(api: _api),
        const ChannelTab(),
        DownloadedTab(api: _api, onPlayTap: _goToPlay),
        const PlayTab(),
      ];

      return Scaffold(
        body: IndexedStack(
          index: _currentIndex,
          children: tabs,
        ),
        bottomNavigationBar: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const PlayerBar(),
            NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: (i) => setState(() => _currentIndex = i),
              destinations: const [
                NavigationDestination(icon: Icon(Icons.link), label: 'Link'),
                NavigationDestination(icon: Icon(Icons.subscriptions), label: 'Channel'),
                NavigationDestination(icon: Icon(Icons.library_music), label: 'Downloaded'),
                NavigationDestination(icon: Icon(Icons.play_circle), label: 'Play'),
              ],
            ),
          ],
        ),
      );
    }
  }
  ```

- [ ] **Step 2: Create `channel_tab.dart` placeholder**

  ```dart
  // flutter_app/lib/pages/channel_tab.dart
  import 'package:flutter/material.dart';

  class ChannelTab extends StatelessWidget {
    const ChannelTab({super.key});

    @override
    Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(title: const Text('Channel')),
        body: const Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.subscriptions_outlined, size: 64),
              SizedBox(height: 16),
              Text('YouTube login coming soon'),
            ],
          ),
        ),
      );
    }
  }
  ```

- [ ] **Step 3: Create stub `play_tab.dart`**

  ```dart
  // flutter_app/lib/pages/play_tab.dart
  import 'package:flutter/material.dart';
  import '../services/audio_service.dart';

  class PlayTab extends StatelessWidget {
    const PlayTab({super.key});

    @override
    Widget build(BuildContext context) {
      return Scaffold(
        appBar: AppBar(title: const Text('Now Playing')),
        body: const Center(child: Text('Player coming in next task')),
      );
    }
  }
  ```

- [ ] **Step 4: Rename `download_page.dart` → `link_tab.dart`, strip outer Scaffold**

  Create `flutter_app/lib/pages/link_tab.dart`. Extract the body content (the download form) into a Scaffold with its own AppBar. It now receives `ApiService` instead of `serverUrl`:

  ```dart
  // flutter_app/lib/pages/link_tab.dart
  import 'dart:async';
  import 'package:flutter/material.dart';
  import '../services/api_service.dart';

  class LinkTab extends StatefulWidget {
    final ApiService api;
    const LinkTab({super.key, required this.api});

    @override
    State<LinkTab> createState() => _LinkTabState();
  }
  ```

  Move all logic from `_DownloadPageState` into `_LinkTabState`. Remove the navigation buttons for "Change Server" and "Browse Library" (they're now tabs). Remove `PlayerBar` from body (it's in `MainScaffold`). Keep everything else the same.

- [ ] **Step 5: Rename `audio_list_page.dart` → `downloaded_tab.dart`**

  Create `flutter_app/lib/pages/downloaded_tab.dart`. Same content as `audio_list_page.dart` but:
  - Constructor takes `ApiService api` and `VoidCallback onPlayTap`
  - Remove `PlayerBar` from body (handled by `MainScaffold`)
  - Keep all existing list logic

- [ ] **Step 6: Update `main.dart` to go straight to `MainScaffold` after setup**

  In `server_setup_page.dart`, replace the `Navigator.pushReplacement` to `DownloadPage` with `MainScaffold`:

  ```dart
  Navigator.pushReplacement(
    context,
    MaterialPageRoute(
      builder: (_) => MainScaffold(
        serverUrl: url,
        accessToken: token,
      ),
    ),
  );
  ```

  Also on startup, if `server_url` is already saved, navigate directly to `MainScaffold`.

- [ ] **Step 7: Delete now-redundant files**
  ```bash
  rm flutter_app/lib/pages/download_page.dart
  rm flutter_app/lib/pages/audio_list_page.dart
  ```

- [ ] **Step 8: Commit**
  ```bash
  git add flutter_app/lib/
  git commit -m "feat: restructure to 4-tab layout (Link/Channel/Downloaded/Play)"
  ```

---

## Task 9: Downloaded Tab — Delete, Context Menu, Sort/Filter, Completion Tracking

**Files:**
- Modify: `flutter_app/lib/pages/downloaded_tab.dart`

- [ ] **Step 1: Add completion tracking to `AudioService`**

  In `audio_service.dart`, in `_onTrackCompleted`, instead of saving position=0, save a special "completed" marker. Also save "opened" flag when playback starts.

  Change `_savePosition` to also track open/complete:

  ```dart
  Future<void> playVideo(Video video) async {
    _currentVideo = video;
    // Mark as opened
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('opened_${video.youtubeId}', true);
    // ... rest of playVideo
  }

  Future<void> _onTrackCompleted() async {
    if (_currentVideo != null) {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool('completed_${_currentVideo!.youtubeId}', true);
      await _savePosition(_currentVideo!.youtubeId, 0);
    }
    await playNextUnplayed();
  }
  ```

  Change `playNextUnplayed` to skip completed videos first:

  ```dart
  Future<void> playNextUnplayed() async {
    if (_playlist.isEmpty) return;
    final prefs = await SharedPreferences.getInstance();

    // First pass: find unstarted videos
    for (final video in _playlist) {
      if (video.youtubeId == _currentVideo?.youtubeId) continue;
      final pos = prefs.getInt('progress_${video.youtubeId}') ?? -1;
      final completed = prefs.getBool('completed_${video.youtubeId}') ?? false;
      if (pos == -1 && !completed) {
        await playVideo(video);
        return;
      }
    }

    // Second pass: find in-progress (started but not completed)
    for (final video in _playlist) {
      if (video.youtubeId == _currentVideo?.youtubeId) continue;
      final completed = prefs.getBool('completed_${video.youtubeId}') ?? false;
      if (!completed) {
        await playVideo(video);
        return;
      }
    }

    // All done — pick first non-current
    for (final video in _playlist) {
      if (video.youtubeId != _currentVideo?.youtubeId) {
        await playVideo(video);
        return;
      }
    }
  }
  ```

  Also in `positionStream` listener, detect 95% completion:

  ```dart
  _player.positionStream.listen((position) {
    if (_currentVideo != null && position.inSeconds > 0) {
      _savePosition(_currentVideo!.youtubeId, position.inSeconds);
      final dur = _currentVideo!.duration;
      if (dur > 0 && position.inSeconds / dur >= 0.95) {
        _markCompleted(_currentVideo!.youtubeId);
      }
    }
  });

  Future<void> _markCompleted(String youtubeId) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('completed_$youtubeId', true);
  }
  ```

- [ ] **Step 2: Add sort/filter state and UI to `downloaded_tab.dart`**

  Add these state variables:

  ```dart
  enum SortMode { downloadTime, channel, listenStatus }
  enum FilterMode { all, unlistened, listened }

  SortMode _sortMode = SortMode.downloadTime;
  FilterMode _filterMode = FilterMode.all;
  Map<String, bool> _openedMap = {};
  Map<String, bool> _completedMap = {};
  ```

  Load `_openedMap` and `_completedMap` from SharedPreferences in `_loadVideos()`:

  ```dart
  for (final v in videos) {
    openedMap[v.youtubeId] = prefs.getBool('opened_${v.youtubeId}') ?? false;
    completedMap[v.youtubeId] = prefs.getBool('completed_${v.youtubeId}') ?? false;
  }
  ```

  Add a computed getter for the sorted/filtered list:

  ```dart
  List<Video> get _displayVideos {
    var list = List<Video>.from(_videos.where((v) => v.status == 'done'));

    // Filter
    if (_filterMode == FilterMode.unlistened) {
      list = list.where((v) => !(_completedMap[v.youtubeId] ?? false)).toList();
    } else if (_filterMode == FilterMode.listened) {
      list = list.where((v) => _completedMap[v.youtubeId] ?? false).toList();
    }

    // Sort
    switch (_sortMode) {
      case SortMode.channel:
        list.sort((a, b) => a.channel.compareTo(b.channel));
        break;
      case SortMode.listenStatus:
        list.sort((a, b) {
          final ac = _completedMap[a.youtubeId] ?? false;
          final bc = _completedMap[b.youtubeId] ?? false;
          return ac == bc ? 0 : (ac ? 1 : -1); // unlistened first
        });
        break;
      case SortMode.downloadTime:
        break; // already in download order from backend
    }

    return list;
  }
  ```

  Add sort/filter chips to the AppBar's `bottom` or as a row above the list.

- [ ] **Step 3: Add long-press context menu and delete**

  Change each `ListTile` to use `onLongPress`:

  ```dart
  onLongPress: () => _showContextMenu(context, video),
  ```

  Implement `_showContextMenu`:

  ```dart
  void _showContextMenu(BuildContext context, Video video) {
    showModalBottomSheet(
      context: context,
      builder: (_) => Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const Icon(Icons.queue_play_next),
            title: const Text('Play Next'),
            onTap: () {
              Navigator.pop(context);
              AudioManager.handler.queueNext(video);
            },
          ),
          ListTile(
            leading: const Icon(Icons.delete_outline),
            title: const Text('Delete'),
            onTap: () async {
              Navigator.pop(context);
              await _deleteVideo(video);
            },
          ),
        ],
      ),
    );
  }

  Future<void> _deleteVideo(Video video) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (_) => AlertDialog(
        title: const Text('Delete'),
        content: Text('Delete "${video.title}"?'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Delete')),
        ],
      ),
    );
    if (confirmed == true && mounted) {
      await widget.api.deleteVideo(video.youtubeId);
      await _loadVideos();
    }
  }
  ```

- [ ] **Step 4: Add `queueNext` to `AudioPlayerHandler`**

  In `audio_service.dart`:

  ```dart
  Video? _queuedNext;

  void queueNext(Video video) {
    _queuedNext = video;
  }

  Future<void> playNextUnplayed() async {
    if (_queuedNext != null) {
      final next = _queuedNext!;
      _queuedNext = null;
      await playVideo(next);
      return;
    }
    // ... rest of existing logic
  }
  ```

- [ ] **Step 5: Commit**
  ```bash
  git add flutter_app/lib/pages/downloaded_tab.dart flutter_app/lib/services/audio_service.dart
  git commit -m "feat: add delete, context menu, sort/filter, 95% completion tracking"
  ```

---

## Task 10: Fix Skip to ±30s

**Files:**
- Modify: `flutter_app/lib/services/audio_service.dart`
- Modify: `flutter_app/lib/widgets/player_bar.dart`

- [ ] **Step 1: Change skip duration in `audio_service.dart`**

  In `skipToNext` and `skipToPrevious`, change `Duration(seconds: 15)` to `Duration(seconds: 30)`:

  ```dart
  @override
  Future<void> skipToNext() async {
    final newPos = _player.position + const Duration(seconds: 30);
    final dur = _player.duration ?? Duration.zero;
    await _player.seek(newPos < dur ? newPos : dur);
  }

  @override
  Future<void> skipToPrevious() async {
    final newPos = _player.position - const Duration(seconds: 30);
    await _player.seek(newPos > Duration.zero ? newPos : Duration.zero);
  }
  ```

- [ ] **Step 2: Update icons in `player_bar.dart`**

  Change `Icons.replay_10` → `Icons.replay_30` and `Icons.forward_10` → `Icons.forward_30`, and update tooltips to 'Back 30s' / 'Forward 30s'.

- [ ] **Step 3: Commit**
  ```bash
  git add flutter_app/lib/services/audio_service.dart flutter_app/lib/widgets/player_bar.dart
  git commit -m "fix: change skip from ±15s to ±30s"
  ```

---

## Task 11: Play Tab — Speed Control + Subtitle Display

**Files:**
- Create: `flutter_app/lib/models/subtitle_entry.dart`
- Modify: `flutter_app/lib/pages/play_tab.dart`
- Modify: `flutter_app/lib/services/audio_service.dart` (add speed control)

- [ ] **Step 1: Create `subtitle_entry.dart` — VTT/SRT parser**

  ```dart
  // flutter_app/lib/models/subtitle_entry.dart

  class SubtitleEntry {
    final Duration start;
    final Duration end;
    final String text;

    const SubtitleEntry({
      required this.start,
      required this.end,
      required this.text,
    });
  }

  List<SubtitleEntry> parseVtt(String vttContent) {
    final entries = <SubtitleEntry>[];
    final lines = vttContent.split('\n');
    int i = 0;

    // Skip WEBVTT header
    while (i < lines.length && !lines[i].contains('-->')) i++;

    while (i < lines.length) {
      final line = lines[i].trim();
      if (line.contains('-->')) {
        final parts = line.split('-->');
        final start = _parseTime(parts[0].trim());
        final end = _parseTime(parts[1].trim().split(' ').first);
        i++;
        final textLines = <String>[];
        while (i < lines.length && lines[i].trim().isNotEmpty) {
          // Remove VTT tags like <c>, <00:00:00.000>
          final cleaned = lines[i].trim().replaceAll(RegExp(r'<[^>]+>'), '');
          if (cleaned.isNotEmpty) textLines.add(cleaned);
          i++;
        }
        if (textLines.isNotEmpty) {
          entries.add(SubtitleEntry(
            start: start,
            end: end,
            text: textLines.join(' '),
          ));
        }
      }
      i++;
    }
    return entries;
  }

  Duration _parseTime(String s) {
    // Supports HH:MM:SS.mmm or MM:SS.mmm
    final parts = s.split(':');
    int h = 0, m = 0;
    double sec = 0;
    if (parts.length == 3) {
      h = int.parse(parts[0]);
      m = int.parse(parts[1]);
      sec = double.parse(parts[2]);
    } else if (parts.length == 2) {
      m = int.parse(parts[0]);
      sec = double.parse(parts[1]);
    }
    final ms = (sec * 1000).round();
    return Duration(hours: h, minutes: m, milliseconds: ms);
  }
  ```

- [ ] **Step 2: Add speed control to `AudioPlayerHandler`**

  In `audio_service.dart`, add:

  ```dart
  static const List<double> speedSteps = [0.5, 0.75, 1.0, 1.25, 1.5, 1.75, 2.0, 2.25, 2.5];

  double get currentSpeed => _player.speed;

  Future<void> setSpeed(double speed) async {
    await _player.setSpeed(speed);
  }
  ```

- [ ] **Step 3: Implement `play_tab.dart` with speed control and subtitle display**

  ```dart
  // flutter_app/lib/pages/play_tab.dart
  import 'package:flutter/material.dart';
  import 'package:just_audio/just_audio.dart';
  import '../services/audio_service.dart';
  import '../services/api_service.dart';
  import '../models/subtitle_entry.dart';

  class PlayTab extends StatefulWidget {
    const PlayTab({super.key});

    @override
    State<PlayTab> createState() => _PlayTabState();
  }

  class _PlayTabState extends State<PlayTab> {
    List<SubtitleEntry> _subtitles = [];
    bool _loadingSubtitles = false;
    String? _lastLoadedYoutubeId;

    @override
    void initState() {
      super.initState();
      _tryLoadSubtitles();
    }

    Future<void> _tryLoadSubtitles() async {
      if (!AudioManager.isInitialized) return;
      final video = AudioManager.handler.currentVideo;
      if (video == null || !video.hasSubtitle) return;
      if (video.youtubeId == _lastLoadedYoutubeId) return;

      setState(() => _loadingSubtitles = true);
      try {
        // ApiService is recreated here — in a real app pass it via provider/inherited widget
        // For now, read from SharedPreferences
        final prefs = await SharedPreferences.getInstance();
        final serverUrl = prefs.getString('server_url') ?? '';
        final token = prefs.getString('access_token') ?? '';
        final api = ApiService(serverUrl, accessToken: token);
        final vtt = await api.getSubtitleText(video.youtubeId);
        setState(() {
          _subtitles = parseVtt(vtt);
          _lastLoadedYoutubeId = video.youtubeId;
          _loadingSubtitles = false;
        });
      } catch (_) {
        setState(() => _loadingSubtitles = false);
      }
    }

    int _currentSubtitleIndex(Duration position) {
      for (int i = 0; i < _subtitles.length; i++) {
        if (position >= _subtitles[i].start && position < _subtitles[i].end) {
          return i;
        }
      }
      return -1;
    }

    @override
    Widget build(BuildContext context) {
      if (!AudioManager.isInitialized) {
        return Scaffold(
          appBar: AppBar(title: const Text('Now Playing')),
          body: const Center(child: Text('No audio playing')),
        );
      }

      final handler = AudioManager.handler;
      final player = handler.player;

      return Scaffold(
        appBar: AppBar(
          title: StreamBuilder(
            stream: handler.mediaItem,
            builder: (_, snap) => Text(snap.data?.title ?? 'Now Playing',
                overflow: TextOverflow.ellipsis),
          ),
        ),
        body: StreamBuilder<Duration>(
          stream: player.positionStream,
          builder: (context, posSnap) {
            final position = posSnap.data ?? Duration.zero;
            final duration = player.duration ?? Duration.zero;
            final currentIdx = _currentSubtitleIndex(position);

            return Column(
              children: [
                // Speed control row
                StreamBuilder<PlayerState>(
                  stream: player.playerStateStream,
                  builder: (_, __) => Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                    child: Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('Speed: '),
                        DropdownButton<double>(
                          value: AudioPlayerHandler.speedSteps.contains(player.speed)
                              ? player.speed
                              : 1.0,
                          items: AudioPlayerHandler.speedSteps
                              .map((s) => DropdownMenuItem(
                                    value: s,
                                    child: Text('${s}x'),
                                  ))
                              .toList(),
                          onChanged: (v) {
                            if (v != null) handler.setSpeed(v);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                // Seek bar
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Slider(
                    value: duration.inMilliseconds > 0
                        ? (position.inMilliseconds / duration.inMilliseconds).clamp(0.0, 1.0)
                        : 0.0,
                    onChanged: (v) {
                      handler.seek(Duration(
                          milliseconds: (v * duration.inMilliseconds).round()));
                    },
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      Text(_fmt(position)),
                      Text(_fmt(duration)),
                    ],
                  ),
                ),
                const Divider(),
                // Subtitle list
                Expanded(
                  child: _buildSubtitleList(currentIdx, position),
                ),
              ],
            );
          },
        ),
      );
    }

    Widget _buildSubtitleList(int currentIdx, Duration position) {
      if (_loadingSubtitles) {
        return const Center(child: CircularProgressIndicator());
      }
      if (_subtitles.isEmpty) {
        return const Center(child: Text('No subtitles available'));
      }

      return ListView.builder(
        itemCount: _subtitles.length,
        itemBuilder: (context, i) {
          final entry = _subtitles[i];
          final isCurrent = i == currentIdx;
          return ListTile(
            dense: true,
            selected: isCurrent,
            selectedTileColor: Theme.of(context).colorScheme.primaryContainer,
            title: Text(
              entry.text,
              style: TextStyle(
                fontWeight: isCurrent ? FontWeight.bold : FontWeight.normal,
                color: isCurrent ? Theme.of(context).colorScheme.onPrimaryContainer : null,
              ),
            ),
            onTap: () => AudioManager.handler.seek(entry.start),
          );
        },
      );
    }

    String _fmt(Duration d) {
      final h = d.inHours;
      final m = d.inMinutes.remainder(60);
      final s = d.inSeconds.remainder(60);
      if (h > 0) return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
      return '$m:${s.toString().padLeft(2, '0')}';
    }
  }
  ```

  Note: This reads SharedPreferences directly for serverUrl/token. If this feels messy, pass `ApiService` via the `MainScaffold` or use `InheritedWidget` — but for now it works.

  Also add a listener in `initState` to reload subtitles when the track changes:

  ```dart
  @override
  void initState() {
    super.initState();
    _tryLoadSubtitles();
    if (AudioManager.isInitialized) {
      AudioManager.handler.mediaItem.listen((_) => _tryLoadSubtitles());
    }
  }
  ```

- [ ] **Step 4: Add `PlayTab` to `MainScaffold` (replace stub)**

  `MainScaffold` already imports `play_tab.dart` — it now gets the real implementation automatically.

- [ ] **Step 5: Add `SharedPreferences` import to `play_tab.dart`**

  ```dart
  import 'package:shared_preferences/shared_preferences.dart';
  ```

- [ ] **Step 6: Commit**
  ```bash
  git add flutter_app/lib/models/subtitle_entry.dart flutter_app/lib/pages/play_tab.dart \
      flutter_app/lib/services/audio_service.dart
  git commit -m "feat: Play tab with speed control (0.5-2.5x) and subtitle display"
  ```

---

## Task 12: Update READMEs and CLAUDE.md Files

**Files:**
- Create: `README.md` (root)
- Create: `CLAUDE.md` (root)
- Modify: `flutter_app/README.md`
- Modify: `backend/README.md` (add Makefile section, access token section)

- [ ] **Step 1: Create root `README.md`**

  Content should cover: what the project is, quick-start (backend first, then Flutter app), link to backend/README.md and flutter_app/README.md.

- [ ] **Step 2: Create root `CLAUDE.md`**

  Content: project structure, how backend and frontend relate, key dev commands, testing strategy.

- [ ] **Step 3: Update `flutter_app/README.md`**

  Replace default Flutter README with: prerequisites (Flutter 3.x, Android device/emulator), how to set up `.env` or enter server URL + token, how to build and run, how to test each tab.

- [ ] **Step 4: Update `backend/README.md`**

  Add sections for: Makefile commands, access token setup, subtitle support.

- [ ] **Step 5: Commit**
  ```bash
  git add README.md CLAUDE.md flutter_app/README.md backend/README.md
  git commit -m "docs: add root README/CLAUDE.md, update flutter and backend docs"
  ```

---

## Deferred: Channel Tab (YouTube Login)

The Channel tab (YouTube OAuth login → subscribed channels → video picker) requires:
- A Google OAuth client ID (Android app credential in Google Cloud Console)
- `google_sign_in` Flutter package
- YouTube Data API v3 calls for `subscriptions.list` and `playlistItems.list`
- The user needs to provide their own Google Cloud project with YouTube API enabled

This is a non-trivial setup requiring user credentials and Google Cloud configuration. **Implement in a separate plan after the user sets up the Google Cloud project.**

---

## Self-Review Against Spec

| Spec Requirement | Task |
|-----------------|------|
| yt-dlp → MP3, no video | Already done ✅ |
| Subtitle download (zh/en) | Task 3 |
| Metadata + thumbnail | Already done ✅ |
| PostgreSQL DB, dedup, caching | Already done ✅ |
| Delete downloaded video | Task 4 (backend) + Task 9 (frontend) |
| Docker, external volume, NAS README | Already done ✅ |
| Backend run scripts | Task 5 |
| 4-tab layout | Task 8 |
| Link tab (YouTube URL download) | Task 8 (refactor existing) |
| Channel tab | Deferred |
| Downloaded tab: list, thumbnail, title, channel, time | Already done ✅ |
| Downloaded tab: delete, context menu | Task 9 |
| Downloaded tab: sort/filter | Task 9 |
| Downloaded tab: opened/completed tracking | Task 9 |
| Play tab: speed 0.5–2.5x/0.25 steps | Task 11 |
| Play tab: subtitle display + highlight + click-to-seek | Task 11 |
| Background playback | Already done ✅ |
| ±30s skip (hardware buttons) | Task 10 |
| Lock screen / notification UI | Already done ✅ (audio_service) |
| Access token auth | Task 4 (backend) + Task 7 (frontend) |
| Fix crash: getVideos() parse | Task 6 |
| Fix crash: video ID UUID vs youtube_id | Task 6 |
| READMEs and CLAUDE.md | Task 12 |
