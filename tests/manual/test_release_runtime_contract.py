"""No-service fixtures: pinned editor/release identity, canonical PCK, opt-in ACKs."""
import hashlib
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import vps_benchmark_agent as agent
import profile_vps as runner

RELEASE_SHA = '3882af22b056e688cd94c71d827870723363422514c912fa261a5f5eb0c4913e'

class ReleaseRuntimeTests(unittest.TestCase):
    def release(self):
        return dict(runtime_kind='export_template_release',runtime='/tmp/noikar-netfox-runtime-abcdef123456/linux_release.x86_64',runtime_version=agent.VERSION,runtime_sha256=RELEASE_SHA)

    def test_legacy_editor_contract_is_unchanged(self):
        self.assertEqual(agent.validate_runtime({}),agent.RUNTIME)
        fields=runner.runtime_binding_fields({})
        self.assertEqual(fields['runtime_sha256'],agent.RUNTIME_SHA256)

    def test_explicit_release_binding_passes_exact_pin(self):
        config=self.release()
        self.assertEqual(agent.validate_runtime(config),config['runtime'])
        fields=runner.runtime_binding_fields(dict(runtime_path=config['runtime'],runtime_version=agent.VERSION,runtime_sha256=RELEASE_SHA,runtime_kind='export_template_release'))
        self.assertEqual(fields['runtime_kind'],'export_template_release')

    def test_release_identity_does_not_relax_editor_or_unknown_kinds(self):
        for change in ({'runtime_kind':'editor'},{'runtime_kind':'release'},{'runtime_sha256':agent.RUNTIME_SHA256},{'runtime_version':'4.7.stable'},{'runtime':'/tmp/foreign/linux_release.x86_64'}):
            with self.subTest(change=change),self.assertRaises(ValueError):agent.validate_runtime(dict(self.release(),**change))

    def test_missing_release_tuple_fails_closed(self):
        for key in ('runtime','runtime_version','runtime_sha256','runtime_kind'):
            config=self.release();config.pop(key)
            with self.subTest(key=key),self.assertRaises(ValueError):agent.validate_runtime(config)

    def test_canonical_release_command_uses_adjacent_pack_without_overrides(self):
        with tempfile.TemporaryDirectory(prefix='noikar-netfox-bench-',dir='/private/tmp') as tmp:
            root=Path(tmp);config=self.release();payload=b'owned executable';pack=b'owned pack'
            source=root/'source';source.write_bytes(payload);(root/'game.pck').write_bytes(pack)
            config['pck_sha256']=hashlib.sha256(pack).hexdigest()
            with patch.object(agent,'verify_runtime_file',return_value=str(source)),patch.object(agent,'RELEASE_SHA256',hashlib.sha256(payload).hexdigest()),patch.object(agent,'RELEASE_BYTES',len(payload)):
                agent.stage_release_runtime(root,config)
                command=agent.game_command(root,config)
                self.assertEqual(command,[str(root/'server.x86_64'),'--headless','--','--server'])
                self.assertEqual((root/'server.pck').read_bytes(),pack)
                self.assertNotIn('--main-pack',command);self.assertNotIn('--path',command)
                (root/'server.pck').unlink();(root/'server.pck').write_bytes(b'changed')
                with self.assertRaises(RuntimeError):agent.game_command(root,config)

    def test_release_staging_rejects_preexisting_destination(self):
        with tempfile.TemporaryDirectory(dir='/private/tmp') as tmp:
            root=Path(tmp);source=root/'source';source.write_bytes(b'bin');(root/'game.pck').write_bytes(b'pack');(root/'server.x86_64').symlink_to(source)
            with patch.object(agent,'verify_runtime_file',return_value=str(source)),self.assertRaises(RuntimeError):agent.stage_release_runtime(root,self.release())

    def test_editor_command_keeps_main_pack(self):
        with patch.object(agent,'verify_runtime_file',return_value=agent.RUNTIME):
            self.assertEqual(agent.game_command(Path('/tmp/example'),{}),[agent.RUNTIME,'--headless','--main-pack','/tmp/example/game.pck','--','--server'])

    def test_replication_tuning_is_explicit_and_forwarded_to_server(self):
        base=dict(profile='compare30')
        self.assertNotIn('NOIKAR_REPLICATION_PROFILE',agent.server_benchmark_env(base,Path('/tmp/example')))
        env=agent.server_benchmark_env(dict(base,replication_profile='diff_ack_100ms'),Path('/tmp/example'))
        self.assertEqual(env['NOIKAR_REPLICATION_PROFILE'],'diff_ack_100ms')
        for bad in ('arbitrary',None,10,True):
            with self.subTest(bad=bad),self.assertRaises(ValueError):agent.server_benchmark_env(dict(base,replication_profile=bad),Path('/tmp/example'))

if __name__=='__main__':unittest.main()
