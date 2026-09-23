#!/usr/bin/env python3
"""Apple-Silicon MLX video node for Silicon Optimizer.

Implements Silicon Optimizer's remote video-node contract with a single,
resumable render queue.  LTX renders at a memory-conscious internal size and
ffmpeg produces a broadly playable review MP4 at the requested display size.
"""

from __future__ import annotations

import argparse
import base64
import fcntl
import hashlib
import hmac
import json
import os
import queue
import re
import shutil
import signal
import subprocess
import sys
import threading
import time
import traceback
import uuid
from datetime import datetime, timezone
from fractions import Fraction
from functools import lru_cache
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode, urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


def configured_path(name: str, default: Path) -> Path:
    return Path(os.environ.get(name) or default).expanduser().absolute()


HOST = os.environ.get("SILICON_VIDEO_HOST", "127.0.0.1")
PORT = int(os.environ.get("SILICON_VIDEO_PORT", "8790"))
SILICON_SUPPORT = Path.home() / "Library/Application Support/SiliconOptimizer"
APP_SUPPORT = configured_path("SILICON_VIDEO_DATA_DIR", SILICON_SUPPORT / "video-node")
SWARM_CONFIG = configured_path("SILICON_SWARM_CONFIG", SILICON_SUPPORT / "swarm.json")
TOKEN_FILE = configured_path("SILICON_VIDEO_TOKEN_FILE", APP_SUPPORT / "token")
LTX_ROOT = configured_path("SILICON_VIDEO_LTX_ROOT", APP_SUPPORT / "ltx-2-mlx")
LTX_BIN = configured_path("SILICON_VIDEO_LTX_BIN", LTX_ROOT / ".venv/bin/ltx-2-mlx")
MODEL_DIR = configured_path("SILICON_VIDEO_MODEL_DIR", APP_SUPPORT / "models/ltx-2.3-mlx-q4")
GEMMA_DIR = configured_path("SILICON_VIDEO_GEMMA_DIR", APP_SUPPORT / "models/gemma-3-12b-it-4bit")
STATE_DIR = APP_SUPPORT / "state"
ARTIFACT_DIR = APP_SUPPORT / "artifacts"
UPLOAD_DIR = APP_SUPPORT / "uploads"
DEFAULT_REVIEW_DIR = Path.home() / "Movies/Silicon Optimizer"
REVIEW_DIR = configured_path("SILICON_VIDEO_REVIEW_DIR", DEFAULT_REVIEW_DIR)
# Explicit compatibility switch for existing standalone HoneyBadger deployments.
LEGACY_HB_LAYOUT = os.environ.get("SILICON_VIDEO_LEGACY_HB_LAYOUT") == "1"
if LEGACY_HB_LAYOUT and os.environ.get("HONEYBADGER_REVIEW_DIR"):
    REVIEW_DIR = configured_path("HONEYBADGER_REVIEW_DIR", DEFAULT_REVIEW_DIR)
STATE_FILE = STATE_DIR / "jobs.json"
# A 30 MiB image becomes roughly 40 MiB after base64 encoding.
MAX_JSON_BYTES = 42 * 1024 * 1024
MAX_ARTIFACT_BYTES = 1024 * 1024 * 1024
SAFE_ID = re.compile(r"^[A-Za-z0-9_-]{1,64}$")
VIDEO_SUFFIXES = {".mp4", ".mov", ".webm"}
PHOSPHENE_PANEL_URL = os.environ.get(
    "PHOSPHENE_PANEL_URL", "http://127.0.0.1:8198"
).rstrip("/")
PHOSPHENE_HTTP_TIMEOUT_SECONDS = 5.0
PHOSPHENE_POLL_SECONDS = 2.0
JOB_TIMEOUT_SECONDS = 12 * 60 * 60
CANCEL_CONFIRM_SECONDS = 15.0
MAX_PHOSPHENE_JSON_BYTES = 16 * 1024 * 1024
H3_SECONDS = frozenset({3, 5, 10, 15})
MAX_H3_CHAIN_PROMPT_CHARS = 4000
PHOSPHENE_H3_TURBO = os.environ.get("PHOSPHENE_H3_TURBO", "true").strip().lower() not in {
    "0",
    "false",
    "no",
    "off",
}


def _phosphene_output_roots() -> Tuple[Path, ...]:
    configured = os.environ.get("PHOSPHENE_OUTPUT_ROOTS", "").strip()
    if configured:
        values = [item for item in configured.split(os.pathsep) if item]
    else:
        values = [
            "~/pinokio/api/phosphene.git/mlx_outputs",
            "~/pinokio/api/phosphene-dev.git/mlx_outputs",
            "~/phosphene/mlx_outputs",
        ]
    return tuple(Path(item).expanduser() for item in values)


PHOSPHENE_OUTPUT_ROOTS = _phosphene_output_roots()


class _NoRedirectHandler(HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


PHOSPHENE_HTTP_OPENER = build_opener(ProxyHandler({}), _NoRedirectHandler())


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def job_deadline(job: Dict[str, Any]) -> float:
    if job.get("deadline_epoch") is not None:
        return float(job["deadline_epoch"])
    try:
        created = datetime.fromisoformat(str(job["created_at"]).replace("Z", "+00:00"))
        return created.timestamp() + JOB_TIMEOUT_SECONDS
    except (KeyError, TypeError, ValueError):
        return time.time() + JOB_TIMEOUT_SECONDS


def job_remaining_seconds(job: Dict[str, Any], maximum: float = JOB_TIMEOUT_SECONDS) -> float:
    remaining = job_deadline(job) - time.time()
    if remaining <= 0:
        raise RuntimeError("video job exceeded the 12-hour limit from submission (including queue time)")
    return min(maximum, remaining)


class JobCancelled(Exception):
    """A cancel was accepted for this job; the worker stops at this point."""


class OwnedProcess:
    """A renderer this node started for one job, in its own process group.

    Signals go to that group only while the child is unreaped. Reaping happens
    under the same lock, so a signal can never reach a recycled process ID:
    cancelling one job must not be able to stop anything else on the Mac.
    """

    def __init__(self, process: Any) -> None:
        self.process = process
        self._lock = threading.Lock()

    def poll(self) -> Optional[int]:
        with self._lock:
            return self.process.poll()

    def signal(self, signum: int) -> bool:
        with self._lock:
            if self.process.poll() is not None:
                return False
            try:
                os.killpg(self.process.pid, signum)
            except ProcessLookupError:
                return False
            return True

    def wait(self, timeout: Optional[float] = None) -> Optional[int]:
        deadline = None if timeout is None else time.monotonic() + timeout
        while True:
            code = self.poll()
            if code is not None:
                return code
            if deadline is not None and time.monotonic() >= deadline:
                return None
            time.sleep(0.05)

    def terminate(self, grace_seconds: float = 10.0) -> None:
        if self.signal(signal.SIGTERM) and self.wait(grace_seconds) is None:
            self.signal(signal.SIGKILL)
            self.wait(3.0)


def required_assets() -> Tuple[Path, ...]:
    return (
        LTX_BIN,
        MODEL_DIR / "transformer-distilled.safetensors",
        MODEL_DIR / "spatial_upscaler_x2_v1_1.safetensors",
        MODEL_DIR / "vae_decoder.safetensors",
        MODEL_DIR / "vocoder.safetensors",
        GEMMA_DIR / "config.json",
    )


def assets_ready() -> bool:
    return all(path.exists() for path in required_assets())


def _validated_phosphene_base_url(value: Optional[str] = None) -> str:
    """Return a canonical loopback-only Phosphene panel URL.

    Phosphene intentionally has no HTTP authentication.  Never let a config
    typo turn prompt/image submission into an outbound request.
    """
    raw = (value if value is not None else PHOSPHENE_PANEL_URL).strip().rstrip("/")
    parsed = urlparse(raw)
    try:
        port = parsed.port
    except ValueError as exc:
        raise RuntimeError("PHOSPHENE_PANEL_URL has an invalid port") from exc
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "::1", "localhost"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.query
        or parsed.fragment
        or parsed.path not in {"", "/"}
    ):
        raise RuntimeError(
            "PHOSPHENE_PANEL_URL must be an HTTP loopback origin with no path"
        )
    if port is None:
        return f"http://{parsed.hostname}"
    host = f"[{parsed.hostname}]" if parsed.hostname == "::1" else parsed.hostname
    return f"http://{host}:{port}"


