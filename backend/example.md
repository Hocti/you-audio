# API Examples — curl

This document shows how to call every endpoint of the YouTube Audio Downloader
backend with `curl`.

## Base URL & authentication

The server listens on port **8000** by default:

```sh
BASE_URL=http://localhost:8000
```

If the `ACCESS_TOKEN` environment variable is set on the server, every request
(except none — all routes are protected) must include an `X-Access-Token`
header. If `ACCESS_TOKEN` is empty (the default in `docker-compose.yml`),
the header is ignored and can be omitted.

```sh
TOKEN=change_me_to_a_random_secret   # must match the server's ACCESS_TOKEN
```

A missing or wrong token returns `401 {"detail":"Invalid access token"}`.

---

## Endpoint summary

| Method | Path | Description |
|--------|------|-------------|
| GET    | `/api/health`              | Health check |
| POST   | `/api/download`            | Submit a YouTube URL, start a download |
| GET    | `/api/progress/{task_id}`  | Poll download/conversion progress |
| GET    | `/api/videos`              | List all downloaded videos |
| GET    | `/api/audio/{video_id}`    | Download/stream the MP3 |
| GET    | `/api/thumbnail/{video_id}`| Download the thumbnail JPEG |
| GET    | `/api/subtitles/{youtube_id}` | Download the subtitle (.vtt) file |
| GET    | `/api/channel/{channel_id}/videos` | List a channel's latest videos (YouTube Data API, cached 1h) |
| DELETE | `/api/videos/{youtube_id}` | Delete a video and its files |

> `video_id` / `youtube_id` in a path always means the **11-character YouTube
> video ID** (e.g. `dQw4w9WgXcQ`), not the database UUID.
> `task_id` is the database UUID returned by `/api/download`.

---

## 1. Health check

```sh
curl "$BASE_URL/api/health"
```

Response:

```json
{"status": "ok"}
```

---

## 2. Start a download

Submit a YouTube URL. The download runs in the background; the response returns
immediately with a `task_id` you use to poll progress.

```sh
curl -X POST "$BASE_URL/api/download" \
  -H "Content-Type: application/json" \
  -H "X-Access-Token: $TOKEN" \
  -d '{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}'
```

Response (new download — `cached: false`):

```json
{
  "cached": false,
  "task_id": "3f8c1e2a-1b2c-4d5e-8f90-1234567890ab",
  "video": {
    "id": "3f8c1e2a-1b2c-4d5e-8f90-1234567890ab",
    "youtube_id": "dQw4w9WgXcQ",
    "title": null,
    "channel_name": null,
    "duration": null,
    "thumbnail_url": null,
    "has_subtitle": false,
    "subtitle_path": null,
    "mp3_path": null,
    "file_size": null,
    "status": "pending",
    "error_message": null,
    "created_at": "2026-06-16T12:00:00.000000"
  }
}
```

If the video was already downloaded, `cached` is `true`, `status` is `"done"`,
and the metadata fields are populated.

- `400 {"detail":"Invalid YouTube URL"}` — the URL has no recognizable video ID.

---

## 3. Poll progress

Use the `task_id` from the download response.

```sh
TASK_ID=3f8c1e2a-1b2c-4d5e-8f90-1234567890ab

curl "$BASE_URL/api/progress/$TASK_ID" \
  -H "X-Access-Token: $TOKEN"
```

Response:

```json
{
  "task_id": "3f8c1e2a-1b2c-4d5e-8f90-1234567890ab",
  "status": "downloading",
  "progress_percent": 42.5,
  "message": "Downloading audio"
}
```

`status` moves through `pending` → `downloading` → `converting` → `done`
(or `error`). Poll until `status` is `done` or `error`.

- `404 {"detail":"Task not found"}` — unknown `task_id` (progress is in-memory
  and is lost on server restart).

Simple poll loop:

```sh
while true; do
  curl -s "$BASE_URL/api/progress/$TASK_ID" -H "X-Access-Token: $TOKEN"
  echo
  sleep 2
done
```

---

## 4. List downloaded videos

```sh
curl "$BASE_URL/api/videos" \
  -H "X-Access-Token: $TOKEN"
```

Response (newest first):

```json
{
  "videos": [
    {
      "id": "3f8c1e2a-1b2c-4d5e-8f90-1234567890ab",
      "youtube_id": "dQw4w9WgXcQ",
      "title": "Rick Astley - Never Gonna Give You Up",
      "channel_name": "Rick Astley",
      "duration": 213,
      "thumbnail_url": "https://i.ytimg.com/vi/dQw4w9WgXcQ/maxresdefault.jpg",
      "has_subtitle": true,
      "subtitle_path": "/data/subtitles/dQw4w9WgXcQ.vtt",
      "mp3_path": "/data/audio/dQw4w9WgXcQ.mp3",
      "file_size": 5123456,
      "status": "done",
      "error_message": null,
      "created_at": "2026-06-16T12:00:00.000000"
    }
  ],
  "total": 1
}
```

---

## 5. Download the MP3

Streams the MP3 file (supports HTTP range requests). Use `youtube_id` in the path.

```sh
VIDEO_ID=dQw4w9WgXcQ

curl "$BASE_URL/api/audio/$VIDEO_ID" \
  -H "X-Access-Token: $TOKEN" \
  -o "$VIDEO_ID.mp3"
```

