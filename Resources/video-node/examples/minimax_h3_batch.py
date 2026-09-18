#!/usr/bin/env python3
"""Render and verify a local MiniMax Hailuo H3 batch (10s, 480p draft Turbo).

The controller deliberately uses its own job namespace and review folder.  It
talks only to the authenticated loopback video node; repeated commands are
safe, and a completed artifact is not replaced unless a newly downloaded copy
has passed the same media checks.
"""

from __future__ import annotations

import argparse
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime, timezone
from fractions import Fraction
from pathlib import Path
from typing import Any, Dict, Iterable, List, Optional
from urllib.error import HTTPError, URLError
from urllib.parse import quote, urlparse
from urllib.request import HTTPRedirectHandler, ProxyHandler, Request, build_opener


HERE = Path(__file__).resolve().parent
DATA_ROOT = Path(os.environ.get("SILICON_VIDEO_DATA_DIR", str(Path.home() / "Library/Application Support/SiliconOptimizer/video-node"))).expanduser()
PROMPTS_FILE = Path(os.environ.get("SILICON_VIDEO_PROMPTS", str(HERE / "honeybadger_prompts.json"))).expanduser()
H3_CHAIN_PROMPTS_FILE = Path(os.environ.get("SILICON_VIDEO_CHAIN_PROMPTS", str(HERE / "minimax_h3_chain_prompts.json"))).expanduser()
SILICON_SWARM = Path(os.environ.get("SILICON_SWARM_CONFIG", str(Path.home() / "Library/Application Support/SiliconOptimizer/swarm.json"))).expanduser()
TOKEN_FILE = Path(os.environ.get("SILICON_VIDEO_TOKEN_FILE", str(DATA_ROOT / "token"))).expanduser()
TOKEN_FILE_EXPLICIT = "SILICON_VIDEO_TOKEN_FILE" in os.environ
WORKER_ARTIFACT_DIR = Path(os.environ.get("SILICON_VIDEO_WORKER_ARTIFACTS", str(DATA_ROOT / "artifacts"))).expanduser()
API_BASE = os.environ.get("SILICON_VIDEO_API", "http://127.0.0.1:8790").rstrip("/")
REVIEW_DIR = Path(os.environ.get("SILICON_VIDEO_REVIEW_DIR", str(Path.home() / "Movies/Silicon Optimizer/MiniMax H3"))).expanduser()
JOB_PREFIX = os.environ.get("SILICON_VIDEO_JOB_PREFIX", "MMH3")
FINAL_DIR = REVIEW_DIR / "final"
POSTER_DIR = REVIEW_DIR / "posters"
MANIFEST_FILE = REVIEW_DIR / "manifest.json"
INDEX_FILE = REVIEW_DIR / "index.html"

MODEL = "hailuo-h3"
DISPLAY_MODEL = "MiniMaxAI/MiniMax-H3"
SECONDS = 10
RESOLUTION = "480p"
QUALITY = "draft"
MAX_ARTIFACT_BYTES = 1024 * 1024 * 1024
TERMINAL_STATUSES = {"done", "failed", "cancelled", "error"}
SAFE_CLIP_ID = re.compile(r"[A-Za-z][A-Za-z0-9-]{0,31}")
SAFE_SLUG = re.compile(r"[A-Za-z0-9][A-Za-z0-9_-]{0,39}")
SAFE_PREFIX = re.compile(r"[A-Za-z][A-Za-z0-9_-]{0,15}")


