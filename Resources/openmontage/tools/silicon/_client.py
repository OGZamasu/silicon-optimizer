"""The one HTTP client the three Silicon tools share.

The app publishes where it is listening in a handshake file — port, pid, and a
per-launch bearer token — and this reads it the same way the app's own MCP bridge
does. No configuration: if the app is running, the tools work.

Two overrides exist for the case where the app is on *another* Mac on your
network (its control server can bind beyond loopback with the swarm token set):

    SILICON_OPTIMIZER_URL=http://<that-mac>:8791
    SILICON_OPTIMIZER_TOKEN=<its swarm token>

With those set the handshake file is not consulted at all.
"""

from __future__ import annotations

import json
import os
import shutil
import sys
from dataclasses import dataclass
from pathlib import Path
from typing import Any, Optional
from urllib import error, request

PROVIDER = "silicon_optimizer"

#: Mirrors Sources/SiliconControl/VideoGenerationBudget.swift. The adapter bounds
#: accepted jobs (including queue time) to twelve hours. Leave room for submission,
#: a final in-flight status request, download, and the control response. The node's
#: resource cap accounts for a peer that sends bytes just before each idle timeout.
#: This outer tool allows one more response margin, matching Harness and Codex.
VIDEO_JOB_TIMEOUT_SECONDS = 12 * 60 * 60
VIDEO_NETWORK_RESOURCE_SECONDS = 600
VIDEO_DOWNLOAD_SECONDS = 600
VIDEO_RESPONSE_OVERHEAD_SECONDS = 60
VIDEO_CONTROL_TIMEOUT_SECONDS = (VIDEO_JOB_TIMEOUT_SECONDS + 2 * VIDEO_NETWORK_RESOURCE_SECONDS
                                 + VIDEO_DOWNLOAD_SECONDS + VIDEO_RESPONSE_OVERHEAD_SECONDS)
VIDEO_TIMEOUT_SECONDS = VIDEO_CONTROL_TIMEOUT_SECONDS + VIDEO_RESPONSE_OVERHEAD_SECONDS
IMAGE_TIMEOUT_SECONDS = 600
MESH_TIMEOUT_SECONDS = 1800

# Control replies contain job metadata and local output paths, never media bytes. Keeping the
# refusal budget smaller also prevents an error page from becoming an agent-sized diagnostic.
MAX_RESPONSE_BYTES = 1 * 1024 * 1024
MAX_ERROR_BYTES = 64 * 1024
MAX_ERROR_DETAIL_CHARS = 4096


class SiliconUnavailable(RuntimeError):
    """The app is not running, or is not reachable from here."""


class SiliconError(RuntimeError):
    """The app answered, and the answer was a refusal — in its own words."""


def handshake_path() -> Path:
    """Where the app writes ``control.json``. macOS only: the app is a Mac app."""
    override = os.environ.get("SILICON_OPTIMIZER_HANDSHAKE")
    if override:
        return Path(override)
    return Path.home() / "Library" / "Application Support" / "SiliconOptimizer" / "control.json"


@dataclass(frozen=True)
class Endpoint:
    base_url: str
    token: str


def _pid_alive(pid: Optional[int]) -> bool:
    if not pid:
        # An older handshake with no pid: trust the port and let /health decide.
        return True
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return False
    except PermissionError:
        return True
    return True


def resolve() -> Endpoint:
    """Find the app, or say precisely why it cannot be found."""
    url = os.environ.get("SILICON_OPTIMIZER_URL")
    if url:
        token = os.environ.get("SILICON_OPTIMIZER_TOKEN", "")
        if not token:
            raise SiliconUnavailable(
                "SILICON_OPTIMIZER_URL is set but SILICON_OPTIMIZER_TOKEN is not. "
                "A remote control server refuses every call without its swarm token."
            )
        return Endpoint(base_url=url.rstrip("/"), token=token)

    if sys.platform != "darwin":
        raise SiliconUnavailable(
            "Silicon Optimizer is a Mac app. On this machine, point at a Mac running it "
            "with SILICON_OPTIMIZER_URL and SILICON_OPTIMIZER_TOKEN."
        )

    path = handshake_path()
    try:
        payload = json.loads(path.read_text())
    except FileNotFoundError:
        raise SiliconUnavailable(
            "Silicon Optimizer is not running. Open the app — it publishes its port "
            f"to {path} the moment it starts."
        )
    except (OSError, ValueError) as exc:
        raise SiliconUnavailable(f"Could not read {path}: {exc}")

    port = payload.get("port")
    token = payload.get("token") or ""
    if not port or not token:
        raise SiliconUnavailable(f"{path} has no port or token in it. Restart the app.")
    if not _pid_alive(payload.get("pid")):
        raise SiliconUnavailable(
            "Silicon Optimizer is not running — its last handshake is stale. Open the app."
        )
    return Endpoint(base_url=f"http://127.0.0.1:{port}", token=token)


