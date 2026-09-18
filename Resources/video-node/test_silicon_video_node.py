#!/usr/bin/env python3

import contextlib
import http.client
import json
import os
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs
from unittest.mock import patch

import silicon_video_node as node


class PhospheneMappingTests(unittest.TestCase):
    def test_h3_resolution_and_duration_mapping(self) -> None:
        # H3 can request a 1080p delivery without changing the pre-existing
        # LTX fallback for an unknown/1080p resolution.
        self.assertEqual(node.resolution_plan("1080p")["output_h"], 720)
        self.assertEqual(node.h3_output_resolution_plan("1080p")["output_h"], 1080)
        self.assertEqual(
            node.phosphene_render_options("480p", 3),
            {"h3_quality": "draft", "h3_length": "3s", "h3_upscale": "off"},
        )
        self.assertEqual(
            node.phosphene_render_options("720p", 10),
            {
                "h3_quality": "standard",
                "h3_length": "10s",
                "h3_upscale": "fit_720p",
            },
        )
        self.assertEqual(
            node.phosphene_render_options("1920x1080", 15),
            {
                "h3_quality": "high",
                "h3_length": "15s",
                "h3_upscale": "fit_1080p",
            },
        )
        with self.assertRaisesRegex(ValueError, "one of 3, 5, 10, or 15"):
            node.phosphene_render_options("720p", 8)
        with self.assertRaisesRegex(ValueError, "480p, 720p, or 1080p"):
            node.phosphene_render_options("360p", 5)

    def test_submission_form_selects_t2v_or_i2v(self) -> None:
        base = {
            "prompt": "A honey badger pilots a tiny sailboat.",
            "seed": 42,
            "resolution": "720p",
            "seconds": 10,
            "image_path": None,
        }
        with patch.object(node, "PHOSPHENE_H3_TURBO", True):
            form = node.phosphene_submission_form(base)
        self.assertEqual(
            form,
            {
                "engine": "h3",
                "mode": "t2v",
                "prompt": base["prompt"],
                "seed": "42",
                "h3_quality": "standard",
                "h3_length": "10s",
                "h3_upscale": "fit_720p",
                "h3_turbo": "true",
                "image": "",
                "enhance": "false",
                "open_when_done": "false",
            },
        )
        with patch.object(node, "PHOSPHENE_H3_TURBO", False):
            form = node.phosphene_submission_form({**base, "image_path": "/tmp/reference.png"})
        self.assertEqual(form["mode"], "i2v")
        self.assertEqual(form["image"], "/tmp/reference.png")
        self.assertEqual(form["h3_turbo"], "false")

    def test_submission_form_encodes_chain_prompts_as_json_text(self) -> None:
        prompts = ["The badger climbs aboard.", "It raises the sail."]
        form = node.phosphene_submission_form(
            {
                "prompt": "A honey badger sails away.",
                "seed": 42,
                "resolution": "720p",
                "seconds": 10,
                "image_path": None,
                "h3_chain_prompts": prompts,
            }
        )
        self.assertEqual(
            form["h3_chain_prompts"],
            '["The badger climbs aboard.","It raises the sail."]',
        )

    def test_chain_prompt_shape_and_bounds(self) -> None:
        self.assertEqual(
            node.normalize_h3_chain_prompts(
                ["  First beat. ", "Second beat."], "hailuo-h3", 10, True
            ),
            ["First beat.", "Second beat."],
        )
        cases = (
            ("not-a-list", "hailuo-h3", 10, "JSON list"),
            (["only one"], "hailuo-h3", 10, "exactly 2"),
            (["one", "  "], "hailuo-h3", 10, "must not be empty"),
            (["one", "x" * (node.MAX_H3_CHAIN_PROMPT_CHARS + 1)], "hailuo-h3", 10, "exceeds"),
            (["one", "two"], "ltx2-distilled", 10, "only supported"),
            (["one"], "hailuo-h3", 5, "only valid"),
        )
        for value, model, seconds, message in cases:
            with self.subTest(message=message), self.assertRaisesRegex(ValueError, message):
                node.normalize_h3_chain_prompts(value, model, seconds, True)
        self.assertIsNone(
            node.normalize_h3_chain_prompts(None, "hailuo-h3", 15, False)
        )


