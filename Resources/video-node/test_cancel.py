"""Job-specific cancellation. Real child processes stand in for renderers; no models."""
import http.client
import json
import os
import subprocess
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path
from unittest.mock import patch

import silicon_video_node as node
from test_silicon_video_node import isolated_node_paths

REAL_POPEN = subprocess.Popen
REAL_KILLPG = os.killpg
RENDERER = "import time; print('Stage 1 denoising', flush=True); time.sleep(120)"
READY = {"ready": True, "reason": "", "missing": []}


def wait_for(condition, seconds=10.0):
    deadline = time.monotonic() + seconds
    while not condition():
        if time.monotonic() > deadline:
            raise AssertionError("condition not reached in time")
        time.sleep(0.02)


class FakePhosphene:
    """Phosphene's queue semantics: /queue/remove checks the ID under its lock."""

    def __init__(self, current, queued):
        self.lock = threading.Lock()
        self.current = current
        self.queued = list(queued)
        self.calls = []

    def __call__(self, path, form=None):
        self.calls.append(path)
        if path == "/stop":
            raise AssertionError("the global /stop must never be used to cancel one job")
        if path == "/queue/remove":
            with self.lock:
                removed = form["id"] in self.queued
                if removed:
                    self.queued.remove(form["id"])
            return {"removed": removed}
        if path == "/status":
            return {"h3": {"available": True, "capable": True, "chain": True, "first_frame": True},
                    "current": {"id": self.current} if self.current else None,
                    "queue": [{"id": item} for item in self.queued], "history": []}
        raise AssertionError(f"unexpected Phosphene request {path}")