def h3_chain_prompt_spec(expected_ids: Optional[Iterable[str]] = None) -> Dict[str, List[str]]:
    try:
        value = json.loads(H3_CHAIN_PROMPTS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise RuntimeError(
            f"cannot read H3 chain prompts at {H3_CHAIN_PROMPTS_FILE}"
        ) from exc
    if not isinstance(value, dict) or not value:
        raise RuntimeError("H3 chain prompt file must contain a nonempty object keyed by clip ID")
    if expected_ids is not None and set(value) != set(expected_ids):
        raise RuntimeError("H3 chain prompt IDs must match the prompt specification exactly")
    normalized: Dict[str, List[str]] = {}
    for source_id, windows in value.items():
        if not SAFE_CLIP_ID.fullmatch(source_id):
            raise RuntimeError(f"invalid H3 chain prompt clip ID: {source_id}")
        if (
            not isinstance(windows, list)
            or len(windows) != 2
            or not all(isinstance(item, str) and item.strip() for item in windows)
            or any(len(item) > 4000 for item in windows)
        ):
            raise RuntimeError(
                f"{source_id} must provide exactly two nonempty H3 window prompts of at most 4000 characters"
            )
        normalized[source_id] = [item.strip() for item in windows]
    return normalized


class APIError(RuntimeError):
    def __init__(self, status: int, detail: str) -> None:
        super().__init__(f"video node returned HTTP {status}: {detail}")
        self.status = status


class _NoRedirect(HTTPRedirectHandler):
    def redirect_request(self, req: Any, fp: Any, code: int, msg: str, headers: Any, newurl: str) -> None:
        return None


HTTP = build_opener(ProxyHandler({}), _NoRedirect())


def utc_now() -> str:
    return datetime.now(timezone.utc).isoformat()


def validated_api_base() -> str:
    parsed = urlparse(API_BASE)
    try:
        port = parsed.port
    except ValueError as exc:
        raise RuntimeError("video-node API origin has an invalid port") from exc
    if (
        parsed.scheme != "http"
        or parsed.hostname not in {"127.0.0.1", "localhost", "::1"}
        or parsed.username is not None
        or parsed.password is not None
        or parsed.path not in {"", "/"}
        or parsed.query
        or parsed.fragment
    ):
        raise RuntimeError("video-node API must be a loopback HTTP origin with no path")
    host = f"[{parsed.hostname}]" if parsed.hostname == "::1" else parsed.hostname
    return f"http://{host}" + (f":{port}" if port is not None else "")


def auth_token() -> str:
    try:
        token = TOKEN_FILE.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        if TOKEN_FILE_EXPLICIT:
            raise RuntimeError(f"token file does not exist at {TOKEN_FILE}")
    except (OSError, UnicodeError) as exc:
        raise RuntimeError(f"cannot read video-node token at {TOKEN_FILE}") from exc
    else:
        if not token or any(character.isspace() for character in token):
            raise RuntimeError(f"token file must contain one nonempty bearer token at {TOKEN_FILE}")
        return token
    try:
        data = json.loads(SILICON_SWARM.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise RuntimeError(f"cannot read Silicon Optimizer credentials at {SILICON_SWARM}") from exc
    target = urlparse(validated_api_base())
    peers = data.get("peers", []) if isinstance(data, dict) else []
    for peer in peers if isinstance(peers, list) else []:
        if not isinstance(peer, dict):
            continue
        try:
            candidate = urlparse(str(peer.get("base_url") or ""))
            candidate_port = candidate.port or 80
        except ValueError:
            continue
        if (
            candidate.scheme == target.scheme
            and candidate.hostname == target.hostname
            and candidate_port == (target.port or 80)
            and candidate.username is None
            and candidate.password is None
            and candidate.path in {"", "/"}
            and not candidate.query
            and not candidate.fragment
        ):
            value = str(peer.get("token") or data.get("swarm_token") or "")
            if value:
                return value
    raise RuntimeError("Silicon Optimizer has no credential for the local video node; use --token-file")


def request(path: str, payload: Optional[Dict[str, Any]] = None, timeout: int = 30) -> Any:
    if not path.startswith("/") or "?" in path or "#" in path:
        raise RuntimeError("invalid video-node API path")
    body = json.dumps(payload).encode("utf-8") if payload is not None else None
    req = Request(
        validated_api_base() + path,
        data=body,
        headers={
            "Authorization": "Bearer " + auth_token(),
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
        method="POST" if payload is not None else "GET",
    )
    try:
        with HTTP.open(req, timeout=timeout) as response:
            raw = response.read(16 * 1024 * 1024 + 1)
    except HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", errors="replace")
        raise APIError(exc.code, detail) from exc
    except (URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"cannot reach local video node at {validated_api_base()}: {exc}") from exc
    if len(raw) > 16 * 1024 * 1024:
        raise RuntimeError("video-node JSON response exceeded 16 MiB")
    try:
        value = json.loads(raw.decode("utf-8"))
    except (UnicodeDecodeError, ValueError) as exc:
        raise RuntimeError("video node returned invalid JSON") from exc
    if not isinstance(value, dict):
        raise RuntimeError("video node returned a non-object JSON response")
    return value


def prompt_spec() -> Dict[str, Any]:
    try:
        spec = json.loads(PROMPTS_FILE.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise RuntimeError(f"cannot read prompt specification at {PROMPTS_FILE}") from exc
    clips = spec.get("clips") if isinstance(spec, dict) else None
    if not isinstance(clips, list) or not clips:
        raise RuntimeError("prompt specification must contain a nonempty clips list")
    required = {"id", "title", "slug", "seed", "prompt"}
    for clip in clips:
        if not isinstance(clip, dict) or required - set(clip):
            raise RuntimeError("each prompt entry requires id, title, slug, seed, and prompt")
        if not isinstance(clip["id"], str) or not SAFE_CLIP_ID.fullmatch(clip["id"]):
            raise RuntimeError("clip IDs must be 1–32 letters, digits, or hyphens, starting with a letter")
        if not isinstance(clip["slug"], str) or not SAFE_SLUG.fullmatch(clip["slug"]):
            raise RuntimeError(f"invalid output slug for {clip['id']}")
        for key in ("title", "prompt"):
            if not isinstance(clip[key], str) or not clip[key].strip():
                raise RuntimeError(f"{clip['id']} requires a nonempty {key}")
        if isinstance(clip["seed"], bool) or not isinstance(clip["seed"], int) or not 0 <= clip["seed"] < 2**32:
            raise RuntimeError(f"{clip['id']} seed must be an integer from 0 to 4294967295")
    ids = [clip["id"] for clip in clips]
    if len({value.upper() for value in ids}) != len(ids):
        raise RuntimeError("prompt clip IDs must be unique (case-insensitive)")
    if not SAFE_PREFIX.fullmatch(JOB_PREFIX):
        raise RuntimeError("job prefix must be 1–16 letters, digits, underscores, or hyphens, starting with a letter")
    for key, expected in (("model", MODEL), ("seconds", SECONDS), ("resolution", RESOLUTION)):
        if key in spec and spec[key] != expected:
            raise RuntimeError(f"this example requires {key}={expected}")
    h3_chain_prompt_spec(ids)
    return spec


def job_id(source_id: str, attempt: int = 1) -> str:
    suffix = "" if attempt == 1 else f"_R{attempt:02d}"
    return f"{JOB_PREFIX}_{source_id}{suffix}"


def source_output_name(clip: Dict[str, Any], attempt: int = 1) -> str:
    suffix = "" if attempt == 1 else f"_R{attempt:02d}"
    return f"{JOB_PREFIX}_{clip['id']}_{clip['slug']}{suffix}.mp4"


def final_output_name(clip: Dict[str, Any]) -> str:
    return f"{JOB_PREFIX}_{clip['id']}_{clip['slug']}.mp4"


def fresh_manifest() -> Dict[str, Any]:
    spec = prompt_spec()
    chains = h3_chain_prompt_spec()
    now = utc_now()
    clips: List[Dict[str, Any]] = []
    for source in spec["clips"]:
        output = final_output_name(source)
        windows = chains[str(source["id"])]
        clips.append(
            {
                **source,
                "source_id": source["id"],
                "attempt": 1,
                "job_id": job_id(source["id"]),
                "source_output_name": source_output_name(source),
                "status": "not submitted",
                "stage": "ready to submit",
                "progress": 0.0,
                "h3_chain_prompts": windows,
                "output": "final/" + output,
                "sidecar": "final/" + Path(output).with_suffix(".json").name,
                "poster": "posters/" + Path(output).with_suffix(".jpg").name,
                "materialized": False,
            }
        )
    return {
        "schema_version": 1,
        "batch": str(spec.get("batch") or "MiniMax H3 Batch"),
        "job_prefix": JOB_PREFIX,
        "created_at": now,
        "updated_at": now,
        "model": MODEL,
        "display_model": DISPLAY_MODEL,
        "seconds": SECONDS,
        "resolution": RESOLUTION,
        "quality": QUALITY,
        "review_folder": str(REVIEW_DIR),
        "clips": clips,
    }


def load_manifest() -> Dict[str, Any]:
    base = fresh_manifest()
    try:
        existing = json.loads(MANIFEST_FILE.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return base
    except (OSError, ValueError, TypeError) as exc:
        raise RuntimeError(f"invalid H3 batch manifest at {MANIFEST_FILE}") from exc
    if not isinstance(existing, dict):
        raise RuntimeError(f"invalid H3 batch manifest at {MANIFEST_FILE}")
    for key in ("model", "seconds", "resolution", "quality", "job_prefix"):
        previous = existing.get(key, "MMH3" if key == "job_prefix" else None)
        if previous != base[key]:
            raise RuntimeError(f"existing review manifest has different {key}; use a new --review-dir")
    if not isinstance(existing.get("clips"), list):
        raise RuntimeError(f"invalid H3 batch clips in manifest at {MANIFEST_FILE}")
    old = {
        str(item.get("source_id") or item.get("id")): item
        for item in existing.get("clips", [])
        if isinstance(item, dict)
    }
    if set(old) != {clip["source_id"] for clip in base["clips"]}:
        raise RuntimeError("existing review manifest has different clips; use a new --review-dir")
    runtime_keys = {
        "job_id",
        "attempt",
        "source_output_name",
        "status",
        "stage",
        "progress",
        "elapsed_s",
        "queue_position",
        "error",
        "duration_s",
        "bytes",
        "artifact",
        "materialized",
        "materialized_at",
        "validation",
        "materialize_error",
    }
    for clip in base["clips"]:
        prior = old[clip["source_id"]]
        for key in ("id", "slug", "seed", "prompt", "h3_chain_prompts"):
            if prior.get(key) != clip[key]:
                raise RuntimeError(f"existing review manifest changed {clip['source_id']} {key}; use a new --review-dir and --job-prefix")
        attempt = prior.get("attempt", 1)
        if isinstance(attempt, bool) or not isinstance(attempt, int) or not 1 <= attempt <= 99:
            raise RuntimeError(f"invalid attempt for {clip['source_id']} in existing review manifest")
        if prior.get("job_id") != job_id(clip["source_id"], attempt) or prior.get("source_output_name") != source_output_name(clip, attempt):
            raise RuntimeError(f"invalid job identity for {clip['source_id']} in existing review manifest")
        for key in runtime_keys:
            if key in prior:
                clip[key] = prior[key]
    base["created_at"] = existing.get("created_at", base["created_at"])
    return base


def atomic_json(path: Path, value: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def save_manifest(manifest: Dict[str, Any]) -> None:
    manifest["updated_at"] = utc_now()
    atomic_json(MANIFEST_FILE, manifest)
    build_index(manifest)


def choose(clips: Iterable[Dict[str, Any]], ids: List[str]) -> List[Dict[str, Any]]:
    selected = list(clips)
    if not ids:
        return selected
    wanted = {value.upper() for value in ids}
    selected = [clip for clip in selected if str(clip["source_id"]).upper() in wanted]
    missing = wanted - {str(clip["source_id"]).upper() for clip in selected}
    if missing:
        raise RuntimeError("unknown clip id(s): " + ", ".join(sorted(missing)))
    return selected


def submission_payload(manifest: Dict[str, Any], clip: Dict[str, Any]) -> Dict[str, Any]:
    windows = clip.get("h3_chain_prompts")
    if not isinstance(windows, list) or len(windows) != 2 or not all(
        isinstance(value, str) and value.strip() for value in windows
    ):
        raise RuntimeError(f"{clip['source_id']} must have exactly two nonempty H3 window prompts")
    return {
        "entry_id": clip["job_id"],
        "output_name": clip["source_output_name"],
        "model": MODEL,
        "prompt": clip["prompt"],
        "h3_chain_prompts": windows,
        "seconds": SECONDS,
        "resolution": RESOLUTION,
        "seed": clip["seed"],
    }


def validate_remote_identity(clip: Dict[str, Any], state: Dict[str, Any]) -> None:
    expected: Dict[str, Any] = {
        "id": clip["job_id"],
        "model": MODEL,
        "seconds": SECONDS,
        "resolution": RESOLUTION,
        "seed": clip["seed"],
        "prompt": clip["prompt"],
        "h3_chain_prompts": clip["h3_chain_prompts"],
    }
    mismatches = [key for key, value in expected.items() if state.get(key) != value]
    if mismatches:
        raise RuntimeError(
            f"refusing job-ID collision for {clip['job_id']}; mismatched " + ", ".join(mismatches)
        )


def apply_remote_state(clip: Dict[str, Any], state: Dict[str, Any]) -> None:
    validate_remote_identity(clip, state)
    for key in (
        "status",
        "stage",
        "progress",
        "elapsed_s",
        "queue_position",
        "error",
        "duration_s",
        "bytes",
        "artifact",
    ):
        if key in state:
            clip[key] = state[key]


def fetch_remote(clip: Dict[str, Any]) -> Optional[Dict[str, Any]]:
    try:
        state = request("/v1/jobs/" + quote(str(clip["job_id"]), safe=""))
    except APIError as exc:
        if exc.status == 404:
            return None
        raise
    validate_remote_identity(clip, state)
    return state


def submit(manifest: Dict[str, Any], clips: List[Dict[str, Any]]) -> None:
    for clip in clips:
        state = fetch_remote(clip)
        if state is None:
            response = request("/v1/text-to-video", submission_payload(manifest, clip))
            if str(response.get("job_id")) != str(clip["job_id"]):
                raise RuntimeError(f"video node returned the wrong job ID for {clip['source_id']}")
            state = fetch_remote(clip)
            if state is None:
                raise RuntimeError(f"submitted job {clip['job_id']} is not yet visible; rerun submit to resume")
            print(f"{clip['source_id']}: queued as {clip['job_id']}")
        else:
            print(f"{clip['source_id']}: already {state.get('status', 'known')} as {clip['job_id']}")
        apply_remote_state(clip, state)
        save_manifest(manifest)


def retry_failed(manifest: Dict[str, Any], clips: List[Dict[str, Any]]) -> int:
    refresh(manifest, clips)
    retryable: List[Dict[str, Any]] = []
    failures = 0
    for clip in clips:
        status = str(clip.get("status") or "")
        attempt = int(clip.get("attempt") or 1)
        if clip.get("materialized"):
            print(f"{clip['source_id']}: already has a verified final; refusing to replace it")
            failures += 1
            continue
        if status == "not submitted" and attempt > 1:
            # A prior retry command may have persisted its new deterministic ID
            # immediately before interruption. Resume that same attempt.
            retryable.append(clip)
            continue
        if status not in {"failed", "cancelled", "error"}:
            print(f"{clip['source_id']}: {status or 'unknown'} is not retryable")
            failures += 1
            continue
        if attempt >= 99:
            print(f"{clip['source_id']}: retry limit of 99 attempts reached")
            failures += 1
            continue
        attempt += 1
        clip["attempt"] = attempt
        clip["job_id"] = job_id(str(clip["source_id"]), attempt)
        clip["source_output_name"] = source_output_name(clip, attempt)
        clip["status"] = "not submitted"
        clip["stage"] = f"retry {attempt} ready to submit"
        clip["progress"] = 0.0
        clip["materialized"] = False
        for key in (
            "elapsed_s",
            "queue_position",
            "error",
            "duration_s",
            "bytes",
            "artifact",
            "materialized_at",
            "validation",
            "materialize_error",
        ):
            clip.pop(key, None)
        save_manifest(manifest)
        retryable.append(clip)
    if retryable:
        submit(manifest, retryable)
    return 2 if failures else 0


def refresh(manifest: Dict[str, Any], clips: List[Dict[str, Any]]) -> None:
    for clip in clips:
        state = fetch_remote(clip)
        if state is None:
            if clip.get("status") not in {"done"} or not clip.get("materialized"):
                clip["status"] = "not submitted"
                clip["stage"] = "ready to submit"
                clip["progress"] = 0.0
            continue
        apply_remote_state(clip, state)
    save_manifest(manifest)


def executable(name: str) -> str:
    for candidate in (f"/opt/homebrew/bin/{name}", f"/usr/local/bin/{name}", f"/usr/bin/{name}"):
        if Path(candidate).is_file():
            return candidate
    found = shutil.which(name)
    if not found:
        raise RuntimeError(f"required executable not found: {name}")
    return found


def sha256(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as handle:
        while True:
            chunk = handle.read(4 * 1024 * 1024)
            if not chunk:
                break
            digest.update(chunk)
    return digest.hexdigest()


def probe_media(path: Path) -> Dict[str, Any]:
    result = subprocess.run(
        [
            executable("ffprobe"),
            "-v",
            "error",
            "-show_entries",
            "format=duration,size:stream=codec_name,codec_type,width,height,avg_frame_rate,nb_frames,duration,channels,sample_rate",
            "-of",
            "json",
            str(path),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode:
        raise RuntimeError("ffprobe failed: " + result.stderr[-1000:])
    try:
        data = json.loads(result.stdout)
    except ValueError as exc:
        raise RuntimeError("ffprobe returned invalid JSON") from exc
    streams = data.get("streams", [])
    video = next((item for item in streams if item.get("codec_type") == "video"), None)
    audio = next((item for item in streams if item.get("codec_type") == "audio"), None)
    if not isinstance(video, dict):
        raise RuntimeError("artifact has no video stream")
    duration = float(video.get("duration") or data.get("format", {}).get("duration") or 0.0)
    try:
        frame_rate = float(Fraction(str(video.get("avg_frame_rate") or "0/1")))
    except (ValueError, ZeroDivisionError):
        frame_rate = 0.0
    try:
        frames = int(video.get("nb_frames") or 0)
    except (TypeError, ValueError):
        frames = 0
    checks = {
        "duration_10_seconds": 9.25 <= duration <= 11.0,
        "h264_video": video.get("codec_name") == "h264",
        "resolution_854x480": (video.get("width"), video.get("height")) == (854, 480),
        "frame_rate_24": abs(frame_rate - 24.0) < 0.01,
        "frame_count_about_240": 239 <= frames <= 241,
        "audio_stream_present": isinstance(audio, dict),
        "aac_audio": isinstance(audio, dict) and audio.get("codec_name") == "aac",
    }
    errors = [name for name, passed in checks.items() if not passed]
    return {
        "valid": not errors,
        "errors": errors,
        "checks": checks,
        "duration_seconds": duration,
        "width": video.get("width"),
        "height": video.get("height"),
        "video_codec": video.get("codec_name"),
        "frame_rate": frame_rate,
        "frames": frames,
        "audio_codec": audio.get("codec_name") if isinstance(audio, dict) else None,
        "audio_channels": audio.get("channels") if isinstance(audio, dict) else None,
        "audio_sample_rate": audio.get("sample_rate") if isinstance(audio, dict) else None,
        "bytes": path.stat().st_size,
        "sha256": sha256(path),
    }


def full_decode(path: Path) -> None:
    result = subprocess.run(
        [
            executable("ffmpeg"),
            "-v",
            "error",
            "-xerror",
            "-i",
            str(path),
            "-map",
            "0:v:0",
            "-map",
            "0:a:0",
            "-f",
            "null",
            "-",
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode or result.stderr.strip():
        raise RuntimeError("full audio/video decode failed: " + result.stderr[-1000:])


def worker_artifact_paths(clip: Dict[str, Any]) -> tuple[Path, Path]:
    source_name = Path(str(clip["source_output_name"]))
    if source_name.name != str(clip["source_output_name"]) or source_name.suffix.lower() != ".mp4":
        raise RuntimeError(f"unsafe worker output name for {clip['source_id']}")
    job = str(clip["job_id"])
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,128}", job):
        raise RuntimeError(f"unsafe worker job ID for {clip['source_id']}")
    # Current nodes isolate each job. Flat sidecars remain readable for batches
    # produced by the original adapter; identity checks below apply to both.
    video = WORKER_ARTIFACT_DIR / job / source_name
    if not video.with_suffix(".json").is_file():
        video = WORKER_ARTIFACT_DIR / source_name
    return video, video.with_suffix(".json")


def worker_artifact_hash(clip: Dict[str, Any]) -> str:
    video, _ = worker_artifact_paths(clip)
    try:
        return sha256(video)
    except OSError as exc:
        raise RuntimeError(f"cannot read local worker video at {video}") from exc


def source_provenance(clip: Dict[str, Any]) -> Dict[str, Any]:
    _, path = worker_artifact_paths(clip)
    try:
        value = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError, TypeError) as exc:
        raise RuntimeError(f"cannot read worker provenance sidecar at {path}") from exc
    if not isinstance(value, dict):
        raise RuntimeError(f"worker provenance sidecar is invalid at {path}")
    expected = {
        "id": clip["job_id"],
        "model": DISPLAY_MODEL,
        "pipeline": "Phosphene Hailuo H3",
        "h3_quality": QUALITY,
        "h3_length": f"{SECONDS}s",
        "h3_upscale": "off",
        "h3_turbo": True,
        "h3_chain_prompts": clip["h3_chain_prompts"],
        "prompt": clip["prompt"],
        "seed": clip["seed"],
    }
    mismatches = [key for key, expected_value in expected.items() if value.get(key) != expected_value]
    phosphene_job = value.get("phosphene_job_id")
    if not isinstance(phosphene_job, str) or not phosphene_job.strip():
        mismatches.append("phosphene_job_id")
    if value.get("audio") is not True:
        mismatches.append("audio")
    if mismatches:
        raise RuntimeError(
            f"worker provenance mismatch for {clip['source_id']}: " + ", ".join(sorted(set(mismatches)))
        )
    return value


def download_artifact(job: str, destination: Path) -> None:
    path = "/v1/artifacts/" + quote(job, safe="") + ".mp4"
    req = Request(
        validated_api_base() + path,
        headers={"Authorization": "Bearer " + auth_token(), "Accept": "video/mp4"},
        method="GET",
    )
    temporary = destination.with_name("." + destination.name + ".download")
    temporary.parent.mkdir(parents=True, exist_ok=True)
    temporary.unlink(missing_ok=True)
    copied = 0
    complete = False
    try:
        with HTTP.open(req, timeout=120) as response, temporary.open("xb") as output:
            length = response.headers.get("Content-Length")
            if length and int(length) > MAX_ARTIFACT_BYTES:
                raise RuntimeError("artifact exceeds the 1 GiB safety limit")
            while True:
                chunk = response.read(1024 * 1024)
                if not chunk:
                    break
                copied += len(chunk)
                if copied > MAX_ARTIFACT_BYTES:
                    raise RuntimeError("artifact exceeds the 1 GiB safety limit")
                output.write(chunk)
        complete = True
    except HTTPError as exc:
        detail = exc.read(4096).decode("utf-8", errors="replace")
        raise APIError(exc.code, detail) from exc
    except (URLError, TimeoutError, OSError) as exc:
        raise RuntimeError(f"artifact download failed for {job}: {exc}") from exc
    finally:
        if not complete or copied < 4096:
            temporary.unlink(missing_ok=True)
    if copied < 4096:
        raise RuntimeError(f"artifact download for {job} was unexpectedly small")


def make_poster(video: Path, poster: Path, duration: float, replace_existing: bool = False) -> None:
    if not replace_existing and poster.is_file() and poster.stat().st_size > 1024:
        return
    poster.parent.mkdir(parents=True, exist_ok=True)
    temporary = poster.with_name("." + poster.name + ".tmp.jpg")
    temporary.unlink(missing_ok=True)
    result = subprocess.run(
        [
            executable("ffmpeg"),
            "-hide_banner",
            "-loglevel",
            "error",
            "-y",
            "-ss",
            str(min(5.0, max(0.0, duration / 2.0))),
            "-i",
            str(video),
            "-frames:v",
            "1",
            "-q:v",
            "2",
            str(temporary),
        ],
        capture_output=True,
        text=True,
    )
    if result.returncode or not temporary.is_file() or temporary.stat().st_size <= 1024:
        temporary.unlink(missing_ok=True)
        raise RuntimeError("poster extraction failed: " + result.stderr[-1000:])
    temporary.replace(poster)


def write_sidecar(
    clip: Dict[str, Any], validation: Dict[str, Any], provenance: Dict[str, Any], path: Path
) -> None:
    # Start from the worker-produced record so the MiniMax/Phosphene provenance
    # survives intact. Controller-only fields are additive and separately named.
    value = dict(provenance)
    value.update(
        {
            "job_prefix": JOB_PREFIX,
            "source_id": clip["source_id"],
            "worker_model": MODEL,
            "requested_seconds": SECONDS,
            "requested_resolution": RESOLUTION,
            "validation": validation,
            "materialized_at": utc_now(),
        }
    )
    atomic_json(path, value)


def materialize_one(clip: Dict[str, Any]) -> bool:
    if clip.get("status") != "done":
        return False
    provenance = source_provenance(clip)
    worker_hash = worker_artifact_hash(clip)
    destination = REVIEW_DIR / str(clip["output"])
    candidate = destination.with_name("." + destination.name + ".download")
    sidecar = REVIEW_DIR / str(clip["sidecar"])
    validation: Optional[Dict[str, Any]] = None
    replaced = False
    if destination.is_file():
        try:
            existing = probe_media(destination)
            previous = json.loads(sidecar.read_text(encoding="utf-8"))
            previous_validation = previous.get("validation", {}) if isinstance(previous, dict) else {}
            if (
                existing["valid"]
                and isinstance(previous, dict)
                and isinstance(previous_validation, dict)
                and all(previous.get(key) == value for key, value in provenance.items())
                and previous_validation.get("full_decode") is True
                and previous_validation.get("sha256") == existing["sha256"] == worker_hash
            ):
                validation = existing
        except (OSError, RuntimeError, ValueError):
            validation = None
    if validation is None:
        download_artifact(str(clip["job_id"]), destination)
        try:
            downloaded = probe_media(candidate)
            if not downloaded["valid"]:
                raise RuntimeError(
                    f"downloaded artifact failed validation: {', '.join(downloaded['errors'])}"
                )
            if downloaded["sha256"] != worker_hash:
                raise RuntimeError("downloaded artifact does not match the local worker video SHA-256")
            full_decode(candidate)
            downloaded["full_decode"] = True
            candidate.replace(destination)
            validation = downloaded
            replaced = True
        except Exception:
            candidate.unlink(missing_ok=True)
            raise
    if not validation.get("full_decode"):
        full_decode(destination)
        validation["full_decode"] = True
    poster = REVIEW_DIR / str(clip["poster"])
    make_poster(destination, poster, float(validation["duration_seconds"]), replace_existing=replaced)
    write_sidecar(clip, validation, provenance, sidecar)
    clip["validation"] = validation
    clip["duration_s"] = validation["duration_seconds"]
    clip["bytes"] = validation["bytes"]
    clip["materialized"] = True
    clip["materialized_at"] = utc_now()
    return True


def materialize(manifest: Dict[str, Any], clips: List[Dict[str, Any]], refresh_first: bool = True) -> int:
    if refresh_first:
        refresh(manifest, clips)
    failures = 0
    for clip in clips:
        if clip.get("status") != "done":
            print(f"{clip['source_id']}: not ready ({clip.get('status', 'unknown')})")
            continue
        try:
            materialize_one(clip)
            print(f"{clip['source_id']}: materialized and verified")
        except Exception as exc:
            failures += 1
            clip["materialized"] = False
            clip["materialize_error"] = str(exc)
            print(f"{clip['source_id']}: materialization failed — {exc}", file=sys.stderr)
        save_manifest(manifest)
    return 2 if failures else 0


def status_line(clip: Dict[str, Any]) -> str:
    progress = min(1.0, max(0.0, float(clip.get("progress") or 0.0)))
    elapsed = clip.get("elapsed_s")
    elapsed_text = f", {float(elapsed) / 60:.1f}m" if elapsed is not None else ""
    queue_position = clip.get("queue_position")
    queue_text = f", queue #{queue_position}" if queue_position else ""
    ready = ", verified" if clip.get("materialized") else ""
    error = f" — {clip.get('error')}" if clip.get("error") else ""
    return (
        f"{clip['source_id']}  {str(clip.get('status', 'unknown')):13} "
        f"{progress * 100:5.1f}%  {clip.get('stage', '')}{queue_text}{elapsed_text}{ready}{error}"
    )


def print_status(manifest: Dict[str, Any], clips: List[Dict[str, Any]]) -> None:
    for clip in clips:
        print(status_line(clip))
    counts: Dict[str, int] = {}
    for clip in manifest["clips"]:
        value = str(clip.get("status", "unknown"))
        counts[value] = counts.get(value, 0) + 1
    materialized_count = sum(bool(clip.get("materialized")) for clip in manifest["clips"])
    print(
        "Batch: "
        + ", ".join(f"{key}={value}" for key, value in sorted(counts.items()))
        + f", materialized={materialized_count}/{len(manifest['clips'])}"
    )


def wait_for(manifest: Dict[str, Any], clips: List[Dict[str, Any]], interval: int) -> int:
    previous = ""
    while True:
        refresh(manifest, clips)
        # Materialize each successful clip as soon as it is available.  The
        # explicit materialize command can safely recover anything interrupted.
        materialize(
            manifest,
            [
                clip
                for clip in clips
                if clip.get("status") == "done" and not clip.get("materialized")
            ],
            False,
        )
        snapshot = "\n".join(status_line(clip) for clip in clips)
        if snapshot != previous:
            print(snapshot, flush=True)
            previous = snapshot
        statuses = {str(clip.get("status")) for clip in clips}
        if "not submitted" in statuses:
            raise RuntimeError("one or more selected clips are not submitted; run submit first")
        if statuses and statuses <= TERMINAL_STATUSES:
            failed = statuses - {"done"}
            unmaterialized = [clip["source_id"] for clip in clips if not clip.get("materialized")]
            return 2 if failed or unmaterialized else 0
        time.sleep(interval)


def url_path(value: str) -> str:
    return "/".join(quote(piece) for piece in value.split("/"))


def build_index(manifest: Dict[str, Any]) -> None:
    REVIEW_DIR.mkdir(parents=True, exist_ok=True)
    cards: List[str] = []
    complete = 0
    for clip in manifest["clips"]:
        status = str(clip.get("status") or "not submitted")
        materialized = bool(clip.get("materialized"))
        if materialized:
            complete += 1
        progress = min(100.0, max(0.0, float(clip.get("progress") or 0.0) * 100.0))
        if materialized:
            media = (
                f'<video controls preload="metadata" poster="{url_path(str(clip["poster"]))}">'
                f'<source src="{url_path(str(clip["output"]))}" type="video/mp4"></video>'
            )
        else:
            media = (
                f'<div class="placeholder"><span>{html.escape(str(clip.get("stage") or status))}</span>'
                f'<div class="bar"><i style="width:{progress:.1f}%"></i></div></div>'
            )
        duration = clip.get("duration_s")
        duration_text = f" · {float(duration):.2f}s" if duration is not None else ""
        error_value = clip.get("materialize_error") or clip.get("error")
        error = f'<p class="error">{html.escape(str(error_value))}</p>' if error_value else ""
        windows = clip.get("h3_chain_prompts", [])
        window_markup = "".join(
            f"<h3>Window {index}</h3><p>{html.escape(str(value))}</p>"
            for index, value in enumerate(windows, start=1)
        )
        cards.append(
            f'''<article class="card {'done' if materialized else html.escape(status)}">
              {media}
              <div class="body"><div class="heading"><h2>{html.escape(str(clip['source_id']))} · {html.escape(str(clip['title']))}</h2>
              <span>{'verified' if materialized else html.escape(status)}{duration_text}</span></div>
              {error}<details><summary>Prompt, chain windows, and seed {clip['seed']}</summary>
              <h3>Full brief</h3><p>{html.escape(str(clip['prompt']))}</p>{window_markup}</details></div>
            </article>'''
        )
    document = f'''<!doctype html>
<html lang="en"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>{html.escape(str(manifest["batch"]))} Review</title>
<style>
:root{{--ink:#f7f4ed;--muted:#b8b4aa;--panel:#1d211f;--line:#343a36;--accent:#edb548;--ok:#77c593}}
*{{box-sizing:border-box}}body{{margin:0;background:#111412;color:var(--ink);font:15px/1.45 -apple-system,BlinkMacSystemFont,"Segoe UI",sans-serif}}
header{{position:sticky;top:0;z-index:2;padding:24px max(22px,4vw);background:#111412ee;backdrop-filter:blur(16px);border-bottom:1px solid var(--line)}}
h1{{margin:0;font-size:clamp(25px,4vw,44px);letter-spacing:-.03em}}header p{{margin:6px 0 0;color:var(--muted)}}
main{{display:grid;grid-template-columns:repeat(auto-fit,minmax(330px,1fr));gap:22px;padding:28px max(22px,4vw) 60px}}
.card{{overflow:hidden;background:var(--panel);border:1px solid var(--line);border-radius:16px;box-shadow:0 12px 32px #0004}}
video,.placeholder{{display:block;width:100%;aspect-ratio:16/9;background:#090b0a;object-fit:cover}}
.placeholder{{display:flex;flex-direction:column;justify-content:center;align-items:center;color:var(--muted);gap:16px;padding:28px;text-align:center}}
.bar{{height:6px;width:72%;background:#303530;border-radius:5px;overflow:hidden}}.bar i{{height:100%;display:block;background:var(--accent)}}
.body{{padding:16px}}.heading{{display:flex;gap:12px;align-items:baseline;justify-content:space-between}}h2{{font-size:17px;margin:0}}
.heading span{{font-size:12px;color:var(--muted);text-transform:uppercase;white-space:nowrap}}.done .heading span{{color:var(--ok)}}
details{{margin-top:12px;color:var(--muted)}}summary{{cursor:pointer}}details p{{font-size:13px}}h3{{font-size:12px;text-transform:uppercase;margin:14px 0 4px;color:var(--ink)}}
.error{{color:#ff938a;font-size:13px}}
</style></head><body>
<header><h1>{html.escape(str(manifest["batch"]))}</h1><p>{complete} of {len(manifest["clips"])} clips verified · 10 seconds · 480p draft · two-window H3 chain · updated {html.escape(str(manifest['updated_at']))}</p></header>
<main>{''.join(cards)}</main></body></html>'''
    temporary = INDEX_FILE.with_suffix(".html.tmp")
    temporary.write_text(document, encoding="utf-8")
    temporary.replace(INDEX_FILE)


def configure(args: argparse.Namespace) -> None:
    global API_BASE, TOKEN_FILE, TOKEN_FILE_EXPLICIT, SILICON_SWARM
    global PROMPTS_FILE, H3_CHAIN_PROMPTS_FILE, WORKER_ARTIFACT_DIR, JOB_PREFIX
    global REVIEW_DIR, FINAL_DIR, POSTER_DIR, MANIFEST_FILE, INDEX_FILE
    API_BASE = args.api.rstrip("/")
    validated_api_base()
    if args.token_file is not None:
        TOKEN_FILE = Path(args.token_file).expanduser().resolve()
        TOKEN_FILE_EXPLICIT = True
    SILICON_SWARM = Path(args.swarm_config).expanduser().resolve()
    PROMPTS_FILE = Path(args.prompts).expanduser().resolve()
    H3_CHAIN_PROMPTS_FILE = Path(args.chain_prompts).expanduser().resolve()
    WORKER_ARTIFACT_DIR = Path(args.worker_artifacts).expanduser().resolve()
    REVIEW_DIR = Path(args.review_dir).expanduser().resolve()
    JOB_PREFIX = args.job_prefix
    FINAL_DIR = REVIEW_DIR / "final"
    POSTER_DIR = REVIEW_DIR / "posters"
    MANIFEST_FILE = REVIEW_DIR / "manifest.json"
    INDEX_FILE = REVIEW_DIR / "index.html"


def main(argv: Optional[List[str]] = None) -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--api", default=API_BASE, help="loopback video-node HTTP origin")
    parser.add_argument("--token-file", help="raw bearer-token file (never pass a token on the command line)")
    parser.add_argument("--swarm-config", default=str(SILICON_SWARM), help="fallback swarm.json if the default token file is absent")
    parser.add_argument("--prompts", default=str(PROMPTS_FILE), help="clip specification JSON")
    parser.add_argument("--chain-prompts", default=str(H3_CHAIN_PROMPTS_FILE), help="JSON object mapping each clip ID to two window prompts")
    parser.add_argument("--review-dir", default=str(REVIEW_DIR), help="output directory for manifest, gallery, videos, and sidecars")
    parser.add_argument("--worker-artifacts", default=str(WORKER_ARTIFACT_DIR), help="local video-node artifact directory containing provenance sidecars")
    parser.add_argument("--job-prefix", default=JOB_PREFIX, help="unique persistent namespace for this batch (default: MMH3)")
    subparsers = parser.add_subparsers(dest="command", required=True)
    for name in ("submit", "retry", "status", "wait", "materialize"):
        child = subparsers.add_parser(name)
        child.add_argument("ids", nargs="*", help="optional source IDs such as HB001 HB002")
        if name == "wait":
            child.add_argument("--interval", type=int, default=15, help="polling interval in seconds")
    subparsers.add_parser("build-review")
    args = parser.parse_args(argv)
    configure(args)

    manifest = load_manifest()
    if args.command == "build-review":
        save_manifest(manifest)
        print(INDEX_FILE)
        return 0
    clips = choose(manifest["clips"], args.ids)
    if args.command == "submit":
        submit(manifest, clips)
        print_status(manifest, clips)
        return 0
    if args.command == "retry":
        result = retry_failed(manifest, clips)
        print_status(manifest, clips)
        return result
    if args.command == "status":
        refresh(manifest, clips)
        print_status(manifest, clips)
        return 0
    if args.command == "materialize":
        return materialize(manifest, clips)
    return wait_for(manifest, clips, max(5, int(args.interval)))


if __name__ == "__main__":
    try:
        raise SystemExit(main())
    except KeyboardInterrupt:
        raise SystemExit(130)
    except Exception as exc:
        print(f"error: {exc}", file=sys.stderr)
        raise SystemExit(1)
