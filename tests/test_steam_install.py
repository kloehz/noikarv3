"""The optional installer must reject tampered archives before creating files."""
import importlib.util
from pathlib import Path
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parents[1]


class SteamInstallTests(unittest.TestCase):
    def test_tampered_archive_never_writes_dependency(self):
        installer = ROOT / "tools/install_steam.py"
        self.assertTrue(installer.is_file(), "Pinned Steam dependency installer is missing")
        if not installer.is_file():
            return
        spec = importlib.util.spec_from_file_location("install_steam", installer)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory(prefix="noikar-steam-") as tmp:
            root = Path(tmp)
            archive = root / "tampered.tar.xz"
            archive.write_bytes(b"not the pinned official dependency")
            with patch.object(module, "ROOT", root), patch("sys.argv", [str(installer), "--archive", str(archive)]):
                with self.assertRaisesRegex(SystemExit, "checksum mismatch"):
                    module.main()
            self.assertFalse((root / "addons").exists())


if __name__ == "__main__":
    unittest.main()