class CancellationTests(unittest.TestCase):
    def setUp(self):
        self.directory = tempfile.TemporaryDirectory()
        self.root = Path(self.directory.name)
        self.paths = isolated_node_paths(self.root)
        self.paths.__enter__()
        self.addCleanup(self.directory.cleanup)
        self.addCleanup(self.paths.__exit__, None, None, None)
        self.signals = []
        spy = patch.object(node.os, "killpg", side_effect=self._killpg)
        spy.start()
        self.addCleanup(spy.stop)
        short = patch.object(node, "CANCEL_CONFIRM_SECONDS", 5.0)
        short.start()
        self.addCleanup(short.stop)

    def _killpg(self, group, signum):
        self.signals.append((group, signum))
        REAL_KILLPG(group, signum)

    def _queue(self):
        render = node.RenderQueue()
        self.addCleanup(render.shutdown)
        return render

    def _submit(self, render, entry_id, model="ltx2-distilled"):
        with patch.object(node, "model_readiness", return_value=READY):
            return render.submit({"entry_id": entry_id, "model": model, "prompt": "A sailboat.", "seconds": 5})

    def _h3_job(self, render, job_id, **fields):
        render.jobs[job_id] = {"id": job_id, "status": "running", "model": "hailuo-h3", "prompt": "A shot.",
                               "seed": 1, "seconds": 5, "resolution": "480p", "image_path": None,
                               "output_path": str(self.root / f"{job_id}.mp4"),
                               "raw_path": str(self.root / f"{job_id}.raw.mp4"),
                               "candidate_path": str(self.root / f".{job_id}.candidate.mp4"),
                               "log_path": str(self.root / f"{job_id}.log"), "poster_path": None,
                               "phosphene_job_id": None, "phosphene_submit_attempted": False,
                               "deadline_epoch": time.time() + 3600, **fields}

    def _launch(self, launched):
        def popen(command, **kwargs):
            kwargs["cwd"] = str(self.root)
            process = REAL_POPEN([sys.executable, "-c", RENDERER], **kwargs)
            launched.append(process)
            return process
        return patch.object(node.subprocess, "Popen", side_effect=popen)

    def test_a_job_waiting_in_this_nodes_queue_is_cancelled_without_signalling_anything(self):
        render = self._queue()
        job_id = self._submit(render, "waiting")
        for _ in range(2):  # repeating the request repeats the confirmed answer
            status, answer = render.cancel(job_id)
            self.assertEqual((status, answer["cancel"], answer["status"]), (200, "cancelled", "cancelled"))
        self.assertEqual(self.signals, [])
        self.assertEqual(render.public_job(job_id)["cancel"]["state"], "cancelled")
        # The worker skips it rather than starting a renderer.
        with patch.object(node.subprocess, "Popen") as popen:
            render.start()
            wait_for(lambda: render.pending.unfinished_tasks == 0)
        popen.assert_not_called()
        restarted = node.RenderQueue()
        self.assertEqual(restarted.jobs[job_id]["status"], "cancelled")
        self.assertTrue(restarted.pending.empty())

    def test_cancelling_a_running_render_stops_its_own_process_group_and_nothing_else(self):
        bystander = REAL_POPEN([sys.executable, "-c", "import time; time.sleep(120)"], start_new_session=True)
        self.addCleanup(bystander.wait)
        self.addCleanup(bystander.kill)
        render = self._queue()
        launched = []
        with self._launch(launched), patch.object(node, "LTX_ROOT", self.root):
            job_id = self._submit(render, "running")
            waiting = self._submit(render, "next-in-line")
            render.start()
            wait_for(lambda: render.jobs[job_id].get("stage") == "rendering motion on Apple GPU")
            renderer = launched[0]
            status, answer = render.cancel(job_id)
            self.assertEqual((status, answer["cancel"]), (200, "cancelled"))
            self.assertIsNotNone(renderer.poll())
            self.assertIsNone(bystander.poll())
            self.assertEqual({group for group, _ in self.signals}, {renderer.pid})
            self.assertEqual(render.jobs[job_id]["status"], "cancelled")
            self.assertFalse(Path(render.jobs[job_id]["output_path"]).exists())
            self.assertFalse(Path(render.jobs[job_id]["raw_path"]).exists())
            signalled = len(self.signals)
            status, answer = render.cancel(job_id)
            self.assertEqual((status, answer["cancel"]), (200, "cancelled"))
            self.assertEqual(len(self.signals), signalled)
            # The queue moves on to the next job; the cancelled one is never retried.
            wait_for(lambda: len(launched) == 2)
            self.assertEqual(render.current_job_id, waiting)
        render.shutdown()
        restarted = node.RenderQueue()
        self.assertEqual(restarted.jobs[job_id]["status"], "cancelled")
        self.assertNotEqual(restarted.jobs[waiting]["status"], "cancelled")

    def test_a_cancel_before_publishing_wins_and_one_after_it_reports_completion(self):
        def finish_render(command, **kwargs):
            Path(command[command.index("--output") + 1]).write_bytes(b"raw" * 2000)
            return REAL_POPEN([sys.executable, "-c", "print('saving')"], **{**kwargs, "cwd": str(self.root)})

        def transcode(command, **kwargs):
            Path(command[-1]).write_bytes(b"mp4" * 2000)
            return subprocess.CompletedProcess(command, 0, "", "")

        probe = {"duration": 5.0, "video_duration": 5.0, "width": 1280, "height": 720, "codec": "h264",
                 "frame_rate": "24/1", "nb_frames": node.seconds_to_frames(5), "audio": False}
        for cancel_at, expected in (("transcode", (200, "cancelled")), ("commit", (409, "completed"))):
            with self.subTest(cancel_at=cancel_at):
                render = self._queue()
                job_id = self._submit(render, f"race-{cancel_at}")
                answers = []
                asker = threading.Thread(target=lambda: answers.append(render.cancel(job_id)))
                original_commit = render._commit

                def commit(job):
                    original_commit(job)
                    if cancel_at == "commit":
                        answers.append(render.cancel(job))

                def slow_transcode(command, **kwargs):
                    if cancel_at == "transcode":
                        asker.start()
                        wait_for(lambda: render.jobs[job_id].get("cancel_requested_at"))
                    return transcode(command, **kwargs)

                with patch.object(node.subprocess, "Popen", side_effect=finish_render), \
                        patch.object(node.subprocess, "run", side_effect=slow_transcode), \
                        patch.object(node, "executable", side_effect=lambda name: name), \
                        patch.object(node, "probe_media", return_value=probe), \
                        patch.object(node, "LTX_ROOT", self.root), patch.object(render, "_commit", commit):
                    render.start()
                    wait_for(lambda: render.jobs[job_id]["status"] in {"done", "cancelled"})
                    if asker.is_alive() or cancel_at == "transcode":
                        asker.join(10)
                status, answer = answers[0]
                self.assertEqual((status, answer["cancel"]), expected)
                published = Path(render.jobs[job_id]["output_path"]).exists()
                self.assertEqual(published, cancel_at == "commit")
                self.assertEqual(render.jobs[job_id]["status"], "done" if published else "cancelled")
                self.assertEqual(self.signals, [])
                render.shutdown()
                # Repeating the request repeats the terminal answer.
                self.assertEqual(render.cancel(job_id)[1]["cancel"], expected[1])

    def test_phosphene_removes_only_our_queued_job_and_never_stops_a_running_one(self):
        render = self._queue()
        self._h3_job(render, "ours", phosphene_job_id="panel-ours", phosphene_submit_attempted=True)
        render.current_job_id = "ours"
        # Another client's job is rendering in the panel; ours is waiting behind it.
        panel = FakePhosphene(current="panel-other", queued=["panel-ours"])
        with patch.object(node, "phosphene_request", side_effect=panel):
            status, answer = render.cancel("ours")
            self.assertEqual((status, answer["cancel"]), (200, "cancelled"))
            self.assertEqual((panel.current, panel.queued), ("panel-other", []))
            # The follower stops at its next step instead of reporting a vanished job.
            with self.assertRaises(node.JobCancelled):
                render._run_phosphene_job("ours")
            self.assertEqual(render.cancel("ours")[1]["cancel"], "cancelled")

        self._h3_job(render, "started", phosphene_job_id="panel-started", phosphene_submit_attempted=True)
        render.current_job_id = "started"
        panel = FakePhosphene(current="panel-started", queued=[])
        with patch.object(node, "phosphene_request", side_effect=panel):
            for _ in range(2):
                status, answer = render.cancel("started")
                self.assertEqual((status, answer["cancel"]), (409, "unsupported"))
        self.assertNotIn("/stop", panel.calls)
        self.assertEqual(render.jobs["started"]["status"], "running")
        self.assertNotIn("cancel_requested_at", render.jobs["started"])
        self.assertNotIn("cancel", render.public_job("started"))

    def test_an_h3_job_is_stopped_before_submission_and_an_unknown_submission_is_left_alone(self):
        render = self._queue()
        self._h3_job(render, "before", status="queued")
        render.current_job_id = "before"
        with patch.object(node, "CANCEL_CONFIRM_SECONDS", 0.1):
            status, answer = render.cancel("before")
        self.assertEqual((status, answer["cancel"]), (202, "requested"))
        self.assertEqual(render.public_job("before")["cancel"]["state"], "requested")
        panel = FakePhosphene(current=None, queued=[])
        with patch.object(node, "phosphene_request", side_effect=panel), \
                self.assertRaises(node.JobCancelled):
            render._run_phosphene_job("before")
        self.assertNotIn("/queue/add", panel.calls)

        self._h3_job(render, "in-flight", phosphene_submit_attempted=True)
        render.current_job_id = "in-flight"
        with patch.object(node, "phosphene_request", side_effect=AssertionError("no panel call")):
            status, answer = render.cancel("in-flight")
        self.assertEqual((status, answer["cancel"]), (409, "unsupported"))
        self.assertEqual(render.jobs["in-flight"]["status"], "running")

    def test_terminal_and_unknown_jobs_answer_the_same_way_every_time(self):
        render = self._queue()
        render.jobs["finished"] = {"id": "finished", "status": "done", "model": "ltx2-distilled"}
        render.jobs["broken"] = {"id": "broken", "status": "failed", "model": "ltx2-distilled", "error": "oom"}
        for _ in range(2):
            status, answer = render.cancel("finished")
            self.assertEqual((status, answer["cancel"]), (409, "completed"))
            status, answer = render.cancel("broken")
            self.assertEqual((status, answer["cancel"], answer["detail"]), (409, "failed", "oom"))
            status, answer = render.cancel("missing")
            self.assertEqual((status, answer["cancel"]), (404, "unknown"))
        self.assertEqual(render.jobs["finished"]["status"], "done")

    def test_a_cancel_accepted_before_a_restart_is_not_resumed_after_it(self):
        node.STATE_DIR.mkdir(parents=True, exist_ok=True)
        saved = {"id": "interrupted", "status": "running", "model": "ltx2-distilled", "prompt": "A shot.",
                 "seed": 1, "seconds": 5, "resolution": "720p", "output_path": str(self.root / "none.mp4"),
                 "cancel_requested_at": node.utc_now(), "deadline_epoch": time.time() + 3600}
        node.STATE_FILE.write_text(json.dumps({"interrupted": saved}))
        render = self._queue()
        self.assertEqual(render.jobs["interrupted"]["status"], "cancelled")
        self.assertTrue(render.pending.empty())
        self.assertIn("restarted", render.public_job("interrupted")["cancel"]["detail"])
        self.assertEqual(render.cancel("interrupted")[1]["cancel"], "cancelled")