def phosphene_request(path: str, form: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    if not path.startswith("/") or "?" in path or "#" in path:
        raise RuntimeError("invalid Phosphene API path")
    base = _validated_phosphene_base_url()
    body = None
    headers = {"Accept": "application/json"}
    method = "GET"
    if form is not None:
        body = urlencode({key: str(value) for key, value in form.items()}).encode("utf-8")
        headers["Content-Type"] = "application/x-www-form-urlencoded"
        method = "POST"
    request = Request(base + path, data=body, headers=headers, method=method)
    try:
        with PHOSPHENE_HTTP_OPENER.open(
            request, timeout=PHOSPHENE_HTTP_TIMEOUT_SECONDS
        ) as response:
            raw = response.read(MAX_PHOSPHENE_JSON_BYTES + 1)
    except HTTPError as exc:
        try:
            raw_error = exc.read(4096)
            error_payload = json.loads(raw_error.decode("utf-8"))
            detail = str(error_payload.get("error") or "")[:500]
        except (OSError, UnicodeDecodeError, ValueError, TypeError, AttributeError):
            detail = ""
        suffix = f": {detail}" if detail else ""
        raise RuntimeError(f"Phosphene {path} returned HTTP {exc.code}{suffix}") from exc
    except (URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"Phosphene panel is unavailable at {base}") from exc
    if len(raw) > MAX_PHOSPHENE_JSON_BYTES:
        raise RuntimeError("Phosphene response exceeded the 16 MiB safety limit")
    try:
        payload = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise RuntimeError(f"Phosphene {path} returned invalid JSON") from exc
    if not isinstance(payload, dict):
        raise RuntimeError(f"Phosphene {path} returned an invalid response")
    return payload


def phosphene_h3_readiness(snapshot: Optional[Dict[str, Any]] = None) -> Dict[str, Any]:
    try:
        status = snapshot if snapshot is not None else phosphene_request("/status")
    except RuntimeError as exc:
        return {"ready": False, "reason": str(exc), "status": None}
    h3 = status.get("h3") if isinstance(status, dict) else None
    if not isinstance(h3, dict):
        return {
            "ready": False,
            "reason": "Phosphene did not report a Hailuo H3 capability",
            "status": status,
        }
    # Older panels did not publish `capable`; absence means legacy-compatible
    # true. A present false wins over weight availability, which prevents an
    # environment where sysctl detection failed from advertising an engine the
    # panel itself will refuse at dispatch.
    ready = bool(h3.get("available")) and bool(h3.get("capable", True))
    if ready:
        reason = ""
    else:
        missing = h3.get("missing")
        if isinstance(missing, list) and missing:
            reason = "Hailuo H3 is missing required components: " + "; ".join(
                Path(str(item)).name for item in missing[:8]
            )
        else:
            reason = str(h3.get("ram_note") or h3.get("reason") or "Hailuo H3 is not ready")
    return {"ready": ready, "reason": reason, "status": status}


def phosphene_supports_h3_steps() -> bool:
    """Gate on the running panel, not its disk checkout or this adapter's version.

    H3 /status has no sampling-depth capability in 4.12.2. That release's
    /version reports the boot version; its make_job and runner forward 4–30
    points. Fail closed for unknown/dev/new-major panels. We also verify the
    completed job's actual parameters before publishing an overridden render.
    """
    try:
        version = phosphene_request("/version").get("local_version")
    except RuntimeError:
        return False
    match = re.fullmatch(r"v?(4)\.(\d+)\.(\d+)", str(version or ""))
    return bool(match and tuple(map(int, match.groups())) >= (4, 12, 2))


def normalize_h3_steps(value: Any, model: str, turbo: Any) -> Optional[int]:
    # JSON null, like omission in the Codable API, means Auto.
    if value is None:
        return None
    if model != "hailuo-h3" or type(value) is not int or not 4 <= value <= 30:
        raise ValueError("h3_steps must be an integer from 4 through 30, only for hailuo-h3; omit for Auto")
    if turbo is not False:
        raise ValueError("h3_steps requires explicit h3_turbo=false; Turbo pins its own schedule")
    return value


def validate_phosphene_h3_request(
    readiness: Dict[str, Any], seconds: int, has_image: bool, has_chain_prompts: bool = False,
    h3_steps: Optional[int] = None,
) -> None:
    if not readiness.get("ready"):
        raise RuntimeError(str(readiness.get("reason") or "Hailuo H3 is not ready"))
    status = readiness.get("status")
    h3 = status.get("h3") if isinstance(status, dict) else None
    if not isinstance(h3, dict):
        raise RuntimeError("Phosphene did not report a Hailuo H3 capability")
    # Current Phosphene publishes both booleans. Missing is therefore an
    # unknown capability, not a legacy promise we can safely infer; older H3
    # runners are exactly the versions that may lack these flags.
    if seconds > 5 and h3.get("chain") is not True:
        raise RuntimeError(
            "This Phosphene H3 runner cannot chain 10/15-second clips; "
            "update the H3 pack or choose 3 or 5 seconds"
        )
    if has_image and h3.get("first_frame") is not True:
        raise RuntimeError(
            "This Phosphene H3 runner cannot condition on a first frame; "
            "update the H3 pack or submit text-to-video"
        )
    if has_chain_prompts and h3.get("chain_prompts") is not True:
        raise RuntimeError(
            "This Phosphene H3 runner cannot condition each chained window "
            "with a separate prompt; update the H3 pack or omit h3_chain_prompts"
        )
    if h3_steps is not None and not phosphene_supports_h3_steps():
        raise RuntimeError(
            "Cannot verify h3_steps support in the running Phosphene panel; "
            "use Phosphene 4.12.2 or a later 4.x release, or omit steps for Auto"
        )


def phosphene_sampling_provenance(job: Dict[str, Any], record: Dict[str, Any]) -> Dict[str, Any]:
    params = record.get("params")
    params = params if isinstance(params, dict) else {}
    steps = params.get("steps")
    steps = steps if type(steps) is int and steps >= 2 else None
    requested = job.get("h3_steps")
    if requested is not None and (steps != requested or params.get("h3_turbo") is not False
                                  or params.get("h3_steps") != requested):
        raise RuntimeError(
            "Phosphene did not confirm the requested H3 denoising steps with Turbo off; "
            "the render will not be published as a matching result. Check the saved Phosphene job before retrying"
        )
    return {
        "requested_h3_steps": requested,
        "h3_steps": steps,
        "h3_forwards_per_window": steps - 1 if steps is not None else None,
    }


def normalize_h3_chain_prompts(
    value: Any, model: str, seconds: int, provided: bool
) -> Optional[list]:
    if not provided:
        return None
    if model != "hailuo-h3":
        raise ValueError("h3_chain_prompts is only supported by hailuo-h3")
    if seconds not in {10, 15}:
        raise ValueError("h3_chain_prompts is only valid for 10/15-second H3 clips")
    if not isinstance(value, list):
        raise ValueError("h3_chain_prompts must be a JSON list of strings")
    expected = seconds // 5
    if len(value) != expected:
        raise ValueError(
            f"h3_chain_prompts must contain exactly {expected} prompts for {seconds} seconds"
        )
    normalized = []
    for index, item in enumerate(value, start=1):
        if not isinstance(item, str):
            raise ValueError(f"h3_chain_prompts item {index} must be a string")
        prompt = item.strip()
        if not prompt:
            raise ValueError(f"h3_chain_prompts item {index} must not be empty")
        if len(prompt) > MAX_H3_CHAIN_PROMPT_CHARS:
            raise ValueError(
                f"h3_chain_prompts item {index} exceeds {MAX_H3_CHAIN_PROMPT_CHARS} characters"
            )
        normalized.append(prompt)
    return normalized


def model_readiness(model: str) -> Dict[str, Any]:
    if model in {"ltx2-distilled", "ltx-2.3-mlx-q4"}:
        missing = [str(path) for path in required_assets() if not path.exists()]
        return {"ready": not missing, "reason": "", "missing": missing}
    if model == "hailuo-h3":
        state = phosphene_h3_readiness()
        return {
            "ready": state["ready"],
            "reason": state["reason"],
            "missing": [],
        }
    return {"ready": False, "reason": f"unsupported video model: {model}", "missing": []}


def expected_token() -> str:
    """Read the private token; legacy installs may use this exact peer's token.

    Never select an unrelated localhost service or the first remote peer. A
    shared token is a fallback only for an exact matching registry entry.
    """
    try:
        with TOKEN_FILE.open(encoding="utf-8") as handle:
            token = handle.read(4097).strip()
        return token if 0 < len(token) <= 4096 else ""
    except FileNotFoundError:
        pass
    except (OSError, UnicodeDecodeError):
        return ""
    try:
        data = json.loads(SWARM_CONFIG.read_text(encoding="utf-8"))
        peers = data.get("peers", [])
        for peer in peers:
            if not isinstance(peer, dict):
                continue
            parsed = urlparse(str(peer.get("base_url", "")))
            if (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}
                    and parsed.port == PORT and not parsed.username and not parsed.password
                    and parsed.path in {"", "/"} and not parsed.query and not parsed.fragment):
                token = peer.get("token") or data.get("swarm_token") or ""
                return token.strip() if isinstance(token, str) else ""
    except (OSError, ValueError, TypeError, AttributeError):
        pass
    return ""


@lru_cache(maxsize=1)
def hardware_profile() -> Dict[str, Any]:
    """Detect this Mac rather than advertising the original development host."""
    def sysctl(key: str) -> str:
        try:
            result = subprocess.run(
                ["/usr/sbin/sysctl", "-n", key], capture_output=True, text=True, timeout=5
            )
            return result.stdout.strip() if result.returncode == 0 else ""
        except (OSError, subprocess.TimeoutExpired):
            return ""
    memory = sysctl("hw.memsize")
    return {
        "chip": sysctl("machdep.cpu.brand_string") or "Apple Silicon",
        "memory_gb": round(int(memory) / (1024 ** 3), 2) if memory.isdigit() else 0,
    }


def executable(name: str) -> str:
    for candidate in (
        f"/opt/homebrew/bin/{name}",
        f"/usr/local/bin/{name}",
        f"/usr/bin/{name}",
    ):
        if Path(candidate).exists():
            return candidate
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f"Required executable not found: {name}")
    return found


def atomic_json(path: Path, payload: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(payload, indent=2, sort_keys=True), encoding="utf-8")
    temporary.chmod(0o600)
    temporary.replace(path)


