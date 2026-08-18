.PHONY: run build run-docker stop venv test pot-provider

# Prefer a project-local .venv when it exists, else fall back to whatever
# python3 is on PATH. Installing this server's pinned dependencies into a shared
# environment (a conda base with gradio, say) makes the two fight over fastapi /
# starlette / python-multipart versions — pip installs one set and quietly breaks
# the other. `make venv` keeps them apart.
VENV := .venv
PY := $(if $(wildcard $(VENV)/bin/python),$(VENV)/bin/python,python3)

# One-time setup: create .venv and install the pinned dependencies into it.
# Everything below then uses it automatically.
venv:
	python3 -m venv $(VENV)
	$(VENV)/bin/python -m pip install --upgrade pip
	$(VENV)/bin/python -m pip install -r requirements.txt
	@echo
	@echo "Done. 'make run' and 'make test' now use $(VENV)."

# Starts (or reuses) the PO Token sidecar yt-dlp needs to avoid 403s on media
# URLs — see docker-compose.yml's `pot-provider` service and downloader.py's
# POT_PROVIDER_URL. Requires Docker even for the non-Docker `make run`, since
# that's the only distribution this plugin ships.
pot-provider:
	@docker start bgutil-provider >/dev/null 2>&1 && echo "using existing bgutil-provider container" || \
	docker run --name bgutil-provider -d --init -p 4416:4416 brainicism/bgutil-ytdlp-pot-provider:latest

# Run directly without Docker (requires Python 3.11+ and ffmpeg locally).
# ACCESS_TOKEN comes from .env, same as the API key — the app needs a token that
# matches the admin user, and ACCESS_TOKEN is what sets it.
run: pot-provider
	@echo "using $(PY)"
	YOUTUBE_API_KEY=$$(grep -E '^YOUTUBE_API_KEY=' .env | cut -d= -f2-) \
	ACCESS_TOKEN=$$(grep -E '^ACCESS_TOKEN=' .env | cut -d= -f2-) \
	DATABASE_URL=sqlite+aiosqlite:///./ytaudio.db \
	DATA_DIR=./data \
	$(PY) -m uvicorn app.main:app --reload --host 0.0.0.0 --port 8000

test:
	$(PY) -m pytest -q

# Build the Docker image
build:
	docker compose build

# Run with Docker (builds if needed, runs in foreground so you see logs)
run-docker:
	docker compose up --build

# Stop Docker containers
stop:
	docker compose down
