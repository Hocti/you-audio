.PHONY: run build run-docker stop venv test

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

# Run directly without Docker (requires Python 3.11+ and ffmpeg locally).
# ACCESS_TOKEN comes from .env, same as the API key — the app needs a token that
# matches the admin user, and ACCESS_TOKEN is what sets it.
run:
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
