#!/usr/bin/env python3
"""Install the optional local video node; never install engines or model weights.

Uses Python's standard library. Run --dry-run first. The app and an existing
video-node service must be stopped before a real install so their writers cannot
race the peer-registry update. No credentials are printed or put in the plist.
"""

from __future__ import annotations

import argparse
import copy
import fcntl
import json
import os
import platform
import plistlib
import secrets
import shutil
import socket
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Any, Dict, Optional, Tuple
from urllib.parse import urlparse
from xml.parsers.expat import ExpatError

LABEL = "dev.siliconoptimizer.video-node"
DEFAULT_SUPPORT = Path.home() / "Library/Application Support/SiliconOptimizer"
MANAGED_ENVIRONMENT_KEYS = frozenset({
    "PATH", "PYTHONUNBUFFERED", "SILICON_VIDEO_DATA_DIR", "SILICON_VIDEO_TOKEN_FILE",
    "SILICON_SWARM_CONFIG", "SILICON_VIDEO_REVIEW_DIR", "PHOSPHENE_PANEL_URL",
    "PHOSPHENE_OUTPUT_ROOTS", "SILICON_VIDEO_LTX_ROOT", "SILICON_VIDEO_MODEL_DIR",
    "SILICON_VIDEO_GEMMA_DIR", "SILICON_VIDEO_LEGACY_HB_LAYOUT",
})


def path_arg(value: str) -> Path:
    return Path(value).expanduser().absolute()


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description=__doc__)
    result.add_argument("--dry-run", action="store_true", help="show paths and prerequisite checks without writing or starting anything")
    result.add_argument("--start", action="store_true", help="bootstrap the installed LaunchAgent (otherwise print the command)")
    result.add_argument("--data-dir", type=path_arg, default=path_arg(os.environ.get("SILICON_VIDEO_DATA_DIR", str(DEFAULT_SUPPORT / "video-node"))))
    result.add_argument("--swarm-config", type=path_arg, default=path_arg(os.environ.get("SILICON_SWARM_CONFIG", str(DEFAULT_SUPPORT / "swarm.json"))))
    result.add_argument("--phosphene-root", type=path_arg, help="existing Phosphene checkout containing mlx_ltx_panel.py; trusts its mlx_outputs")
    result.add_argument("--phosphene-url", default="http://127.0.0.1:8198", help="running loopback Phosphene panel origin")
    result.add_argument("--port", type=int, default=8790)
    result.add_argument("--peer-name", default="local-mlx-video")
    result.add_argument("--ltx-root", type=path_arg, help="existing standalone ltx-2-mlx checkout (.venv/bin/ltx-2-mlx)")
    result.add_argument("--model-dir", type=path_arg, help="existing standalone LTX Q4 model folder")
    result.add_argument("--gemma-dir", type=path_arg, help="existing standalone Gemma 3 12B 4-bit folder")
    result.add_argument("--review-dir", type=path_arg, default=Path.home() / "Movies/Silicon Optimizer")
    result.add_argument("--legacy-hb-layout", action="store_true", help="explicitly preserve old HBnnn output layout when reusing a HoneyBadger deployment")
    return result


def loopback_endpoint(value: Any, port: int) -> bool:
    try:
        parsed = urlparse(str(value))
        return (parsed.scheme == "http" and parsed.hostname in {"127.0.0.1", "localhost"}
                and parsed.port == port and not parsed.username and not parsed.password
                and parsed.path in {"", "/"} and not parsed.query and not parsed.fragment)
    except ValueError:
        return False


def read_swarm(path: Path) -> Tuple[Dict[str, Any], Optional[bytes]]:
    if path.is_symlink():
        raise ValueError("swarm config is a symlink; choose the real file explicitly")
    try:
        original = path.read_bytes()
    except FileNotFoundError:
        return {"peers": []}, None
    try:
        data = json.loads(original)
    except (ValueError, UnicodeDecodeError) as exc:
        raise ValueError("existing swarm config is invalid JSON; it has been left unchanged") from exc
    if not isinstance(data, dict) or not isinstance(data.get("peers", []), list):
        raise ValueError("existing swarm config must contain a peers array")
    if any(not isinstance(peer, dict) for peer in data.get("peers", [])):
        raise ValueError("existing swarm config contains an invalid peer; it has been left unchanged")
    return data, original


