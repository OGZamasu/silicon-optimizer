#!/usr/bin/env python3
"""Hermetic authorization checks for the bundled loopback sensor servers."""

import importlib.util
import pathlib
import unittest


ROOT = pathlib.Path(__file__).resolve().parents[1]


def load(name):
    path = ROOT / "Resources" / f"{name}.py"
    spec = importlib.util.spec_from_file_location(name, path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


TRACKER = load("tracker")
FACECAM = load("facecam")


class SensorAuthorizationTests(unittest.TestCase):
    def test_bearer_and_query_capabilities(self):
        for module in (TRACKER, FACECAM):
            check = module.request_is_authorized
            self.assertTrue(check("/state?token=secret", None, "secret"))
            self.assertTrue(check("/state", "bearer secret", "secret"))
            self.assertFalse(check("/state", None, "secret"))
            self.assertFalse(check("/state?token=wrong", None, "secret"))
            self.assertFalse(check("/state?token=%E2%98%83", None, "secret"))
            self.assertFalse(check("/state", "Basic secret", "secret"))
            self.assertFalse(check("/state?token=secret", None, ""))

    def test_tracker_cors_accepts_only_loopback_origins(self):
        trusted = TRACKER.trusted_loopback_origin
        self.assertEqual(trusted("http://127.0.0.1:8790"), "http://127.0.0.1:8790")
        self.assertEqual(trusted("http://localhost:8790"), "http://localhost:8790")
        self.assertIsNone(trusted("https://example.com"))
        self.assertIsNone(trusted("null"))
        self.assertIsNone(trusted("http://127.0.0.1:8790/path"))


if __name__ == "__main__":
    unittest.main()
