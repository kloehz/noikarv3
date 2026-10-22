"""Shader include dependency fixtures; no renderer, export, services or gameplay."""
import hashlib
import tempfile
import unittest
from pathlib import Path
import package_vps_benchmark as package


class ShaderIncludePackagingTests(unittest.TestCase):
    def put(self,root,path,text):
        p=root/path;p.parent.mkdir(parents=True,exist_ok=True);p.write_text(text)

    def repo(self,root):
        self.put(root,'project.godot','config_version=5\nrun/main_scene="res://scenes/main.tscn"')
        self.put(root,'tools/benchmark_profiles.json','{}')
        self.put(root,'scenes/main.tscn','[gd_scene format=3]\n[ext_resource type="Shader" path="res://assets/effect.gdshader" id="1"]')

    def test_relative_and_resource_includes_recursive_source_bytes_preserved(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);self.repo(root)
            self.put(root,'assets/effect.gdshader','shader_type spatial;\n#include "util/shared.gdshaderinc"\n')
            self.put(root,'assets/util/shared.gdshaderinc','#include "res://assets/common/constants.gdshaderinc"\nfloat fixture=1.0;')
            self.put(root,'assets/common/constants.gdshaderinc','float constant_value=2.0;')
            paths=package.dependency_closure(root)
            for p in ['assets/effect.gdshader','assets/util/shared.gdshaderinc','assets/common/constants.gdshaderinc']:
                self.assertIn(p,paths);self.assertEqual(paths[p],hashlib.sha256((root/p).read_bytes()).hexdigest())

    def test_comments_not_dependencies_and_cycles_are_bounded(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);self.repo(root)
            self.put(root,'assets/effect.gdshader','// #include "absent.gdshaderinc"\n/* #include "other_absent.gdshaderinc" */\n#include "cycle.gdshaderinc" // actual include\n')
            self.put(root,'assets/cycle.gdshaderinc','#include "effect.gdshader"\n')
            paths=package.dependency_closure(root)
            self.assertIn('assets/cycle.gdshaderinc',paths)
            self.assertNotIn('assets/absent.gdshaderinc',paths)
            self.assertEqual(len(package.shader_dependencies(root,'assets/effect.gdshader',(root/'assets/effect.gdshader').read_text())),1)

    def test_missing_private_external_escape_and_malformed_include_fail_closed(self):
        for include in ['missing.gdshaderinc','res://backend/private.gdshaderinc','../../escape.gdshaderinc',
                        'https://example.invalid/file.gdshaderinc','../.env','uid://unresolved']:
            with self.subTest(include=include),tempfile.TemporaryDirectory() as d:
                root=Path(d);self.repo(root);self.put(root,'assets/effect.gdshader','#include "'+include+'"\n')
                with self.assertRaises(ValueError):package.dependency_closure(root)
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);self.repo(root);self.put(root,'assets/effect.gdshader','#include <missing>\n')
            with self.assertRaises(ValueError):package.dependency_closure(root)
            self.put(root,'assets/effect.gdshader','#include "symlink.gdshaderinc"\n')
            self.put(root,'assets/actual.gdshaderinc','float x=1.;')
            (root/'assets/symlink.gdshaderinc').symlink_to(root/'assets/actual.gdshaderinc')
            with self.assertRaises(ValueError):package.dependency_closure(root)

    def test_proved_real_required_include_is_in_closure_with_exact_original_hash(self):
        root=Path(__file__).resolve().parents[2]
        shader='assets/BinbunVFX_Vol2/StylizedHitFX/shader/streaks.gdshader'
        include='assets/BinbunVFX_Vol2/StylizedHitFX/shader/util/blend_util.gdshaderinc'
        expected='8dc83b45eac3711a993508ed0566eb9ceb3f1078fc540d20ea3904af8c5c819f'
        self.assertIn('#include "util/blend_util.gdshaderinc"',(root/shader).read_text())
        self.assertEqual(hashlib.sha256((root/include).read_bytes()).hexdigest(),expected)
        paths=package.dependency_closure(root)
        self.assertEqual(paths[include],expected)

if __name__=='__main__':unittest.main()