def merge_peer(config: Dict[str, Any], name: str, port: int, token: str) -> Dict[str, Any]:
    """Preserve other peers, existing names/credentials and unknown schema fields."""
    updated = copy.deepcopy(config)
    peers = updated.setdefault("peers", [])
    matches = [peer for peer in peers if loopback_endpoint(peer.get("base_url"), port)]
    if len(matches) > 1:
        raise ValueError("multiple peers already use this endpoint; resolve the duplicate registry entries first")
    named = [peer for peer in peers if peer.get("name") == name]
    if named and (not matches or any(peer is not matches[0] for peer in named)):
        raise ValueError("peer name is already used by another endpoint; choose --peer-name")
    if matches:
        peer = matches[0]
        existing = peer.get("token")
        if existing and existing != token:
            raise ValueError("node token and existing peer credential disagree; both have been left unchanged")
        peer["token"] = token
    else:
        peers.append({"name": name, "base_url": f"http://127.0.0.1:{port}", "token": token})
    return updated


def choose_token(config: Dict[str, Any], path: Path, port: int) -> str:
    if path.is_symlink():
        raise ValueError("token file is a symlink; it has been left unchanged")
    if path.exists():
        token = path.read_text(encoding="utf-8").strip()
        if not token or len(token) > 4096 or any(char.isspace() for char in token):
            raise ValueError("existing token file contains an invalid credential")
        return token
    matches = [peer for peer in config.get("peers", []) if loopback_endpoint(peer.get("base_url"), port)]
    if len(matches) == 1:
        token = matches[0].get("token")
        if isinstance(token, str) and token.strip() and not any(char.isspace() for char in token):
            return token
    return secrets.token_urlsafe(32)


def make_plist(args: argparse.Namespace, python: str, launch_dir: Optional[Path] = None) -> Tuple[Path, Dict[str, Any]]:
    directory = launch_dir or Path.home() / "Library/LaunchAgents"
    env = {
        "PATH": "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
        "PYTHONUNBUFFERED": "1",
        "SILICON_VIDEO_DATA_DIR": str(args.data_dir),
        "SILICON_VIDEO_TOKEN_FILE": str(args.data_dir / "token"),
        "SILICON_SWARM_CONFIG": str(args.swarm_config),
        "SILICON_VIDEO_REVIEW_DIR": str(args.review_dir),
        "PHOSPHENE_PANEL_URL": args.phosphene_url,
    }
    if args.phosphene_root:
        env["PHOSPHENE_OUTPUT_ROOTS"] = str(args.phosphene_root / "mlx_outputs")
    for value, key in ((args.ltx_root, "SILICON_VIDEO_LTX_ROOT"), (args.model_dir, "SILICON_VIDEO_MODEL_DIR"), (args.gemma_dir, "SILICON_VIDEO_GEMMA_DIR")):
        if value:
            env[key] = str(value)
    if args.legacy_hb_layout:
        env["SILICON_VIDEO_LEGACY_HB_LAYOUT"] = "1"
    return directory / f"{LABEL}.plist", {
        "Label": LABEL,
        "ProgramArguments": [python, str(args.data_dir / "silicon_video_node.py"), "--host", "127.0.0.1", "--port", str(args.port)],
        "WorkingDirectory": str(args.data_dir),
        "EnvironmentVariables": env,
        "RunAtLoad": True,
        "KeepAlive": True,
        "ProcessType": "Interactive",
        "ThrottleInterval": 10,
        "ExitTimeOut": 30,
        "StandardOutPath": str(args.data_dir / "logs/node.stdout.log"),
        "StandardErrorPath": str(args.data_dir / "logs/node.stderr.log"),
    }


