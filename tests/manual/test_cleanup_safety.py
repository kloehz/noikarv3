"""Deterministic owned-cleanup fixtures; no services, SSH, sockets or signals."""
import json
import signal
import subprocess
import tempfile
import unittest
from contextlib import ExitStack
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock, patch

import profile_room_scaling as local
import profile_vps as vps
import vps_benchmark_agent as agent


class FakeClock:
    def __init__(self):
        self.now = 0.0

    def monotonic(self):
        return self.now

    def sleep(self, seconds):
        if seconds < 0:
            raise AssertionError('negative wait')
        self.now += seconds

    def time(self):
        return 1000 + self.now

    def time_ns(self):
        return int(self.time() * 1_000_000_000)

    def install(self, stack):
        # Both modules use the same stdlib time object.
        for name in ('monotonic', 'sleep', 'time', 'time_ns'):
            stack.enter_context(patch.object(vps.time, name, getattr(self, name)))


class ClosedSocket:
    def __enter__(self):
        return self

    def __exit__(self, *_):
        return False

    def settimeout(self, seconds):
        if seconds <= 0:
            raise AssertionError('non-positive timeout')

    def connect_ex(self, address):
        return 111


def plan(processes=(), container=None, volume=None):
    return SimpleNamespace(processes=list(processes), server_pids=set(), container=container,
                           volume=volume, log_files=[Mock()], keep_artifacts=True)


