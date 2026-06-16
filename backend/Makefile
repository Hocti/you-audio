.PHONY: run build run-docker stop

# Run directly without Docker (requires Python 3.11+, ffmpeg, yt-dlp installed locally)
run:
	YOUTUBE_API_KEY=$$(grep -E '^YOUTUBE_API_KEY=' .env | cut -d= -f2-) \
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
