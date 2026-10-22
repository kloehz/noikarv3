"""Dependency closure fixtures; no services, gameplay, export or remote actions."""
import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

import package_vps_benchmark as package


class PackageDependencyTests(unittest.TestCase):
    def repo(self, directory):
        root = Path(directory)
        self.put(root, 'project.godot', 'config_version=5\nrun/main_scene="res://scenes/main.tscn"')
        self.put(root, 'tools/benchmark_profiles.json', '{}')
        self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\n')
        return root

    def put(self, root, path, data):
        target = root/path
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_bytes(data if isinstance(data, bytes) else data.encode())

    def closure(self, root, extra=None):
        remaps={path:package.preview_import_remaps((root/path).read_text())
                for path in package.runtime_files(root) if path.endswith('.import')}
        return package.dependency_closure(root, {'scenes/main.tscn': [], **(extra or {})},
                                          {'Node', 'RefCounted', 'Resource'}, strict_native=True,import_remaps=remaps)

    def test_asset_named_base_and_typed_global_references_are_runtime_roots(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'assets/shared/base.gd', 'extends Node\nclass_name VFXBase\n')
            self.put(root, 'assets/effect.gd', 'extends VFXBase\nclass_name Effect\nvar item: TypedAsset\n')
            self.put(root, 'assets/typed.gd', 'extends Resource\nclass_name TypedAsset\n')
            paths = self.closure(root)
            cache = package.class_cache(root, paths, {'Node', 'RefCounted', 'Resource'})
            for path in ('assets/shared/base.gd', 'assets/effect.gd', 'assets/typed.gd'):
                self.assertIn(path, paths)
                self.assertEqual(paths[path], hashlib.sha256((root/path).read_bytes()).hexdigest())
            self.assertIn('VFXBase', cache)
            self.assertIn('TypedAsset', cache)
            with self.assertRaisesRegex(ValueError, 'base omitted'):
                package.class_cache(root, {p: h for p, h in paths.items() if p != 'assets/shared/base.gd'})

    def test_unknown_base_parameter_return_and_nested_typed_global_fail(self):
        declarations = ['extends MissingBase\n', 'extends Node\nvar item: MissingType\n',
                        'extends Node\nvar items: Array[MissingType]\n',
                        'extends Node\nfunc f(arg: MissingType) -> void:\n pass\n',
                        'extends Node\nfunc f() -> MissingType:\n return null\n']
        for declaration in declarations:
            with self.subTest(declaration=declaration), tempfile.TemporaryDirectory() as directory:
                root = self.repo(directory)
                self.put(root, 'assets/main.gd', 'class_name Fixture\n'+declaration)
                with self.assertRaisesRegex(ValueError, 'unresolved'):
                    self.closure(root)

    def test_quoted_resource_paths_keep_apostrophe_and_decode_godot_escapes(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, "assets/kog'maw.png", b'image')
            self.put(root, "assets/kog'maw.png.import", "[remap]\npath=\"res://.godot/imported/kog\\'maw.ctex\"")
            self.put(root, ".godot/imported/kog'maw.ctex", b'native')
            self.put(root, 'assets/main.gd', "extends Node\nclass_name Fixture\nvar p = \"res://assets/kog\\'maw.png\"\n")
            paths = self.closure(root, {".godot/imported/kog'maw.ctex": []})
            self.assertIn("assets/kog'maw.png", paths)
            self.assertIn(".godot/imported/kog'maw.ctex", paths)

    def test_relative_and_uid_quoted_inheritance_registers_actual_base(self):
        for reference in ('"base.gd"', '"uid://fixture"'):
            with self.subTest(reference=reference), tempfile.TemporaryDirectory() as directory:
                root = self.repo(directory)
                self.put(root, 'assets/base.gd', 'extends Node\nclass_name FixtureBase\n')
                self.put(root, 'assets/base.gd.uid', 'uid://fixture')
                self.put(root, 'assets/child.gd', 'extends '+reference+'\nclass_name FixtureChild\n')
                cache = package.class_cache(root, self.closure(root), {'Node', 'RefCounted'})
                self.assertIn('"base": &"FixtureBase"', cache)

    def test_relative_gltf_image_buffer_import_and_runtime_remap_transitive(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\npath="res://assets/model/mesh.gltf"')
            self.put(root, 'assets/model/mesh.gltf', json.dumps(dict(images=[{'uri': 'forest%20texture.png'}],
                          buffers=[{'uri': '../mesh.bin'}, {'uri': 'data:application/octet-stream;base64,eA=='}])))
            self.put(root, 'assets/model/forest texture.png', b'fixture-image')
            self.put(root, 'assets/mesh.bin', b'fixture-buffer')
            self.put(root, 'assets/model/forest texture.png.import', '[remap]\nuid="uid://fixture"\npath="res://.godot/imported/forest.ctex"')
            self.put(root, '.godot/imported/forest.ctex', b'native-fixture')
            paths = self.closure(root, {'.godot/imported/forest.ctex': []})
            for path in ('assets/model/forest texture.png', 'assets/mesh.bin',
                         'assets/model/forest texture.png.import', '.godot/imported/forest.ctex'):
                self.assertIn(path, paths)

    def test_native_binary_dependency_uid_fallback_and_source_remap(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\npath="res://assets/mesh.res"')
            self.put(root, 'assets/mesh.res', b'native-fixture-no-text-literal')
            self.put(root, 'assets/texture.png', b'texture')
            self.put(root, 'assets/texture.png.import', '[remap]\nuid="uid://texture"\npath="res://.godot/imported/tex.ctex"')
            self.put(root, '.godot/imported/tex.ctex', b'native-texture')
            metadata = {'assets/mesh.res': ['uid://unknown::Texture2D::res://assets/texture.png'],
                        '.godot/imported/tex.ctex': []}
            self.assertIn('.godot/imported/tex.ctex', self.closure(root, metadata))
            metadata['assets/mesh.res'] = ['uid://texture::Texture2D']
            self.assertIn('assets/texture.png', self.closure(root, metadata))
            metadata['assets/mesh.res'] = ['uid://unknown::Texture2D']
            with self.assertRaisesRegex(ValueError, 'unresolved'):
                self.closure(root, metadata)

    def test_missing_native_metadata_or_import_target_fails_before_export(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\npath="res://assets/foo.png"')
            self.put(root, 'assets/foo.png', b'x')
            self.put(root, 'assets/foo.png.import', '[remap]\npath="res://.godot/imported/missing.ctex"')
            with self.assertRaisesRegex(ValueError, 'missing'):
                self.closure(root)
            destination = root.parent/(root.name+'-new-package')
            with (patch.object(package.subprocess, 'run', return_value=SimpleNamespace(stdout='4.8.dev6.official.8898c2b3d')) as run,
                 patch.object(package, 'native_dependency_scan', return_value={'dependencies': {'scenes/main.tscn': []}, 'builtin_classes': ['Node']})):
                with self.assertRaises(ValueError):
                    package.build(root, destination, Path('/fixture/godot'))
                self.assertEqual(run.call_count, 1)  # Version only: no pack/export call.
            import shutil
            shutil.rmtree(destination)
            with self.assertRaisesRegex(ValueError, 'native dependency readback missing'):
                package.dependency_closure(root, {}, {'Node'}, strict_native=True)

    def test_nonlocal_or_missing_gltf_dependency_fails(self):
        for uri in ('https://example.invalid/tex.png', '../../../outside.png', 'missing.png', '/tmp/private.png'):
            with self.subTest(uri=uri), tempfile.TemporaryDirectory() as directory:
                root = self.repo(directory)
                with self.assertRaises(ValueError):
                    package.gltf_dependencies(root, 'assets/model.gltf', json.dumps({'images': [{'uri': uri}]}))

    def test_privacy_editor_cache_symlink_and_ambiguous_uid_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            for path in ('.env', '.git/config', 'docs/private.res', 'backend/private.res', 'tests/private.res',
                         '.godot/editor/private.res', 'addons/gut/test.gd'):
                self.put(root, path, b'x')
            candidates = package.runtime_files(root)
            self.assertFalse(any(path in candidates for path in ('.env', '.git/config', 'docs/private.res', 'backend/private.res', 'tests/private.res', '.godot/editor/private.res', 'addons/gut/test.gd')))
            for path in ('.env', '.git/config', '.godot/editor/private.res'):
                with self.assertRaises(ValueError):
                    package.safe_resource(root, path)
            (root/'link.res').symlink_to(root/'scenes/main.tscn')
            with self.assertRaises(ValueError):
                package.safe_resource(root, 'link.res')
            self.put(root, 'assets/first.gd.uid', 'uid://duplicate')
            self.put(root, 'assets/second.gd.uid', 'uid://duplicate')
            uids = package.uid_index(root, package.runtime_files(root))
            self.assertIsNone(uids['uid://duplicate'])
            with self.assertRaisesRegex(ValueError, 'unresolved'):
                package.resolve_dependency('uid://duplicate', uids)
            self.assertEqual(package.resolve_dependency('uid://duplicate::Script::res://assets/first.gd', uids), 'assets/first.gd')

    def test_native_import_paths_all_variants_ignore_own_uid_and_deps_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\npath="res://assets/tex.png"')
            self.put(root, 'assets/tex.png', b'image')
            self.put(root, 'assets/tex.png.import', '[remap]\nuid="uid://unresolved-own-id"\npath.s3tc="res://.godot/imported/tex.ctex"\n[deps]\ndest_files=["res://.godot/imported/stale.ctex"]')
            native_paths = {'path.s3tc': 'res://.godot/imported/tex.ctex',
                            'path.etc2': "res://.godot/imported/kog'maw.ctex"}
            for target in native_paths.values():
                self.put(root, target[6:], b'native')
            dependencies = {'scenes/main.tscn': [], **{target[6:]: [] for target in native_paths.values()}}
            paths = package.dependency_closure(root, dependencies, {'Node', 'RefCounted'}, strict_native=True,
                                              import_remaps={'assets/tex.png.import': native_paths})
            for target in native_paths.values():
                self.assertIn(target[6:], paths)
            self.assertNotIn('.godot/imported/stale.ctex', paths)

    def test_ext_resource_explicit_path_wins_over_ambiguous_uid_and_root_uid_is_metadata(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3 uid="uid://root-metadata"]\n[ext_resource type="Script" uid="uid://duplicate" path="res://assets/first.gd" id="1"]')
            for name in ('first', 'second'):
                self.put(root, 'assets/'+name+'.gd', 'extends Node\n')
                self.put(root, 'assets/'+name+'.gd.uid', 'uid://duplicate')
            paths = package.dependency_closure(root, {'scenes/main.tscn': []}, {'Node', 'RefCounted'},
                                              strict_native=True, import_remaps={})
            self.assertIn('assets/first.gd', paths)
            self.assertNotIn('assets/second.gd', paths)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\n[ext_resource type="Script" uid="uid://duplicate" id="1"]')
            with self.assertRaisesRegex(ValueError, 'unresolved'):
                package.dependency_closure(root, {'scenes/main.tscn': []}, {'Node', 'RefCounted'},
                                           strict_native=True, import_remaps={})

    def test_strict_import_metadata_missing_or_non_resource_value_fails_closed(self):
        with tempfile.TemporaryDirectory() as directory:
            root = self.repo(directory)
            self.put(root, 'scenes/main.tscn', '[gd_scene format=3]\npath="res://assets/tex.png"')
            self.put(root, 'assets/tex.png', b'image')
            self.put(root, 'assets/tex.png.import', '[remap]\npath="res://.godot/imported/tex.ctex"')
            for remaps in ({}, {'assets/tex.png.import': {'path': 0}}):
                with self.subTest(remaps=remaps), self.assertRaises(ValueError):
                    package.dependency_closure(root, {'scenes/main.tscn': []}, {'Node'}, strict_native=True,
                                               import_remaps=remaps)

    def test_real_proven_missing_asset_classes_and_relative_texture_are_in_static_closure(self):
        repo = Path(package.__file__).resolve().parents[2]
        paths = package.dependency_closure(repo)
        for path in ('assets/BinbunVFX_Vol2/shared/script/VFXControllerBB.gd',
                     'assets/BinbunVFX/shared/script/vfx_effect.gd',
                     'assets/maps/KayKit_Forest_Nature_Pack_1.0_FREE/Assets/gltf/forest_texture.png',
                     'assets/maps/KayKit_Forest_Nature_Pack_1.0_FREE/Assets/gltf/forest_texture.png.import',
                     '.godot/imported/forest_texture.png-5983720600d41ef39ea31d17696a0863.s3tc.ctex'):
            self.assertIn(path, paths)
        cache = package.class_cache(repo, paths)
        self.assertIn('VFXControllerBB', cache)
        self.assertIn('VFXEffect', cache)
        self.assertLess(sum((repo/path).stat().st_size for path in paths), 1024**3)


if __name__ == '__main__':
    unittest.main()