Request a byte range (e.g. for seeking):

```sh
curl "$BASE_URL/api/audio/$VIDEO_ID" \
  -H "X-Access-Token: $TOKEN" \
  -H "Range: bytes=0-1023" \
  -o first_kb.mp3
```

- `404 {"detail":"Audio not found"}` — no completed download for that ID.
- `404 {"detail":"Audio file missing from disk"}` — DB row exists but file is gone.

---

## 6. Download the thumbnail

```sh
curl "$BASE_URL/api/thumbnail/$VIDEO_ID" \
  -H "X-Access-Token: $TOKEN" \
  -o "$VIDEO_ID.jpg"
```

- `404 {"detail":"Thumbnail not found"}` / `"Thumbnail file missing from disk"`.

---

## 7. Download subtitles

Returns the subtitle file as `text/vtt`.

```sh
curl "$BASE_URL/api/subtitles/$VIDEO_ID" \
  -H "X-Access-Token: $TOKEN" \
  -o "$VIDEO_ID.vtt"
```

- `404 {"detail":"Subtitles not found"}` / `"Subtitle file missing from disk"`.

---

## 8. Delete a video

Removes the database row and deletes the MP3, thumbnail, and subtitle files from
disk. Returns `204 No Content` on success (no body).

```sh
curl -X DELETE "$BASE_URL/api/videos/$VIDEO_ID" \
  -H "X-Access-Token: $TOKEN" \
  -i
```

- `204` — deleted.
- `404 {"detail":"Video not found"}` — no row for that `youtube_id`.

---

## 9. List a channel's latest videos

Returns up to 50 of a channel's latest uploads via the YouTube Data API v3.
Requires `YOUTUBE_API_KEY` to be set on the server. Results are cached in memory
for 1 hour per channel, so repeated requests within the hour don't spend quota
(`"cached": true` on a cache hit).

The path segment must be a **bare channel ID** — a 24-character string starting
with `UC` (e.g. `UC_x5XG1OV2P6uZZ5FSM9Ttw`). A full channel URL or an `@handle`
is **not** accepted and returns `404`.

```sh
CHANNEL_ID=UC_x5XG1OV2P6uZZ5FSM9Ttw   # Google for Developers

curl "$BASE_URL/api/channel/$CHANNEL_ID/videos" \
  -H "X-Access-Token: $TOKEN"
```

Response (truncated to one video):

```json
{
  "channel_id": "UC_x5XG1OV2P6uZZ5FSM9Ttw",
  "cached": false,
  "total": 50,
  "videos": [
    {
      "video_id": "o2rUT2GloV0",
      "title": "Run Gemma on the edge with the Coral Board",
      "published_at": "2026-06-15T23:00:40Z",
      "thumbnail_url": "https://i.ytimg.com/vi/o2rUT2GloV0/maxresdefault.jpg",
      "channel_name": "Google for Developers"
    }
  ]
}
```

- `404 {"detail":"Channel not found"}` — no channel matches that ID (e.g. you
  passed a URL or `@handle` instead of a `UC…` ID).
- `500 {"detail":"YouTube API key not configured"}` — `YOUTUBE_API_KEY` is unset.
- `502 {"detail":"YouTube API error: ..."}` — the YouTube API rejected the call
  (quota exhausted, invalid key, etc.); the original message is included.

### Resolve a channel ID from a URL or @handle

If you only have a channel URL or `@handle`, resolve it to a `UC…` id first.
Accepts a bare id, a `/channel/UC…` URL, an `@handle` (or handle URL), a
`/user/NAME` URL, a `/c/NAME` custom URL, or plain search text.

```sh
curl -G "$BASE_URL/api/channel/resolve" \
  --data-urlencode "q=https://www.youtube.com/@SinicAnalytica" \
  -H "X-Access-Token: $TOKEN"
```

Response:

```json
{"channel_id": "UCGg1R6-6T80QfuPbGScZXfQ", "channel_name": "馮智政 x Sinic 政經頻道"}
```

- An `@handle` or `/user/` lookup costs **1** quota unit; the plain-text / `/c/`
  search fallback costs **100**.
- `404 {"detail":"Could not resolve a channel from that input"}` — no match.

---

## End-to-end example

```sh
BASE_URL=http://localhost:8000
TOKEN=change_me_to_a_random_secret

# 1. Start the download
RESP=$(curl -s -X POST "$BASE_URL/api/download" \
  -H "Content-Type: application/json" \
  -H "X-Access-Token: $TOKEN" \
  -d '{"url": "https://www.youtube.com/watch?v=dQw4w9WgXcQ"}')
echo "$RESP"

TASK_ID=$(echo "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin)["task_id"])')

# 2. Wait until done
while true; do
  P=$(curl -s "$BASE_URL/api/progress/$TASK_ID" -H "X-Access-Token: $TOKEN")
  echo "$P"
  echo "$P" | grep -q '"status":"done"' && break
  echo "$P" | grep -q '"status":"error"' && { echo "FAILED"; exit 1; }
  sleep 2
done

# 3. Download the MP3
curl "$BASE_URL/api/audio/dQw4w9WgXcQ" -H "X-Access-Token: $TOKEN" -o song.mp3
echo "Saved song.mp3"
```
