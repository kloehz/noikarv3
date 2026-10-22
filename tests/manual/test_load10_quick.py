"""REAL10 quick fixtures only: no services, signals, SSH, export or gameplay."""
import copy
import json
import tempfile
import unittest
from contextlib import redirect_stderr
from io import StringIO
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch
import profile_room_scaling as local
import profile_vps as vps
import vps_benchmark_agent as agent


class Load10QuickTests(unittest.TestCase):
    def config(self, **extra):
        return dict(host='8.8.8.8', profile='compare30', node='/tmp/node/bin/node',
                    runtime=agent.RUNTIME, preparation_seconds=5, active_seconds=150,
                    cleanup_seconds=30, **extra)

    def cli(self, *extra):
        return vps.parse_args(['--binding','/tmp/binding','--package','/tmp/package',
            '--noray-closure','/tmp/noray.tar.gz','--node','/tmp/node/bin/node',
            '--netfox-profile','compare30','--output','/tmp/result',*extra])

    def population(self, count=10, offset=0):
        ids=list(range(2,count+2))
        return dict(owners=ids,input_authorities=ids,connected_peers=ids,
            authenticated_accounts=count,authenticated_peers=count,lobby_players=count,
            red=count//2,blue=count//2,alive_players=count,server_state_authorities=count,
            live_mobs=20,alive_mobs=20,positions={str(i):[float(i)+offset,0.,0.] for i in ids})

    def markers(self,count=10):
        return [dict(index=i,owner=i+2,team=1 if i<count//2 else 2) for i in range(count)]

    def capacity(self,count=10,role='server'):
        return dict(role=role,requested_players=count,max_players_per_team=count//2,
                    total_capacity=count,runtime_clone=True,authored_max_players_per_team=3)

    def window_fixture(self,count=10,window_count=1):
        windows=[]
        for i in range(window_count):
            windows.append(dict(schema=1,index=i,start_unix_usec=(100+30*i)*10**6,
                end_unix_usec=(130+30*i)*10**6,duration_usec=30*10**6,native_ticks=900,
                native_interval_p95_ms=40.,native_interval_p99_ms=43.,native_interval_samples=899,
                native_interval_dropped=0,population_start=self.population(count),
                population_samples=[self.population(count,2)],population_end=self.population(count,3),
                stride_start={'1':20},stride_end={'1':20}))
        rows=[dict(unix_usec=s*10**6,cpu_seconds=(s-99)*.2,rss_kib=1000+s,
                   read_begin_unix_usec=s*10**6-1000,read_end_unix_usec=s*10**6+1000)
              for s in range(99,132+30*(window_count-1))]
        text='\n'.join('[PROFILE_SERVER_WINDOW] '+json.dumps(w) for w in windows)
        return windows,rows,text

    def test_legacy_real20_default_and_explicit_real10_short_plan(self):
        args=self.cli()
        self.assertEqual((args.player_count,args.sample_windows,args.sample_seconds,args.warmup_seconds),(20,3,30,10))
        args=self.cli('--player-count','10','--sample-windows','1','--warmup-seconds','5')
        self.assertEqual((args.player_count,args.sample_windows,args.sample_seconds,args.warmup_seconds),(10,1,30,5))
        self.assertEqual(agent.workload_plan(self.config()),dict(player_count=20,team_size=10,sample_windows=3,sample_seconds=30,warmup_seconds=10))
        self.assertEqual(agent.workload_plan(self.config(player_count=10,sample_windows=1,sample_seconds=30,warmup_seconds=5))['team_size'],5)

    def test_invalid_or_implicit_short_plan_rejects_without_clamping(self):
        for extra in [('--player-count','9'),('--player-count','10.0'),('--player-count','true'),
            ('--player-count','10'),('--sample-windows','2'),('--sample-seconds','29'),
            ('--player-count','10','--sample-windows','3','--warmup-seconds','5'),
            ('--player-count','20','--sample-windows','1','--warmup-seconds','5')]:
            with self.subTest(extra=extra),redirect_stderr(StringIO()),self.assertRaises(SystemExit):self.cli(*extra)
        for fields in [dict(player_count=True),dict(player_count=10.0),dict(player_count=9),
            dict(player_count=10),dict(sample_windows=True),dict(sample_windows=2),
            dict(warmup_seconds=5.0),dict(sample_seconds=29),
            dict(player_count=10,sample_windows=3,warmup_seconds=5)]:
            with self.subTest(fields=fields),self.assertRaises(ValueError):agent.validate_config(self.config(**fields))

    def test_client_env_exact_ten_headless_client_and_short_duration(self):
        env=vps.remote_client_env(local.Account('fixture','fixture'),9,'compare30','8.8.8.8',Path('/tmp/fixture'),None,15,True,
            player_count=10,sample_windows=1,sample_seconds=30,warmup_seconds=5)
        expected={'NOIKAR_BENCHMARK_PLAYER_LIMIT':'10','NOIKAR_BENCHMARK_CLIENT':'1',
            'NOIKAR_PROFILE_PLAYER_COUNT':'10','NOIKAR_PROFILE_PLAYER_INDEX':'9',
            'NOIKAR_PROFILE_WARMUP_SEC':'5.0','NOIKAR_PROFILE_SAMPLE_SEC':'30.0',
            'NOIKAR_PROFILE_EXPECTED_MOB_COUNT':'20','NOIKAR_PROFILE_FIXED_ROUTE':'1',
            'NOIKAR_BENCHMARK_REMOTE':'1','NOIKAR_NORAY_BIND_PORT':'0','NOIKAR_PROFILE_PREPARATION_SEC':'15'}
        for k,v in expected.items():self.assertEqual(env[k],v)
        self.assertIn('--headless',local.client_command(Path('/godot'),Path('/repo'),10))
        self.assertIn('--headless',local.client_command(Path('/godot'),Path('/repo'),20))
        self.assertNotIn('--headless',local.client_command(Path('/godot'),Path('/repo'),2))

    def test_server_env_matches_plan_not_client_simulation_or_npc_reduction(self):
        old=agent.server_benchmark_env(self.config(),Path('/tmp/fixture'))
        self.assertEqual(old['NOIKAR_BENCHMARK_PLAYER_LIMIT'],'20')
        self.assertEqual(old['NOIKAR_PROFILE_WINDOW_COUNT'],'3');self.assertEqual(old['NOIKAR_PROFILE_WARMUP_SEC'],'10.0')
        short=agent.server_benchmark_env(self.config(player_count=10,sample_windows=1,sample_seconds=30,warmup_seconds=5),Path('/tmp/fixture'))
        self.assertEqual(short['NOIKAR_BENCHMARK_PLAYER_LIMIT'],'10')
        self.assertEqual(short['NOIKAR_PROFILE_WINDOW_COUNT'],'1');self.assertEqual(short['NOIKAR_PROFILE_WARMUP_SEC'],'5.0')
        self.assertEqual(short['NOIKAR_PROFILE_MOB_COUNT'],'20');self.assertEqual(short['NOIKAR_SERVER_MAX_FPS'],'75')
        self.assertEqual(short['NOIKAR_NPC_SNAPSHOT_HZ'],'30');self.assertNotIn('NOIKAR_BENCHMARK_CLIENT',short)

    def test_ten_distinct_owner_indices_and_five_per_team_reject_nine(self):
        rows=self.markers();self.assertTrue(local.verified_owners(rows,10))
        for bad in [rows[:9],rows+[rows[0]],[dict(r,owner=2) for r in rows],
            [dict(r,team=1) for r in rows],[dict(r,index=True) for r in rows],self.markers(20)]:
            self.assertFalse(local.verified_owners(bad,10))
        self.assertTrue(local.verified_twenty_owners(self.markers(20)))
        self.assertFalse(local.verified_twenty_owners(rows))

    def test_actual_population_requires_ten_unique_accounts_owners_movement_and_twenty_npcs(self):
        row=self.population();self.assertTrue(local.verified_owner_population(row,set(range(2,12)),player_count=10))
        for k,v in [('authenticated_accounts',9),('authenticated_peers',9),('red',6),('blue',4),('live_mobs',19),
            ('alive_mobs',19),('alive_players',9),('server_state_authorities',9),('owners',[2]*10),
            ('input_authorities',list(range(2,11))),('connected_peers',[]),('positions',{}),('live_mobs',20.)]:
            self.assertFalse(local.verified_owner_population(dict(row,**{k:v}),player_count=10))
        self.assertFalse(local.verified_owner_population(row))
        self.assertEqual(local.authoritative_moving_owners([row,self.population(10,2)],player_count=10),set(range(2,12)))
        self.assertEqual(local.authoritative_moving_owners([row],player_count=10),set())

    def test_runtime_clone_capacity_readback_exact_not_production_six(self):
        row=self.capacity();text='[PROFILE_CAPACITY] '+json.dumps(row)
        self.assertTrue(local.verified_capacity_readback(text,'server',player_count=10))
        self.assertFalse(local.verified_capacity_readback(text,'server'))
        for k,v in [('total_capacity',20),('max_players_per_team',10),('runtime_clone',False),('authored_max_players_per_team',5)]:
            self.assertFalse(local.verified_capacity_readback('[PROFILE_CAPACITY] '+json.dumps(dict(row,**{k:v})),'server',player_count=10))
        self.assertFalse(local.verified_capacity_readback(text+'\n'+text,'server',player_count=10))

    def test_complete_ten_proof_rejects_nine_wrong_oid_clock_and_capacity(self):
        with tempfile.TemporaryDirectory() as d:
            clients=[]
            for i in range(10):
                p=Path(d)/str(i);p.write_text('[PROFILE_CAPACITY] '+json.dumps(self.capacity(role='client'))+
                    '\n[LIVE-PROBE] OWNER_READY index=%d owner=%d team=%d'%(i,i+2,1 if i<5 else 2)+
                    '\n[PROFILE_CLIENT_CLOCK] ticks=1230 elapsed_sec=41.000000 achieved_hz=30.000')
                clients.append(SimpleNamespace(index=i,log_path=p,parser=SimpleNamespace(admitted_oid='fixture-room')))
            pops=[dict(self.population(10,o),workload_started=True) for o in [0,2]]
            text='[PROFILE_CAPACITY] '+json.dumps(self.capacity())+'\n'+'\n'.join(
                '[PERF] owner_population='+json.dumps(p)+' native_achieved_hz=30.000' for p in pops)
            self.assertTrue(local.load20_proof(clients,text,'compare30',player_count=10)['ok'])
            self.assertFalse(local.load20_proof(clients[:9],text,'compare30',player_count=10)['ok'])
            self.assertFalse(local.load20_proof(clients,text,'compare30')['ok'])
            clients[9].parser.admitted_oid='other';self.assertFalse(local.load20_proof(clients,text,'compare30',player_count=10)['ok'])
            clients[9].parser.admitted_oid='fixture-room'
            self.assertFalse(local.load20_proof(clients,text.replace('native_achieved_hz=30.000','native_achieved_hz=20.000'),'compare30',player_count=10)['ok'])

    def test_one_json_native_window_is_not_three_and_requires_ten_moving_owners(self):
        _,rows,text=self.window_fixture()
        proof=local.build_consecutive_windows(text,rows,'compare30',player_count=10,window_count=1)
        self.assertTrue(proof['ok'],proof);self.assertEqual(proof['requested_windows'],1)
        self.assertEqual(proof['windows'][0]['authoritative_moving_owner_count'],10)
        self.assertEqual(proof['windows'][0]['cpu_percent_one_core'],20.)
        self.assertFalse(local.build_consecutive_windows(text,rows,'compare30')['ok'])
        windows,rows,text=self.window_fixture(20,3)
        self.assertTrue(local.build_consecutive_windows(text,rows,'compare30')['ok'])
        _,rows,text=self.window_fixture();self.assertFalse(local.build_consecutive_windows(text,rows,'compare60',player_count=10,window_count=1)['ok'])
        broken=json.loads(text.split(' ',1)[1]);broken['population_end']=self.population(10);broken['population_samples']=[self.population(10)]
        self.assertFalse(local.build_consecutive_windows('[PROFILE_SERVER_WINDOW] '+json.dumps(broken),rows,'compare30',player_count=10,window_count=1)['ok'])

    def test_generator_guard_counts_ten_without_lowering_850_ceiling(self):
        self.assertEqual(vps.generator_guard(849.,10,10,2),(849.,0))
        self.assertEqual(vps.generator_guard(851.,10,10,0),(851.,1))
        self.assertEqual(vps.generator_guard(851.,10,10,2),(851.,3))
        self.assertEqual(vps.generator_guard(851.,9,10,2),(None,0))
        self.assertEqual(vps.generator_guard(851.,20,20,2),(851.,3))
        with self.assertRaises(ValueError):vps.generator_guard(851.,11,10,2)
        with self.assertRaises(RuntimeError):local.guard_load20(14,0)
        with self.assertRaises(RuntimeError):local.guard_load20(50,8*1024*1024+1)

    def test_new_owned_runtime_binding_requires_exact_pinned_version_hash_and_full_tuple(self):
        fields=dict(runtime_path='/tmp/noikar-netfox-runtime-12d0d2ee1355/Godot_v4.8-dev6_linux.x86_64',
                    runtime_version=agent.VERSION,runtime_sha256=agent.RUNTIME_SHA256)
        result=vps.runtime_binding_fields(fields)
        self.assertEqual(agent.validate_runtime(result),fields['runtime_path'])
        self.assertEqual(vps.runtime_binding_fields({})['runtime'],agent.RUNTIME)
        for change in [dict(runtime_path='/usr/bin/godot'),dict(runtime_version='4.7.stable'),dict(runtime_sha256='0'*64),
                       dict(runtime_path=fields['runtime_path']+';echo'),dict(runtime_path='/tmp/noikar-netfox-runtime-../../godot')]:
            with self.assertRaises(ValueError):vps.runtime_binding_fields(fields|change)
        with self.assertRaises(ValueError):vps.runtime_binding_fields(dict(runtime_path=fields['runtime_path']))
        with self.assertRaises(ValueError):agent.validate_runtime(dict(runtime=fields['runtime_path']))
        with patch.object(agent,'verify_runtime_file',side_effect=RuntimeError('runtime unavailable')),patch.object(agent.subprocess,'run') as command:
            with self.assertRaises(RuntimeError):agent.preflight(self.config())
            command.assert_not_called()

    def test_native_source_contract_scopes_ten_to_remote_and_keeps_normal_auth_rule_assets(self):
        repo=Path(__file__).resolve().parents[2]
        profile=(repo/'common/benchmark_profile.gd').read_text()
        self.assertIn('limit == "10" and options.get("remote") != "1"',profile)
        self.assertIn('runtime.max_players_per_team = int(limit / 2)',profile)
        self.assertIn('return local in [0, 10, 20] and local == remote',profile)
        self.assertIn('player_limit = int(options.limit)',profile)
        self.assertIn('static func server_window_plan',profile)
        rules=(repo/'common/resources/default_match_rules.tres').read_text()
        self.assertNotIn('max_players_per_team =',rules)
        self.assertIn('@export var max_players_per_team: int = 3',(repo/'common/resources/match_rules.gd').read_text())
        auth=(repo/'common/match_manager.gd').read_text()
        self.assertIn('await AuthService.validate_access_token(token)',auth)
        self.assertIn('BenchmarkProfile.capacity_matches(BenchmarkProfile.player_limit, player_limit)',auth)
        director=(repo/'common/match_director.gd').read_text()
        self.assertIn('"requested_players": BenchmarkProfile.player_limit',director)
        self.assertIn('BenchmarkProfile.player_limit in [10, 20]',(repo/'client/connection_manager.gd').read_text())
        probe=(repo/'tests/manual/live_gameplay_probe.gd').read_text()
        self.assertIn('raw in ["10", "20"] and int(raw) == root.get_node("BenchmarkProfile").player_limit',probe)
        self.assertIn('if expected_players in [10, 20]:',probe)
        self.assertIn('observer.start_server_windows(plan.window_count, plan.warmup_seconds)',(repo/'common/perf_probe.gd').read_text())
        self.assertIn('_window_index >= _window_count',(repo/'common/benchmark_observer.gd').read_text())

if __name__=='__main__':unittest.main()