def probe_media(path: Path) -> Dict[str, Any]:
    ffprobe = executable("ffprobe")
    result = subprocess.run(
        [
            ffprobe,
            "-v",
            "error",
            "-show_entries",
            "format=duration:stream=index,codec_name,codec_type,width,height,avg_frame_rate,r_frame_rate,nb_frames,duration",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
        timeout=60,
    )
    if result.returncode != 0:
        raise RuntimeError("ffprobe failed: " + result.stderr[-1000:])
    data = json.loads(result.stdout)
    video = next((stream for stream in data.get("streams", []) if stream.get("codec_type") == "video"), {})
    frame_count = video.get("nb_frames", 0)
    try:
        frame_count = int(frame_count or 0)
    except (TypeError, ValueError):
        frame_count = 0
    return {
        "duration": float(data.get("format", {}).get("duration", 0) or 0),
        "video_duration": float(video.get("duration", 0) or 0),
        "width": video.get("width"),
        "height": video.get("height"),
        "codec": video.get("codec_name"),
        "frame_rate": video.get("avg_frame_rate") or video.get("r_frame_rate") or "0/1",
        "nb_frames": frame_count,
        "audio": any(stream.get("codec_type") == "audio" for stream in data.get("streams", [])),
    }


def completed_media_matches(job: Dict[str, Any], path: Path) -> bool:
    if not path.is_file() or path.stat().st_size < 4096:
        return False
    try:
        probe = probe_media(path)
        plan = job_delivery_plan(job)
        expected_frames = int(job.get("frames") or seconds_to_frames(int(job.get("seconds") or 10)))
        seconds = int(job.get("seconds") or 10)
        rate = Fraction(str(probe["frame_rate"]))
        duration = probe["video_duration"] or probe["duration"]
        return (
            probe["codec"] == "h264"
            and probe["width"] == plan["output_w"]
            and probe["height"] == plan["output_h"]
            and abs(float(rate) - 24.0) < 0.01
            and (not probe["nb_frames"] or abs(probe["nb_frames"] - expected_frames) <= 1)
            and max(0.5, seconds - 0.75) <= duration <= seconds + 1.0
        )
    except (OSError, RuntimeError, ValueError, ZeroDivisionError, subprocess.TimeoutExpired):
        return False


def completed_sidecar_matches(job: Dict[str, Any], path: Path) -> bool:
    """A crash between MP4 publication and sidecar write is not completion."""
    try:
        metadata = json.loads(path.with_suffix(".json").read_text(encoding="utf-8"))
        h3 = job.get("model") == "hailuo-h3"
        if not isinstance(metadata, dict) or any(
            metadata.get(key) != job.get(key) for key in ("id", "prompt", "seed")
        ):
            return False
        expected_model = "MiniMaxAI/MiniMax-H3" if h3 else "dgrauet/ltx-2.3-mlx-q4"
        if metadata.get("model") != expected_model:
            return False
        if h3 and (metadata.get("phosphene_job_id") != job.get("phosphene_job_id")
                   or metadata.get("h3_chain_prompts") != job.get("h3_chain_prompts")):
            return False
        if h3 and job.get("h3_steps") is not None and (
            metadata.get("requested_h3_steps") != job["h3_steps"]
            or metadata.get("h3_steps") != job["h3_steps"]
            or metadata.get("h3_turbo") is not False
        ):
            return False
        return True
    except (OSError, ValueError, TypeError):
        return False


def acquire_node_lock() -> Any:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    lock_path = STATE_DIR / "node.lock"
    handle = lock_path.open("a+", encoding="utf-8")
    try:
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
    except BlockingIOError as exc:
        handle.close()
        raise RuntimeError("another local MLX video node is already running") from exc
    return handle


def seconds_to_frames(seconds: int) -> int:
    # LTX requires (frames - 1) % 8 == 0.  At 24 fps this is exact for 10/15 s.
    return max(9, round(seconds * 24 / 8) * 8 + 1)


_LTX_PLANS = {
    "1080p": {"internal_w": 768, "internal_h": 448, "output_w": 1920, "output_h": 1080},
    "1920x1080": {"internal_w": 768, "internal_h": 448, "output_w": 1920, "output_h": 1080},
    "720p": {"internal_w": 768, "internal_h": 448, "output_w": 1280, "output_h": 720},
    "1280x720": {"internal_w": 768, "internal_h": 448, "output_w": 1280, "output_h": 720},
    "480p": {"internal_w": 672, "internal_h": 384, "output_w": 854, "output_h": 480},
    "854x480": {"internal_w": 672, "internal_h": 384, "output_w": 854, "output_h": 480},
    "360p": {"internal_w": 576, "internal_h": 320, "output_w": 640, "output_h": 360},
    "640x360": {"internal_w": 576, "internal_h": 320, "output_w": 640, "output_h": 360},
}
LTX_RESOLUTIONS = ("360p", "480p", "720p", "1080p")


def resolution_plan(value: str) -> Dict[str, int]:
    """The LTX canvas and delivery size for a request, or ValueError.

    1080p keeps the proven 768x448 canvas that 720p uses and scales it for
    delivery: a larger canvas has not been measured against this node's memory
    budget. Every plan is an upscale, and the sidecar and job say so.
    """
    normalized = value.strip().lower().replace(" ", "")
    if normalized not in _LTX_PLANS:
        raise ValueError("LTX resolution must be 360p, 480p, 720p, or 1080p")
    return dict(_LTX_PLANS[normalized])


def legacy_resolution_plan(value: str) -> Dict[str, int]:
    """What nodes before 1080p delivery rendered: anything unknown became 720p.

    Only used to recognise their finished artifacts after an upgrade, so a
    completed 1080p-request/720p-output clip is not rendered again.
    """
    normalized = value.strip().lower().replace(" ", "")
    if normalized in {"1080p", "1920x1080"} or normalized not in _LTX_PLANS:
        normalized = "720p"
    return dict(_LTX_PLANS[normalized])


def job_delivery_plan(job: Dict[str, Any]) -> Dict[str, int]:
    """The canvas this job's artifact was, or will be, rendered to.

    New jobs pin their plan at submission. A job saved without one predates
    1080p delivery, so its artifact follows the old table.
    """
    if job.get("model") == "hailuo-h3":
        return h3_output_resolution_plan(str(job.get("resolution") or "720p"))
    pinned = job.get("delivery_plan")
    if isinstance(pinned, dict) and all(
        type(pinned.get(key)) is int and pinned[key] > 0
        for key in ("internal_w", "internal_h", "output_w", "output_h")
    ):
        return {key: pinned[key] for key in ("internal_w", "internal_h", "output_w", "output_h")}
    return legacy_resolution_plan(str(job.get("resolution") or "720p"))


def delivery_report(job: Dict[str, Any]) -> Dict[str, Any]:
    """Requested size versus the pixels planned and, once done, delivered.

    `width`/`height` and `matches_request` describe a validated file, so they
    appear only when the job is done; until then only the plan is reported.
    `scaling` distinguishes an LTX canvas scaled up by ffmpeg from native
    generation; H3's canvas belongs to Phosphene, so it is not claimed here.
    """
    requested = str(job.get("resolution") or "720p")
    plan = job_delivery_plan(job)
    delivered = job.get("status") == "done"
    report: Dict[str, Any] = {
        "requested": requested,
        "planned_width": plan["output_w"],
        "planned_height": plan["output_h"],
        "delivered": delivered,
    }
    if delivered:
        # A done job's file was probed against this plan before it was published,
        # or at load for one finished before sizes were recorded.
        report["width"] = job.get("delivered_width") or plan["output_w"]
        report["height"] = job.get("delivered_height") or plan["output_h"]
    if job.get("model") != "hailuo-h3":
        report["internal_width"] = plan["internal_w"]
        report["internal_height"] = plan["internal_h"]
        report["scaling"] = (
            "upscaled" if (plan["output_w"], plan["output_h"]) != (plan["internal_w"], plan["internal_h"])
            else "native"
        )
        if delivered:
            try:
                current = resolution_plan(requested)
                report["matches_request"] = (
                    (report["width"], report["height"]) == (current["output_w"], current["output_h"])
                )
            except ValueError:
                report["matches_request"] = False
    return report


def h3_output_resolution_plan(value: str) -> Dict[str, int]:
    normalized = value.strip().lower().replace(" ", "")
    if normalized in {"1080p", "1920x1080"}:
        return {"internal_w": 768, "internal_h": 448, "output_w": 1920, "output_h": 1080}
    return resolution_plan(value)


def phosphene_render_options(resolution: str, seconds: int) -> Dict[str, str]:
    if seconds not in H3_SECONDS:
        raise ValueError("Hailuo H3 seconds must be one of 3, 5, 10, or 15")
    normalized = resolution.strip().lower().replace(" ", "")
    choices = {
        "480p": ("draft", "off"),
        "854x480": ("draft", "off"),
        "720p": ("standard", "fit_720p"),
        "1280x720": ("standard", "fit_720p"),
        "1080p": ("high", "fit_1080p"),
        "1920x1080": ("high", "fit_1080p"),
    }
    if normalized not in choices:
        raise ValueError("Hailuo H3 resolution must be 480p, 720p, or 1080p")
    quality, upscale = choices[normalized]
    return {
        "h3_quality": quality,
        "h3_length": f"{seconds}s",
        "h3_upscale": upscale,
    }


def phosphene_submission_form(job: Dict[str, Any]) -> Dict[str, str]:
    options = phosphene_render_options(str(job["resolution"]), int(job["seconds"]))
    mode = "i2v" if job.get("image_path") else "t2v"
    turbo = bool(job.get("phosphene_h3_turbo", PHOSPHENE_H3_TURBO))
    form = {
        "engine": "h3",
        "mode": mode,
        "prompt": str(job["prompt"]),
        "seed": str(job["seed"]),
        "h3_quality": options["h3_quality"],
        "h3_length": options["h3_length"],
        "h3_upscale": options["h3_upscale"],
        "h3_turbo": "true" if turbo else "false",
        "image": str(job.get("image_path") or ""),
        "enhance": "false",
        "open_when_done": "false",
    }
    chain_prompts = job.get("h3_chain_prompts")
    steps = normalize_h3_steps(job.get("h3_steps"), "hailuo-h3", job.get("phosphene_h3_turbo"))
    if steps is not None:
        form["h3_steps"] = str(steps)
    if chain_prompts is not None:
        form["h3_chain_prompts"] = json.dumps(
            chain_prompts, ensure_ascii=False, separators=(",", ":")
        )
    return form


def locate_phosphene_job(
    snapshot: Dict[str, Any], phosphene_job_id: str
) -> Tuple[str, Optional[Dict[str, Any]]]:
    current = snapshot.get("current")
    if isinstance(current, dict) and str(current.get("id")) == phosphene_job_id:
        return "current", current
    queued = snapshot.get("queue")
    if isinstance(queued, list):
        for item in queued:
            if isinstance(item, dict) and str(item.get("id")) == phosphene_job_id:
                return "queued", item
    history = snapshot.get("history")
    if isinstance(history, list):
        for item in history:
            if isinstance(item, dict) and str(item.get("id")) == phosphene_job_id:
                return "history", item
    return "missing", None


def map_phosphene_progress(location: str, record: Optional[Dict[str, Any]]) -> Dict[str, Any]:
    item = record or {}
    remote_status = str(item.get("status") or location).lower()
    details = item.get("progress")
    details = details if isinstance(details, dict) else {}
    if location == "queued":
        return {"status": "running", "stage": "queued in Phosphene", "progress": 0.01}
    if location == "history" and remote_status == "done":
        return {"status": "done", "stage": "Phosphene render complete", "progress": 0.94}
    if location == "history" and remote_status in {"failed", "cancelled", "stopped"}:
        return {"status": remote_status, "stage": f"Phosphene render {remote_status}", "progress": 0.0}
    try:
        pct = float(details.get("pct", 0.0) or 0.0)
    except (TypeError, ValueError):
        pct = 0.0
    # Reserve the final 5% for copying, transcoding, and validating the file.
    progress = max(0.02, min(0.94, pct / 100.0 * 0.94))
    stage = str(
        details.get("phase_label")
        or details.get("phase")
        or ("rendering Hailuo H3 in Phosphene" if location == "current" else remote_status)
    )
    return {"status": "running", "stage": stage, "progress": progress}


def safe_output_name(value: str, job_id: str) -> str:
    stem = Path(value or job_id).stem
    stem = re.sub(r"[^A-Za-z0-9_-]+", "_", stem).strip("_-")[:96]
    return f"{stem or job_id}.mp4"


def validated_phosphene_output(value: Any, seconds: int) -> Path:
    raw = str(value or "").strip()
    if not raw:
        raise RuntimeError("Phosphene completed without an output path")
    candidate = Path(raw).expanduser()
    if not candidate.is_absolute():
        raise RuntimeError("Phosphene returned a non-absolute output path")
    try:
        resolved = candidate.resolve(strict=True)
    except OSError as exc:
        raise RuntimeError("Phosphene output is no longer available") from exc
    trusted = False
    for root in PHOSPHENE_OUTPUT_ROOTS:
        try:
            resolved.relative_to(root.resolve(strict=True))
            trusted = True
            break
        except (OSError, ValueError):
            continue
    if not trusted:
        raise RuntimeError("Phosphene output was outside the configured output folders")
    if not resolved.is_file() or resolved.suffix.lower() not in VIDEO_SUFFIXES:
        raise RuntimeError("Phosphene output is not a supported video file")
    size = resolved.stat().st_size
    if size < 4096 or size > MAX_ARTIFACT_BYTES:
        raise RuntimeError("Phosphene output failed the artifact size check")
    probe = probe_media(resolved)
    duration = float(probe.get("video_duration") or probe.get("duration") or 0.0)
    width = int(probe.get("width") or 0)
    height = int(probe.get("height") or 0)
    if width <= 0 or height <= 0:
        raise RuntimeError("Phosphene output has no readable video stream")
    if not (max(0.5, seconds - 1.25) <= duration <= seconds + 3.0):
        raise RuntimeError(f"Phosphene output had an unexpected duration: {duration:.3f}s")
    return resolved


class RenderQueue:
    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.jobs: Dict[str, Dict[str, Any]] = {}
        self.pending: "queue.Queue[str]" = queue.Queue()
        self.current_job_id: Optional[str] = None
        # Renderer processes by the job that started them. A cancel signals the
        # one registered for its own job and nothing else.
        self.processes: Dict[str, OwnedProcess] = {}
        # Jobs already publishing their artifact: too late to cancel.
        self.committing: set = set()
        # One Phosphene removal at a time, so a repeated cancel reads the first
        # one's outcome instead of racing it.
        self.phosphene_cancel_lock = threading.Lock()
        self.stop_event = threading.Event()
        self._load()
        self.worker: Optional[threading.Thread] = None

    def start(self) -> None:
        if self.worker and self.worker.is_alive():
            return
        self.worker = threading.Thread(target=self._worker, name="mlx-video-worker", daemon=True)
        self.worker.start()

    def _load(self) -> None:
        STATE_DIR.mkdir(parents=True, exist_ok=True)
        ARTIFACT_DIR.mkdir(parents=True, exist_ok=True)
        UPLOAD_DIR.mkdir(parents=True, exist_ok=True)
        (REVIEW_DIR / "final").mkdir(parents=True, exist_ok=True)
        (REVIEW_DIR / "posters").mkdir(parents=True, exist_ok=True)
        (REVIEW_DIR / "logs").mkdir(parents=True, exist_ok=True)
        try:
            raw = json.loads(STATE_FILE.read_text(encoding="utf-8"))
            if not isinstance(raw, dict) or any(
                not isinstance(job, dict) or job.get("id") != key or not SAFE_ID.fullmatch(key)
                for key, job in raw.items()
            ):
                raise ValueError("invalid persisted job map")
            self.jobs = raw
        except FileNotFoundError:
            self.jobs = {}
        except (ValueError, TypeError) as exc:
            raise RuntimeError("video queue state is invalid; original state file has been preserved") from exc

        for job in self.jobs.values():
            job.setdefault("deadline_epoch", job_deadline(job))
            if job.get("status") == "cancelled":
                # Terminal: never resumed, whatever is on disk.
                continue
            output = Path(str(job.get("output_path", "")))
            if completed_media_matches(job, output) and completed_sidecar_matches(job, output):
                # Includes a cancel that arrived after publishing had begun: the
                # caller was told the job completed, and it did.
                # A clip finished before 1080p delivery keeps the size it was
                # rendered at. Pin it, so no later reading of its resolution
                # can make a finished artifact look incomplete and render again.
                if job.get("model") != "hailuo-h3" and "delivery_plan" not in job:
                    job["delivery_plan"] = job_delivery_plan(job)
                job["status"] = "done"
                job["stage"] = "complete"
                job["progress"] = 1.0
                continue
            if job.get("cancel_requested_at") and job.get("status") in {"queued", "running", "done"}:
                # Accepted, but the node stopped before its worker confirmed it.
                # Resuming would render what the caller asked to stop.
                now = utc_now()
                job.update(status="cancelled", stage="cancelled", cancelled_at=now, updated_at=now, error=None,
                           cancel_detail="Cancelled; the node restarted before the renderer confirmed the stop, "
                           "and it will not resume or publish this job.")
                continue
            if job.get("status") in {"queued", "running", "done"}:
                job["status"] = "queued"
                job["stage"] = "recovering after node restart"
                job["progress"] = 0.0
                # The size of an artifact that is not complete is not delivered.
                job.pop("delivered_width", None)
                job.pop("delivered_height", None)
                self.pending.put(job["id"])
        self._persist()

    def _persist(self) -> None:
        with self.lock:
            atomic_json(STATE_FILE, self.jobs)

    def _update(self, job_id: str, **changes: Any) -> None:
        """Record the worker's progress, or stop it if the job was cancelled.

        The cancel check and the write share one lock, so an accepted cancel
        takes effect at the worker's next step and never after its next write.
        """
        with self.lock:
            self._checkpoint_locked(job_id)
            self._record_locked(job_id, changes)

    def _record(self, job_id: str, **changes: Any) -> None:
        """An unconditional write, for facts that must be kept even after a
        cancel: a remote job ID, or how the job ended."""
        with self.lock:
            self._record_locked(job_id, changes)

    def _record_locked(self, job_id: str, changes: Dict[str, Any]) -> None:
        self.jobs[job_id].update(changes)
        self.jobs[job_id]["updated_at"] = utc_now()
        self._persist()

    def _checkpoint_locked(self, job_id: str) -> None:
        job = self.jobs[job_id]
        if job.get("status") == "cancelled" or (
            job.get("cancel_requested_at") and job_id not in self.committing
        ):
            raise JobCancelled()

    def _checkpoint(self, job_id: str) -> None:
        with self.lock:
            self._checkpoint_locked(job_id)

    def _commit(self, job_id: str) -> None:
        """The last point a cancel wins. After it, the artifact is published."""
        with self.lock:
            self._checkpoint_locked(job_id)
            self.committing.add(job_id)

    def _mark_cancelled_locked(self, job_id: str, detail: str) -> None:
        job = self.jobs[job_id]
        now = utc_now()
        job.update(
            status="cancelled", stage="cancelled", error=None, updated_at=now,
            cancel_requested_at=job.get("cancel_requested_at") or now,
            cancelled_at=job.get("cancelled_at") or now,
            cancel_detail=job.get("cancel_detail") if job.get("status") == "cancelled" else detail,
        )
        self._persist()

    def _discard_staging(self, job_id: str) -> None:
        """Remove only this job's intermediate files; a published artifact stays."""
        with self.lock:
            job = dict(self.jobs.get(job_id) or {})
        for key in ("raw_path", "candidate_path"):
            if job.get(key):
                Path(str(job[key])).unlink(missing_ok=True)

    def _cancel_answer(self, job_id: str, http_status: int, outcome: str, detail: str) -> Tuple[int, Dict[str, Any]]:
        with self.lock:
            status = str((self.jobs.get(job_id) or {}).get("status") or "unknown")
        return http_status, {"job_id": job_id, "cancel": outcome, "status": status, "detail": detail}

    def cancel(self, job_id: str) -> Tuple[int, Dict[str, Any]]:
        """Stop one job, touching nothing that belongs to another.

        Outcomes: "cancelled" (confirmed, 200), "requested" (accepted, confirmation
        pending, 202), "completed" or "failed" (already terminal, 409),
        "unsupported" (cannot be stopped without risking other work, 409) and
        "unknown" (no such job, 404). Repeating a request repeats its answer.
        """
        owned: Optional[OwnedProcess] = None
        phosphene_job_id = ""
        with self.lock:
            job = self.jobs.get(job_id)
            if job is None:
                return HTTPStatus.NOT_FOUND, {"job_id": job_id, "cancel": "unknown", "status": "unknown",
                                              "detail": "This node has no job with that ID."}
            status = job.get("status")
            if status == "cancelled":
                return self._cancel_answer(job_id, HTTPStatus.OK, "cancelled",
                                           str(job.get("cancel_detail") or "Cancelled."))
            if status == "done" or job_id in self.committing:
                return self._cancel_answer(job_id, HTTPStatus.CONFLICT, "completed",
                                           "The render had already finished; its artifact is kept.")
            if status == "failed":
                return self._cancel_answer(job_id, HTTPStatus.CONFLICT, "failed",
                                           str(job.get("error") or "The render had already failed."))
            h3 = job.get("model") == "hailuo-h3"
            if h3 and job.get("phosphene_job_id"):
                phosphene_job_id = str(job["phosphene_job_id"])
            elif h3 and job.get("phosphene_submit_attempted"):
                return self._cancel_answer(
                    job_id, HTTPStatus.CONFLICT, "unsupported",
                    "Its submission to Phosphene has not returned a job ID, so there is no way to stop "
                    "that render and nothing else. Nothing was changed.")
            elif job_id != self.current_job_id:
                # Still waiting in this node's own queue: no renderer has it yet.
                self._mark_cancelled_locked(job_id, "Cancelled before rendering started.")
                return self._cancel_answer(job_id, HTTPStatus.OK, "cancelled", "Cancelled before rendering started.")
            else:
                job["cancel_requested_at"] = job.get("cancel_requested_at") or utc_now()
                self._persist()
                owned = self.processes.get(job_id)
        if phosphene_job_id:
            return self._cancel_phosphene(job_id, phosphene_job_id)
        deadline = time.monotonic() + CANCEL_CONFIRM_SECONDS
        if owned is not None:
            # Its SIGTERM grace and SIGKILL escalation run beside this answer, so the
            # request never waits longer than the confirmation window.
            threading.Thread(target=owned.terminate, name=f"cancel-{job_id}", daemon=True).start()
        while time.monotonic() < deadline:
            with self.lock:
                if self.jobs[job_id].get("status") == "cancelled":
                    return self._cancel_answer(job_id, HTTPStatus.OK, "cancelled",
                                               str(self.jobs[job_id].get("cancel_detail") or "Cancelled."))
            time.sleep(0.05)
        return self._cancel_answer(job_id, HTTPStatus.ACCEPTED, "requested",
                                   "The renderer is stopping; this job will report status \"cancelled\".")

    def _cancel_phosphene(self, job_id: str, phosphene_job_id: str) -> Tuple[int, Dict[str, Any]]:
        """Phosphene's only job-specific stop is removing a job that has not started.

        /queue/remove takes the expected job ID and checks it under the panel's own
        lock, so it cannot remove anything else. A render already running there has
        no such stop: its /stop ends whatever is current, which may be another
        client's job by the time it arrives, so it is never called.
        """
        with self.phosphene_cancel_lock:
            with self.lock:
                if self.jobs[job_id].get("status") == "cancelled":
                    return self._cancel_answer(job_id, HTTPStatus.OK, "cancelled",
                                               str(self.jobs[job_id].get("cancel_detail") or "Cancelled."))
            try:
                removed = phosphene_request("/queue/remove", {"id": phosphene_job_id}).get("removed") is True
                reason = ""
            except RuntimeError as exc:
                removed, reason = False, f" ({exc})"
            with self.lock:
                if removed:
                    self._mark_cancelled_locked(job_id, "Removed from Phosphene's queue before it started rendering.")
                    return self._cancel_answer(job_id, HTTPStatus.OK, "cancelled",
                                               "Removed from Phosphene's queue before it started rendering.")
            return self._cancel_answer(
                job_id, HTTPStatus.CONFLICT, "unsupported",
                "Phosphene has already started this render (or could not be asked" + reason + "). It offers no "
                "way to stop one specific running job, so nothing was stopped; the render continues and can "
                "still be downloaded.")

    def submit(self, request: Dict[str, Any]) -> str:
        # Requests arrive on separate HTTP threads. Keep deduplication, image
        # staging and queue insertion atomic for one entry_id.
        with self.lock:
            return self._submit_locked(request)

    def _submit_locked(self, request: Dict[str, Any]) -> str:
        prompt = str(request.get("prompt", "")).strip()
        if not prompt:
            raise ValueError("prompt is required")
        if len(prompt) > 12000:
            raise ValueError("prompt is too long")

        model = str(request.get("model") or "ltx2-distilled")
        if model not in {"ltx2-distilled", "ltx-2.3-mlx-q4", "hailuo-h3"}:
            raise ValueError(f"unsupported video model: {model}")

        h3_turbo = request.get("h3_turbo", PHOSPHENE_H3_TURBO)
        if "h3_turbo" in request and (model != "hailuo-h3" or not isinstance(h3_turbo, bool)):
            raise ValueError("h3_turbo must be a boolean and is only supported for hailuo-h3")
        h3_steps = normalize_h3_steps(request.get("h3_steps"), model, request.get("h3_turbo"))

        seconds = int(request.get("seconds") or 10)
        resolution = str(request.get("resolution") or "720p")
        chain_prompts = normalize_h3_chain_prompts(
            request.get("h3_chain_prompts"),
            model,
            seconds,
            "h3_chain_prompts" in request,
        )
        delivery_plan: Optional[Dict[str, int]] = None
        if model == "hailuo-h3":
            # Reject invalid discrete H3 durations/canvases before polling the
            # panel or staging an image.
            phosphene_render_options(resolution, seconds)
        else:
            if not 1 <= seconds <= 15:
                raise ValueError("seconds must be between 1 and 15")
            # An unknown size is refused, never quietly rendered at another.
            delivery_plan = resolution_plan(resolution)

        h3_state: Optional[Dict[str, Any]] = None
        if model == "hailuo-h3":
            # One status response answers readiness AND request-specific
            # capability gates; do not race three independently-polled facts.
            h3_state = phosphene_h3_readiness()
            readiness = {
                "ready": h3_state["ready"],
                "reason": h3_state["reason"],
                "missing": [],
            }
        else:
            readiness = model_readiness(model)
        if not readiness["ready"]:
            detail = readiness["reason"]
            if readiness["missing"]:
                detail = "missing: " + ", ".join(readiness["missing"])
            raise RuntimeError(f"Video model {model} is not ready; {detail}")

        if model == "hailuo-h3":
            assert h3_state is not None
            validate_phosphene_h3_request(
                h3_state,
                seconds,
                bool(request.get("image_b64")),
                chain_prompts is not None,
                h3_steps,
            )
        requested_id = str(request.get("entry_id") or request.get("entryID") or "")
        if requested_id and not SAFE_ID.fullmatch(requested_id):
            raise ValueError("entry_id must contain only letters, numbers, underscores, or hyphens")
        seed = int(request.get("seed") if request.get("seed") is not None else -1)
        if seed < 0 and requested_id in self.jobs:
            seed = int(self.jobs[requested_id]["seed"])
        if seed < 0:
            seed = int.from_bytes(hashlib.sha256((prompt + utc_now()).encode()).digest()[:4], "big")

        job_id = requested_id or uuid.uuid4().hex[:16]

        output_name = safe_output_name(str(request.get("output_name") or job_id), job_id)
        fingerprint_payload = {
            "prompt": prompt,
            "model": model,
            "seconds": seconds,
            "resolution": resolution,
            "seed": seed,
            "output_name": output_name,
            "has_image": bool(request.get("image_b64")),
            "image_sha256": hashlib.sha256(str(request.get("image_b64") or "").encode()).hexdigest(),
            "h3_turbo": h3_turbo if model == "hailuo-h3" else None,
            "h3_chain_prompts": chain_prompts,
        }
        # Preserve fingerprints of pre-steps requests when Auto is omitted.
        if h3_steps is not None:
            fingerprint_payload["h3_steps"] = h3_steps
        request_fingerprint = hashlib.sha256(
            json.dumps(fingerprint_payload, sort_keys=True, separators=(",", ":")).encode("utf-8")
        ).hexdigest()

        with self.lock:
            existing = self.jobs.get(job_id)
            if existing:
                existing_fingerprint = existing.get("request_fingerprint")
                if existing_fingerprint == request_fingerprint:
                    return job_id
                # Preserve compatibility with state created before fingerprints
                # were recorded, but compare every material field.
                legacy_matches = all(
                    existing.get(key) == value
                    for key, value in {
                        "prompt": prompt,
                        "model": model,
                        "seconds": seconds,
                        "resolution": resolution,
                        "seed": seed,
                        "output_name": output_name,
                        "h3_chain_prompts": chain_prompts,
                        "h3_steps": h3_steps,
                    }.items()
                )
                if (existing.get("fingerprint_version", 1) == 1 and legacy_matches
                        and not request.get("image_b64") and not existing.get("image_path")
                        and (model != "hailuo-h3" or existing.get("phosphene_h3_turbo") == h3_turbo)):
                    return job_id
                raise ValueError("entry_id already exists with different render settings")

        is_batch_clip = LEGACY_HB_LAYOUT and bool(re.fullmatch(r"HB\d{3}(?:_[A-Za-z0-9_-]+)?", Path(output_name).stem))
        # A caller may reuse a display filename for different jobs. Isolate the
        # files so completing a second job cannot overwrite the first artifact.
        output_dir = REVIEW_DIR / "final" if is_batch_clip else ARTIFACT_DIR / job_id
        output_path = output_dir / output_name
        raw_path = ARTIFACT_DIR / f"{job_id}.raw.mp4"
        candidate_path = output_dir / f".{job_id}.candidate.mp4"
        log_dir = REVIEW_DIR / "logs" if is_batch_clip else STATE_DIR / "logs"
        log_path = log_dir / f"{Path(output_name).stem if is_batch_clip else job_id}.log"
        poster_path = REVIEW_DIR / "posters" / f"{Path(output_name).stem}.jpg" if is_batch_clip else None

        image_path = self._save_image(request, job_id)
        created = utc_now()
        job = {
            "id": job_id,
            "status": "queued",
            "stage": "waiting for Apple GPU",
            "progress": 0.0,
            "prompt": prompt,
            "model": model,
            "seconds": seconds,
            "resolution": resolution,
            "seed": seed,
            "frames": seconds * 24 if model == "hailuo-h3" else seconds_to_frames(seconds),
            "output_name": output_name,
            "output_path": str(output_path),
            "raw_path": str(raw_path),
            "candidate_path": str(candidate_path),
            "log_path": str(log_path),
            "poster_path": str(poster_path) if poster_path else None,
            "image_path": str(image_path) if image_path else None,
            "phosphene_job_id": None,
            "phosphene_submit_attempted": False,
            "phosphene_h3_turbo": h3_turbo if model == "hailuo-h3" else None,
            "h3_chain_prompts": chain_prompts,
            "h3_steps": h3_steps,
            "delivery_plan": delivery_plan,
            "request_fingerprint": request_fingerprint,
            "fingerprint_version": 2,
            "created_at": created,
            "updated_at": created,
            "deadline_epoch": time.time() + JOB_TIMEOUT_SECONDS,
        }
        with self.lock:
            self.jobs[job_id] = job
            self._persist()
            self.pending.put(job_id)
        return job_id

    def _save_image(self, request: Dict[str, Any], job_id: str) -> Optional[Path]:
        encoded = request.get("image_b64")
        if not encoded:
            return None
        raw = str(encoded)
        if "," in raw and raw.lstrip().startswith("data:"):
            raw = raw.split(",", 1)[1]
        try:
            payload = base64.b64decode(raw, validate=True)
        except Exception as exc:
            raise ValueError("image_b64 is not valid base64") from exc
        if len(payload) > 30 * 1024 * 1024:
            raise ValueError("reference image is larger than 30 MiB")
        suffix = Path(str(request.get("image_name") or "reference.png")).suffix.lower()
        if suffix not in {".png", ".jpg", ".jpeg", ".webp"}:
            suffix = ".png"
        path = UPLOAD_DIR / f"{job_id}{suffix}"
        path.write_bytes(payload)
        return path

    def queue_position(self, job_id: str) -> int:
        with self.lock:
            queued = [
                job for job in self.jobs.values() if job.get("status") == "queued"
            ]
            queued.sort(key=lambda item: item.get("created_at", ""))
            for index, job in enumerate(queued, start=1):
                if job.get("id") == job_id:
                    return index
        return 0

    def public_job(self, job_id: str) -> Optional[Dict[str, Any]]:
        with self.lock:
            source = self.jobs.get(job_id)
            if not source:
                return None
            job = dict(source)
        try:
            delivery: Optional[Dict[str, Any]] = delivery_report(job)
        except ValueError:
            delivery = None
        cancel: Optional[Dict[str, Any]] = None
        if job.get("status") == "cancelled":
            cancel = {"state": "cancelled", "requested_at": job.get("cancel_requested_at"),
                      "cancelled_at": job.get("cancelled_at"), "detail": job.get("cancel_detail")}
        elif job.get("cancel_requested_at"):
            cancel = {"state": "requested", "requested_at": job.get("cancel_requested_at")}
        started = job.get("started_epoch")
        if started and job.get("status") == "running":
            job["elapsed_s"] = round(time.time() - float(started), 1)
        job["queue_position"] = self.queue_position(job_id)
        # Silicon Optimizer recursively treats any returned string ending in a
        # video suffix as the artifact URL.  Hide the display filename so the
        # explicit authenticated artifact route below is the only candidate.
        for key in (
            "output_name",
            "output_path",
            "raw_path",
            "candidate_path",
            "log_path",
            "poster_path",
            "image_path",
            "request_fingerprint",
            "started_epoch",
            "phosphene_job_id",
            "phosphene_submit_attempted",
            "phosphene_h3_turbo",
            "delivery_plan",
            "delivered_width",
            "delivered_height",
            "cancel_requested_at",
            "cancelled_at",
            "cancel_detail",
        ):
            job.pop(key, None)
        if delivery is not None:
            job["delivery"] = delivery
        if cancel is not None:
            job["cancel"] = cancel
        if job.get("status") == "done":
            job["artifact"] = f"/v1/artifacts/{job_id}.mp4"
        return job

    def artifact_for(self, job_id: str) -> Optional[Path]:
        with self.lock:
            job = self.jobs.get(job_id)
            if not job or job.get("status") != "done":
                return None
            path = Path(str(job.get("output_path", "")))
        if not path.is_file() or path.suffix.lower() not in VIDEO_SUFFIXES:
            return None
        if path.stat().st_size > MAX_ARTIFACT_BYTES:
            return None
        return path

    def _worker(self) -> None:
        while not self.stop_event.is_set():
            try:
                job_id = self.pending.get(timeout=1.0)
            except queue.Empty:
                continue
            try:
                with self.lock:
                    # Taking the job and checking it is still wanted are one step,
                    # so a cancel either finds it waiting or finds it current.
                    if (self.jobs.get(job_id) or {}).get("status") != "queued":
                        continue
                    self.current_job_id = job_id
                self._run_job(job_id)
            except Exception as exc:
                error = f"{type(exc).__name__}: {exc}"
                try:
                    with self.lock:
                        job = self.jobs.get(job_id) or {}
                        cancelled = (isinstance(exc, JobCancelled) or bool(job.get("cancel_requested_at"))
                                     or job.get("status") == "cancelled")
                        if cancelled:
                            self._mark_cancelled_locked(job_id, "Cancelled; the renderer was stopped.")
                    if cancelled:
                        self._discard_staging(job_id)
                    elif self.stop_event.is_set():
                        self._record(
                            job_id,
                            status="queued",
                            stage="interrupted safely; will resume after restart",
                            error=None,
                        )
                    else:
                        self._record(
                            job_id,
                            status="failed",
                            stage="render failed",
                            error=error,
                            traceback=traceback.format_exc(),
                        )
                except Exception:
                    pass
            finally:
                with self.lock:
                    self.current_job_id = None
                    self.committing.discard(job_id)
                    self.processes.pop(job_id, None)
                self.pending.task_done()

    def _run_phosphene_job(self, job_id: str) -> None:
        with self.lock:
            job = dict(self.jobs[job_id])
        output_path = Path(job["output_path"])
        raw_path = Path(job["raw_path"])
        candidate_path = Path(
            job.get("candidate_path") or output_path.parent / f".{job_id}.candidate.mp4"
        )
        log_path = Path(job["log_path"])
        poster_path = Path(job["poster_path"]) if job.get("poster_path") else None
        output_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        raw_path.unlink(missing_ok=True)
        candidate_path.unlink(missing_ok=True)

        started_epoch = float(job.get("started_epoch") or time.time())
        phosphene_job_id = str(job.get("phosphene_job_id") or "")
        if not phosphene_job_id:
            if job.get("phosphene_submit_attempted"):
                raise RuntimeError(
                    "Phosphene submission was interrupted before its job ID was saved; "
                    "refusing to submit a possible duplicate"
                )
            # The request may have waited behind another local render. Recheck
            # once, immediately before the unauthenticated Phosphene enqueue,
            # and derive every gate from that same snapshot.
            chain_prompts = normalize_h3_chain_prompts(
                job.get("h3_chain_prompts"),
                "hailuo-h3",
                int(job["seconds"]),
                job.get("h3_chain_prompts") is not None,
            )
            job["h3_chain_prompts"] = chain_prompts
            live_h3_state = phosphene_h3_readiness()
            validate_phosphene_h3_request(
                live_h3_state,
                int(job["seconds"]),
                bool(job.get("image_path")),
                chain_prompts is not None,
                normalize_h3_steps(job.get("h3_steps"), "hailuo-h3", job.get("phosphene_h3_turbo")),
            )
            self._update(
                job_id,
                status="running",
                stage="submitting to local Phosphene",
                progress=0.01,
                started_at=job.get("started_at") or utc_now(),
                started_epoch=started_epoch,
                phosphene_submit_attempted=True,
                error=None,
            )
            response = phosphene_request("/queue/add", phosphene_submission_form(job))
            phosphene_job_id = str(response.get("id") or "")
            if not response.get("ok") or not re.fullmatch(r"[A-Za-z0-9._-]{1,128}", phosphene_job_id):
                raise RuntimeError("Phosphene accepted no usable job ID")
            # Kept unconditionally: losing a live remote ID would leave a render
            # nobody can identify, follow or stop.
            self._record(
                job_id,
                phosphene_job_id=phosphene_job_id,
                stage="queued in Phosphene",
            )
        else:
            self._update(
                job_id,
                status="running",
                stage="reconnecting to Phosphene job",
                progress=max(0.01, float(job.get("progress") or 0.0)),
                started_at=job.get("started_at") or utc_now(),
                started_epoch=started_epoch,
                error=None,
            )

        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"\n[{utc_now()}] following Phosphene job {phosphene_job_id}\n")
            log.flush()
            missing_since: Optional[float] = None
            unavailable_since: Optional[float] = None
            terminal: Optional[Dict[str, Any]] = None
            while not self.stop_event.is_set():
                self._checkpoint(job_id)
                job_remaining_seconds(job)
                try:
                    snapshot = phosphene_request("/status")
                    unavailable_since = None
                except RuntimeError as exc:
                    if unavailable_since is None:
                        unavailable_since = time.time()
                        log.write(f"[{utc_now()}] panel temporarily unavailable: {exc}\n")
                        log.flush()
                    self.stop_event.wait(PHOSPHENE_POLL_SECONDS)
                    continue

                location, record = locate_phosphene_job(snapshot, phosphene_job_id)
                if location == "missing":
                    if missing_since is None:
                        missing_since = time.time()
                    if time.time() - missing_since > 15:
                        raise RuntimeError(
                            "Phosphene no longer reports the persisted job ID; "
                            "refusing to submit a duplicate"
                        )
                    self.stop_event.wait(PHOSPHENE_POLL_SECONDS)
                    continue
                missing_since = None
                mapped = map_phosphene_progress(location, record)
                if location == "history":
                    remote_status = str((record or {}).get("status") or "").lower()
                    if remote_status == "done":
                        terminal = record
                        break
                    if remote_status in {"failed", "cancelled", "stopped"}:
                        remote_error = str((record or {}).get("error") or "")[:1000]
                        suffix = f": {remote_error}" if remote_error else ""
                        raise RuntimeError(f"Phosphene render {remote_status}{suffix}")
                self._update(job_id, **mapped)
                self.stop_event.wait(PHOSPHENE_POLL_SECONDS)

        if self.stop_event.is_set():
            raise RuntimeError("video node is stopping")
        assert terminal is not None
        sampling_provenance = phosphene_sampling_provenance(job, terminal)
        source = validated_phosphene_output(terminal.get("output_path"), int(job["seconds"]))
        self._update(job_id, stage="copying validated Phosphene output", progress=0.95)
        copied = 0
        try:
            with source.open("rb") as incoming, raw_path.open("xb") as outgoing:
                while chunk := incoming.read(1024 * 1024):
                    copied += len(chunk)
                    if copied > MAX_ARTIFACT_BYTES:
                        raise RuntimeError("Phosphene output grew beyond the artifact size limit")
                    outgoing.write(chunk)
        except Exception:
            raw_path.unlink(missing_ok=True)
            raise
        if not raw_path.is_file() or raw_path.stat().st_size < 4096:
            raise RuntimeError("could not stage the completed Phosphene video")

        self._update(job_id, stage="optimizing review MP4", progress=0.97)
        plan = h3_output_resolution_plan(job["resolution"])
        ffmpeg = executable("ffmpeg")
        filter_chain = (
            f"fps=24,scale={plan['output_w']}:{plan['output_h']}:"
            "force_original_aspect_ratio=increase:flags=lanczos,"
            f"crop={plan['output_w']}:{plan['output_h']},setsar=1"
        )
        completed = subprocess.run(
            [
                ffmpeg,
                "-hide_banner",
                "-loglevel",
                "error",
                "-y",
                "-i",
                str(raw_path),
                "-map",
                "0:v:0",
                "-map",
                "0:a?",
                "-vf",
                filter_chain,
                "-t",
                str(job["seconds"]),
                "-c:v",
                "libx264",
                "-preset",
                "medium",
                "-crf",
                "19",
                "-pix_fmt",
                "yuv420p",
                "-c:a",
                "aac",
                "-b:a",
                "192k",
                "-movflags",
                "+faststart",
                str(candidate_path),
            ],
            capture_output=True,
            text=True,
            timeout=job_remaining_seconds(job, 600),
        )
        if completed.returncode != 0:
            raise RuntimeError("ffmpeg post-process failed: " + completed.stderr[-2000:])
        probe = probe_media(candidate_path)
        duration = float(probe.get("duration", 0.0))
        if not completed_media_matches(job, candidate_path):
            raise RuntimeError(
                "Phosphene output stream failed validation: "
                f"codec={probe.get('codec')} size={probe.get('width')}x{probe.get('height')} "
                f"fps={probe.get('frame_rate')} frames={probe.get('nb_frames')} "
                f"duration={duration:.3f}s"
            )
        self._commit(job_id)
        candidate_path.replace(output_path)

        if poster_path:
            poster_path.parent.mkdir(parents=True, exist_ok=True)
            poster = subprocess.run(
                [
                    ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-ss",
                    str(min(5.0, max(0.0, duration / 2))),
                    "-i",
                    str(output_path),
                    "-frames:v",
                    "1",
                    "-q:v",
                    "2",
                    str(poster_path),
                ],
                capture_output=True,
                text=True,
                timeout=job_remaining_seconds(job, 120),
            )
            if poster.returncode != 0:
                poster_path = None

        options = phosphene_render_options(job["resolution"], int(job["seconds"]))
        atomic_json(
            output_path.with_suffix(".json"),
            {
                "id": job_id,
                "title": Path(job["output_name"]).stem,
                "prompt": job["prompt"],
                "seed": job["seed"],
                "model": "MiniMaxAI/MiniMax-H3",
                "pipeline": "Phosphene Hailuo H3",
                "phosphene_job_id": phosphene_job_id,
                "h3_quality": options["h3_quality"],
                "h3_length": options["h3_length"],
                "h3_upscale": options["h3_upscale"],
                "h3_turbo": bool(job.get("phosphene_h3_turbo", PHOSPHENE_H3_TURBO)),
                "h3_chain_prompts": job.get("h3_chain_prompts"),
                **sampling_provenance,
                "duration_seconds": duration,
                "frames": job["frames"],
                "frame_rate": 24,
                "output_resolution": f"{probe.get('width')}x{probe.get('height')}",
                "audio": probe.get("audio", False),
                "created_at": utc_now(),
            },
        )
        raw_path.unlink(missing_ok=True)
        elapsed = time.time() - started_epoch
        self._update(
            job_id,
            status="done",
            stage="complete",
            progress=1.0,
            elapsed_s=round(elapsed, 1),
            completed_at=utc_now(),
            duration_s=round(duration, 3),
            # Probed, and already validated against the plan above.
            delivered_width=probe.get("width"),
            delivered_height=probe.get("height"),
            bytes=output_path.stat().st_size,
            poster_path=str(poster_path) if poster_path else None,
        )

    def _run_job(self, job_id: str) -> None:
        with self.lock:
            job = dict(self.jobs[job_id])
        job_remaining_seconds(job)
        if job.get("model") == "hailuo-h3":
            self._run_phosphene_job(job_id)
            return
        output_path = Path(job["output_path"])
        raw_path = Path(job["raw_path"])
        candidate_path = Path(job.get("candidate_path") or output_path.parent / f".{job_id}.candidate.mp4")
        log_path = Path(job["log_path"])
        poster_path = Path(job["poster_path"]) if job.get("poster_path") else None
        output_path.parent.mkdir(parents=True, exist_ok=True)
        log_path.parent.mkdir(parents=True, exist_ok=True)
        raw_path.unlink(missing_ok=True)
        candidate_path.unlink(missing_ok=True)

        if job.get("delivery_plan"):
            plan = job_delivery_plan(job)
        else:
            # Saved before 1080p delivery and never finished: render the size it
            # asked for, and pin that before any output can exist.
            plan = resolution_plan(str(job["resolution"]))
            self._update(job_id, delivery_plan=plan)
            job["delivery_plan"] = plan
        command = [
            "/usr/bin/caffeinate",
            "-dimsu",
            str(LTX_BIN),
            "generate",
            "--prompt",
            job["prompt"],
            "--output",
            str(raw_path),
            "--model",
            str(MODEL_DIR),
            "--gemma",
            str(GEMMA_DIR),
            "--seed",
            str(job["seed"]),
            "--height",
            str(plan["internal_h"]),
            "--width",
            str(plan["internal_w"]),
            "--frames",
            str(job["frames"]),
            "--frame-rate",
            "24",
            "--distilled",
            "--stage1-steps",
            "8",
            "--stage2-steps",
            "3",
        ]
        if job.get("image_path"):
            command.extend(["--image", job["image_path"]])

        environment = os.environ.copy()
        environment.update(
            {
                "HF_HOME": str(APP_SUPPORT / "hf-home"),
                "HF_HUB_OFFLINE": "1",
                "PYTHONUNBUFFERED": "1",
                "TOKENIZERS_PARALLELISM": "false",
            }
        )
        started_epoch = time.time()
        self._update(
            job_id,
            status="running",
            stage="loading local Gemma and LTX weights",
            progress=0.02,
            started_at=utc_now(),
            started_epoch=started_epoch,
            error=None,
        )

        tail = []
        with log_path.open("a", encoding="utf-8") as log:
            log.write(f"\n[{utc_now()}] starting {job_id}\n")
            log.write("Command: " + " ".join(command[:2] + ["<ltx-command-with-prompt-redacted>"]) + "\n")
            log.flush()
            with self.lock:
                # Starting the renderer and registering it as this job's are one
                # step with the cancel check, so a cancel always finds it or
                # stops it from starting.
                self._checkpoint_locked(job_id)
                process = subprocess.Popen(
                    command,
                    cwd=str(LTX_ROOT),
                    env=environment,
                    stdout=subprocess.PIPE,
                    stderr=subprocess.STDOUT,
                    text=True,
                    bufsize=1,
                    start_new_session=True,
                )
                owned = OwnedProcess(process)
                self.processes[job_id] = owned
            assert process.stdout is not None
            deadline_timer = threading.Timer(job_remaining_seconds(job), owned.terminate)
            deadline_timer.daemon = True
            deadline_timer.start()
            try:
                for line in process.stdout:
                    log.write(line)
                    log.flush()
                    clean = line.strip()
                    if clean:
                        tail.append(clean)
                        tail = tail[-30:]
                        lower = clean.lower()
                        if "text encod" in lower or "gemma" in lower:
                            self._update(job_id, stage="encoding prompt locally", progress=0.08)
                        elif "stage 1" in lower or "denois" in lower:
                            self._update(job_id, stage="rendering motion on Apple GPU", progress=0.18)
                        elif "upscal" in lower or "stage 2" in lower:
                            self._update(job_id, stage="refining frames", progress=0.72)
                        elif "decod" in lower:
                            self._update(job_id, stage="decoding video and audio", progress=0.88)
                        elif "sav" in lower or "writ" in lower:
                            self._update(job_id, stage="saving raw render", progress=0.93)
                return_code = owned.wait()
            finally:
                deadline_timer.cancel()
                owned.terminate()
                with self.lock:
                    self.processes.pop(job_id, None)
                process.stdout.close()
            # A renderer stopped by a cancel exits nonzero; say cancelled, not failed.
            self._checkpoint(job_id)
            job_remaining_seconds(job)
            log.write(f"[{utc_now()}] renderer exit code {return_code}\n")
        if return_code != 0:
            raise RuntimeError("LTX renderer exited with code %d: %s" % (return_code, " | ".join(tail[-8:])))
        if not raw_path.is_file() or raw_path.stat().st_size < 4096:
            raise RuntimeError("LTX renderer did not produce a usable MP4")

        self._update(job_id, stage="optimizing review MP4", progress=0.95)
        ffmpeg = executable("ffmpeg")
        filter_chain = (
            f"scale={plan['output_w']}:{plan['output_h']}:force_original_aspect_ratio=increase:flags=lanczos,"
            f"crop={plan['output_w']}:{plan['output_h']},setsar=1"
        )
        transcode = [
            ffmpeg,
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-i",
            str(raw_path),
            "-map",
            "0:v:0",
            "-map",
            "0:a?",
            "-vf",
            filter_chain,
            "-c:v",
            "libx264",
            "-preset",
            "medium",
            "-crf",
            "19",
            "-pix_fmt",
            "yuv420p",
            "-c:a",
            "aac",
            "-b:a",
            "192k",
            "-movflags",
            "+faststart",
            str(candidate_path),
        ]
        completed = subprocess.run(transcode, capture_output=True, text=True, timeout=job_remaining_seconds(job, 600))
        if completed.returncode != 0:
            raise RuntimeError("ffmpeg post-process failed: " + completed.stderr[-2000:])

        probe = probe_media(candidate_path)
        duration = float(probe.get("duration", 0.0))
        if not (max(0.5, job["seconds"] - 0.75) <= duration <= job["seconds"] + 1.0):
            raise RuntimeError(f"unexpected output duration: {duration:.3f}s")
        if not completed_media_matches(job, candidate_path):
            raise RuntimeError(
                "output stream failed validation: "
                f"codec={probe.get('codec')} size={probe.get('width')}x{probe.get('height')} "
                f"fps={probe.get('frame_rate')} frames={probe.get('nb_frames')}"
            )

        # Preserve an existing good clip until its replacement has passed all
        # stream checks, then swap the new candidate into place atomically.
        self._commit(job_id)
        candidate_path.replace(output_path)

        if poster_path:
            poster_path.parent.mkdir(parents=True, exist_ok=True)
            poster = subprocess.run(
                [
                    ffmpeg,
                    "-hide_banner",
                    "-loglevel",
                    "error",
                    "-y",
                    "-ss",
                    str(min(5.0, max(0.0, duration / 2))),
                    "-i",
                    str(output_path),
                    "-frames:v",
                    "1",
                    "-q:v",
                    "2",
                    str(poster_path),
                ],
                capture_output=True,
                text=True,
                timeout=job_remaining_seconds(job, 120),
            )
            if poster.returncode != 0:
                poster_path = None

        sidecar = output_path.with_suffix(".json")
        metadata = {
            "id": job_id,
            "title": Path(job["output_name"]).stem,
            "prompt": job["prompt"],
            "seed": job["seed"],
            "model": "dgrauet/ltx-2.3-mlx-q4",
            "pipeline": "distilled two-stage MLX",
            "duration_seconds": duration,
            "frames": job["frames"],
            "frame_rate": 24,
            "requested_resolution": job["resolution"],
            "internal_resolution": f"{plan['internal_w']}x{plan['internal_h']}",
            "output_resolution": f"{probe.get('width')}x{probe.get('height')}",
            # The canvas is smaller than every delivery size: ffmpeg scaled
            # it, and that is not the detail of native generation at this size.
            "delivery_scaling": (
                "upscaled" if (probe.get("width"), probe.get("height")) != (plan["internal_w"], plan["internal_h"])
                else "native"
            ),
            "audio": probe.get("audio", False),
            "created_at": utc_now(),
        }
        atomic_json(sidecar, metadata)
        raw_path.unlink(missing_ok=True)
        elapsed = time.time() - started_epoch
        self._update(
            job_id,
            status="done",
            stage="complete",
            progress=1.0,
            elapsed_s=round(elapsed, 1),
            completed_at=utc_now(),
            duration_s=round(duration, 3),
            # Probed, and already validated against the plan above.
            delivered_width=probe.get("width"),
            delivered_height=probe.get("height"),
            bytes=output_path.stat().st_size,
            poster_path=str(poster_path) if poster_path else None,
        )

    def shutdown(self) -> None:
        self.stop_event.set()
        with self.lock:
            owned = list(self.processes.values())
        for process in owned:
            process.terminate()
        worker = self.worker
        if worker and worker.is_alive() and worker is not threading.current_thread():
            worker.join(timeout=15)


