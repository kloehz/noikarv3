"""Readiness observation fixtures; no services, native runtime, SSH or workloads."""
import json
import unittest
from pathlib import Path
import profile_room_scaling as local
import profile_vps as vps
import vps_benchmark_agent as agent


class ReadinessDiagnosticsTests(unittest.TestCase):
    def row(self, **extra):
        return dict(schema=1, role='client', index=0, row=0, event=0, stage=1,
                    uptime_usec=123, unix_usec=456, cap_reached=False, phase=None,
                    avatar_present=False, sync_count=0, initialized_sync_count=None,
                    replica_ack_count=None, **extra)

    def cli(self, *extra):
        return vps.parse_args(['--binding','/tmp/binding','--package','/tmp/package',
            '--noray-closure','/tmp/noray.tar.gz','--node','/tmp/node/bin/node',
            '--netfox-profile','compare30','--output','/tmp/result',*extra])

    def config(self, **extra):
        return dict(host='8.8.8.8',profile='compare30',node='/tmp/node/bin/node',
                    runtime=agent.RUNTIME,**extra)

    def text(self, row):
        return '[PROFILE_READINESS] '+json.dumps(row)

    def test_json_round_trip_preserves_unknown_as_null_and_filters_secrets(self):
        raw=self.row(token='secret',path='/private/secret',account='private')
        rows=local.readiness_trace_rows(self.text(raw),'client',0)
        self.assertEqual(len(rows),1)
        self.assertIsNone(rows[0]['phase']);self.assertIsNone(rows[0]['replica_ack_count'])
        for key in ('token','path','account'):self.assertNotIn(key,rows[0])
        self.assertEqual(json.loads(json.dumps(rows)),rows)

    def test_rejects_identity_role_and_nonprimitive_core_values(self):
        for fields in [dict(role='unknown'),dict(index=1),dict(schema=True),dict(row=True),
            dict(row=192),dict(event=8),dict(stage=20),dict(uptime_usec=-1),
            dict(unix_usec=1.5),dict(cap_reached='false')]:
            raw=self.row();raw.update(fields)
            with self.subTest(fields=fields):self.assertEqual(local.readiness_trace_rows(self.text(raw),'client',0),[])
        self.assertEqual(local.readiness_trace_rows(self.text(self.row()),'server'),[])
        self.assertEqual(local.readiness_trace_rows('[PROFILE_READINESS] broken','client',0),[])

    def test_optional_values_reject_strings_bools_as_counts_and_fractional_counts(self):
        for key,value in [('phase','secret'),('sync_count',True),('sync_count',1.5),
                          ('avatar_present','true'),('generation',-1)]:
            raw=self.row();raw[key]=value
            with self.subTest(key=key):self.assertEqual(local.readiness_trace_rows(self.text(raw),'client',0),[])

    def test_server_rows_and_row_cap_are_bounded(self):
        raw=self.row();raw.update(role='server',index=-1)
        self.assertEqual(len(local.readiness_trace_rows(self.text(raw),'server')),1)
        text='\n'.join(self.text(self.row()) for _ in range(300))
        self.assertEqual(len(local.readiness_trace_rows(text,'client',0)),192)

    def test_client_and_server_sanitizers_reconstruct_numeric_envelope(self):
        text=self.text(self.row(token='secret',path='/private/secret'))
        clean=vps.sanitized_client_text(text,[])
        self.assertIn('[PROFILE_READINESS]',clean);self.assertNotIn('secret',clean)
        raw=self.row();raw.update(role='server',index=-1,token='secret')
        clean=agent.safe_line(self.text(raw)+'\n')
        self.assertIn('[PROFILE_READINESS]',clean);self.assertNotIn('secret',clean)
        self.assertIsNone(agent.safe_line('[PROFILE_READINESS] {"token":"secret"}\n'))

    def test_explicit_flag_defaults_off_and_forwards_to_both_roles(self):
        self.assertFalse(self.cli().readiness_trace)
        self.assertTrue(self.cli('--readiness-trace').readiness_trace)
        args=(local.Account('fixture','fixture'),0,'compare30','8.8.8.8',Path('/tmp/fixture'),None,15,True)
        self.assertNotIn('NOIKAR_PROFILE_READINESS_TRACE',vps.remote_client_env(*args))
        self.assertEqual(vps.remote_client_env(*args,readiness_trace=True)['NOIKAR_PROFILE_READINESS_TRACE'],'1')
        self.assertNotIn('NOIKAR_PROFILE_READINESS_TRACE',agent.server_benchmark_env(self.config(),Path('/tmp/fixture')))
        self.assertEqual(agent.server_benchmark_env(self.config(readiness_trace=True),Path('/tmp/fixture'))['NOIKAR_PROFILE_READINESS_TRACE'],'1')
        for value in ('1',1,None):
            with self.subTest(value=value),self.assertRaises(ValueError):agent.validate_config(self.config(readiness_trace=value))
        with self.assertRaises(ValueError):vps.remote_client_env(*args,readiness_trace=1)

    def test_nine_owners_do_not_unlock_ten_readiness(self):
        rows=[dict(index=i,owner=i+2,team=1 if i<5 else 2) for i in range(10)]
        self.assertTrue(local.verified_owners(rows,10))
        self.assertFalse(local.verified_owners(rows[:9],10))
        self.assertFalse(local.verified_owners([dict(row,owner=2) for row in rows],10))

    def test_source_contract_observes_without_rpc_or_phase_write(self):
        repo=local.repo_root_from_script();helper=(repo/'common/benchmark_readiness_trace.gd').read_text()
        self.assertIn('const MAX_ROWS := 192',helper);self.assertIn('const POLL_SECONDS := 1.0',helper)
        self.assertIn('weakref(node)',helper);self.assertIn('node_removed',helper)
        self.assertNotIn('.rpc',helper);self.assertNotIn('NetworkTime',helper)
        self.assertNotIn('class_name',helper)
        probe=(repo/'tests/manual/live_gameplay_probe.gd').read_text()
        self.assertIn('const FLOW_TIMEOUT_SEC := 45.0',probe)
        self.assertIn('NOIKAR_PROFILE_READINESS_TRACE',probe)
        self.assertIn('"OWNER_READY index=%d owner=%d team=%d"'.replace('"',''),probe)
        self.assertIn('_trace_stage(8)',probe)

if __name__=='__main__':unittest.main()
