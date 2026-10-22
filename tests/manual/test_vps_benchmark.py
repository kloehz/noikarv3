"""Deterministic transport/lease/package tests. No SSH/Docker/services/workloads."""
import io
import json
import os
import tarfile
import tempfile
import unittest
from pathlib import Path
from unittest.mock import patch
import profile_room_scaling as local
import profile_vps as vps
import vps_benchmark_agent as agent
import package_vps_benchmark as package


class VpsBenchmarkTests(unittest.TestCase):
    def config(self):
        return dict(host='8.8.8.8',profile='compare30',node='/tmp/node/bin/node',runtime=agent.RUNTIME,
                    preparation_seconds=15,active_seconds=150,cleanup_seconds=30)

    def test_profile_transport_requires_public_exact_contract(self):
        self.assertEqual(agent.validate_config(self.config()),self.config())
        for fields in [dict(host='127.0.0.1'),dict(host='192.168.1.2'),dict(profile='default'),
                       dict(runtime='/usr/bin/godot'),dict(node='node'),dict(preparation_seconds=30),
                       dict(active_seconds=180),dict(cleanup_seconds=31)]:
            with self.subTest(fields=fields),self.assertRaises(ValueError):agent.validate_config(self.config()|fields)

    def test_proc_fields_comm_parentheses_cumulative_cpu_and_rss(self):
        fields=['S','4','77','1','0','0','0','0','0','0','0','120','30','0','0','0','0','1','0','999','4000','25']
        row=agent.parse_proc_stat('77 (game (worker) name) '+' '.join(fields),100,4096)
        self.assertEqual(row['cpu_seconds'],1.5);self.assertEqual(row['rss_kib'],100)
        self.assertEqual(row['starttime'],999);self.assertEqual(row['pgid'],77)
        with self.assertRaises(ValueError):agent.parse_proc_stat('bad',100,4096)

    def test_identity_reuse_uid_group_change_and_missing_never_owned(self):
        owned=dict(pid=77,starttime=999,pgid=77,uid=1000)
        self.assertTrue(agent.same_identity(owned,owned))
        for key in owned:self.assertFalse(agent.same_identity(owned,owned|{key:owned[key]+1}))
        self.assertFalse(agent.same_identity(owned,None))

    def test_host_cpu_guest_not_double_counted_and_guards_unchanged(self):
        row=agent.host_delta(dict(total=100,idle=70,steal=1),dict(total=200,idle=150,steal=3))
        self.assertEqual(row,dict(idle_percent=80,steal_percent=2))
        memory=dict(available_percent=20)
        self.assertEqual(agent.runtime_guard(row,memory,1000,5),0)
        for cause in ['memory','rss','host']:
            with self.subTest(cause=cause),self.assertRaises(RuntimeError):
                agent.runtime_guard(dict(idle_percent=0,steal_percent=50) if cause=='host' else row,
                    dict(available_percent=19) if cause=='memory' else memory,
                    2*1024*1024 if cause=='rss' else 1000,5)
        with self.assertRaises(RuntimeError):local.guard_load20(14,0)
        with self.assertRaises(RuntimeError):local.guard_load20(50,8*1024*1024+1)

    def test_firewall_matches_exact_tag_source_and_port_never_index(self):
        rule=dict(source='8.8.8.8',tag='noikar-bench-123456abcdef')
        text='24691/tcp ALLOW 8.8.8.8 # noikar-bench-123456abcdef'
        self.assertTrue(agent.rule_matches(text,rule));self.assertFalse(agent.rule_matches(text+'\n'+text,rule))
        self.assertFalse(agent.rule_matches(text.replace('8.8.8.8','1.1.1.1'),rule))
        calls=[]
        with patch.object(agent,'rule_status',side_effect=[text,'Status: active']),patch.object(agent.subprocess,'run',side_effect=lambda argv,**kw:calls.append(argv)):
            self.assertTrue(agent.remove_rule(rule))
        self.assertIn('24691',calls[0]);self.assertIn('8.8.8.8/32',calls[0]);self.assertNotIn('reset',calls[0])
        with patch.object(agent,'rule_status',return_value=text.replace('8.8.8.8','1.1.1.1')),patch.object(agent.subprocess,'run') as command:
            self.assertFalse(agent.remove_rule(rule));command.assert_not_called()

    def test_staged_spawner_env_preserves_normal_auth_hooks_and_no_secret_argv(self):
        text=''.join(['    `--provision-token=${provision.provisionToken}`,\n',
            '    `--room-creator-ticket=${provision.roomCreatorTicket}`,\n',
            '    `--provision-instance-id=${provision.provisionInstanceId}`,\n',
            '      NOIKAR_WORLD_SERVER_CREDENTIAL: provision.worldServerCredential,'])
        result=agent.staged_spawner(text)
        self.assertNotIn('--provision-token',result);self.assertIn('NOIKAR_ROOM_CREATOR_TICKET',result)
        self.assertIn('NOIKAR_WORLD_SERVER_CREDENTIAL',result)
        with self.assertRaises(ValueError):agent.staged_spawner('unknown')

    def test_safe_logs_keep_actual_capacity_and_windows_drop_tokens(self):
        self.assertIsNone(agent.safe_line('Noray private PID secret-token\n'))
        self.assertIsNone(agent.safe_line('Registering Spawned Server with token secret\n'))
        self.assertEqual(agent.safe_line('[PROFILE_CAPACITY] {"total_capacity":20}\n'),'[PROFILE_CAPACITY] {"total_capacity":20}\n')
        self.assertIn('error observed',agent.safe_line('SCRIPT ERROR: sensitive detail'))
        self.assertNotIn('password',vps.sanitized_client_text('Noray private PID password\n[LIVE-PROBE] PASS\n',[]))

    def test_preparation_default_inert_override_scoped_and_windows_distinct(self):
        args=local.parse_args([]);self.assertEqual(args.preparation_timeout_seconds,5);self.assertFalse(args.dedupe_phase_trace)
        full=['--player-count','20','--mob-count','20','--netfox-profile','compare60','--warmup-seconds','10','--sample-seconds','30','--sample-windows','3','--preparation-timeout-seconds','15','--dedupe-phase-trace']
        args=local.parse_args(full);self.assertEqual(args.sample_seconds,90);self.assertEqual(args.preparation_timeout_seconds,15)
        with self.assertRaises(SystemExit):local.parse_args(['--preparation-timeout-seconds','15'])
        env=vps.remote_client_env(local.Account('fixture','secret'),19,'compare60','8.8.8.8',Path('/tmp/fixture'),None,15,True)
        self.assertEqual(env['NOIKAR_BENCHMARK_CLIENT'],'1');self.assertEqual(env['NOIKAR_NORAY_BIND_PORT'],'0')
        self.assertEqual(env['NOIKAR_BACKEND_URL'],'http://127.0.0.1:18090')
        self.assertEqual(env['NOIKAR_PROFILE_PREPARATION_SEC'],'15')

    def test_archive_closure_rejects_escape_and_secrets(self):
        for name in ['../escape','.env','safe']:
            with tempfile.TemporaryDirectory() as d:
                root=Path(d);archive=root/'test.tar';destination=root/'extract';destination.mkdir()
                with tarfile.open(archive,'w') as tar:
                    member=tarfile.TarInfo(name);member.size=1;tar.addfile(member,io.BytesIO(b'x'))
                if name=='safe':agent.safe_extract(archive,destination);self.assertEqual((destination/'safe').read_text(),'x')
                else:
                    with self.assertRaises(ValueError):agent.safe_extract(archive,destination)

    def test_dependency_closure_sources_imports_no_editor_or_secrets(self):
        with tempfile.TemporaryDirectory() as d:
            repo=Path(d);(repo/'tools').mkdir();(repo/'common').mkdir();(repo/'assets').mkdir();(repo/'.godot/imported').mkdir(parents=True)
            (repo/'project.godot').write_text('res://common/main.gd');(repo/'tools/benchmark_profiles.json').write_text('{}')
            (repo/'common/main.gd').write_text('extends Node\nclass_name Fixture\nvar p="res://assets/tex.png"')
            (repo/'assets/tex.png').write_bytes(b'x');(repo/'assets/tex.png.import').write_text('[remap]\npath="res://.godot/imported/tex.ctex"')
            (repo/'.godot/imported/tex.ctex').write_bytes(b'x');(repo/'.env').write_text('secret')
            closure=package.dependency_closure(repo);self.assertIn('.godot/imported/tex.ctex',closure);self.assertNotIn('.env',closure)
            self.assertIn('Fixture',package.class_cache(repo,closure))
            with self.assertRaises(ValueError):package.safe_resource(repo,'.env')
            with self.assertRaises(ValueError):package.safe_resource(repo,'.godot/editor/state.cfg')

    def test_selected_real_dirty_runtime_closure_has_class_bases_and_no_secret_roots(self):
        repo=local.repo_root_from_script()
        closure=package.dependency_closure(repo)
        self.assertIn('scenes/main.tscn',closure)
        self.assertLess(sum((repo/name).stat().st_size for name in closure),1024**3)
        self.assertFalse(any(name.startswith(('docs/','backend/','tests/','.git/')) for name in closure))
        registry=package.class_cache(repo,closure)
        self.assertIn('NpcStateSynchronizer',registry);self.assertIn('RefCounted',registry)

    def test_cleanup_only_proved_identity_and_no_unowned_signals(self):
        with tempfile.TemporaryDirectory() as d:
            root=Path(d);identity=dict(pid=77,starttime=999,pgid=77,uid=1000,role='server')
            agent.private_json(root/'manifest.json',dict(processes=[identity],rule=None))
            with patch.object(agent,'process_sample',return_value=identity|{'starttime':1000,'state':'S'}),patch.object(agent.os,'killpg') as kill,patch.object(agent,'port_inventory',return_value=[]):
                outcome=agent.cleanup(root,'fixture')
            kill.assert_not_called();self.assertTrue(outcome['ok'])
            self.assertTrue(json.loads((root/'manifest.json').read_text())['stop_requested'])

if __name__=='__main__':unittest.main()