RENDERS: Optional[RenderQueue] = None


class Handler(BaseHTTPRequestHandler):
    server_version = "SiliconOptimizerVideoNode/1.0"

    def log_message(self, fmt: str, *args: Any) -> None:
        sys.stderr.write("[%s] %s\n" % (self.log_date_time_string(), fmt % args))

    def _authorized(self) -> bool:
        wanted = expected_token()
        supplied = self.headers.get("Authorization", "")
        if not wanted:
            return False
        if not supplied.startswith("Bearer "):
            return False
        return hmac.compare_digest(supplied[7:], wanted)

    def _json(self, status: int, payload: Any) -> None:
        encoded = json.dumps(payload, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(encoded)

    def _require_auth(self) -> bool:
        if self._authorized():
            return True
        self._json(HTTPStatus.UNAUTHORIZED, {"error": "missing or invalid bearer token"})
        return False

    def do_GET(self) -> None:
        parsed = urlparse(self.path)
        path = parsed.path
        if path == "/health":
            ltx_ready = assets_ready()
            h3_ready = bool(phosphene_h3_readiness()["ready"])
            self._json(
                HTTPStatus.OK,
                {
                    "ok": True,
                    "ready": ltx_ready or h3_ready,
                    "models": {
                        "ltx2-distilled": ltx_ready,
                        "hailuo-h3": h3_ready,
                    },
                },
            )
            return
        if not self._require_auth():
            return
        assert RENDERS is not None

        if path == "/v1/node":
            ltx_missing = [item.name for item in required_assets() if not item.exists()]
            h3_state = phosphene_h3_readiness()
            self._json(
                HTTPStatus.OK,
                {
                    "name": "Local Apple-Silicon Video",
                    "platform": "macos",
                    "profile": hardware_profile(),
                    "metrics": {
                        "queue_depth": sum(1 for job in RENDERS.jobs.values() if job.get("status") == "queued"),
                        "busy": RENDERS.current_job_id is not None,
                    },
                    "capabilities": [
                        {
                            "id": "ltx2-distilled",
                            "kind": "video",
                            "ready": not ltx_missing,
                            "peak_gb": 25,
                            "typical_seconds": 600,
                            "detail": "LTX-2.3 distilled Q4, native MLX; local audio/video; "
                            "renders a canvas of at most 768x448 and scales it up for delivery",
                            "supported_resolutions": list(LTX_RESOLUTIONS),
                            # This node owns the LTX renderer process for each job,
                            # so POST /v1/jobs/{id}/cancel can stop exactly that one.
                            "supported_job_actions": ["cancel"],
                            "missing": ltx_missing,
                        },
                        {
                            # No "cancel" here. Phosphene can remove a job that has not
                            # started, by its ID, but a running render's only stop is
                            # global and may hit another client's job. The cancel
                            # route still answers for H3, honestly, per job.
                            "id": "hailuo-h3",
                            "kind": "video",
                            "supported_parameters": ["seed", "h3_chain_prompts", "h3_turbo", "entry_id"]
                            + (["h3_steps"] if h3_state["ready"] and phosphene_supports_h3_steps() else []),
                            "ready": bool(h3_state["ready"]),
                            "supported_resolutions": ["480p", "720p", "1080p"],
                            "peak_gb": 32,
                            "typical_seconds": 1200,
                            "detail": (
                                "MiniMax Hailuo H3 through the loopback Phosphene panel"
                                if h3_state["ready"]
                                else str(h3_state["reason"])
                            ),
                            "missing": [] if h3_state["ready"] else [str(h3_state["reason"])],
                        },
                    ],
                },
            )
            return

        if path == "/v1/jobs":
            jobs = [RENDERS.public_job(job_id) for job_id in sorted(RENDERS.jobs)]
            self._json(HTTPStatus.OK, {"jobs": jobs})
            return

        match = re.fullmatch(r"/v1/jobs/([A-Za-z0-9_-]{1,64})", path)
        if match:
            job = RENDERS.public_job(match.group(1))
            if not job:
                self._json(HTTPStatus.NOT_FOUND, {"error": "job not found"})
            else:
                self._json(HTTPStatus.OK, job)
            return

        match = re.fullmatch(r"/v1/artifacts/([A-Za-z0-9_-]{1,64})\.(mp4|mov|webm)", path)
        if not match:
            # Compatibility route for older Silicon Optimizer builds that
            # resolve a bare filename at the node root.
            match = re.fullmatch(r"/([A-Za-z0-9_-]{1,64})\.(mp4|mov|webm)", path)
        if match:
            artifact = RENDERS.artifact_for(match.group(1))
            if not artifact:
                self._json(HTTPStatus.NOT_FOUND, {"error": "artifact not found"})
                return
            size = artifact.stat().st_size
            self.send_response(HTTPStatus.OK)
            self.send_header("Content-Type", "video/mp4")
            self.send_header("Content-Length", str(size))
            self.send_header("Content-Disposition", f'attachment; filename="{artifact.name}"')
            self.send_header("Cache-Control", "private, max-age=3600")
            self.end_headers()
            with artifact.open("rb") as handle:
                shutil.copyfileobj(handle, self.wfile, length=1024 * 1024)
            return

        self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})

    def do_POST(self) -> None:
        parsed = urlparse(self.path)
        cancel = re.fullmatch(r"/v1/jobs/([A-Za-z0-9_-]{1,64})/cancel", parsed.path)
        if parsed.path != "/v1/text-to-video" and not cancel:
            self._json(HTTPStatus.NOT_FOUND, {"error": "not found"})
            return
        if not self._require_auth():
            return
        if cancel:
            # The body carries nothing; the job ID in the path is the whole request.
            try:
                length = int(self.headers.get("Content-Length", "0"))
            except ValueError:
                length = 0
            if 0 < length <= 4096:
                self.rfile.read(length)
            assert RENDERS is not None
            status, answer = RENDERS.cancel(cancel.group(1))
            self._json(status, answer)
            return
        try:
            size = int(self.headers.get("Content-Length", "0"))
        except ValueError:
            size = 0
        if size <= 0 or size > MAX_JSON_BYTES:
            self._json(HTTPStatus.REQUEST_ENTITY_TOO_LARGE, {"error": "invalid request size"})
            return
        try:
            payload = json.loads(self.rfile.read(size))
            if not isinstance(payload, dict):
                raise ValueError("JSON body must be an object")
            assert RENDERS is not None
            job_id = RENDERS.submit(payload)
            self._json(HTTPStatus.ACCEPTED, {"job_id": job_id})
        except (ValueError, TypeError) as exc:
            self._json(HTTPStatus.BAD_REQUEST, {"error": str(exc)})
        except RuntimeError as exc:
            self._json(HTTPStatus.SERVICE_UNAVAILABLE, {"error": str(exc)})
        except Exception as exc:
            self._json(HTTPStatus.INTERNAL_SERVER_ERROR, {"error": f"{type(exc).__name__}: {exc}"})