class CancelRouteTests(unittest.TestCase):
    def test_the_route_is_authenticated_and_advertised_only_where_it_can_stop_one_job(self):
        with tempfile.TemporaryDirectory() as directory, isolated_node_paths(Path(directory)):
            node.TOKEN_FILE.write_text("fixture-token\n")
            render = node.RenderQueue()
            with patch.object(node, "model_readiness", return_value=READY):
                job_id = render.submit({"entry_id": "route", "model": "ltx2-distilled", "prompt": "A shot.", "seconds": 5})
            server = ThreadingHTTPServer(("127.0.0.1", 0), node.Handler)
            worker = threading.Thread(target=server.serve_forever, daemon=True)
            worker.start()

            def post(path, token="fixture-token"):
                connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                headers = {"Authorization": f"Bearer {token}"} if token else {}
                try:
                    connection.request("POST", path, body=b"{}", headers=headers)
                    response = connection.getresponse()
                    return response.status, json.loads(response.read())
                finally:
                    connection.close()
            try:
                with patch.object(node, "RENDERS", render), patch.object(node.Handler, "log_message"), \
                        patch.object(node, "phosphene_h3_readiness", return_value={"ready": True, "reason": "", "status": {}}), \
                        patch.object(node, "phosphene_supports_h3_steps", return_value=False), \
                        patch.object(node, "hardware_profile", return_value={"chip": "test", "memory_gb": 36}):
                    self.assertEqual(post(f"/v1/jobs/{job_id}/cancel", token=None)[0], 401)
                    self.assertEqual(post(f"/v1/jobs/{job_id}/cancel", token="wrong")[0], 401)
                    self.assertEqual(render.jobs[job_id]["status"], "queued")
                    self.assertEqual(post("/v1/jobs/nope/cancel"), (404, {"job_id": "nope", "cancel": "unknown", "status": "unknown", "detail": "This node has no job with that ID."}))
                    status, answer = post(f"/v1/jobs/{job_id}/cancel")
                    self.assertEqual((status, answer["cancel"], answer["status"]), (200, "cancelled", "cancelled"))
                    connection = http.client.HTTPConnection("127.0.0.1", server.server_port, timeout=5)
                    connection.request("GET", "/v1/node", headers={"Authorization": "Bearer fixture-token"})
                    capabilities = {item["id"]: item for item in json.loads(connection.getresponse().read())["capabilities"]}
                    connection.close()
                    self.assertEqual(capabilities["ltx2-distilled"]["supported_job_actions"], ["cancel"])
                    self.assertNotIn("supported_job_actions", capabilities["hailuo-h3"])
            finally:
                server.shutdown()
                server.server_close()
                worker.join(timeout=5)


if __name__ == "__main__":
    unittest.main()
