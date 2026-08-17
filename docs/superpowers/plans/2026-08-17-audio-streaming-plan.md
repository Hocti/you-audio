# Audio Streaming — Implementation Plan

> **For agentic workers:** Steps use checkbox (`- [ ]`) syntax for tracking. Phases are
> independently shippable — stop after any phase and the app still works.

**Goal:** Replace "wait for the whole download, then play" with "play as soon as bytes
start arriving", while still ending up with a complete local file that plays offline
exactly as today.

**Status:** Not started. Written 2026-08-17.

---

## Why

Time-to-first-sound today is the **sum** of four serial stages:

| Stage | Where | Rough cost (1-hour video) |
|---|---|---|
| 1. yt-dlp downloads bestaudio | backend | 20 s – 3 min |
| 2. ffmpeg transcodes to 192k MP3 | backend | 20 – 60 s |
| 3. App pulls the whole MP3 (`/api/audio`) | LAN/WAN | ~87 MB — 10 s on LAN, minutes over WAN |
| 4. `LocalLibrary.addEntry` → `setFilePath` → play | device | instant |

Nothing overlaps. Stage 2 cannot start until stage 1 finishes (yt-dlp writes a file,
*then* the post-processor runs), and stage 3 cannot start until stage 2 finishes
(`/api/audio` requires `status == "done"`).

## Constraints that shape the design

These are non-negotiable — the current app depends on all of them:

1. **A complete local file must remain the end state.** The Downloaded tab, offline
   playback, and `LocalLibrary` all read `library/audio/{id}.mp3` from disk.
2. **Seeking must keep working.** Tap-a-subtitle-to-seek, ±30 s, the seek bar, and
   `restoreLastSession()` (which seeks to a saved position on open) are core features.
3. **Duration must be known.** The seek bar and the media notification need it.
4. **Auth.** Every backend request carries `X-Access-Token`.
5. **Backgrounding.** Downloads run under a foreground service; playback runs under
   `audio_service`.

Constraint 2+3 is what rules out the naive answer. A chunked HTTP response has no
`Content-Length` and no `Accept-Ranges`, so ExoPlayer reports an unknown duration and
**refuses to seek**. Any design that streams a live transcode has to pay for that.

---

## Key finding: just_audio already has the client half

`just_audio` 0.9.46 (already in `pubspec.yaml`) ships
**`LockCachingAudioSource`** — it plays a remote URL while writing it to a cache file
we choose. Verified by reading `just_audio.dart:2908-3130`:

- `LockCachingAudioSource(uri, headers: {...}, cacheFile: File(...))` — headers are
  supported (it spins up a local cleartext proxy to inject them), so our access token
  works.
- It writes to `{cacheFile}.part` while downloading and exposes
  `downloadProgressStream` (0.0 → 1.0).
- Byte-range handling: within the cached region → served from the file; overlapping →
  file + live buffer; **entirely beyond** the cached region → **a separate HTTP Range
  request to the origin**, in parallel with the ongoing download.
- That last path is gated on the origin advertising `Accept-Ranges`. If it doesn't,
  the source declares `rangeRequestsSupported: false` and `sourceLength: null` —
  i.e. **no seeking, no duration**.
- `resolve()` returns a plain file-backed source when the cache file already exists,
  so replays stay fully offline.

It is annotated `@experimental`. That is a real risk to budget for (see Risks).

**Consequence:** the phase that needs no new client code and keeps every feature is
the one where the *backend serves a normal file with `Content-Length` +
`Accept-Ranges`* — which `/api/audio` already does. That is Phase 2, and it removes
stage 3 from the critical path entirely.

---

## Options considered

| | Approach | Time-to-first-sound | Seek / duration | Cost |
|---|---|---|---|---|
| **A** | Pipe yt-dlp → ffmpeg on the backend (stages 1+2 overlap) | −20…60 s | unaffected | backend only, low |
| **B** | `LockCachingAudioSource` against `/api/audio` (stage 3 leaves the critical path) | −(whole transfer) | **fully preserved** | small client change |
| **C** | Live-transcode endpoint `/api/stream/{id}`, chunked (stages 1+2+3 all overlap) | seconds | **degraded until complete** | backend + client + UI work |
| **D** | Drop the MP3 transcode; serve native m4a/opus | removes stage 2 entirely | preserved | breaks the `.mp3` file layout |

**Recommendation: A, then B, then C — in that order, measuring after each.**

A and B together are cheap, carry no feature regression, and likely capture most of
the felt improvement (they turn a "wait minutes" into "wait for the source download").
C is where the remaining seconds are, and it is the only phase that costs a feature,
so it is deliberately last and behind a flag.

D is noted for completeness: it is technically the cleanest streaming story (YouTube's
opus/m4a needs no transcode, so backend bytes = disk bytes = player bytes), but it
changes every stored filename and the existing library, and ffmpeg is not the
bottleneck. **Not recommended** unless C's transcode pipe proves unreliable.

---

## Phase A — Overlap the transcode with the source download

**Backend only. No client change. No feature change.**

Today `_sync_download` hands yt-dlp a `FFmpegExtractAudio` post-processor, so ffmpeg
starts only after the source file is fully written. Piping makes them concurrent.

- [ ] In `backend/app/downloader.py`, replace the post-processor approach in
      `_sync_download` with an explicit pipeline: yt-dlp writes the chosen format to
      stdout (`-o -`), ffmpeg reads `pipe:0` and writes
      `{AUDIO_DIR}/{id}.mp3`.
      - Use the yt-dlp **CLI** via `subprocess`, not the Python API — `YoutubeDL` has
        no clean way to expose the download as a pipe.
      - Keep `js_runtimes`/bun by passing the equivalent CLI flags.
