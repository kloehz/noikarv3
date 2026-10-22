"""Deterministic observation/window tests; no services or connected workloads."""
import json
import unittest
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import patch
import profile_room_scaling as prs


class ObservationWindowTests(unittest.TestCase):
    def args(self, extra=()):
        return prs.parse_args(["--player-count", "20", "--mob-count", "20", "--netfox-profile", "compare30",
                               "--warmup-seconds", "10", "--sample-seconds", "30", *extra])

    def population(self, offset=0):
        ids = list(range(2, 22))
        return dict(owners=ids, input_authorities=ids, connected_peers=ids, authenticated_accounts=20,
                    authenticated_peers=20, lobby_players=20, red=10, blue=10, alive_players=20,
                    server_state_authorities=20, live_mobs=20, alive_mobs=20,
                    positions={str(i): [float(i)+offset, 0., 0.] for i in ids})

    def fixtures(self, hz=30):
        windows = []
        for index in range(3):
            windows.append(dict(schema=1, index=index, start_unix_usec=(100+30*index)*1_000_000,
                end_unix_usec=(130+30*index)*1_000_000, duration_usec=30_000_000, native_ticks=30*hz,
                native_interval_p95_ms=1000/hz, native_interval_p99_ms=1000/hz, native_interval_samples=30*hz-1,
                native_interval_dropped=0, population_start=self.population(), population_end=self.population(3),
                population_samples=[self.population(2)], stride_start={"1":20}, stride_end={"1":20}))
        rows=[dict(unix_usec=s*1_000_000, cpu_seconds=(s-99)*.2, rss_kib=1000+s,
                   read_begin_unix_usec=s*1_000_000-1000, read_end_unix_usec=s*1_000_000+1000)
              for s in range(99,192)]
        return windows, rows

    def proof(self, windows, rows, hz=30):
        text="\n".join("[PROFILE_SERVER_WINDOW] "+json.dumps(w) for w in windows)
        # Exercise actual JSON round-trip, including numeric nested observations.
        return prs.build_consecutive_windows(text, rows, "compare30" if hz==30 else "compare60")

    def test_default_window_and_observation_flags_are_inert(self):
        args=prs.parse_args([])
        self.assertEqual(args.sample_windows,1); self.assertFalse(args.observe_clients)
        server=prs.noray_env(Path('/repo'),Path('/godot'),'fixture')
        self.assertNotIn('NOIKAR_PROFILE_WINDOW_COUNT',server)
        client=prs.client_probe_env(account=prs.Account('fixture','fixture'),lobby_hold_seconds=0,
                                    warmup_seconds=10,sample_seconds=60)
        self.assertNotIn('NOIKAR_PROFILE_CLIENT_OBSERVE',client)

    def test_explicit_three_windows_are_per_window_thirty_not_aggregate_thirty(self):
        args=self.args(['--sample-windows','3','--observe-clients'])
        self.assertEqual(args.sample_seconds,90); self.assertEqual(args.sample_windows,3)
        server=prs.noray_env(Path('/repo'),Path('/godot'),'fixture',sample_windows=3)
        self.assertEqual(server['NOIKAR_PROFILE_WARMUP_SEC'],'10.0')
        self.assertEqual(server['NOIKAR_PROFILE_WINDOW_COUNT'],'3')

    def test_invalid_types_counts_durations_and_populations_reject_before_launch(self):
        for extra in [['--sample-windows','2'],['--sample-windows','3.0'],['--sample-windows','true'],
                      ['--sample-windows','3','--sample-seconds','60'],
                      ['--sample-windows','3','--warmup-seconds','5'],
                      ['--sample-windows','3','--player-count','2'],
                      ['--sample-windows','3','--deadline-seconds','119']]:
            with self.subTest(extra=extra), self.assertRaises(SystemExit): self.args(extra)
        with self.assertRaises(SystemExit): prs.parse_args(['--observe-clients'])

    def test_three_real_distinct_native_windows_cpu_rss_and_population(self):
        for hz in [30,60]:
            windows,rows=self.fixtures(hz); proof=self.proof(windows,rows,hz)
            self.assertTrue(proof['ok'],proof)
            self.assertEqual(len(proof['windows']),3)
            for index,w in enumerate(proof['windows']):
                self.assertEqual(w['cpu_percent_one_core'],20.)
                self.assertEqual(w['native_achieved_hz'],hz)
                self.assertEqual(w['rss_median_kib'],1115+30*index)
                self.assertEqual(w['rss_max_kib'],1130+30*index)
                self.assertEqual(w['authoritative_moving_owner_count'],20)

    def test_missing_metrics_remain_unavailable_never_zero(self):
        windows,_=self.fixtures(); proof=self.proof(windows,[])
        self.assertFalse(proof['ok'])
        for w in proof['windows']:
            self.assertIsNone(w['cpu_percent_one_core']); self.assertIsNone(w['rss_max_kib'])
            self.assertIsNone(w['rss_median_kib'])

    def test_shortage_gap_duplicate_mismatch_and_clock_jump_fail(self):
        for mutation in ['shortage','stationary','stride','duplicate','gap','wallclock','native','type','dropped']:
            windows,rows=self.fixtures()
            if mutation=='shortage': windows[1]['population_end']['alive_mobs']=19
            if mutation=='stationary':
                windows[1]['population_end']=self.population(); windows[1]['population_samples']=[self.population()]
            if mutation=='stride': windows[1]['stride_end']={'1':19,'missing':1}
            if mutation=='duplicate': windows[1]['index']=0
            if mutation=='gap': windows[1]['start_unix_usec']+=1000
            if mutation=='wallclock': windows[1]['end_unix_usec']+=500000
            if mutation=='native': windows[1]['native_ticks']=300
            if mutation=='type': windows[1]['duration_usec']=30000000.5
            if mutation=='dropped': windows[1]['native_interval_dropped']=1
            with self.subTest(mutation=mutation): self.assertFalse(self.proof(windows,rows)['ok'])
        windows,rows=self.fixtures()
        self.assertFalse(self.proof(windows[:2],rows)['ok'])
        self.assertFalse(self.proof(windows+[windows[2]],rows)['ok'])

    def test_cpu_interpolation_is_bracketed_and_rejects_stale_or_backwards_time(self):
        _,rows=self.fixtures()
        boundary=100_500_000
        point=prs.interpolate_cpu_boundary(rows,boundary)
        self.assertAlmostEqual(point['cpu_seconds'],.3)
        self.assertEqual(point['bracket_seconds'],1.)
        self.assertIsNone(prs.interpolate_cpu_boundary(rows,98_000_000))
        self.assertIsNone(prs.interpolate_cpu_boundary(rows[::4],boundary))
        backward=[dict(rows[0]),dict(rows[1],cpu_seconds=-1)]
        self.assertIsNone(prs.interpolate_cpu_boundary(backward,99_500_000))

    def test_numeric_sanitization_discards_private_fields_strings_and_nonfinite_values(self):
        good=dict(schema=1,index=0,row=0,native_ticks=30,last_loop_monitors={'rollback_nodes':None})
        for bad in [dict(good,token='secret'),dict(good,phase='secret'),dict(good,native_ticks=float('nan')),
                    dict(good,last_loop_monitors={'private_key':1})]:
            self.assertEqual(prs.safe_observation_rows('[PROFILE_CLIENT_OBSERVATION] '+json.dumps(bad),
                            '[PROFILE_CLIENT_OBSERVATION] '),[])
        text=('prefix [PROFILE_CLIENT_OBSERVATION] '+json.dumps(good)+' PRIVATE_SUFFIX\n')*200
        self.assertEqual(len(prs.safe_observation_rows(text,'[PROFILE_CLIENT_OBSERVATION] ')),180)

    def test_process_readback_has_real_begin_end_midpoint_and_unavailable_case(self):
        with patch.object(prs,'ps_sample',return_value=(1.5,1234)), patch.object(prs.time,'time_ns',side_effect=[1000000,3000000]):
            self.assertEqual(prs.timed_ps_sample(12),dict(unix_usec=2000,read_begin_unix_usec=1000,
                              read_end_unix_usec=3000,cpu_seconds=1.5,rss_kib=1234))
        with patch.object(prs,'ps_sample',return_value=None): self.assertIsNone(prs.timed_ps_sample(12))

    def test_real_opt_in_prelogin_observer_reports_effective_clocks_without_network_or_scene_load(self):
        godot=Path('/Applications/Godot.app/Contents/MacOS/Godot')
        if not godot.exists(): self.skipTest('Godot unavailable')
        repo=Path(__file__).resolve().parents[2]
        env=prs.client_probe_env(account=prs.Account('fixture','fixture'),lobby_hold_seconds=0,
            warmup_seconds=10,sample_seconds=60,mob_count=20,player_count=20,player_index=0,
            netfox_profile='compare30',observe_clients=True)
        script_text='extends SceneTree\nfunc _initialize() -> void:\n\tcall_deferred("_check")\nfunc _check() -> void:\n\tawait process_frame\n\tvar observer: Node = load("res://common/benchmark_observer.gd").new()\n\troot.add_child(observer)\n\tobserver.start_client(0, func() -> int: return -1)\n\tawait create_timer(1.2).timeout\n\tprint("PRELOGIN_OBSERVER_FIXTURE_PASS")\n\tquit(0)\n'
        with tempfile.TemporaryDirectory(prefix='noikar-observer-fixture-') as directory:
            script=Path(directory)/'check.gd'; script.write_text(script_text)
            result=subprocess.run([str(godot),'--headless','--path',str(repo),'--script',str(script)],
                env=env,capture_output=True,text=True,timeout=10)
        output=result.stdout+result.stderr
        self.assertEqual(result.returncode,0,output)
        self.assertNotIn('SCRIPT ERROR',output); self.assertNotIn('ERROR:',output)
        rows=prs.safe_observation_rows(output,'[PROFILE_CLIENT_OBSERVATION] ')
        self.assertEqual(len(rows),1,output)
        row=rows[0]
        self.assertEqual(row['phase'],-1); self.assertEqual(row['players'],0); self.assertEqual(row['mobs'],0)
        self.assertEqual(row['max_fps'],60); self.assertEqual(row['physics_hz'],50)
        self.assertEqual(row['native_hz'],30)
        self.assertGreater(row['effective_process_hz'],40); self.assertLessEqual(row['effective_process_hz'],65)
        self.assertGreater(row['effective_physics_hz'],40); self.assertLessEqual(row['effective_physics_hz'],55)
        # Inactive networking produces a measured zero callbacks, not guessed consumption.
        self.assertEqual(row['native_ticks'],0); self.assertEqual(row['effective_native_hz'],0)


if __name__=='__main__': unittest.main()
