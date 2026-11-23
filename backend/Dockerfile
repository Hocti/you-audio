FROM python:3.11-slim

# Install ffmpeg
RUN apt-get update && \
    apt-get install -y --no-install-recommends ffmpeg && \
    rm -rf /var/lib/apt/lists/*

# Deno: JavaScript runtime yt-dlp uses (via yt-dlp-ejs) to solve YouTube's JS
# challenges. Deno is yt-dlp's recommended runtime; bun is deprecated there
# (yt-dlp#16766) and anything newer than bun 1.3.14 is unsupported — the old
# `oven/bun:1` tag floated to 1.4.x and quietly broke the n-challenge solver.
# The `bin` image holds just the glibc-linked binary, which this Debian-based
# python:slim image can run.
COPY --from=denoland/deno:bin /deno /usr/local/bin/deno

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