- [ ] Keep the progress hook semantics: parse yt-dlp's `--newline --progress-template`
      output for the percentage instead of `_progress_hook`, so `/api/progress` keeps
      reporting the same shape the app already polls.
- [ ] Preserve the metadata fetch. The piped run no longer returns an `info` dict, so
      call the existing `_sync_metadata` (or `--print-json`) for title / channel /
      duration / thumbnail.
- [ ] Subtitles: unchanged (already a separate `extract_info` call).
- [ ] Verify: a long video's `converting` phase should no longer be a distinct
      trailing stage.

**Risk:** a piped ffmpeg can't seek its input, which is fine for opus/m4a → mp3 but
means the source format must be streamable. Guard by keeping the current code path
behind a `PIPELINE_TRANSCODE=0` env fallback for one release.

---

## Phase B — Play while pulling to the device

**The big win, and the cheapest one.** The app stops waiting for an 87 MB transfer
before making a sound; the transfer becomes the thing it does *while playing*.

- [ ] `LocalLibrary`: add `partPath(id)` (`library/audio/{id}.mp3.part`) and treat a
      lone `.part` file as "not in the library" (`contains` must stay false until the
      file is complete, or the Downloaded tab will offer an unplayable row).
- [ ] `AudioPlayerHandler.playVideo`: when the local file is absent but the backend
      has it (`status == "done"`), build
      ```dart
      LockCachingAudioSource(
        Uri.parse(api.audioUrl(id)),
        headers: api.authHeaders,
        cacheFile: File(LocalLibrary.audioPath(id)),
      )
      ```
      and `setAudioSource(...)`. When the local file **is** present, keep the existing
      `setFilePath` path untouched (offline replay must not change).
      - This requires the handler to hold an `ApiService`. It currently has none —
        pass it in from `MainScaffold` (same instance the tabs get) and rebuild it
        when server settings change.
- [ ] On `downloadProgressStream` reaching 1.0, call `LocalLibrary.addEntry(...)` with
      the metadata the app already has, so the track appears in the Downloaded tab
      exactly as a normal download would.
- [ ] `DownloadManager`: add `startAndPlay(api, url)` used by "tap a video to play it
      now". It runs steps 1–2 (metadata + `/api/download` + poll) and then hands off to
      the handler instead of doing step 3's `downloadAudioBytes`. The existing
      `start()` (download-only, no playback) stays for share-intent and queue
      downloads.
- [ ] Resume: `restoreLastSession()` must not build a `LockCachingAudioSource` for a
      track whose file is missing and whose backend copy may be gone. Keep it
      file-only.
- [ ] Interrupted-download hygiene: on startup, delete `.part` files with no matching
      in-flight job.

**Verify:** with the phone on mobile data and the backend on the LAN, tapping a
never-downloaded track should start playing in ~1–2 s; seeking to the end immediately
should work (it issues a Range request); killing the app mid-play should leave a
`.part` file and no phantom library entry.

---

## Phase C — Live transcode streaming (optional, flagged)

Only worth building if, after A and B, the wait for the *source download* is still the
complaint. This is the phase that costs seeking.

- [ ] Backend `GET /api/stream/{video_id}`:
      - Complete file on disk → `FileResponse` (Range-capable). Identical to
        `/api/audio`. **This must stay the common case.**
      - Otherwise → `StreamingResponse` of the ffmpeg stdout from Phase A's pipeline,
        tee'd to `{id}.mp3.part` on the backend so the bytes are not thrown away;
        rename to `{id}.mp3` and set `status = "done"` at the end.
      - Send `X-Duration-Seconds` (known from metadata) and `X-Complete: false`.
      - A second client requesting the same id while a stream is live must attach to
        the tee file rather than starting a second yt-dlp.
- [ ] Client: use `/api/stream/{id}` only when `/api/progress` says the backend is not
      yet done; otherwise `/api/audio`.
- [ ] **Seek/duration degradation must be handled explicitly, not left to break:**
      - Play tab + player bar: fall back to the metadata duration
        (`currentVideo.duration`) when `player.duration` is null, so the seek bar and
        the ±30 s buttons still render.
      - While `X-Complete: false`, clamp seeks to the downloaded frontier and show a
        one-line "still buffering — seek available shortly" snackbar.
      - When the backend finishes, transparently swap to the complete-file source at
        the current position.
- [ ] Put the whole phase behind a settings toggle (default **off**) until it has been
      lived with.

---

## Risks

| Risk | Mitigation |
|---|---|
| `LockCachingAudioSource` is `@experimental` | Phase B keeps `setFilePath` for every already-downloaded track, so a regression only affects first play. Keep `DownloadManager.start()` as a working fallback path and make the streaming path a settings toggle. |
| Piped ffmpeg can't seek its input | Only affects exotic source formats; keep the current post-processor path behind an env flag for one release. |
| A dropped connection mid-stream leaves a partial file | `.part` naming + startup sweep; `LocalLibrary.contains` stays false until the rename. |
| Two devices streaming the same video | Phase C's tee must attach, not duplicate. Phases A/B are unaffected (they serve a finished file). |
| Backend disk fills with `.part` files | Sweep `.part` files older than 24 h on startup. |

## Explicitly not in scope

- Changing the stored audio format away from MP3 (option D).
- Serving YouTube's signed CDN URL directly to the phone (leaks the device IP to
  YouTube, and the URL expires).
- Streaming to more than one client from a single live transcode beyond the simple
  tee-attach in Phase C.

## How we'll know it worked

Measure on one short (~5 min) and one long (~1 h) video, on LAN and on mobile data:

- **T1** = tap → first audible sound.
- **T2** = tap → file complete on device.

Today T1 == T2. Target after A+B: T1 ≈ backend pipeline time, with T2 unchanged.
Target after C: T1 ≈ a few seconds regardless of length.
