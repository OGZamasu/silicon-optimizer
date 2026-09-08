import contextlib
import io
import json
import os
import plistlib
import stat
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch

import install


class InstallerTests(unittest.TestCase):
    def arguments(self, root: Path, *extra: str):
        return install.parser().parse_args([
            "--data-dir", str(root / "node"), "--swarm-config", str(root / "swarm.json"),
            "--phosphene-root", str(root / "phosphene"), "--review-dir", str(root / "review"), *extra,
        ])

    def test_merge_preserves_existing_peers_tokens_and_unknown_fields(self):
        config = {"swarm_token": "admin-secret", "future": {"setting": True}, "peers": [
            {"name": "remote", "base_url": "http://remote:8790", "token": "remote-secret", "extra": 17},
            {"name": "existing-local-name", "base_url": "http://localhost:8790/", "token": "local-secret", "extra": 18},
        ]}
        merged = install.merge_peer(config, "local-mlx-video", 8790, "local-secret")
        self.assertEqual(merged, config)
        self.assertIsNot(merged, config)
        with self.assertRaisesRegex(ValueError, "credential disagree"):
            install.merge_peer(config, "local-mlx-video", 8790, "different-secret")
        with self.assertRaisesRegex(ValueError, "another endpoint"):
            install.merge_peer(config, "remote", 8888, "local-secret")
        self.assertEqual(config["peers"][0]["token"], "remote-secret")

    def test_endpoint_matching_rejects_deceptive_urls_and_wrong_ports(self):
        for value in ("http://127.0.0.1.evil:8790", "http://evil/127.0.0.1:8790", "http://127.0.0.1:8799", "http://user@127.0.0.1:8790", "http://127.0.0.1:8790/v1", "http://localhost:8790?x=1"):
            with self.subTest(value=value):
                self.assertFalse(install.loopback_endpoint(value, 8790))

    def test_dry_run_has_no_writes_and_hides_credentials(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = root / "swarm.json"
            content = '{"swarm_token":"never-print-this","peers":[]}'
            config.write_text(content)
            output = io.StringIO()
            with patch.object(install, "prerequisites", return_value=[]), patch.object(install, "mutation_blockers", return_value=[]), contextlib.redirect_stdout(output):
                result = install.main(["--dry-run", "--data-dir", str(root / "node"), "--swarm-config", str(config)])
            self.assertEqual(result, 0)
            self.assertEqual(list(root.iterdir()), [config])
            self.assertEqual(config.read_text(), content)
            self.assertNotIn("never-print-this", output.getvalue())

    def test_install_is_idempotent_private_and_keeps_a_recoverable_registry(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.arguments(root, "--port", "8892")
            original = {"swarm_token": "admin-secret", "future": [1, 2], "peers": [{"name": "remote", "base_url": "http://remote:8790", "token": "remote-secret"}]}
            args.swarm_config.write_text(json.dumps(original))
            source = root / "source.py"
            source.write_text("print('node fixture')\n")
            plist_path, backup = install.write_install(args, source, root / "agents")
            self.assertIsNotNone(backup)
            self.assertEqual(json.loads(backup.read_bytes()), original)
            after = json.loads(args.swarm_config.read_bytes())
            self.assertEqual(after["future"], [1, 2])
            self.assertEqual(after["peers"][0], original["peers"][0])
            token = (args.data_dir / "token").read_text().strip()
            self.assertEqual(after["peers"][1]["token"], token)
            plist = plistlib.loads(plist_path.read_bytes())
            self.assertNotIn(token, plist_path.read_text())
            self.assertEqual(plist["ProgramArguments"][-1], "8892")
            self.assertEqual(plist["EnvironmentVariables"]["PHOSPHENE_OUTPUT_ROOTS"], str(args.phosphene_root / "mlx_outputs"))
            for private in (args.swarm_config, backup, args.data_dir / "token", plist_path):
                self.assertEqual(stat.S_IMODE(private.stat().st_mode), 0o600)
            _, second_backup = install.write_install(args, source, root / "agents")
            self.assertIsNone(second_backup)
            self.assertEqual((args.data_dir / "token").read_text().strip(), token)
            self.assertEqual(len(json.loads(args.swarm_config.read_bytes())["peers"]), 2)

    def test_existing_local_credential_is_reused_without_rotating_admin(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            config = {"swarm_token": "admin", "peers": [{"name": "local", "base_url": "http://127.0.0.1:8790", "token": "stable"}]}
            self.assertEqual(install.choose_token(config, root / "token", 8790), "stable")
            self.assertEqual(config["swarm_token"], "admin")

    def test_corrupt_config_and_symlink_fail_without_writes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.arguments(root)
            args.swarm_config.write_text("{broken")
            source = root / "source.py"
            source.write_text("node")
            with self.assertRaisesRegex(ValueError, "invalid JSON"):
                install.write_install(args, source, root / "agents")
            self.assertEqual(args.swarm_config.read_text(), "{broken")
            self.assertFalse(args.data_dir.exists())
            args.swarm_config.unlink()
            args.swarm_config.symlink_to(source)
            with self.assertRaisesRegex(ValueError, "symlink"):
                install.write_install(args, source, root / "agents")
            self.assertEqual(source.read_text(), "node")

    def test_running_app_prevents_install_before_any_files_change(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            with patch.object(install, "prerequisites", return_value=[]), patch.object(install.platform, "system", return_value="Darwin"), patch.object(install, "mutation_blockers", return_value=["quit Silicon Optimizer before pairing"]), patch.object(install, "write_install") as write, contextlib.redirect_stdout(io.StringIO()):
                result = install.main(["--data-dir", str(root / "node"), "--swarm-config", str(root / "swarm.json")])
            self.assertEqual(result, 2)
            write.assert_not_called()
            self.assertEqual(list(root.iterdir()), [])

    def test_explicit_legacy_paths_are_carried_into_launchagent(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            args = self.arguments(root, "--ltx-root", str(root / "legacy/ltx-2-mlx"), "--model-dir", str(root / "legacy/models/ltx"), "--gemma-dir", str(root / "legacy/models/gemma"), "--legacy-hb-layout")
            _, plist = install.make_plist(args, "/python", root / "agents")
            environment = plist["EnvironmentVariables"]
            self.assertEqual(environment["SILICON_VIDEO_LTX_ROOT"], str(root / "legacy/ltx-2-mlx"))
            self.assertEqual(environment["SILICON_VIDEO_MODEL_DIR"], str(root / "legacy/models/ltx"))
            self.assertEqual(environment["SILICON_VIDEO_LEGACY_HB_LAYOUT"], "1")


if __name__ == "__main__":
    unittest.main()
