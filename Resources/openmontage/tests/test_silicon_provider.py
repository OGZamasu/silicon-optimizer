"""The Silicon Optimizer provider, against a fake app.

Runs inside an OpenMontage checkout that has ``tools/silicon`` in it, so the real
``BaseTool`` contract and the real registry are what is being tested. The app is
faked: a handshake file in a throwaway HOME, and a tiny HTTP server that answers
the way the control server does.
"""

from __future__ import annotations

import json
import io
import os
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

import pytest

from tools.base_tool import ToolStatus
from tools.silicon import _client
from tools.silicon.silicon_3d import Silicon3D
from tools.silicon.silicon_image import SiliconImage
from tools.silicon.silicon_video import SiliconVideo
from tools.tool_registry import ToolRegistry

TOKEN = "test-token-1234"


class _FakeApp:
    """Just enough of the control server: /health open, everything else bearer-gated."""

    def __init__(self, tmp_path: Path):
        self.tmp_path = tmp_path
        self.requests: list[tuple[str, dict]] = []
        self.video_available = True
        self.refuse_with: str | None = None
        fake = self

        class Handler(BaseHTTPRequestHandler):
            def log_message(self, *_):
                pass

            def _send(self, code: int, payload: dict):
                body = json.dumps(payload).encode()
                self.send_response(code)
                self.send_header("Content-Type", "application/json")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)

            def _authed(self) -> bool:
                return self.headers.get("Authorization") == f"Bearer {TOKEN}"

            def do_GET(self):
                if self.path == "/health":
                    return self._send(200, {"ok": True})
                if not self._authed():
                    return self._send(401, {"error": "Invalid or missing control token."})
                if self.path == "/video/models":
                    return self._send(200, [{"id": "wan22", "available": fake.video_available, "node": "silicon-node"}])
                return self._send(404, {"error": "no such route"})

            def do_POST(self):
                if not self._authed():
                    return self._send(401, {"error": "Invalid or missing control token."})
                length = int(self.headers.get("Content-Length") or 0)
                body = json.loads(self.rfile.read(length) or b"{}")
                fake.requests.append((self.path, body))
                if fake.refuse_with:
                    return self._send(422, {"error": fake.refuse_with})
                out = fake.tmp_path / "app-output"
                out.mkdir(exist_ok=True)
                if self.path == "/image/generate":
                    path = out / "render.png"
                    path.write_bytes(b"PNG")
                    return self._send(200, {"path": str(path), "elapsedSeconds": 1.5, "predictedPeakBytes": 1, "model": "flux-schnell", "warning": None})
                if self.path == "/video/generate":
                    path = out / "clip.mp4"
                    path.write_bytes(b"MP4")
                    return self._send(200, {"file": str(path), "node": "silicon-node", "model": "wan22", "elapsedSeconds": 90.0})
                if self.path == "/mesh/generate":
                    glb = out / "mesh.glb"
                    obj = out / "mesh.obj"
                    glb.write_bytes(b"GLB")
                    obj.write_bytes(b"OBJ")
                    return self._send(200, {"glbPath": str(glb), "objPath": str(obj), "elapsedSeconds": 40.0, "model": "hunyuan3d"})
                return self._send(404, {"error": "no such route"})

        self.server = HTTPServer(("127.0.0.1", 0), Handler)
        self.port = self.server.server_address[1]
        threading.Thread(target=self.server.serve_forever, daemon=True).start()

    def stop(self):
        self.server.shutdown()


@pytest.fixture
def app(tmp_path, monkeypatch):
    """A running fake app and a handshake that points at it."""
    fake = _FakeApp(tmp_path)
    handshake = tmp_path / "control.json"
    handshake.write_text(json.dumps({"port": fake.port, "pid": os.getpid(), "token": TOKEN, "version": "0.1.0"}))
    monkeypatch.setenv("SILICON_OPTIMIZER_HANDSHAKE", str(handshake))
    monkeypatch.delenv("SILICON_OPTIMIZER_URL", raising=False)
    yield fake
    fake.stop()


# --- discovery ------------------------------------------------------------------------


def test_registry_discovers_all_three_under_one_provider():
    registry = ToolRegistry()
    registry.discover("tools")
    ours = {t.name: t.capability for t in registry.get_by_provider("silicon_optimizer")}
    assert ours == {
        "silicon_image": "image_generation",
        "silicon_video": "video_generation",
        "silicon_3d": "3d_asset_generation",
    }


def test_every_tool_costs_nothing_and_reports_a_full_contract():
    for tool in (SiliconImage(), SiliconVideo(), Silicon3D()):
        assert tool.estimate_cost({"prompt": "x"}) == 0.0
        info = tool.get_info()
        assert info["provider"] == "silicon_optimizer"
        assert info["input_schema"]["required"], f"{tool.name} declares no required inputs"


# --- absence is reported, never guessed -----------------------------------------------


def test_no_app_means_unavailable_with_a_reason(tmp_path, monkeypatch):
    monkeypatch.setenv("SILICON_OPTIMIZER_HANDSHAKE", str(tmp_path / "missing.json"))
    monkeypatch.delenv("SILICON_OPTIMIZER_URL", raising=False)
    assert SiliconImage().get_status() == ToolStatus.UNAVAILABLE
    result = SiliconImage().execute({"prompt": "a cottage"})
    assert not result.success
    assert "not running" in result.error


def test_a_stale_handshake_is_not_trusted(tmp_path, monkeypatch, app):
    # Same port, but the pid belongs to nothing: a crash left the file behind.
    handshake = Path(os.environ["SILICON_OPTIMIZER_HANDSHAKE"])
    stale = json.loads(handshake.read_text())
    stale["pid"] = 2**22 + 12345  # far past any real pid on macOS
    handshake.write_text(json.dumps(stale))
    with pytest.raises(_client.SiliconUnavailable, match="stale"):
        _client.resolve()


