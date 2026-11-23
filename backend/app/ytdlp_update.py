"""Which packages to pip-upgrade to keep yt-dlp working, and a CLI to do it.

Deliberately imports nothing heavy (no yt_dlp, no database), so
`entrypoint.sh` can run `python -m app.ytdlp_update` before uvicorn starts.
`downloader.upgrade_yt_dlp()` uses the same `upgrade_specs()` at runtime.

Two version rules this encodes, both learned from real breakage:

* **yt-dlp-ejs must match yt-dlp.** yt-dlp pins the exact ejs version it
  supports (`yt-dlp-ejs==X` in its `default` extra) and ignores others, so we
  install `yt-dlp[default]` rather than upgrading the two independently.
* **The bgutil PO Token plugin must match the `pot-provider` sidecar.** The
  plugin is a pip package we upgrade; the sidecar is a Docker image we don't.
  Upgrading the plugin to latest (2.0.2) against an older sidecar (1.3.1)
  is a major-version mismatch: the plugin refuses to fetch a token, every
  client that needs one (web_music) is skipped, and downloads silently fall
  back to android's 360p muxed format — or fail outright. So we ask the
  sidecar its version (`GET /ping`) and install exactly that plugin version,
  falling back to latest only if the sidecar can't be reached.
"""

from __future__ import annotations

import logging
import os
import subprocess
import sys
import time

import httpx

logger = logging.getLogger(__name__)

POT_PROVIDER_URL = os.getenv("POT_PROVIDER_URL", "http://127.0.0.1:4416")
POT_PLUGIN = "bgutil-ytdlp-pot-provider"

# pip over the network; generous but bounded so a hung index can't wedge us.
PIP_TIMEOUT_SECONDS = 300


def pot_server_version(attempts: int = 1, delay: float = 2.0) -> str | None:
    """Version of the running PO Token sidecar, or None if unreachable."""
    for i in range(attempts):
        try:
            resp = httpx.get(f"{POT_PROVIDER_URL.rstrip('/')}/ping", timeout=5)
            resp.raise_for_status()
            version = resp.json().get("version")
            if version:
                return str(version)
        except Exception as exc:  # noqa: BLE001 - any failure means "unknown"
            logger.debug("PO Token sidecar ping failed: %s", exc)
        if i + 1 < attempts:
            time.sleep(delay)
    return None


def upgrade_specs(attempts: int = 1) -> list[str]:
    """pip requirement specs for an upgrade (see module docstring)."""
    server = pot_server_version(attempts=attempts)
    if server:
        plugin = f"{POT_PLUGIN}=={server}"
    else:
        logger.warning(
            "PO Token sidecar at %s unreachable; upgrading %s to latest",
            POT_PROVIDER_URL, POT_PLUGIN,
        )
        plugin = POT_PLUGIN
    return ["yt-dlp[default]", plugin]


def pip_command(specs: list[str]) -> list[str]:
    return [
        sys.executable, "-m", "pip", "install", "--no-cache-dir",
        "--disable-pip-version-check", "--upgrade", *specs,
    ]


def main() -> int:
    """Upgrade synchronously; used by entrypoint.sh before the server starts."""
    logging.basicConfig(level=logging.INFO, format="[ytdlp-update] %(message)s")
    # The sidecar container may still be booting when the backend starts.
    specs = upgrade_specs(attempts=5)
    logger.info("pip install --upgrade %s", " ".join(specs))
    try:
        return subprocess.run(pip_command(specs), timeout=PIP_TIMEOUT_SECONDS).returncode
    except subprocess.TimeoutExpired:
        logger.error("pip timed out after %ss", PIP_TIMEOUT_SECONDS)
        return 1


if __name__ == "__main__":
    sys.exit(main())
