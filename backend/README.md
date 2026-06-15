# YouTube Audio Downloader — Backend

A self-hosted server that converts YouTube videos to MP3 files. It runs inside Docker and stores files on your machine (or NAS).

---

## How It Works

1. A client (the Flutter app) sends a YouTube URL.
2. The server downloads the audio using **yt-dlp** and converts it to MP3 using **ffmpeg**.
3. Metadata (title, channel, thumbnail) is saved to a PostgreSQL database.
4. The MP3 and thumbnail files are stored in a Docker volume.
5. If the same video is requested again, the server returns the cached version immediately.

---

## Requirements

- Docker and Docker Compose installed on your host machine.
- Internet access on the host machine (to download from YouTube).
- Port **8000** available (or change it — see below).

**No other software is needed.** Python, ffmpeg, and yt-dlp are all installed inside the Docker image.

---

## Quick Start (Local Machine or Linux Server)

**Step 1 — Get the files**

```bash
git clone <your-repo-url>
cd youtube-audio/backend
```

**Step 2 — Start the server**

```bash
docker compose up -d --build
```

This command:
- Builds the backend Docker image (takes 2–5 minutes the first time).
- Starts a PostgreSQL database container.
- Starts the backend API server on port **8000**.

**Step 3 — Check it is running**

Open this URL in your browser:

```
http://localhost:8000/api/health
```

You should see: `{"status": "ok"}`

**Step 4 — Stop the server**

```bash
docker compose down
```

Your data (database and audio files) is saved in Docker volumes and will still be there next time you start.

---

## Setting Up on Synology NAS

Synology NAS supports Docker through the **Container Manager** app (DSM 7.2+) or the older **Docker** package (DSM 7.1 and below).

### Method 1 — SSH (Recommended)

This is the most reliable method.

**Step 1 — Enable SSH on your NAS**

Go to: `Control Panel` → `Terminal & SNMP` → check `Enable SSH service` → Apply.

**Step 2 — Connect to your NAS via SSH**

On your computer, open Terminal and run:

```bash
ssh your-username@your-nas-ip-address
```

Example: `ssh admin@192.168.1.100`

**Step 3 — Copy the project files to the NAS**

On your local machine (not in SSH), run:

```bash
scp -r /path/to/youtube-audio/backend your-username@your-nas-ip:/volume1/docker/youtube-audio-backend
```

**Step 4 — Build and start on the NAS**

Back in the SSH session:

```bash
cd /volume1/docker/youtube-audio-backend
docker compose up -d --build
```

**Step 5 — Verify**

Open a browser on any device on your network:

```
http://192.168.1.100:8000/api/health
```

Replace `192.168.1.100` with your NAS IP address.

---

### Method 2 — Container Manager UI (No SSH)

**Step 1 — Upload files**

Use Synology **File Station** to upload the entire `backend/` folder to `/volume1/docker/youtube-audio-backend/`.

**Step 2 — Open Container Manager**

Go to the Container Manager app in DSM.

**Step 3 — Create a project**

- Click `Project` → `Create`.
- Set the project path to the folder you uploaded.
- Container Manager will detect the `docker-compose.yml` file automatically.
- Click `Next` and follow the prompts.

---

### Changing the Port on Synology

If port 8000 is already in use, edit `docker-compose.yml` before building:

```yaml
ports:
  - "9000:8000"   # Change 9000 to any free port you want
```

Then the API will be available at `http://your-nas-ip:9000`.

### Opening the Port in Synology Firewall

If you have the Synology firewall enabled:

Go to: `Control Panel` → `Security` → `Firewall` → `Edit Rules` → Add a rule to allow TCP on your chosen port (e.g. 8000) from your local network (e.g. `192.168.1.0/24`).

---

## File Locations

All downloaded files are stored in a Docker volume named `ytdata`.

To find where Synology stores Docker volumes on disk:

```bash
ls /volume1/@docker/volumes/
```

You will see folders like `backend_ytdata` and `backend_pgdata`.

Audio files are inside `backend_ytdata/_data/audio/`.

---

## Configuration (Optional)

You do **not** need to edit any configuration for basic use. These options are available if you need them.

### Change Database Password

Edit `docker-compose.yml`:

```yaml
environment:
  POSTGRES_USER: ytaudio
  POSTGRES_PASSWORD: change_this_password   # ← change this
  POSTGRES_DB: ytaudio
```

Also update the `DATABASE_URL` in the `backend` service:

```yaml
DATABASE_URL: "postgresql+asyncpg://ytaudio:change_this_password@db:5432/ytaudio"
```

### Change Storage Directory

By default, files are stored at `/data` inside the container, which maps to the `ytdata` Docker volume. You can map it to a specific folder on your NAS instead:

```yaml
volumes:
  - /volume1/music/youtube:/data   # ← map to a real NAS folder
```

---

## API Reference

| Method | URL | Description |
|--------|-----|-------------|
| POST | `/api/download` | Start a download. Body: `{"url": "https://youtube.com/..."}` |
| GET | `/api/progress/{task_id}` | Get download progress |
| GET | `/api/videos` | List all downloaded videos |
| GET | `/api/audio/{youtube_id}` | Stream an MP3 file |
| GET | `/api/thumbnail/{youtube_id}` | Get a thumbnail image |
| GET | `/api/health` | Health check |

---

## Troubleshooting

**The server starts but downloads fail**

yt-dlp needs to be up to date. YouTube sometimes changes its format, which breaks older versions. To update yt-dlp without rebuilding the whole image:

```bash
docker compose exec backend pip install -U yt-dlp
```

**The NAS cannot pull Docker images**

Make sure the NAS has internet access. Go to `Control Panel` → `Network` and check the DNS settings. Try `8.8.8.8` as a DNS server.

**Port conflict**

Run `sudo netstat -tlnp | grep 8000` on the NAS to see what is using port 8000, then change the port in `docker-compose.yml`.

**View logs**

```bash
docker compose logs -f backend
```
