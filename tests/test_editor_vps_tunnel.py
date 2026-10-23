"""The SSH transport must not outlive a stopped/crashed editor game process."""
import importlib.util
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import threading
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class EditorVpsTunnelTests(unittest.TestCase):
    def test_parent_death_stops_only_the_owned_transport_process(self):
        source = ROOT / "tools/editor_vps_tunnel.py"
        self.assertTrue(source.is_file(), "An abrupt editor stop must not strand its SSH tunnel")
        if not source.is_file():
            return
        spec = importlib.util.spec_from_file_location("editor_vps_tunnel", source)
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        with tempfile.TemporaryDirectory() as tmp:
            root = Path(tmp)
            child = root / "child.py"
            pid_file = root / "pid"
            child.write_text('import os,time\nfrom pathlib import Path\nPath(%r).write_text(str(os.getpid()))\ntime.sleep(30)\n' % str(pid_file))
            parent = subprocess.Popen(["/bin/sleep", "30"])
            unrelated = subprocess.Popen(["/bin/sleep", "30"])
            result = []
            worker = threading.Thread(target=lambda: result.append(module.run_for_parent(parent.pid, [sys.executable, str(child)])))
            worker.start()
            try:
                until = time.monotonic() + 3
                while not pid_file.exists() and time.monotonic() < until:
                    time.sleep(0.02)
                self.assertTrue(pid_file.is_file())
                parent.kill()
                parent.wait(timeout=2)
                worker.join(timeout=3)
                self.assertFalse(worker.is_alive(), "Guardian must detect parent exit promptly")
                self.assertIsNone(unrelated.poll(), "Never terminate other SSH/game processes")
                with self.assertRaises(ProcessLookupError):
                    os.kill(int(pid_file.read_text()), 0)
            finally:
                if parent.poll() is None:
                    parent.kill()
                    parent.wait(timeout=2)
                unrelated.terminate()
                unrelated.wait(timeout=2)
                worker.join(timeout=3)


if __name__ == "__main__":
    unittest.main()