def existing_custom_environment(path: Path) -> Dict[str, str]:
    """Preserve manual engine settings while installer-owned paths stay authoritative."""
    if path.is_symlink():
        raise ValueError("existing LaunchAgent is a symlink; it has been left unchanged")
    try:
        original = path.read_bytes()
    except FileNotFoundError:
        return {}
    try:
        plist = plistlib.loads(original)
    except (ValueError, TypeError, plistlib.InvalidFileException, ExpatError) as exc:
        raise ValueError("existing LaunchAgent is unreadable; it has been left unchanged") from exc
    if not isinstance(plist, dict):
        raise ValueError("existing LaunchAgent must be a dictionary; it has been left unchanged")
    environment = plist.get("EnvironmentVariables", {})
    if not isinstance(environment, dict) or any(
        not isinstance(key, str) or not isinstance(value, str)
        for key, value in environment.items()
    ):
        raise ValueError("existing LaunchAgent environment must contain string keys and values")
    return {key: value for key, value in environment.items() if key not in MANAGED_ENVIRONMENT_KEYS}


def prerequisites(args: argparse.Namespace) -> list:
    issues = []
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        issues.append("the renderer requires an Apple Silicon Mac running an arm64 Python")
    if sys.version_info < (3, 9):
        issues.append("Python 3.9 or newer is required")
    for name in ("ffmpeg", "ffprobe"):
        if not shutil.which(name, path="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:" + os.environ.get("PATH", "")):
            issues.append(f"{name} is missing; install ffmpeg before installing the node")
    if args.phosphene_root:
        if not (args.phosphene_root / "mlx_ltx_panel.py").is_file():
            issues.append("--phosphene-root must point to an existing Phosphene checkout containing mlx_ltx_panel.py")
    else:
        root = args.ltx_root or args.data_dir / "ltx-2-mlx"
        model = args.model_dir or args.data_dir / "models/ltx-2.3-mlx-q4"
        gemma = args.gemma_dir or args.data_dir / "models/gemma-3-12b-it-4bit"
        required = (root / ".venv/bin/ltx-2-mlx", model / "transformer-distilled.safetensors", model / "spatial_upscaler_x2_v1_1.safetensors", model / "vae_decoder.safetensors", model / "vocoder.safetensors", gemma / "config.json")
        if not all(item.is_file() for item in required):
            issues.append("provide --phosphene-root for H3 or install standalone LTX/Gemma assets first (see README.md)")
    return issues


def mutation_blockers(args: argparse.Namespace) -> list:
    issues = []
    try:
        app = subprocess.run(["/usr/bin/pgrep", "-x", "SiliconOptimizer"], capture_output=True, timeout=5)
        if app.returncode == 0:
            issues.append("quit Silicon Optimizer before pairing so the app cannot overwrite swarm.json")
        elif app.returncode != 1:
            issues.append("could not check whether Silicon Optimizer is running")
        service = subprocess.run(["/bin/launchctl", "print", f"gui/{os.getuid()}/{LABEL}"], capture_output=True, timeout=5)
        if service.returncode == 0:
            issues.append(f"stop the existing service first: launchctl bootout gui/{os.getuid()}/{LABEL}")
    except (OSError, subprocess.TimeoutExpired):
        issues.append("could not inspect macOS app/service state")
    try:
        with socket.socket() as probe:
            probe.bind(("127.0.0.1", args.port))
    except OSError:
        issues.append(f"port {args.port} is in use; stop the existing node or choose --port")
    lock_path = args.data_dir / "state/node.lock"
    if lock_path.exists():
        try:
            with lock_path.open("r") as handle:
                fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        except (OSError, BlockingIOError):
            issues.append("a node is using this data directory; stop it before installing")
    return issues


