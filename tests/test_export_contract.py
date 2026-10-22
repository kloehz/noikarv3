#!/usr/bin/env python3
"""Exercise the static security/resource boundary with controlled preset files."""

from pathlib import Path
import tempfile
import unittest

from test_engine_contract import ROOT, TEMP_ROOT, module


EXPORTS = module("verify_export_isolation")


class ExportContractTests(unittest.TestCase):
    def test_shared_match_composition_is_not_a_secret_leak(self):
        self.assertEqual(EXPORTS.check_folder_isolation(ROOT), [])

    def test_host_export_must_not_strip_authoritative_gameplay(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as tmp:
            path = Path(tmp)
            (path / "export_presets.cfg").write_text(
                '[preset.0]\nname="Client (Windows)"\ndedicated_server=false\n'
                'exclude_filter="res://core/*,res://backend/*,res://tests/*,res://addons/gut/*"\n'
            )
            problems = EXPORTS.verify_export_presets(path)
            self.assertTrue(any("core" in problem for problem in problems), problems)

    def test_export_must_exclude_backend_and_secret_configuration(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as tmp:
            path = Path(tmp)
            (path / "export_presets.cfg").write_text(
                '[preset.0]\nname="Client (Windows)"\ndedicated_server=false\nexclude_filter=""\n'
            )
            problems = EXPORTS.verify_export_presets(path)
            self.assertTrue(any("backend" in problem for problem in problems), problems)
            self.assertTrue(any(".env" in problem for problem in problems), problems)

    def test_gdignore_cannot_hide_required_simulation_from_the_editor(self):
        with tempfile.TemporaryDirectory(dir=TEMP_ROOT) as tmp:
            path = Path(tmp)
            (path / "core").mkdir()
            (path / "core/.gdignore").touch()
            problems = EXPORTS.check_folder_isolation(path)
            self.assertTrue(any(".gdignore" in problem for problem in problems), problems)


if __name__ == "__main__":
    unittest.main()
