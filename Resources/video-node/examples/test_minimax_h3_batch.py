#!/usr/bin/env python3

import json
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

sys.path.insert(0, str(Path(__file__).resolve().parent))
import minimax_h3_batch as batch


def setUpModule() -> None:
    global network_guard
    network_guard = patch.object(batch.HTTP, "open", side_effect=AssertionError("unexpected network request"))
    network_guard.start()


def tearDownModule() -> None:
    network_guard.stop()


def valid_probe(path: Path) -> dict:
    return {
        "valid": True,
        "errors": [],
        "checks": {},
        "duration_seconds": 10.0,
        "width": 854,
        "height": 480,
        "video_codec": "h264",
        "frame_rate": 24.0,
        "frames": 240,
        "audio_codec": "aac",
        "audio_channels": 2,
        "audio_sample_rate": "32000",
        "bytes": path.stat().st_size,
        "sha256": batch.sha256(path),
    }


class BatchSpecificationTests(unittest.TestCase):
    def test_exactly_twenty_namespaced_h3_payloads(self) -> None:
        manifest = batch.fresh_manifest()
        self.assertEqual(len(manifest["clips"]), 20)
        self.assertEqual(manifest["model"], "hailuo-h3")
        self.assertEqual(manifest["seconds"], 10)
        self.assertEqual(manifest["resolution"], "480p")
        self.assertEqual(manifest["quality"], "draft")
        self.assertEqual(
            [clip["source_id"] for clip in manifest["clips"]],
            [f"HB{index:03d}" for index in range(1, 21)],
        )
        for clip in manifest["clips"]:
            payload = batch.submission_payload(manifest, clip)
            self.assertTrue(payload["entry_id"].startswith("MMH3_HB"))
            self.assertTrue(payload["output_name"].startswith("MMH3_HB"))
            self.assertNotRegex(payload["output_name"], r"^HB\d{3}")
            self.assertEqual(payload["model"], "hailuo-h3")
            self.assertEqual(payload["seconds"], 10)
            self.assertEqual(payload["resolution"], "480p")
            self.assertEqual(len(payload["h3_chain_prompts"]), 2)
            self.assertIn("Window 1", payload["h3_chain_prompts"][0])
            self.assertIn("Window 2", payload["h3_chain_prompts"][1])

    def test_chain_file_fails_closed_on_wrong_key_set_or_pair(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "chains.json"
            path.write_text(json.dumps({"HB001": ["one", "two"]}), encoding="utf-8")
            with patch.object(batch, "H3_CHAIN_PROMPTS_FILE", path):
                with self.assertRaisesRegex(RuntimeError, "must match"):
                    batch.prompt_spec()

            invalid = {f"HB{index:03d}": ["one", "two"] for index in range(1, 21)}
            invalid["HB020"] = ["only one"]
            path.write_text(json.dumps(invalid), encoding="utf-8")
            with patch.object(batch, "H3_CHAIN_PROMPTS_FILE", path):
                with self.assertRaisesRegex(RuntimeError, "exactly two"):
                    batch.h3_chain_prompt_spec()

    def test_custom_manifest_can_have_one_clip(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            prompt = root / "prompts.json"
            chains = root / "chains.json"
            prompt.write_text(json.dumps({"batch": "My example", "clips": [{
                "id": "Scene-1", "title": "A scene", "slug": "my_scene", "seed": 42,
                "prompt": "A continuous scene",
            }]}), encoding="utf-8")
            chains.write_text(json.dumps({"Scene-1": ["The opening", "The continuation"]}), encoding="utf-8")
            with patch.object(batch, "PROMPTS_FILE", prompt), patch.object(
                batch, "H3_CHAIN_PROMPTS_FILE", chains
            ), patch.object(batch, "JOB_PREFIX", "Custom"):
                manifest = batch.fresh_manifest()
            self.assertEqual(manifest["batch"], "My example")
            self.assertEqual(len(manifest["clips"]), 1)
            self.assertEqual(manifest["clips"][0]["job_id"], "Custom_Scene-1")
            self.assertEqual(manifest["clips"][0]["source_output_name"], "Custom_Scene-1_my_scene.mp4")

    def test_prompt_paths_duplicate_ids_and_wrong_settings_are_rejected(self) -> None:
        original = batch.prompt_spec()
        invalid_specs = []
        for field, value in (("slug", "../../escaped"), ("id", "../escaped"), ("seed", -1)):
            spec = json.loads(json.dumps(original))
            spec["clips"][0][field] = value
            invalid_specs.append(spec)
        spec = json.loads(json.dumps(original))
        spec["clips"][1]["id"] = spec["clips"][0]["id"].lower()
        invalid_specs.append(spec)
        spec = json.loads(json.dumps(original))
        spec["seconds"] = 15
        invalid_specs.append(spec)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "prompts.json"
            for spec in invalid_specs:
                with self.subTest(spec=spec["clips"][0]["id"]):
                    path.write_text(json.dumps(spec), encoding="utf-8")
                    with patch.object(batch, "PROMPTS_FILE", path), self.assertRaises(RuntimeError):
                        batch.prompt_spec()

    def test_remote_identity_includes_chain_prompts(self) -> None:
        clip = batch.fresh_manifest()["clips"][0]
        state = {
            "id": clip["job_id"],
            "model": "hailuo-h3",
            "seconds": 10,
            "resolution": "480p",
            "seed": clip["seed"],
            "prompt": clip["prompt"],
            "h3_chain_prompts": ["wrong one", "wrong two"],
        }
        with self.assertRaisesRegex(RuntimeError, "h3_chain_prompts"):
            batch.validate_remote_identity(clip, state)


class IdempotencyTests(unittest.TestCase):
    def test_resume_rejects_changed_prompt_in_existing_manifest(self) -> None:
        manifest = batch.fresh_manifest()
        manifest["clips"][0]["prompt"] = "An older, different prompt"
        manifest["clips"][0]["materialized"] = True
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with patch.object(batch, "MANIFEST_FILE", path):
                with self.assertRaisesRegex(RuntimeError, "changed HB001 prompt"):
                    batch.load_manifest()

    def test_resume_preserves_retry_identity(self) -> None:
        manifest = batch.fresh_manifest()
        clip = manifest["clips"][0]
        clip.update(attempt=2, job_id="MMH3_HB001_R02", status="queued")
        clip["source_output_name"] = batch.source_output_name(clip, 2)
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "manifest.json"
            path.write_text(json.dumps(manifest), encoding="utf-8")
            with patch.object(batch, "MANIFEST_FILE", path):
                resumed = batch.load_manifest()
        self.assertEqual(resumed["clips"][0]["job_id"], "MMH3_HB001_R02")
        self.assertEqual(resumed["clips"][0]["status"], "queued")

    def test_repeated_submit_posts_only_once(self) -> None:
        manifest = batch.fresh_manifest()
        clip = manifest["clips"][0]
        remote = None
        posts = []

        def fake_request(path: str, payload=None, timeout=30):
            nonlocal remote
            if path.startswith("/v1/jobs/"):
                if remote is None:
                    raise batch.APIError(404, "missing")
                return dict(remote)
            posts.append(payload)
            remote = {
                "id": clip["job_id"],
                "status": "queued",
                "stage": "waiting for Apple GPU",
                "progress": 0.0,
                "model": payload["model"],
                "seconds": payload["seconds"],
                "resolution": payload["resolution"],
                "seed": payload["seed"],
                "prompt": payload["prompt"],
                "h3_chain_prompts": payload["h3_chain_prompts"],
            }
            return {"job_id": clip["job_id"]}

        with patch.object(batch, "request", side_effect=fake_request), patch.object(
            batch, "save_manifest"
        ):
            batch.submit(manifest, [clip])
            batch.submit(manifest, [clip])
        self.assertEqual(len(posts), 1)
        self.assertEqual(len(posts[0]["h3_chain_prompts"]), 2)

    def test_explicit_retry_uses_deterministic_new_namespace(self) -> None:
        manifest = batch.fresh_manifest()
        clip = manifest["clips"][0]
        clip["status"] = "failed"
        submitted = []
        with patch.object(batch, "refresh"), patch.object(batch, "save_manifest"), patch.object(
            batch, "submit", side_effect=lambda _manifest, clips: submitted.extend(clips)
        ):
            self.assertEqual(batch.retry_failed(manifest, [clip]), 0)
        self.assertEqual(clip["attempt"], 2)
        self.assertEqual(clip["job_id"], "MMH3_HB001_R02")
        self.assertTrue(clip["source_output_name"].endswith("_R02.mp4"))
        self.assertEqual(submitted, [clip])


class ArtifactValidationTests(unittest.TestCase):
    def test_probe_requires_about_240_frames(self) -> None:
        response = {
            "streams": [
                {
                    "codec_type": "video",
                    "codec_name": "h264",
                    "width": 854,
                    "height": 480,
                    "avg_frame_rate": "24/1",
                    "nb_frames": "238",
                    "duration": "10.0",
                },
                {"codec_type": "audio", "codec_name": "aac", "channels": 2},
            ],
            "format": {"duration": "10.0"},
        }
        completed = subprocess.CompletedProcess([], 0, stdout=json.dumps(response), stderr="")
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clip.mp4"
            path.write_bytes(b"video")
            with patch.object(batch.subprocess, "run", return_value=completed) as run, patch.object(
                batch, "executable", return_value="ffprobe"
            ):
                result = batch.probe_media(path)
        self.assertFalse(result["valid"])
        self.assertIn("frame_count_about_240", result["errors"])
        argv = run.call_args.args[0]
        self.assertEqual(argv[argv.index("-v") + 1], "error")
        self.assertEqual(argv.count("error"), 1)

    def test_failed_decode_does_not_replace_existing_artifact(self) -> None:
        clip = batch.fresh_manifest()["clips"][0]
        clip["status"] = "done"
        with tempfile.TemporaryDirectory() as directory:
            review = Path(directory)
            destination = review / clip["output"]
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"previous artifact")
            candidate = destination.with_name("." + destination.name + ".download")
            candidate.write_bytes(b"new artifact")
            with patch.object(batch, "REVIEW_DIR", review), patch.object(
                batch, "source_provenance", return_value={}
            ), patch.object(batch, "worker_artifact_hash", return_value=batch.sha256(candidate)
            ), patch.object(batch, "probe_media", side_effect=[{"valid": False}, valid_probe(candidate)]), patch.object(
                batch, "download_artifact"
            ), patch.object(batch, "full_decode", side_effect=RuntimeError("decode failed")):
                with self.assertRaisesRegex(RuntimeError, "decode failed"):
                    batch.materialize_one(clip)
            self.assertEqual(destination.read_bytes(), b"previous artifact")
            self.assertFalse(candidate.exists())

    def test_decoder_rejects_errors_even_with_zero_exit_status(self) -> None:
        completed = subprocess.CompletedProcess([], 0, stdout="", stderr="corrupt video frame")
        with patch.object(batch, "executable", return_value="ffmpeg"), patch.object(
            batch.subprocess, "run", return_value=completed
        ) as run:
            with self.assertRaisesRegex(RuntimeError, "full audio/video decode failed"):
                batch.full_decode(Path("placeholder.mp4"))
        self.assertIn("-xerror", run.call_args.args[0])

    def test_materialize_preserves_verified_worker_provenance(self) -> None:
        manifest = batch.fresh_manifest()
        clip = manifest["clips"][0]
        clip["status"] = "done"
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            review = root / "review"
            worker = root / "worker"
            destination = review / clip["output"]
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"x" * 5000)
            worker.mkdir()
            provenance = {
                "id": clip["job_id"],
                "title": Path(clip["source_output_name"]).stem,
                "prompt": clip["prompt"],
                "seed": clip["seed"],
                "model": "MiniMaxAI/MiniMax-H3",
                "pipeline": "Phosphene Hailuo H3",
                "phosphene_job_id": "j-test-001",
                "h3_quality": "draft",
                "h3_length": "10s",
                "h3_upscale": "off",
                "h3_turbo": True,
                "h3_chain_prompts": clip["h3_chain_prompts"],
                "duration_seconds": 10.0,
                "frames": 240,
                "frame_rate": 24,
                "output_resolution": "854x480",
                "audio": True,
            }
            source = worker / Path(clip["source_output_name"]).with_suffix(".json").name
            source.write_text(json.dumps(provenance), encoding="utf-8")
            source.with_suffix(".mp4").write_bytes(destination.read_bytes())
            previous = dict(provenance, validation=dict(valid_probe(destination), full_decode=True))
            (review / clip["sidecar"]).write_text(json.dumps(previous), encoding="utf-8")
            with patch.object(batch, "REVIEW_DIR", review), patch.object(
                batch, "WORKER_ARTIFACT_DIR", worker
            ), patch.object(batch, "probe_media", side_effect=valid_probe), patch.object(
                batch, "download_artifact"
            ) as download, patch.object(batch, "full_decode"), patch.object(batch, "make_poster"):
                self.assertTrue(batch.materialize_one(clip))
            download.assert_not_called()
            final_sidecar = review / clip["sidecar"]
            saved = json.loads(final_sidecar.read_text(encoding="utf-8"))
            self.assertEqual(saved["id"], clip["job_id"])
            self.assertEqual(saved["model"], "MiniMaxAI/MiniMax-H3")
            self.assertEqual(saved["pipeline"], "Phosphene Hailuo H3")
            self.assertEqual(saved["phosphene_job_id"], "j-test-001")
            self.assertEqual(saved["h3_chain_prompts"], clip["h3_chain_prompts"])
            self.assertTrue(saved["validation"]["full_decode"])

    def test_valid_old_attempt_is_downloaded_before_relabeling(self) -> None:
        clip = batch.fresh_manifest()["clips"][0]
        clip.update(attempt=2, job_id="MMH3_HB001_R02", status="done")
        clip["source_output_name"] = batch.source_output_name(clip, 2)
        with tempfile.TemporaryDirectory() as directory:
            review = Path(directory)
            destination = review / clip["output"]
            destination.parent.mkdir(parents=True)
            destination.write_bytes(b"old attempt" * 500)
            sidecar = review / clip["sidecar"]
            sidecar.write_text(json.dumps({
                "id": "MMH3_HB001", "phosphene_job_id": "old-phosphene",
                "validation": dict(valid_probe(destination), full_decode=True),
            }), encoding="utf-8")
            worker_video = review / "worker.mp4"
            worker_video.write_bytes(b"new attempt" * 500)
            new_hash = batch.sha256(worker_video)
            current_provenance = {"id": clip["job_id"], "phosphene_job_id": "new-phosphene"}

            def download(_job, target):
                self.assertEqual(target.read_bytes(), b"old attempt" * 500)
                target.with_name("." + target.name + ".download").write_bytes(worker_video.read_bytes())

            with patch.object(batch, "REVIEW_DIR", review), patch.object(
                batch, "source_provenance", return_value=current_provenance
            ), patch.object(batch, "worker_artifact_hash", return_value=new_hash), patch.object(
                batch, "probe_media", side_effect=valid_probe
            ), patch.object(batch, "download_artifact", side_effect=download) as fetch, patch.object(
                batch, "full_decode"
            ), patch.object(batch, "make_poster") as poster:
                self.assertTrue(batch.materialize_one(clip))
            fetch.assert_called_once()
            self.assertEqual(destination.read_bytes(), worker_video.read_bytes())
            saved = json.loads(sidecar.read_text(encoding="utf-8"))
            self.assertEqual(saved["id"], "MMH3_HB001_R02")
            self.assertEqual(saved["phosphene_job_id"], "new-phosphene")
            self.assertEqual(saved["validation"]["sha256"], new_hash)
            self.assertTrue(poster.call_args.kwargs["replace_existing"])

    def test_worker_paths_prefer_isolated_job_layout(self) -> None:
        clip = batch.fresh_manifest()["clips"][0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            legacy = root / clip["source_output_name"]
            legacy.with_suffix(".json").write_text("{}", encoding="utf-8")
            isolated = root / clip["job_id"] / clip["source_output_name"]
            isolated.parent.mkdir()
            isolated.with_suffix(".json").write_text("{}", encoding="utf-8")
            with patch.object(batch, "WORKER_ARTIFACT_DIR", root):
                self.assertEqual(batch.worker_artifact_paths(clip), (isolated, isolated.with_suffix(".json")))

    def test_worker_provenance_mismatch_fails_closed(self) -> None:
        clip = batch.fresh_manifest()["clips"][0]
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            root.mkdir(exist_ok=True)
            path = root / Path(clip["source_output_name"]).with_suffix(".json").name
            path.write_text(json.dumps({"id": clip["job_id"], "model": "not-minimax"}), encoding="utf-8")
            with patch.object(batch, "WORKER_ARTIFACT_DIR", root):
                with self.assertRaisesRegex(RuntimeError, "worker provenance mismatch"):
                    batch.source_provenance(clip)


class ConfigurationTests(unittest.TestCase):
    def test_cli_builds_custom_review_without_network_or_rendering(self) -> None:
        globals_to_restore = {
            name: getattr(batch, name) for name in (
                "API_BASE", "TOKEN_FILE", "TOKEN_FILE_EXPLICIT", "SILICON_SWARM", "PROMPTS_FILE",
                "H3_CHAIN_PROMPTS_FILE", "WORKER_ARTIFACT_DIR", "JOB_PREFIX", "REVIEW_DIR",
                "FINAL_DIR", "POSTER_DIR", "MANIFEST_FILE", "INDEX_FILE",
            )
        }
        with tempfile.TemporaryDirectory() as directory, patch.multiple(batch, **globals_to_restore):
            root = Path(directory)
            with patch.object(batch, "request", side_effect=AssertionError("unexpected API request")), patch.object(
                batch.subprocess, "run", side_effect=AssertionError("unexpected renderer invocation")
            ):
                result = batch.main([
                    "--api", "http://localhost:8999", "--token-file", str(root / "token"),
                    "--review-dir", str(root / "review"), "--worker-artifacts", str(root / "artifacts"),
                    "--job-prefix", "Test", "build-review",
                ])
            manifest = json.loads((root / "review/manifest.json").read_text(encoding="utf-8"))
            self.assertEqual(result, 0)
            self.assertEqual(manifest["clips"][0]["job_id"], "Test_HB001")
            self.assertTrue((root / "review/index.html").exists())
            self.assertEqual(batch.WORKER_ARTIFACT_DIR, (root / "artifacts").resolve())
            self.assertEqual(batch.API_BASE, "http://localhost:8999")

    def test_token_file_auth_and_explicit_missing_file(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "token"
            with patch.object(batch, "TOKEN_FILE", path), patch.object(batch, "TOKEN_FILE_EXPLICIT", True):
                with self.assertRaisesRegex(RuntimeError, "does not exist"):
                    batch.auth_token()
                path.write_text("example-test-token\n", encoding="utf-8")
                self.assertEqual(batch.auth_token(), "example-test-token")

    def test_legacy_swarm_credential_requires_matching_origin(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "swarm.json"
            value = {"swarm_token": "shared-test-token", "peers": [
                {"base_url": "http://127.0.0.1:bad-port", "token": "invalid"},
                {"base_url": "http://127.0.0.1:9999", "token": "wrong-port"},
                {"base_url": "https://127.0.0.1:8790", "token": "wrong-scheme"},
                {"base_url": "http://127.0.0.1:8790"},
            ]}
            config.write_text(json.dumps(value), encoding="utf-8")
            with patch.object(batch, "TOKEN_FILE", root / "absent-token"), patch.object(
                batch, "TOKEN_FILE_EXPLICIT", False
            ), patch.object(batch, "SILICON_SWARM", config), patch.object(
                batch, "API_BASE", "http://127.0.0.1:8790"
            ):
                self.assertEqual(batch.auth_token(), "shared-test-token")
                value["peers"].pop()
                config.write_text(json.dumps(value), encoding="utf-8")
                with self.assertRaisesRegex(RuntimeError, "no credential"):
                    batch.auth_token()

    def test_nonlocal_api_is_rejected_before_credentials_are_read(self) -> None:
        for origin in ("https://example.com", "http://127.0.0.1:8790/path", "http://user@127.0.0.1:8790"):
            with self.subTest(origin=origin), patch.object(batch, "API_BASE", origin), patch.object(
                batch, "auth_token", side_effect=AssertionError("credential read")
            ):
                with self.assertRaisesRegex(RuntimeError, "loopback HTTP origin"):
                    batch.request("/v1/health")


if __name__ == "__main__":
    unittest.main()