def atomic_write(path: Path, payload: bytes) -> None:
    if path.is_symlink():
        raise ValueError(f"refusing to replace a symlink: {path}")
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, temporary = tempfile.mkstemp(prefix=f".{path.name}.", dir=path.parent)
    try:
        with os.fdopen(fd, "wb") as handle:
            handle.write(payload)
            handle.flush()
            os.fsync(handle.fileno())
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def write_install(args: argparse.Namespace, source: Path, launch_dir: Optional[Path] = None) -> Tuple[Path, Optional[Path]]:
    """Called only after app/service checks; compare the registry again before writing."""
    config, original = read_swarm(args.swarm_config)
    token_path = args.data_dir / "token"
    token = choose_token(config, token_path, args.port)
    merged = merge_peer(config, args.peer_name, args.port, token)
    # A fresh owner config needs its own admin token for normal app pairing.
    # Existing configs, including member-only configs, retain their exact state.
    if original is None:
        merged["swarm_token"] = secrets.token_urlsafe(32)
    plist_path, plist = make_plist(args, sys.executable, launch_dir)
    plist["EnvironmentVariables"] = {
        **existing_custom_environment(plist_path),
        **plist["EnvironmentVariables"],
    }
    script = source.read_bytes()
    plist_bytes = plistlib.dumps(plist, sort_keys=True)
    registry = json.dumps(merged, indent=2, sort_keys=True).encode() + b"\n"
    # Refuse conflicts before any writes. The token is shared only via private
    # files; it is never a command argument, plist value, or log message.
    for path in (args.data_dir / "silicon_video_node.py", plist_path, token_path):
        if path.is_symlink():
            raise ValueError(f"refusing to replace a symlink: {path}")
    current = args.swarm_config.read_bytes() if args.swarm_config.exists() else None
    if current != original:
        raise ValueError("swarm config changed while planning; rerun with the app closed")
    backup = None
    args.data_dir.mkdir(parents=True, exist_ok=True)
    (args.data_dir / "logs").mkdir(exist_ok=True)
    if original is not None and merged != config:
        fd, saved = tempfile.mkstemp(prefix=args.swarm_config.name + ".backup-", dir=args.swarm_config.parent)
        with os.fdopen(fd, "wb") as handle:
            handle.write(original)
        backup = Path(saved)
    atomic_write(args.data_dir / "silicon_video_node.py", script)
    atomic_write(token_path, (token + "\n").encode())
    atomic_write(plist_path, plist_bytes)
    if merged != config or original is None:
        atomic_write(args.swarm_config, registry)
    args.swarm_config.chmod(0o600)
    return plist_path, backup


def main(argv: Optional[list] = None) -> int:
    arg_parser = parser()
    args = arg_parser.parse_args(argv)
    if not 1 <= args.port <= 65535:
        arg_parser.error("--port must be between 1 and 65535")
    if not args.peer_name.strip() or len(args.peer_name) > 128:
        arg_parser.error("--peer-name must be 1–128 characters")
    from silicon_video_node import _validated_phosphene_base_url
    try:
        args.phosphene_url = _validated_phosphene_base_url(args.phosphene_url)
        config, _ = read_swarm(args.swarm_config)
        # Validate the complete proposed merge even during a dry run.
        merge_peer(config, args.peer_name, args.port, choose_token(config, args.data_dir / "token", args.port))
        issues = prerequisites(args)
        blockers = mutation_blockers(args) if platform.system() == "Darwin" else []
        plist_path, _ = make_plist(args, sys.executable)
        existing_custom_environment(plist_path)
        print(f"Node data: {args.data_dir}\nRegistry: {args.swarm_config}\nLaunchAgent: {plist_path}\nEndpoint: http://127.0.0.1:{args.port}")
        for issue in issues + blockers:
            print(f"Required before install: {issue}")
        if args.dry_run:
            print("Dry run: no files, services, packages, or models changed. Credentials are omitted.")
            return 0 if not issues else 2
        if issues or blockers:
            return 2
        os.umask(0o077)
        plist_path, backup = write_install(args, Path(__file__).with_name("silicon_video_node.py"))
        if backup:
            print(f"Previous registry preserved at: {backup}")
        print("Installed the video node and paired its local peer. Engine/model installation remains separate.")
        if args.start:
            subprocess.run(["/bin/launchctl", "bootstrap", f"gui/{os.getuid()}", str(plist_path)], check=True)
            print("LaunchAgent started. Start Phosphene, then reopen Silicon Optimizer and choose Video → MiniMax Hailuo H3.")
        else:
            import shlex
            print(f"Start the node: launchctl bootstrap gui/{os.getuid()} {shlex.quote(str(plist_path))}")
        return 0
    except (OSError, ValueError, RuntimeError, subprocess.SubprocessError) as exc:
        print(f"Install failed: {exc}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
