"""Deployment payload is bounded to the isolated test instance, never production."""
import importlib.util
from pathlib import Path
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]


class VpsPlaytestDeployTests(unittest.TestCase):
    def test_internal_database_endpoint_is_private_and_needs_no_published_port(self):
        source = ROOT / "tools/vps_playtest_install.py"
        spec = importlib.util.spec_from_file_location("vps_playtest_install", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        self.assertTrue(hasattr(module, "private_database_endpoint"))
        if not hasattr(module, "private_database_endpoint"):
            return
        self.assertEqual(module.private_database_endpoint("172.26.0.2"), "172.26.0.2:5432")
        for address in ["72.60.58.24", "example.com", "0.0.0.0"]:
            with self.assertRaises(ValueError):
                module.private_database_endpoint(address)

    def test_payload_validation_rejects_shared_paths_missing_artifacts_and_symlinks(self):
        source = ROOT / "tools/prepare_vps_playtest.py"
        self.assertTrue(source.is_file(), "Reproducible isolated F5 preparation is missing")
        if not source.is_file():
            return
        spec = importlib.util.spec_from_file_location("prepare_vps_playtest", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            path = Path(tmp)
            for name in ["noikar-f5-server.x86_64", "noikar-f5-server.pck", "noikar-f5-api"]:
                (path / name).write_bytes(b"fixture artifact")
            payload = module.validate_payload(path, "/opt/noikar-f5-playtest")
            self.assertEqual(set(payload), {"noikar-f5-server.x86_64", "noikar-f5-server.pck", "noikar-f5-api"})
            with self.assertRaises(ValueError):
                module.validate_payload(path, "/root/noikar/world/current")
            (path / "noikar-f5-api").unlink()
            with self.assertRaises(ValueError):
                module.validate_payload(path, "/opt/noikar-f5-playtest")
            (path / "noikar-f5-api").symlink_to(path / "noikar-f5-server.pck")
            with self.assertRaises(ValueError):
                module.validate_payload(path, "/opt/noikar-f5-playtest")


if __name__ == "__main__":
    unittest.main()
