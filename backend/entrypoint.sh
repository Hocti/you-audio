#!/bin/sh
# Upgrade yt-dlp (with its matching JS challenge solver, yt-dlp-ejs) and the
# PO Token plugin (pinned to the pot-provider sidecar's version) on every start,
# so the app always runs a current version — YouTube breaks stale yt-dlp builds
# every few months. See app/ytdlp_update.py for the version rules. Failures
# (e.g. offline) are non-fatal: the versions baked into the image are used.
#
# The server also re-runs this upgrade on its own: daily, and right after a
# download fails (then retries that download once) — see downloader.py.
set -e

python -m app.ytdlp_update \
  || echo "[entrypoint] yt-dlp upgrade failed; using the version from the image."

yt-dlp --version 2>/dev/null | sed 's/^/[entrypoint] yt-dlp /' || true

exec uvicorn app.main:app --host 0.0.0.0 --port 8000