def test_video_is_unavailable_when_no_node_offers_it(app):
    assert SiliconVideo().get_status() == ToolStatus.AVAILABLE
    app.video_available = False
    assert SiliconVideo().get_status() == ToolStatus.UNAVAILABLE


# --- the wire -------------------------------------------------------------------------


def test_image_translates_names_and_delivers_to_output_path(app, tmp_path):
    out = tmp_path / "wanted" / "hero.png"
    result = SiliconImage().execute({
        "prompt": "a lighthouse at dusk",
        "negative_prompt": "ignored by FLUX",
        "width": 1024, "height": 576, "seed": 7,
        "reference_image_path": "/tmp/ref.png", "reference_strength": 0.6,
        "output_path": str(out),
    })
    assert result.success, result.error
    path, body = app.requests[-1]
    assert path == "/image/generate"
    # OpenMontage names → the app's ImageRequest names, and nothing null sent.
    assert body == {"prompt": "a lighthouse at dusk", "width": 1024, "height": 576, "seed": 7,
                    "initImagePath": "/tmp/ref.png", "initImageInfluence": 0.6,
                    "localOnly": True}
    assert out.read_bytes() == b"PNG"
    assert result.artifacts == [str(out)]
    assert result.cost_usd == 0.0
    assert result.model == "flux-schnell"
    assert result.data["execution_destination"] == "this Mac"


def test_video_only_sends_the_still_for_image_to_video(app, tmp_path):
    SiliconVideo().execute({"prompt": "waves", "reference_image_path": "/tmp/still.png"})
    _, body = app.requests[-1]
    assert "imagePath" not in body, "text_to_video must not animate a still it was not asked to"

    result = SiliconVideo().execute({"prompt": "waves", "operation": "image_to_video",
                                     "reference_image_path": "/tmp/still.png", "duration_seconds": 5})
    _, body = app.requests[-1]
    assert body == {"prompt": "waves", "seconds": 5, "imagePath": "/tmp/still.png"}
    assert result.data["node"] == "silicon-node"
    assert result.data["format"] == "mp4"


def test_video_refuses_image_to_video_without_a_still(app):
    result = SiliconVideo().execute({"prompt": "waves", "operation": "image_to_video"})
    assert not result.success and "reference_image_path" in result.error
    assert app.requests == [], "a request the app would reject is never sent"


def test_3d_delivers_the_glb_and_keeps_the_obj(app, tmp_path):
    out = tmp_path / "props" / "crate.glb"
    result = Silicon3D().execute({"image_path": "/tmp/crate.png", "output_path": str(out), "vertex_budget": 1500})
    assert result.success, result.error
    _, body = app.requests[-1]
    assert body == {"imagePath": "/tmp/crate.png", "vertexBudget": 1500}
    assert out.read_bytes() == b"GLB"
    assert result.artifacts[0] == str(out)
    assert result.artifacts[1].endswith("mesh.obj")


def test_3d_will_not_pretend_to_do_text_to_3d(app):
    result = Silicon3D().execute({"operation": "text_to_3d", "prompt": "a crate", "output_path": "/tmp/x.glb"})
    assert not result.success and "silicon_image first" in result.error
    assert app.requests == []


# --- the app's own words come through -------------------------------------------------


def test_a_refusal_arrives_in_the_apps_words(app):
    app.refuse_with = "FLUX.1 dev needs 24 GB and this Mac has 16 GB free. Try schnell."
    result = SiliconImage().execute({"prompt": "a cottage"})
    assert not result.success
    assert "16 GB free" in result.error
    assert "422" in result.error


def test_a_remote_mac_needs_its_token(monkeypatch):
    monkeypatch.setenv("SILICON_OPTIMIZER_URL", "http://10.0.0.5:8791")
    monkeypatch.delenv("SILICON_OPTIMIZER_TOKEN", raising=False)
    with pytest.raises(_client.SiliconUnavailable, match="SILICON_OPTIMIZER_TOKEN"):
        _client.resolve()
    monkeypatch.setenv("SILICON_OPTIMIZER_TOKEN", "swarm-secret")
    assert _client.resolve() == _client.Endpoint("http://10.0.0.5:8791", "swarm-secret")


def test_success_body_is_capped_even_without_content_length(monkeypatch):
    class Response(io.BytesIO):
        headers = {}

        def __enter__(self):
            return self

        def __exit__(self, *_):
            self.close()

    monkeypatch.setattr(_client, "MAX_RESPONSE_BYTES", 8)
    monkeypatch.setattr(_client.request, "urlopen", lambda *_args, **_kwargs: Response(b"123456789"))
    with pytest.raises(_client.SiliconError, match="8-byte limit"):
        _client._open(_client.request.Request("http://127.0.0.1/test"), 1)


def test_error_body_and_diagnostic_are_bounded(monkeypatch):
    monkeypatch.setattr(_client, "MAX_ERROR_BYTES", 16)
    failure = _client.error.HTTPError(
        "http://127.0.0.1/test", 500, "failure", {}, io.BytesIO(b"x" * 17)
    )

    def raise_failure(*_args, **_kwargs):
        raise failure

    monkeypatch.setattr(_client.request, "urlopen", raise_failure)
    with pytest.raises(_client.SiliconError, match="16-byte limit") as raised:
        _client._open(_client.request.Request("http://127.0.0.1/test"), 1)
    assert len(str(raised.value)) < 200