def _read_limited(stream: Any, limit: int, kind: str) -> bytes:
    """Read at most ``limit`` bytes, including for chunked/lengthless responses."""
    length = None
    headers = getattr(stream, "headers", None)
    if headers is not None:
        try:
            raw_length = headers.get("Content-Length")
            length = int(raw_length) if raw_length is not None else None
        except (TypeError, ValueError, OverflowError):
            length = None
    if length is not None and length > limit:
        raise SiliconError(f"Silicon Optimizer {kind} exceeded the {limit}-byte limit.")

    chunks: list[bytes] = []
    total = 0
    while True:
        chunk = stream.read(min(64 * 1024, limit + 1 - total))
        if not chunk:
            break
        total += len(chunk)
        if total > limit:
            raise SiliconError(f"Silicon Optimizer {kind} exceeded the {limit}-byte limit.")
        chunks.append(chunk)
    return b"".join(chunks)


def _open(req: request.Request, timeout: float) -> Any:
    try:
        with request.urlopen(req, timeout=timeout) as response:
            body = _read_limited(response, MAX_RESPONSE_BYTES, "response")
    except error.HTTPError as exc:
        # The app answers refusals as {"error": "..."} with a 4xx/5xx. Those words are
        # the diagnosis — "model won't fit", "no node offers video" — so they are what
        # the agent should see, not a status code.
        try:
            detail = _read_limited(exc, MAX_ERROR_BYTES, "error response").decode(
                "utf-8", "replace"
            )
        except SiliconError as size_error:
            raise SiliconError(f"Silicon Optimizer answered {exc.code}: {size_error}") from exc
        try:
            parsed = json.loads(detail)
            if isinstance(parsed, dict):
                detail = parsed.get("error", detail)
        except (TypeError, ValueError):
            pass
        detail = str(detail)[:MAX_ERROR_DETAIL_CHARS]
        raise SiliconError(f"Silicon Optimizer answered {exc.code}: {detail}")
    except TimeoutError as exc:
        raise SiliconError("The request exceeded its time limit. The app or node may still be working; check its job status before submitting again.") from exc
    except error.URLError as exc:
        if isinstance(exc.reason, TimeoutError):
            raise SiliconError("The request exceeded its time limit. The app or node may still be working; check its job status before submitting again.") from exc
        raise SiliconUnavailable(f"Could not reach Silicon Optimizer: {exc.reason}")
    return json.loads(body) if body else {}


def get(path: str, timeout: float = 10) -> Any:
    endpoint = resolve()
    req = request.Request(
        endpoint.base_url + path,
        headers={"Authorization": f"Bearer {endpoint.token}", "Accept": "application/json"},
    )
    return _open(req, timeout)


def post(path: str, body: dict[str, Any], timeout: float) -> Any:
    endpoint = resolve()
    req = request.Request(
        endpoint.base_url + path,
        data=json.dumps(body).encode("utf-8"),
        method="POST",
        headers={
            "Authorization": f"Bearer {endpoint.token}",
            "Content-Type": "application/json",
            "Accept": "application/json",
        },
    )
    return _open(req, timeout)


def is_running() -> bool:
    """True when the app answers /health. Cheap; safe to call from get_status()."""
    try:
        endpoint = resolve()
    except SiliconUnavailable:
        return False
    try:
        req = request.Request(endpoint.base_url + "/health")
        with request.urlopen(req, timeout=3):
            return True
    except (error.URLError, OSError):
        return False


def deliver(source: str, output_path: Optional[str]) -> str:
    """Put the app's output where the pipeline asked for it.

    The app writes into its own output folder and returns that path. OpenMontage
    tools are expected to honour ``output_path`` when given one, so the file is
    copied there — copied, not moved, because the app's own Images/3D tabs still
    list it and a moved file would show as a broken entry.
    """
    if not output_path:
        return source
    destination = Path(output_path)
    destination.parent.mkdir(parents=True, exist_ok=True)
    if destination.resolve() != Path(source).resolve():
        shutil.copy2(source, destination)
    return str(destination)


def drop_none(body: dict[str, Any]) -> dict[str, Any]:
    """The app's decoders treat a missing key as "use the default"; a null does not."""
    return {key: value for key, value in body.items() if value is not None}