def main() -> int:
    global PORT
    parser = argparse.ArgumentParser(description="Local MLX video node for Silicon Optimizer")
    parser.add_argument("--host", default=HOST)
    parser.add_argument("--port", default=PORT, type=int)
    args = parser.parse_args()
    if args.host not in {"127.0.0.1", "localhost"}:
        parser.error("the local video node must bind to 127.0.0.1 or localhost")
    if not 1 <= args.port <= 65535:
        parser.error("port must be between 1 and 65535")
    PORT = args.port
    if not expected_token():
        parser.error("no local video-node credential; run install.py or configure SILICON_VIDEO_TOKEN_FILE")
    for dependency in ("ffmpeg", "ffprobe"):
        executable(dependency)
    os.umask(0o077)
    node_lock = acquire_node_lock()
    global RENDERS
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    try:
        RENDERS = RenderQueue()
        RENDERS.start()
    except Exception:
        server.server_close()
        raise

    def stop(_signum: int, _frame: Any) -> None:
        threading.Thread(target=server.shutdown, daemon=True).start()

    signal.signal(signal.SIGTERM, stop)
    signal.signal(signal.SIGINT, stop)
    print(f"Silicon Optimizer MLX video node listening on http://{args.host}:{args.port}", flush=True)
    print(f"Model ready: {assets_ready()}; review folder: {REVIEW_DIR}", flush=True)
    try:
        server.serve_forever(poll_interval=0.5)
    finally:
        RENDERS.shutdown()
        server.server_close()
        node_lock.close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