class CleanupSafetyTests(unittest.TestCase):
    def test_shared_stop_local_then_completion_order_and_remaining_timeout(self):
        clock = FakeClock()
        calls = []

        def request(action, timeout):
            calls.append((action, clock.now, timeout))
            clock.sleep(1)
            return {'stop_requested': True} if action == 'stop' else {'completion': {'ok': True}}

        def teardown(_plan, deadline):
            calls.append(('local', clock.now, deadline))
            clock.sleep(25)
            return {'ok': True}

        with ExitStack() as stack:
            clock.install(stack)
            stack.enter_context(patch.object(vps, 'cleanup_owned_local', side_effect=teardown))
            result = vps.finish_cleanup(SimpleNamespace(request=request), plan(), True, {})
        self.assertEqual([x[0] for x in calls], ['stop', 'local', 'status'])
        self.assertEqual(calls[0][2], 3)
        self.assertEqual(calls[1][2], 30)
        self.assertEqual(calls[2][2], 4)
        self.assertEqual(result['actual_seconds'], 27)
        self.assertTrue(result['ok'])
        self.assertTrue(vps.cleanup_qualified(True, True, result))

    def test_completion_timeout_cannot_add_twenty_seconds_after_local_cleanup(self):
        clock = FakeClock()
        timeouts = []

        def request(action, timeout):
            timeouts.append((action, timeout))
            if action == 'stop':
                clock.sleep(2)
                return {'stop_requested': True}
            clock.sleep(timeout)
            raise subprocess.TimeoutExpired('sanitized-fixture', timeout)

        def teardown(_plan, deadline):
            self.assertEqual(deadline, 30)
            clock.sleep(25)
            return {'ok': True}

        with ExitStack() as stack:
            clock.install(stack)
            stack.enter_context(patch.object(vps, 'cleanup_owned_local', side_effect=teardown))
            result = vps.finish_cleanup(SimpleNamespace(request=request), plan(), True, {})
        self.assertEqual(timeouts, [('stop', 3), ('status', 3)])
        self.assertEqual(result['actual_seconds'], 30)
        self.assertTrue(result['deadline_exhausted'])
        self.assertFalse(vps.cleanup_qualified(True, True, result))

    def test_stop_exception_and_unproved_local_cleanup_fail_even_with_remote_completion(self):
        for cause in ('stop_exception', 'stop_unproved', 'local_exception', 'local_unproved', 'remote_failure'):
            with self.subTest(cause=cause), ExitStack() as stack:
                clock = FakeClock()
                clock.install(stack)
                def request(action, timeout):
                    if action == 'stop':
                        if cause == 'stop_exception':
                            raise TimeoutError('fixture')
                        return {'stop_requested': cause != 'stop_unproved'}
                    return {'completion': {'ok': True}, 'failure': 'fixture' if cause == 'remote_failure' else None}
                if cause == 'local_exception':
                    stack.enter_context(patch.object(vps, 'cleanup_owned_local', side_effect=OSError('fixture')))
                else:
                    stack.enter_context(patch.object(vps, 'cleanup_owned_local', return_value={'ok': cause != 'local_unproved'}))
                result = vps.finish_cleanup(SimpleNamespace(request=request), plan(), True, {})
                self.assertFalse(result['ok'])
                self.assertFalse(vps.cleanup_qualified(True, True, result))

    def test_missing_completion_stops_at_shared_deadline_and_unarmed_is_not_qualified(self):
        clock = FakeClock()
        remote = Mock()
        remote.request.side_effect = lambda action, timeout: {'stop_requested': True} if action == 'stop' else {}
        with ExitStack() as stack:
            clock.install(stack)
            stack.enter_context(patch.object(vps, 'cleanup_owned_local', return_value={'ok': True}))
            result = vps.finish_cleanup(remote, plan(), True, {})
            self.assertEqual(result['actual_seconds'], 30)
            self.assertIsNone(result['remote_completion'])
            self.assertFalse(result['ok'])
            remote.reset_mock()
            self.assertFalse(vps.finish_cleanup(remote, plan(), False, {})['ok'])
            remote.request.assert_not_called()

    def test_actual_overrun_is_retained_and_cannot_qualify(self):
        clock = FakeClock()
        def teardown(_plan, deadline):
            clock.sleep(30.25)
            return {'ok': True}
        with ExitStack() as stack:
            clock.install(stack)
            stack.enter_context(patch.object(vps, 'cleanup_owned_local', side_effect=teardown))
            remote = Mock()
            remote.request.return_value = {'stop_requested': True}
            result = vps.finish_cleanup(remote, plan(), True, {})
        self.assertEqual(result['actual_seconds'], 30.25)
        self.assertTrue(result['deadline_exhausted'])
        self.assertFalse(vps.cleanup_qualified(True, True, result))
        self.assertFalse(vps.cleanup_qualified(False, True, {'ok': True, 'actual_seconds': 1}))
        self.assertFalse(vps.cleanup_qualified(True, False, {'ok': True, 'actual_seconds': 1}))
        self.assertFalse(vps.cleanup_qualified(True, True, {'ok': True}))

    def test_local_docker_calls_use_one_remaining_budget_and_owned_names_only(self):
        clock = FakeClock()
        clock.now = 17
        calls = []
        def command(argv, timeout, **kwargs):
            calls.append((argv, timeout, clock.now))
            clock.sleep(timeout)
            return SimpleNamespace(returncode=0)
        owned = plan(container='owned-fixture', volume='owned-volume')
        with ExitStack() as stack:
            clock.install(stack)
            stack.enter_context(patch.object(vps.subprocess, 'run', side_effect=command))
            stack.enter_context(patch.object(vps.socket, 'socket', side_effect=ClosedSocket))
            result = vps.cleanup_owned_local(owned, 30)
        self.assertEqual(calls, [(['docker', 'rm', '-f', 'owned-fixture'], 8, 17),
                                 (['docker', 'volume', 'rm', '-f', 'owned-volume'], 5, 25)])
        self.assertEqual(clock.now, 30)
        self.assertTrue(result['deadline_exhausted'])
        self.assertFalse(result['ok'])
        self.assertTrue(all(x is None for x in result['loopback_ports_clear'].values()))
        owned.log_files[0].close.assert_called_once()

    def test_local_process_disappearance_idempotent_and_changed_group_rejected(self):
        for disappears in (True, False):
            with self.subTest(disappears=disappears), ExitStack() as stack:
                clock = FakeClock()
                clock.install(stack)
                state = {'alive': True}
                proc = SimpleNamespace(pid=77, poll=lambda: None if state['alive'] else 0)
                def pgid(pid):
                    if disappears:
                        state['alive'] = False
                        raise ProcessLookupError()
                    return 88
                stack.enter_context(patch.object(vps.os, 'getpgid', side_effect=pgid))
                kill = stack.enter_context(patch.object(vps.os, 'killpg'))
                stack.enter_context(patch.object(vps.socket, 'socket', side_effect=ClosedSocket))
                result = vps.cleanup_owned_local(plan([proc]), 30)
                kill.assert_not_called()
                self.assertEqual(result['ok'], disappears)
                self.assertLessEqual(clock.now, 8)

    def remote_fixture(self, stack, identity=None, rule=None, lease_seconds=180):
        clock = FakeClock()
        clock.install(stack)
        directory = stack.enter_context(tempfile.TemporaryDirectory())
        root = Path(directory)
        agent.private_json(root/'manifest.json', dict(processes=[identity] if identity else [], rule=rule,
                           cleanup_until_unix=clock.time()+lease_seconds))
        (root/'environment.json').write_text('ephemeral fixture')
        stack.enter_context(patch.object(agent, 'port_inventory', return_value=[]))
        return root, clock

    def test_remote_sample_signal_disappearance_still_removes_rule_and_records_completion(self):
        identity = dict(pid=77, starttime=999, pgid=77, uid=1000, state='S')
        with ExitStack() as stack:
            root, clock = self.remote_fixture(stack, identity, {'fixture': True})
            alive = {'value': True}
            stack.enter_context(patch.object(agent, 'process_sample', side_effect=lambda pid: identity if alive['value'] else None))
            def disappear(*args):
                alive['value'] = False
                raise ProcessLookupError()
            kill = stack.enter_context(patch.object(agent.os, 'killpg', side_effect=disappear))
            remove = stack.enter_context(patch.object(agent, 'remove_rule', return_value=True))
            result = agent.cleanup(root, 'fixture')
            self.assertTrue(result['ok'])
            kill.assert_called_once_with(77, signal.SIGTERM)
            remove.assert_called_once_with({'fixture': True}, deadline=30)
            self.assertEqual(json.loads((root/'manifest.json').read_text())['completion'], result)
            self.assertFalse((root/'environment.json').exists())

    def test_remote_teardown_error_cannot_skip_rule_or_completion_finally(self):
        identity = dict(pid=77, starttime=999, pgid=77, uid=1000, state='S')
        for cause in ('sample_error', 'signal_error', 'rule_error'):
            with self.subTest(cause=cause), ExitStack() as stack:
                root, clock = self.remote_fixture(stack, identity, {'fixture': True})
                stack.enter_context(patch.object(agent, 'process_sample', side_effect=OSError('fixture') if cause == 'sample_error' else None,
                                                return_value=identity))
                stack.enter_context(patch.object(agent.os, 'killpg', side_effect=PermissionError('fixture')))
                remove = stack.enter_context(patch.object(agent, 'remove_rule', side_effect=TimeoutError('fixture') if cause == 'rule_error' else None,
                                                         return_value=True))
                result = agent.cleanup(root, 'fixture')
                remove.assert_called_once()
                self.assertFalse(result['ok'])
                self.assertTrue(result['errors'])
                self.assertEqual(json.loads((root/'manifest.json').read_text())['completion'], result)
                self.assertFalse((root/'environment.json').exists())
                self.assertLessEqual(clock.now, 8)

    def test_remote_changed_uid_group_or_pid_starttime_never_signaled(self):
        identity = dict(pid=77, starttime=999, pgid=77, uid=1000, state='S')
        for fields in ({'uid': 0}, {'pgid': 88}, {'starttime': 1000}):
            with self.subTest(fields=fields), ExitStack() as stack:
                root, clock = self.remote_fixture(stack, identity)
                stack.enter_context(patch.object(agent, 'process_sample', return_value=identity | fields))
                kill = stack.enter_context(patch.object(agent.os, 'killpg'))
                result = agent.cleanup(root, 'fixture')
                kill.assert_not_called()
                self.assertEqual(result['ok'], 'starttime' in fields)
                self.assertEqual(result['owned_processes_clear'], 'starttime' in fields)

    def test_remote_lease_remainder_caps_waits_and_rule_commands(self):
        identity = dict(pid=77, starttime=999, pgid=77, uid=1000, state='S')
        with ExitStack() as stack:
            root, clock = self.remote_fixture(stack, identity, {'fixture': True}, lease_seconds=3)
            stack.enter_context(patch.object(agent, 'process_sample', return_value=identity))
            stack.enter_context(patch.object(agent.os, 'killpg'))
            deadlines = []
            def remove(rule, deadline):
                deadlines.append(deadline)
                agent.cleanup_timeout(deadline)
                return True
            stack.enter_context(patch.object(agent, 'remove_rule', side_effect=remove))
            result = agent.cleanup(root, 'fixture')
            self.assertEqual(clock.now, 3)
            self.assertEqual(deadlines, [3])
            self.assertTrue(result['cleanup_budget_exhausted'])
            self.assertFalse(result['temporary_rule_clear'])
            self.assertIsNone(result['remaining_benchmark_ports'])
            self.assertFalse(result['ok'])

    def test_rule_delete_uses_remaining_timeout_and_default_remains_five(self):
        clock = FakeClock()
        rule = dict(source='8.8.8.8', tag='noikar-bench-123456abcdef')
        line = '24691/tcp ALLOW 8.8.8.8 # noikar-bench-123456abcdef'
        calls = []
        def command(argv, timeout, **kwargs):
            calls.append((argv, timeout))
            clock.sleep(1)
            return SimpleNamespace(stdout=line if len(calls) == 1 else 'Status: active')
        with ExitStack() as stack:
            clock.install(stack)
            stack.enter_context(patch.object(agent, 'rule_prefix', return_value=['fixture-ufw']))
            stack.enter_context(patch.object(agent.subprocess, 'run', side_effect=command))
            self.assertTrue(agent.remove_rule(rule, deadline=3))
            self.assertEqual([x[1] for x in calls], [3, 2, 1])
            self.assertIn('8.8.8.8/32', calls[1][0])
            self.assertNotIn('reset', calls[1][0])
            self.assertEqual(agent.cleanup_timeout(None), 5)
            with self.assertRaises(TimeoutError):
                agent.cleanup_timeout(3)

    def test_local_ordinary_cleanup_methods_remain_inherited_and_unused(self):
        clock = FakeClock()
        owned = local.CleanupPlan(keep_artifacts=True)
        with ExitStack() as stack:
            clock.install(stack)
            legacy = stack.enter_context(patch.object(local.CleanupPlan, 'run', side_effect=AssertionError('legacy cleanup used')))
            stack.enter_context(patch.object(vps.socket, 'socket', side_effect=ClosedSocket))
            self.assertTrue(vps.cleanup_owned_local(owned, 30)['ok'])
            legacy.assert_not_called()


if __name__ == '__main__':
    unittest.main()