class PhospheneReadinessAndStatusTests(unittest.TestCase):
    @staticmethod
    def _empty_render_queue() -> node.RenderQueue:
        render_queue = node.RenderQueue.__new__(node.RenderQueue)
        render_queue.lock = threading.RLock()
        render_queue.jobs = {}
        return render_queue

    def test_readiness_uses_mocked_panel_status(self) -> None:
        with patch.object(
            node,
            "phosphene_request",
            return_value={"h3": {"available": True, "ram_note": "ready"}},
        ) as request:
            state = node.phosphene_h3_readiness()
        self.assertTrue(state["ready"])
        self.assertEqual(state["reason"], "")
        request.assert_called_once_with("/status")

        state = node.phosphene_h3_readiness(
            {"h3": {"available": False, "ram_note": "Q8 pack is not installed"}}
        )
        self.assertFalse(state["ready"])
        self.assertEqual(state["reason"], "Q8 pack is not installed")

        state = node.phosphene_h3_readiness(
            {
                "h3": {
                    "available": True,
                    "capable": False,
                    "ram_note": "H3 hardware detection reported 0 GB",
                }
            }
        )
        self.assertFalse(state["ready"])
        self.assertEqual(state["reason"], "H3 hardware detection reported 0 GB")

    def test_locates_jobs_and_maps_progress(self) -> None:
        snapshot = {
            "current": {
                "id": "p-current",
                "status": "running",
                "progress": {"pct": 50, "phase_label": "Denoising · step 4 / 8"},
            },
            "queue": [{"id": "p-queued", "status": "queued"}],
            "history": [
                {"id": "p-done", "status": "done", "output_path": "/trusted/clip.mp4"},
                {"id": "p-failed", "status": "failed", "error": "renderer stopped"},
            ],
        }
        location, record = node.locate_phosphene_job(snapshot, "p-current")
        self.assertEqual(location, "current")
        mapped = node.map_phosphene_progress(location, record)
        self.assertEqual(mapped["status"], "running")
        self.assertEqual(mapped["stage"], "Denoising · step 4 / 8")
        self.assertAlmostEqual(mapped["progress"], 0.47)

        location, record = node.locate_phosphene_job(snapshot, "p-queued")
        self.assertEqual(node.map_phosphene_progress(location, record)["stage"], "queued in Phosphene")

        location, record = node.locate_phosphene_job(snapshot, "p-done")
        self.assertEqual(node.map_phosphene_progress(location, record)["status"], "done")

        location, record = node.locate_phosphene_job(snapshot, "absent")
        self.assertEqual((location, record), ("missing", None))

    def test_panel_url_is_loopback_only(self) -> None:
        self.assertEqual(
            node._validated_phosphene_base_url("http://127.0.0.1:8198/"),
            "http://127.0.0.1:8198",
        )
        self.assertEqual(
            node._validated_phosphene_base_url("http://[::1]:8198"),
            "http://[::1]:8198",
        )
        for value in (
            "https://127.0.0.1:8198",
            "http://example.com:8198",
            "http://127.0.0.1:8198/status",
            "http://user:pass@127.0.0.1:8198",
        ):
            with self.subTest(value=value), self.assertRaises(RuntimeError):
                node._validated_phosphene_base_url(value)

    def test_long_h3_request_rejects_explicit_false_chain_capability(self) -> None:
        render_queue = self._empty_render_queue()
        status = {
            "h3": {
                "available": True,
                "capable": True,
                "chain": False,
                "first_frame": True,
            }
        }
        with patch.object(node, "phosphene_request", return_value=status) as request:
            with self.assertRaisesRegex(RuntimeError, "cannot chain"):
                render_queue.submit(
                    {
                        "model": "hailuo-h3",
                        "prompt": "A honey badger crosses the deck.",
                        "seconds": 10,
                        "resolution": "720p",
                    }
                )
        request.assert_called_once_with("/status")
        self.assertEqual(render_queue.jobs, {})

    def test_h3_i2v_rejects_explicit_false_first_frame_capability(self) -> None:
        render_queue = self._empty_render_queue()
        status = {
            "h3": {
                "available": True,
                "capable": True,
                "chain": True,
                "first_frame": False,
            }
        }
        with patch.object(node, "phosphene_request", return_value=status) as request:
            with self.assertRaisesRegex(RuntimeError, "cannot condition on a first frame"):
                render_queue.submit(
                    {
                        "model": "hailuo-h3",
                        "prompt": "The honey badger looks into camera.",
                        "seconds": 5,
                        "resolution": "480p",
                        "image_b64": "aW1hZ2U=",
                    }
                )
        request.assert_called_once_with("/status")
        self.assertEqual(render_queue.jobs, {})

    def test_missing_h3_capability_fields_are_not_assumed(self) -> None:
        readiness = node.phosphene_h3_readiness(
            {"h3": {"available": True, "capable": True}}
        )
        with self.assertRaisesRegex(RuntimeError, "cannot chain"):
            node.validate_phosphene_h3_request(readiness, 15, False)
        with self.assertRaisesRegex(RuntimeError, "cannot condition"):
            node.validate_phosphene_h3_request(readiness, 5, True)
        readiness_with_chain = node.phosphene_h3_readiness(
            {"h3": {"available": True, "capable": True, "chain": True}}
        )
        with self.assertRaisesRegex(RuntimeError, "separate prompt"):
            node.validate_phosphene_h3_request(readiness_with_chain, 10, False, True)

    def test_chain_prompts_require_live_runner_capability(self) -> None:
        render_queue = self._empty_render_queue()
        status = {
            "h3": {
                "available": True,
                "capable": True,
                "chain": True,
                "chain_prompts": False,
                "first_frame": True,
            }
        }
        with patch.object(node, "phosphene_request", return_value=status) as request:
            with self.assertRaisesRegex(RuntimeError, "separate prompt"):
                render_queue.submit(
                    {
                        "model": "hailuo-h3",
                        "prompt": "A continuous two-beat shot.",
                        "seconds": 10,
                        "resolution": "720p",
                        "h3_chain_prompts": ["The badger runs.", "It dives."],
                    }
                )
        request.assert_called_once_with("/status")
        self.assertEqual(render_queue.jobs, {})

    def test_chain_prompts_are_persisted_and_fingerprinted(self) -> None:
        render_queue = self._empty_render_queue()
        render_queue.pending = node.queue.Queue()
        status = {
            "h3": {
                "available": True,
                "capable": True,
                "chain": True,
                "chain_prompts": True,
                "first_frame": True,
            }
        }
        request = {
            "entry_id": "chain-test",
            "model": "hailuo-h3",
            "prompt": "A continuous two-beat shot.",
            "seconds": 10,
            "resolution": "720p",
            "seed": 123,
            "h3_chain_prompts": ["The badger runs.", "It dives."],
        }
        with patch.object(node, "phosphene_request", return_value=status), patch.object(
            render_queue, "_persist"
        ):
            self.assertEqual(render_queue.submit(request), "chain-test")
            first_fingerprint = render_queue.jobs["chain-test"]["request_fingerprint"]
            self.assertEqual(
                render_queue.jobs["chain-test"]["h3_chain_prompts"],
                request["h3_chain_prompts"],
            )
            with self.assertRaisesRegex(ValueError, "different render settings"):
                render_queue.submit(
                    {
                        **request,
                        "h3_chain_prompts": ["The badger waits.", "It dives."],
                    }
                )
        self.assertEqual(render_queue.jobs["chain-test"]["request_fingerprint"], first_fingerprint)

    def test_per_clip_sampling_is_frozen_fingerprinted_and_forwarded(self) -> None:
        render_queue = self._empty_render_queue()
        render_queue.pending = node.queue.Queue()
        status = {"h3": {"available": True, "capable": True, "chain": True, "first_frame": True}}
        payload = {"entry_id": "full-sampling", "model": "hailuo-h3", "prompt": "A badger sails.",
                   "seconds": 10, "resolution": "480p", "seed": 42, "h3_turbo": False}
        with patch.object(node, "phosphene_request", return_value=status), patch.object(render_queue, "_persist"), patch.object(node, "PHOSPHENE_H3_TURBO", True):
            self.assertEqual(render_queue.submit(payload), "full-sampling")
            self.assertEqual(render_queue.submit(payload), "full-sampling")
            saved = render_queue.jobs["full-sampling"]
            self.assertIs(saved["phosphene_h3_turbo"], False)
            self.assertEqual(saved["resolution"], "480p")
            self.assertEqual(node.phosphene_submission_form(saved)["h3_turbo"], "false")
            with self.assertRaisesRegex(ValueError, "different render settings"):
                render_queue.submit({**payload, "h3_turbo": True})
            render_queue.submit({**payload, "entry_id": "turbo", "h3_turbo": True})
            self.assertEqual(node.phosphene_submission_form(render_queue.jobs["turbo"])["h3_turbo"], "true")

    def test_sampling_rejects_wrong_types_and_wrong_models_before_readiness(self) -> None:
        for value in ("false", 0, 1, None, []):
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "h3_turbo must be a boolean"):
                self._empty_render_queue().submit({"prompt": "shot", "model": "hailuo-h3", "h3_turbo": value})
        with self.assertRaisesRegex(ValueError, "only supported for hailuo-h3"):
            self._empty_render_queue().submit({"prompt": "shot", "model": "ltx2-distilled", "h3_turbo": False})

    def test_interrupted_submission_is_not_repeated(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            render_queue = node.RenderQueue.__new__(node.RenderQueue)
            render_queue.lock = threading.RLock()
            render_queue.stop_event = threading.Event()
            render_queue.jobs = {
                "local-job": {
                    "id": "local-job",
                    "model": "hailuo-h3",
                    "output_path": str(root / "output.mp4"),
                    "raw_path": str(root / "raw.mp4"),
                    "candidate_path": str(root / "candidate.mp4"),
                    "log_path": str(root / "job.log"),
                    "poster_path": None,
                    "phosphene_job_id": None,
                    "phosphene_submit_attempted": True,
                }
            }
            with patch.object(node, "phosphene_request") as request:
                with self.assertRaisesRegex(RuntimeError, "refusing to submit a possible duplicate"):
                    render_queue._run_phosphene_job("local-job")
            request.assert_not_called()

    def test_capabilities_are_rechecked_immediately_before_remote_enqueue(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            render_queue = node.RenderQueue.__new__(node.RenderQueue)
            render_queue.lock = threading.RLock()
            render_queue.stop_event = threading.Event()
            render_queue.jobs = {
                "local-job": {
                    "id": "local-job",
                    "model": "hailuo-h3",
                    "prompt": "A honey badger trims a sail.",
                    "seed": 7,
                    "seconds": 15,
                    "resolution": "720p",
                    "image_path": None,
                    "output_path": str(root / "output.mp4"),
                    "raw_path": str(root / "raw.mp4"),
                    "candidate_path": str(root / "candidate.mp4"),
                    "log_path": str(root / "job.log"),
                    "poster_path": None,
                    "phosphene_job_id": None,
                    "phosphene_submit_attempted": False,
                }
            }
            status = {
                "h3": {
                    "available": True,
                    "capable": True,
                    "chain": False,
                    "first_frame": True,
                }
            }
            with patch.object(node, "phosphene_request", return_value=status) as request:
                with self.assertRaisesRegex(RuntimeError, "cannot chain"):
                    render_queue._run_phosphene_job("local-job")
            request.assert_called_once_with("/status")


class PhospheneArtifactSafetyTests(unittest.TestCase):
    def test_only_accepts_media_below_a_trusted_output_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "mlx_outputs"
            root.mkdir()
            clip = root / "clip.mp4"
            clip.write_bytes(b"0" * 5000)
            outside = Path(directory) / "outside.mp4"
            outside.write_bytes(b"0" * 5000)
            media = {
                "duration": 10.1,
                "video_duration": 10.1,
                "width": 1024,
                "height": 576,
            }
            with patch.object(node, "PHOSPHENE_OUTPUT_ROOTS", (root,)), patch.object(
                node, "probe_media", return_value=media
            ):
                self.assertEqual(node.validated_phosphene_output(clip, 10), clip.resolve())
                with self.assertRaisesRegex(RuntimeError, "outside the configured"):
                    node.validated_phosphene_output(outside, 10)


@contextlib.contextmanager
def isolated_node_paths(root):
    with contextlib.ExitStack() as stack:
        for name, value in {
            "APP_SUPPORT": root,
            "STATE_DIR": root / "state",
            "STATE_FILE": root / "state/jobs.json",
            "ARTIFACT_DIR": root / "artifacts",
            "UPLOAD_DIR": root / "uploads",
            "REVIEW_DIR": root / "review",
            "TOKEN_FILE": root / "token",
            "SWARM_CONFIG": root / "swarm.json",
            "LEGACY_HB_LAYOUT": False,
        }.items():
            stack.enter_context(patch.object(node, name, value))
        yield


class PortableNodeTests(unittest.TestCase):
    def test_environment_paths_expand_home_and_support_explicit_legacy_install(self):
        with patch.dict(os.environ, {"SILICON_VIDEO_DATA_DIR": "~/legacy-video"}):
            self.assertEqual(node.configured_path("SILICON_VIDEO_DATA_DIR", Path("/default")), Path.home() / "legacy-video")
        with patch.dict(os.environ, {}, clear=True):
            self.assertEqual(node.configured_path("SILICON_VIDEO_DATA_DIR", Path("/default")), Path("/default"))

    def test_token_file_wins_and_legacy_fallback_matches_only_this_peer(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            config = {"swarm_token": "shared", "peers": [
                {"name": "first-remote", "base_url": "http://remote:8790", "token": "unrelated"},
                {"name": "wrong-port", "base_url": "http://127.0.0.1:8198", "token": "unrelated-local"},
                {"name": "deceptive", "base_url": "http://127.0.0.1.evil:8790", "token": "deceptive"},
                {"name": "ours", "base_url": "http://localhost:8790/", "token": "matching"},
            ]}
            node.SWARM_CONFIG.write_text(json.dumps(config))
            with patch.object(node, "PORT", 8790):
                self.assertEqual(node.expected_token(), "matching")
                config["peers"][-1].pop("token")
                node.SWARM_CONFIG.write_text(json.dumps(config))
                self.assertEqual(node.expected_token(), "shared")
                config["peers"].pop()
                node.SWARM_CONFIG.write_text(json.dumps(config))
                self.assertEqual(node.expected_token(), "")
                node.TOKEN_FILE.write_text("private-token\n")
                self.assertEqual(node.expected_token(), "private-token")
                node.TOKEN_FILE.write_text("")
                self.assertEqual(node.expected_token(), "")

    def test_hardware_profile_uses_host_values(self):
        node.hardware_profile.cache_clear()
        def sysctl(command, **kwargs):
            value = str(64 * 1024 ** 3) if command[-1] == "hw.memsize" else "Apple M4 Max"
            return subprocess.CompletedProcess(command, 0, value + "\n", "")
        try:
            with patch.object(node.subprocess, "run", side_effect=sysctl):
                self.assertEqual(node.hardware_profile(), {"chip": "Apple M4 Max", "memory_gb": 64.0})
        finally:
            node.hardware_profile.cache_clear()

    def test_output_names_are_isolated_and_reference_image_changes_conflict(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            render = node.RenderQueue()
            request = {"entry_id": "one", "model": "ltx2-distilled", "prompt": "A sailboat.", "output_name": "same.mp4", "image_b64": "aW1hZ2U="}
            with patch.object(node, "model_readiness", return_value={"ready": True, "reason": "", "missing": []}):
                render.submit(request)
                self.assertEqual(render.submit(request), "one")
                render.submit({**request, "entry_id": "two"})
                self.assertNotEqual(render.jobs["one"]["output_path"], render.jobs["two"]["output_path"])
                with self.assertRaisesRegex(ValueError, "different render settings"):
                    render.submit({**request, "image_b64": "ZGlmZmVyZW50"})

    def test_recovery_keeps_phosphene_job_and_original_deadline(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            node.STATE_DIR.mkdir()
            deadline = time.time() + 60
            saved = {"recover": {"id": "recover", "status": "running", "model": "hailuo-h3", "phosphene_job_id": "panel-existing", "deadline_epoch": deadline}}
            node.STATE_FILE.write_text(json.dumps(saved))
            render = node.RenderQueue()
            self.assertEqual(render.jobs["recover"]["status"], "queued")
            self.assertEqual(render.pending.get_nowait(), "recover")
            self.assertEqual(render.jobs["recover"]["phosphene_job_id"], "panel-existing")
            self.assertEqual(render.jobs["recover"]["deadline_epoch"], deadline)

    def test_corrupt_queue_is_preserved(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            node.STATE_DIR.mkdir()
            node.STATE_FILE.write_text("{broken")
            with self.assertRaisesRegex(RuntimeError, "original state file has been preserved"):
                node.RenderQueue()
            self.assertEqual(node.STATE_FILE.read_text(), "{broken")

    def test_restart_after_mp4_before_sidecar_recovers_known_phosphene_job(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            node.STATE_DIR.mkdir()
            output = Path(directory) / "clip.mp4"
            output.write_bytes(b"fixture" * 1000)
            job = {"id": "recover", "status": "running", "model": "hailuo-h3", "prompt": "A sailboat.", "seed": 4, "phosphene_job_id": "panel-existing", "output_path": str(output)}
            node.STATE_FILE.write_text(json.dumps({"recover": job}))
            with patch.object(node, "completed_media_matches", return_value=True):
                render = node.RenderQueue()
                self.assertEqual(render.jobs["recover"]["status"], "queued")
                self.assertEqual(render.jobs["recover"]["phosphene_job_id"], "panel-existing")
                output.with_suffix(".json").write_text(json.dumps({**job, "model": "MiniMaxAI/MiniMax-H3"}))
                recovered = node.RenderQueue()
                self.assertEqual(recovered.jobs["recover"]["status"], "done")
                self.assertTrue(recovered.pending.empty())

    def test_expired_queued_job_never_submits_to_phosphene(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            render = node.RenderQueue()
            render.jobs["expired"] = {"model": "hailuo-h3", "deadline_epoch": time.time() - 1}
            with patch.object(node, "phosphene_request") as request:
                with self.assertRaisesRegex(RuntimeError, "including queue time"):
                    render._run_job("expired")
            request.assert_not_called()
            created = {"created_at": "2026-01-01T00:00:00+00:00"}
            self.assertEqual(node.job_deadline(created), 1767268800.0)


class NodeHTTPIntegrationTests(unittest.TestCase):
    def test_h3_http_submit_poll_provenance_and_authenticated_artifact(self):
        """Exercise both real HTTP contracts; only MLX/ffmpeg/media probing are mocked."""
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            root = Path(directory)
            source = root / "mlx_outputs/source.mp4"
            source.parent.mkdir()
            media_bytes = b"synthetic-media-for-contract-test" * 300
            source.write_bytes(media_bytes)
            captured = []
            class PanelHandler(BaseHTTPRequestHandler):
                def log_message(self, *args):
                    pass
                def do_GET(self):
                    response = ({"local_version": "4.12.2"} if self.path == "/version" else
                                {"h3": {"available": True, "capable": True, "chain": True, "chain_prompts": True, "first_frame": True}, "history": [{"id": "panel-h3-001", "status": "done", "output_path": str(source), "params": {"h3_turbo": False, "h3_steps": 30, "steps": 30}}] if captured else []})
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(json.dumps(response).encode())
                def do_POST(self):
                    self.assert_path = self.path
                    captured.append(parse_qs(self.rfile.read(int(self.headers["Content-Length"])).decode(), keep_blank_values=True))
                    self.send_response(200)
                    self.end_headers()
                    self.wfile.write(b'{"ok":true,"id":"panel-h3-001"}')
            panel = ThreadingHTTPServer(("127.0.0.1", 0), PanelHandler)
            server = ThreadingHTTPServer(("127.0.0.1", 0), node.Handler)
            workers = [threading.Thread(target=item.serve_forever, daemon=True) for item in (panel, server)]
            for worker in workers:
                worker.start()
            def request(method, path, body=None, authenticated=True):
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                headers = {"Authorization": "Bearer fixture-token"} if authenticated else {}
                if body is not None:
                    headers["Content-Type"] = "application/json"
                try:
                    connection.request(method, path, body=body, headers=headers)
                    response = connection.getresponse()
                    return response.status, response.read()
                finally:
                    connection.close()
            probe = {"duration": 10.0, "video_duration": 10.0, "width": 854, "height": 480, "codec": "h264", "frame_rate": "24/1", "nb_frames": 240, "audio": True}
            def ffmpeg(command, **kwargs):
                self.assertLessEqual(kwargs["timeout"], 600)
                Path(command[-1]).write_bytes(media_bytes)
                return subprocess.CompletedProcess(command, 0, "", "")
            try:
                node.TOKEN_FILE.write_text("fixture-token\n")
                render = node.RenderQueue()
                with patch.object(node, "RENDERS", render), patch.object(node, "PHOSPHENE_PANEL_URL", f"http://127.0.0.1:{panel.server_port}"), patch.object(node, "PHOSPHENE_OUTPUT_ROOTS", (source.parent,)), patch.object(node, "probe_media", return_value=probe), patch.object(node, "executable", side_effect=lambda name: name), patch.object(node.subprocess, "run", side_effect=ffmpeg), patch.object(node.Handler, "log_message"):
                    self.assertEqual(request("GET", "/v1/jobs", authenticated=False)[0], 401)
                    self.assertEqual(request("POST", "/v1/text-to-video", b"not-json")[0], 400)
                    with patch.object(node, "hardware_profile", return_value={"chip": "test", "memory_gb": 36}):
                        advertisement = json.loads(request("GET", "/v1/node")[1])
                    self.assertIn("h3_steps", advertisement["capabilities"][1]["supported_parameters"])
                    payload = {"entry_id": "http-h3", "model": "hailuo-h3", "prompt": "A sailboat crosses a lake.", "seconds": 10, "resolution": "480p", "seed": 7, "h3_turbo": False, "h3_steps": 30, "h3_chain_prompts": ["The sailboat moves.", "It reaches the shore."]}
                    encoded = json.dumps(payload).encode()
                    self.assertEqual(request("POST", "/v1/text-to-video", encoded)[0], 202)
                    self.assertEqual(request("POST", "/v1/text-to-video", encoded)[0], 202)
                    self.assertEqual(len(render.jobs), 1)
                    render._run_job("http-h3")
                    status, content = request("GET", "/v1/jobs/http-h3")
                    self.assertEqual(status, 200)
                    job = json.loads(content)
                    self.assertEqual(job["status"], "done")
                    self.assertEqual(len(captured), 1)
                    self.assertEqual(captured[0]["engine"], ["h3"])
                    self.assertEqual(captured[0]["h3_turbo"], ["false"])
                    self.assertEqual(captured[0]["h3_steps"], ["30"])
                    self.assertEqual(json.loads(captured[0]["h3_chain_prompts"][0]), payload["h3_chain_prompts"])
                    self.assertEqual(request("GET", job["artifact"], authenticated=False)[0], 401)
                    self.assertEqual(request("GET", job["artifact"]), (200, media_bytes))
                    metadata = json.loads(Path(render.jobs["http-h3"]["output_path"]).with_suffix(".json").read_text())
                    self.assertEqual(metadata["model"], "MiniMaxAI/MiniMax-H3")
                    self.assertIs(metadata["h3_turbo"], False)
                    self.assertEqual(metadata["requested_h3_steps"], 30)
                    self.assertEqual(metadata["h3_steps"], 30)
                    self.assertEqual(metadata["h3_forwards_per_window"], 29)
                    self.assertEqual(metadata["phosphene_job_id"], "panel-h3-001")
                    self.assertEqual(metadata["h3_chain_prompts"], payload["h3_chain_prompts"])
                    self.assertEqual(metadata["duration_seconds"], 10)
                    self.assertNotIn("output_path", job)
            finally:
                for item in (server, panel):
                    item.shutdown()
                    item.server_close()
                for worker in workers:
                    worker.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
