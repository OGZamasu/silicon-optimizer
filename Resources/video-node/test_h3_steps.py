"""Sampling-depth contract tests. No models, real panel, or GPU work."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import silicon_video_node as node
from test_silicon_video_node import isolated_node_paths


READY = {"h3": {"available": True, "capable": True, "chain": True}}


def panel(path, form=None):
    if path == "/version":
        return {"local_version": "4.12.2"}
    if path == "/status":
        return READY
    raise AssertionError(f"Unexpected request {path}")


class H3StepsTests(unittest.TestCase):
    def test_only_known_running_release_contract_is_advertised(self):
        for version, supported in [("4.12.2", True), ("v4.12.2", True), ("4.13.0", True),
                                   ("4.12.1", False), ("4.9.9", False), ("5.0.0", False),
                                   ("dev", False), (None, False), ("4.12.2-dev", False), ("", False)]:
            with self.subTest(version=version), patch.object(node, "phosphene_request", return_value={"local_version": version, "disk_version": "4.99.0"}) as request:
                self.assertIs(node.phosphene_supports_h3_steps(), supported)
                request.assert_called_once_with("/version")
        with patch.object(node, "phosphene_request", side_effect=RuntimeError("unavailable")):
            self.assertFalse(node.phosphene_supports_h3_steps())

    def test_rejects_invalid_steps_and_requires_explicit_full_before_readiness(self):
        for value in [True, False, 20.0, 20.5, "20", 0, 3, 31, [], {}, -1]:
            with self.subTest(value=value), self.assertRaisesRegex(ValueError, "h3_steps"):
                node.normalize_h3_steps(value, "hailuo-h3", False)
        for turbo in [None, True, 0, "false"]:
            with self.subTest(turbo=turbo), self.assertRaisesRegex(ValueError, "explicit h3_turbo=false"):
                node.normalize_h3_steps(20, "hailuo-h3", turbo)
        with self.assertRaisesRegex(ValueError, "only for hailuo-h3"):
            node.normalize_h3_steps(20, "ltx2-distilled", False)
        self.assertIsNone(node.normalize_h3_steps(None, "ltx2-distilled", None))
        for value in [4, 9, 20, 30]:
            self.assertEqual(node.normalize_h3_steps(value, "hailuo-h3", False), value)

    def test_steps_are_saved_forwarded_deduplicated_and_recovered(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)), patch.object(node, "phosphene_request", side_effect=panel):
            queue = node.RenderQueue()
            payload = {"entry_id": "steps", "model": "hailuo-h3", "prompt": "A badger learns.",
                       "seconds": 15, "resolution": "720p", "seed": 42, "h3_turbo": False, "h3_steps": 30}
            self.assertEqual(queue.submit(payload), "steps")
            self.assertEqual(queue.submit(payload), "steps")
            job = queue.jobs["steps"]
            form = node.phosphene_submission_form(job)
            self.assertEqual(form["h3_steps"], "30")
            self.assertEqual(form["h3_turbo"], "false")
            self.assertEqual(form["h3_quality"], "standard")
            self.assertEqual(form["h3_length"], "15s")
            for settings in [{"h3_steps": 20}, {"h3_steps": None}]:
                with self.assertRaisesRegex(ValueError, "different render settings"):
                    queue.submit({**payload, **settings})
            recovered = node.RenderQueue()
            self.assertEqual(recovered.jobs["steps"]["h3_steps"], 30)
            self.assertEqual(recovered.jobs["steps"]["deadline_epoch"], job["deadline_epoch"])

    def test_auto_preserves_pre_steps_fingerprints_and_does_not_probe_version(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)), patch.object(node, "phosphene_request", return_value=READY) as request:
            queue = node.RenderQueue()
            payload = {"entry_id": "auto", "model": "hailuo-h3", "prompt": "A badger.",
                       "seconds": 15, "resolution": "720p", "seed": 42, "h3_turbo": False}
            queue.submit(payload)
            job = queue.jobs["auto"]
            previous_fields = {"prompt": "A badger.", "model": "hailuo-h3", "seconds": 15,
                               "resolution": "720p", "seed": 42, "output_name": "auto.mp4",
                               "has_image": False, "image_sha256": hashlib.sha256(b"").hexdigest(),
                               "h3_turbo": False, "h3_chain_prompts": None}
            expected = hashlib.sha256(json.dumps(previous_fields, sort_keys=True, separators=(",", ":")).encode()).hexdigest()
            self.assertEqual(job["request_fingerprint"], expected)
            self.assertNotIn("h3_steps", node.phosphene_submission_form(job))
            self.assertEqual(queue.submit({**payload, "h3_steps": None}), "auto")
            self.assertTrue(all(call.args[0] == "/status" for call in request.call_args_list))

    def test_legacy_identity_cannot_reuse_a_job_with_different_steps(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)), patch.object(node, "phosphene_request", side_effect=panel):
            queue = node.RenderQueue()
            payload = {"entry_id": "legacy", "model": "hailuo-h3", "prompt": "A badger.",
                       "seconds": 15, "seed": 42, "h3_turbo": False}
            queue.submit(payload)
            queue.jobs["legacy"].pop("request_fingerprint")
            queue.jobs["legacy"]["fingerprint_version"] = 1
            self.assertEqual(queue.submit(payload), "legacy")
            with self.assertRaisesRegex(ValueError, "different render settings"):
                queue.submit({**payload, "h3_steps": 20})

    def test_old_panel_refuses_before_image_staging_or_receipt(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)), patch.object(node, "phosphene_request", return_value=READY):
            queue = node.RenderQueue()
            with patch.object(queue, "_save_image") as save, self.assertRaisesRegex(RuntimeError, "Cannot verify h3_steps"):
                queue.submit({"prompt": "A badger.", "model": "hailuo-h3", "seconds": 15, "h3_turbo": False, "h3_steps": 20})
            save.assert_not_called()
            self.assertFalse(queue.jobs)

    def test_queued_override_rechecks_panel_version_before_submission(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            queue = node.RenderQueue()
            with patch.object(node, "phosphene_request", side_effect=panel):
                queue.submit({"entry_id": "downgrade", "prompt": "A badger.", "model": "hailuo-h3", "seconds": 15, "h3_turbo": False, "h3_steps": 30})
            with patch.object(node, "phosphene_request", return_value=READY) as request, self.assertRaisesRegex(RuntimeError, "Cannot verify h3_steps"):
                queue._run_job("downgrade")
            self.assertFalse(queue.jobs["downgrade"]["phosphene_submit_attempted"])
            self.assertFalse(any(call.args[0] == "/queue/add" for call in request.call_args_list))

    def test_actual_sampling_must_match_before_output_can_be_published(self):
        good = {"steps": 30, "h3_steps": 30, "h3_turbo": False}
        result = node.phosphene_sampling_provenance({"h3_steps": 30}, {"params": good})
        self.assertEqual(result, {"requested_h3_steps": 30, "h3_steps": 30, "h3_forwards_per_window": 29})
        for params in [{}, {**good, "steps": 9}, {**good, "h3_steps": 0}, {**good, "h3_turbo": True},
                       {**good, "steps": "30"}, {**good, "steps": True}]:
            with self.subTest(params=params), self.assertRaisesRegex(RuntimeError, "did not confirm"):
                node.phosphene_sampling_provenance({"h3_steps": 30}, {"params": params})
        self.assertIsNone(node.phosphene_sampling_provenance({}, {})["h3_steps"])
        self.assertEqual(node.phosphene_sampling_provenance({}, {"params": {"steps": 9}})["h3_forwards_per_window"], 8)

    def test_recovery_requires_step_provenance_for_overrides_only(self):
        with tempfile.TemporaryDirectory() as directory:
            output = Path(directory) / "clip.mp4"
            job = {"id": "one", "prompt": "A badger", "seed": 42, "model": "hailuo-h3", "h3_steps": 30}
            metadata = {**job, "model": "MiniMaxAI/MiniMax-H3", "h3_turbo": False}
            output.with_suffix(".json").write_text(json.dumps(metadata))
            self.assertFalse(node.completed_sidecar_matches(job, output))
            metadata["requested_h3_steps"] = 30
            output.with_suffix(".json").write_text(json.dumps(metadata))
            self.assertTrue(node.completed_sidecar_matches(job, output))


if __name__ == "__main__":
    unittest.main()
