#!/bin/sh
# Upgrade yt-dlp (and its JS challenge solver) to the latest release on every
# start, so the app always runs a current version — YouTube breaks stale
# yt-dlp builds every few months. Failures (e.g. offline) are non-fatal: the
# version baked into the image at build time is used instead.
set -e

echo "[entrypoint] Upgrading yt-dlp to latest..."
pip install --no-cache-dir --upgrade yt-dlp yt-dlp-ejs bgutil-ytdlp-pot-provider \
  || echo "[entrypoint] yt-dlp upgrade failed; using the version from the image."

yt-dlp --version 2>/dev/null | sed 's/^/[entrypoint] yt-dlp /' || true

exec uvicorn app.main:app --host 0.0.0.0 --port 8000
