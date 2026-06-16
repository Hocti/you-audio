FROM python:3.11-slim

# Install ffmpeg
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# Bun: JavaScript runtime yt-dlp uses to solve YouTube's JS challenges.
# Copied as a single static binary from the official image (glibc build,
# compatible with this Debian-based python:slim image).
COPY --from=oven/bun:1 /usr/local/bin/bun /usr/local/bin/bun

WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app/ ./app/
COPY entrypoint.sh ./entrypoint.sh
RUN chmod +x ./entrypoint.sh

# Create data dirs (will be overridden by volume mount)
RUN mkdir -p /data/audio /data/thumbnails

ENV DATA_DIR=/data

EXPOSE 8000

# entrypoint.sh upgrades yt-dlp to latest, then launches uvicorn.
ENTRYPOINT ["./entrypoint.sh"]
