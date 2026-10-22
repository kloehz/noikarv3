#!/usr/bin/env python3
"""Linux stdlib benchmark lease/observer. JSON stdin; never credentials in argv.

Only the explicit unique scratch root, recorded PID/starttime/PGIDs and a tagged
source-/32 TCP rule are owned. No production service or broad process commands.
"""
from __future__ import annotations
import fcntl
import hashlib
import ipaddress
import json
import os
import re
import shutil
import signal
import socket
import statistics
import subprocess
import sys
import tarfile
import time
from contextlib import contextmanager
from pathlib import Path

RUNTIME = '/tmp/noikar-netfox-runtime-3b27e4bea14f/Godot_v4.8-dev6_linux.x86_64'
VERSION = '4.8.dev6.official.8898c2b3d'
RUNTIME_SHA256 = '7343548b1af2f853618e42af6d3923be6680a71c1adcd40a9d2ee064c327445a'
RELEASE_SHA256 = '3882af22b056e688cd94c71d827870723363422514c912fa261a5f5eb0c4913e'
RELEASE_BYTES = 78002600
NORAY_SHA = 'cc3377ea75dd2dedfbf5dbfd02799d42c0808dc7a76c08a2482661a441411686'
TCP_PORTS = (24689, 24691, 24692)
UDP_PORTS = (24690, 24693, *range(24600, 24640))


def workload_plan(config):
    values = {key: config.get(key, default) for key, default in
              (('player_count', 20), ('sample_windows', 3), ('sample_seconds', 30), ('warmup_seconds', 10))}
    if any(type(value) is not int for value in values.values()):
        raise ValueError('integer workload counts/durations required')
    if tuple(values.values()) not in ((20, 3, 30, 10), (10, 1, 30, 5)):
        raise ValueError('use historical REAL20/3x30/10s or explicit REAL10/1x30/5s')
    return dict(values, team_size=values['player_count'] // 2)


def runtime_identity(config):
    kind = config.get('runtime_kind', 'editor')
    if kind == 'editor':
        return kind, RUNTIME_SHA256, 'Godot_v4.8-dev6_linux.x86_64'
    if kind == 'export_template_release':
        return kind, RELEASE_SHA256, 'linux_release.x86_64'
    raise ValueError('runtime kind must be editor or explicit export_template_release')


def validate_runtime(config):
    kind, expected_sha, basename = runtime_identity(config)
    runtime = config.get('runtime', RUNTIME)
    if not isinstance(runtime, str) or not re.fullmatch(
            r'/tmp/noikar-netfox-runtime-[a-f0-9]{12}/' + re.escape(basename), runtime):
        raise ValueError('runtime must be in the exact owned matched-runtime namespace')
    required = ('runtime', 'runtime_version', 'runtime_sha256')
    if (runtime != RUNTIME or kind != 'editor') and not all(key in config for key in required):
        raise ValueError('new runtime binding requires explicit path/version/SHA256 tuple')
    if config.get('runtime_version', VERSION) != VERSION or config.get('runtime_sha256', expected_sha) != expected_sha:
        raise ValueError('runtime version/SHA256 is not the verified official binary for its kind')
    return runtime


def verify_runtime_file(config):
    runtime = Path(validate_runtime(config))
    kind, expected_sha, _ = runtime_identity(config)
    if (runtime.is_symlink() or runtime.parent.is_symlink() or not runtime.is_file()
            or hashlib.sha256(runtime.read_bytes()).hexdigest() != expected_sha
            or (kind == 'export_template_release' and runtime.stat().st_size != RELEASE_BYTES)):
        raise RuntimeError('matched runtime unavailable or byte identity changed; re-stage before running')
    return str(runtime)


def stage_release_runtime(root, config):
    if runtime_identity(config)[0] != 'export_template_release':
        return
    source = Path(verify_runtime_file(config))
    executable, adjacent_pack = root/'server.x86_64', root/'server.pck'
    if any(path.exists() or path.is_symlink() for path in (executable, adjacent_pack)):
        raise RuntimeError('canonical per-arm runtime destination already exists')
    shutil.copyfile(source, executable)
    executable.chmod(0o700)
    os.link(root/'game.pck', adjacent_pack)
    verify_canonical_release(root, config)


def verify_canonical_release(root, config):
    executable, pack = root/'server.x86_64', root/'server.pck'
    if (root.is_symlink() or any(path.is_symlink() or not path.is_file() for path in (executable, pack))
            or executable.stat().st_size != RELEASE_BYTES
            or hashlib.sha256(executable.read_bytes()).hexdigest() != RELEASE_SHA256
            or hashlib.sha256(pack.read_bytes()).hexdigest() != config.get('pck_sha256')):
        raise RuntimeError('canonical owned Release executable/adjacent PCK identity changed')
    return str(executable)


def game_command(root, config):
    if runtime_identity(config)[0] == 'export_template_release':
        return [verify_canonical_release(root, config), '--headless', '--', '--server']
    return [verify_runtime_file(config), '--headless', '--main-pack', str(root/'game.pck'), '--', '--server']


# This envelope is deliberately numeric/boolean-only, including unknown as null.
READINESS_COUNTS = ('phase','players','mobs','expected_mobs','connected_peers','generation','entity_kind',
                    'sync_count','initialized_sync_count','replica_ack_count')
READINESS_BOOLEANS = ('in_game','avatar_present','owned_state_present','owned_sync_present',
                      'owned_sync_initialized','selection_gate_open','workload_gate_open','initialized','history_available')

def sanitize_readiness_row(row, role=None, index=None):
    if not isinstance(row,dict):return None
    actual_role=row.get('role'); actual_index=row.get('index')
    if actual_role not in ('client','server') or (role is not None and actual_role != role):return None
    if type(actual_index) is not int or not (-1 <= actual_index < 20):return None
    if (actual_role=='server') != (actual_index==-1) or (index is not None and actual_index!=index):return None
    bounds={'schema':(1,1),'row':(0,191),'event':(0,3),'stage':(0,12),
            'uptime_usec':(0,2**63-1),'unix_usec':(0,2**63-1)}
    for key,(lo,hi) in bounds.items():
        if type(row.get(key)) is not int or not lo <= row[key] <= hi:return None
    if type(row.get('cap_reached')) is not bool:return None
    clean={key:row[key] for key in ('schema','role','index','row','event','stage','uptime_usec','unix_usec','cap_reached')}
    for key in READINESS_COUNTS:
        if key not in row:continue
        value=row[key]
        if value is not None and (type(value) is not int or value < (-1 if key=='phase' else 0)):return None
        clean[key]=value
    for key in READINESS_BOOLEANS:
        if key not in row:continue
        value=row[key]
        if value is not None and type(value) is not bool:return None
        clean[key]=value
    return clean

def replication_profile(config):
    profile = config.get('replication_profile', 'baseline')
    if profile not in ('baseline', 'diff_ack_100ms'):
        raise ValueError('invalid opt-in replication profile')
    return profile


def server_benchmark_env(config, root):
    tuning = replication_profile(config)
    plan = workload_plan(config)
    env = dict(NOIKAR_PERF_PROBE='1', NOIKAR_PERF_PROBE_NPC_COST='1', NOIKAR_NETFOX_PROFILE=config['profile'],
        NOIKAR_SERVER_MAX_FPS='75', NOIKAR_NPC_SNAPSHOT_HZ='30' if config['profile']=='compare30' else '60',
        NOIKAR_BENCHMARK_PLAYER_LIMIT=str(plan['player_count']), NOIKAR_PROFILE_FIXED_POPULATION='1',
        NOIKAR_PROFILE_MOB_COUNT='20', NOIKAR_PROFILE_WINDOW_COUNT=str(plan['sample_windows']),
        NOIKAR_PROFILE_WARMUP_SEC=str(float(plan['warmup_seconds'])), NOIKAR_PROFILE_START_FILE=str(root/'start-workload'))
    if type(config.get('readiness_trace', False)) is not bool:raise ValueError('readiness trace requires boolean')
    if config.get('readiness_trace', False):env['NOIKAR_PROFILE_READINESS_TRACE']='1'
    if tuning != 'baseline':env['NOIKAR_REPLICATION_PROFILE']=tuning
    return env


def validate_config(config):
    replication_profile(config)
    if type(config.get('readiness_trace', False)) is not bool:raise ValueError('readiness trace requires boolean')
    for key, default in (('preparation_seconds',5),('active_seconds',150),('cleanup_seconds',30)):
        if type(config.get(key,default)) is not int: raise ValueError('integer budgets required')
    host = ipaddress.IPv4Address(config['host'])
    if not host.is_global or config['profile'] not in ('compare30', 'compare60'):
        raise ValueError('invalid public address/comparison profile')
    validate_runtime(config)
    workload_plan(config)
    if not str(config['node']).startswith('/'):
        raise ValueError('missing absolute Node path')
    if config.get('preparation_seconds', 5) not in (5, 15):
        raise ValueError('preparation seconds must be5 or15')
    if config.get('active_seconds', 150) != 150 or config.get('cleanup_seconds', 30) != 30:
        raise ValueError('lease must be150 active+30 cleanup')
    return config


def owned_root(value):
    root = Path(value)
    if not re.fullmatch(r'/tmp/noikar-netfox-bench-[a-f0-9]{12}', str(root)) or root.is_symlink():
        raise ValueError('invalid owned scratch root')
    return root


def parse_proc_stat(text, hz, page_size):
    # comm may contain spaces and ')' characters; fields after the LAST ')' are fixed.
    end = text.rfind(')')
    pid = int(text[:text.find(' ')])
    fields = text[end+2:].split()
    if end < 0 or len(fields) < 22 or hz <= 0 or page_size <= 0:
        raise ValueError('invalid /proc stat')
    return dict(pid=pid, ppid=int(fields[1]), pgid=int(fields[2]), starttime=int(fields[19]),
                cpu_seconds=(int(fields[11])+int(fields[12]))/hz,
                rss_kib=int(fields[21])*page_size/1024, state=fields[0])


def process_sample(pid):
    start = time.time_ns()//1000
    try:
        path = Path('/proc')/str(int(pid))
        row = parse_proc_stat((path/'stat').read_text(), os.sysconf('SC_CLK_TCK'), os.sysconf('SC_PAGE_SIZE'))
        row['uid'] = path.stat().st_uid
    except (FileNotFoundError, ProcessLookupError):
        return None
    end = time.time_ns()//1000
    return dict(row, unix_usec=(start+end)//2, read_begin_unix_usec=start, read_end_unix_usec=end)


def same_identity(expected, current):
    return current is not None and all(type(expected.get(k)) is int and expected[k] == current.get(k)
                                       for k in ('pid', 'starttime', 'pgid', 'uid'))


def host_counters():
    fields = Path('/proc/stat').read_text().splitlines()[0].split()[1:]
    values = [int(x) for x in fields]
    # Linux guest fields are already included in user/nice; do not double count.
    return dict(total=sum(values[:8]), idle=values[3]+values[4], steal=values[7])


def host_delta(before, after):
    delta = after['total']-before['total']
    if delta <= 0:
        raise RuntimeError('host CPU counter unavailable')
    return dict(idle_percent=100*(after['idle']-before['idle'])/delta,
                steal_percent=100*(after['steal']-before['steal'])/delta)


def memory_row():
    values = {}
    for line in Path('/proc/meminfo').read_text().splitlines():
        key, value = line.split(':', 1)
        values[key] = int(value.strip().split()[0])
    return dict(mem_available_kib=values['MemAvailable'], mem_total_kib=values['MemTotal'],
                available_percent=100*values['MemAvailable']/values['MemTotal'])


def runtime_guard(host, memory, rss, bad_intervals):
    if memory['available_percent'] < 20 or rss > 1.5*1024*1024:
        raise RuntimeError('VPS memory/owned RSS guard')
    bad = host['idle_percent'] < 10 or host['steal_percent'] > 30
    count = bad_intervals+1 if bad else 0
    if count >= 6:
        raise RuntimeError('VPS host idle/steal guard for6 intervals')
    return count


def port_inventory():
    rows = []
    for protocol in ('tcp', 'tcp6', 'udp', 'udp6'):
        for line in Path('/proc/net', protocol).read_text().splitlines()[1:]:
            fields = line.split()
            port = int(fields[1].split(':')[1], 16)
            # Ignore TCP TIME_WAIT; a listener or UDP bound socket remains a blocker.
            if port in (TCP_PORTS if protocol.startswith('tcp') else UDP_PORTS) and (not protocol.startswith('tcp') or fields[3] == '0A'):
                rows.append(dict(protocol=protocol, port=port))
    return rows


def preflight(config):
    validate_config(config)
    runtime = verify_runtime_file(config)
    for executable, expected in ((runtime, VERSION), (config['node'], 'v20.19.2')):
        result = subprocess.run([executable, '--version'], capture_output=True, text=True, timeout=5, check=True)
        if result.stdout.strip() != expected:
            raise RuntimeError('matched runtime/Node version unavailable')
    occupied = port_inventory()
    if occupied:
        raise RuntimeError('required isolated port already bound')
    samples=[]; before=host_counters()
    for _ in range(15):
        time.sleep(1); after=host_counters()
        samples.append(dict(host_delta(before, after), **memory_row())); before=after
    disk=shutil.disk_usage('/tmp').free
    ok=(statistics.median(r['idle_percent'] for r in samples) >= 70
        and statistics.median(r['steal_percent'] for r in samples) <= 10
        and min(r['mem_available_kib'] for r in samples) >= 2*1024*1024 and disk >= 1024**3)
    return dict(ok=ok, samples=samples, disk_free_bytes=disk, runtime_version=VERSION, runtime_sha256=runtime_identity(config)[1], runtime_kind=runtime_identity(config)[0],
                node_version='v20.19.2', preparation_actual_seconds=15)


@contextmanager
def state_lock(root):
    with (root/'lock').open('a') as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        data=json.loads((root/'manifest.json').read_text())
        yield data
        private_json(root/'manifest.json', data)


def private_json(path, data):
    tmp=path.with_suffix(path.suffix+'.new')
    with tmp.open('w') as handle:
        os.chmod(tmp, 0o600); json.dump(data, handle)
    os.replace(tmp, path)


def safe_extract(archive, destination):
    with tarfile.open(archive) as tar:
        for member in tar.getmembers():
            path=destination/member.name
            if member.isdev() or member.isfifo() or not path.resolve().is_relative_to(destination.resolve()):
                raise ValueError('unsafe closure member')
            if member.issym() or member.islnk():
                target=(path.parent/member.linkname if member.issym() else destination/member.linkname).resolve()
                if not target.is_relative_to(destination.resolve()):
                    raise ValueError('escaping closure symlink')
            if any(part in ('.env', '.git') for part in Path(member.name).parts):
                raise ValueError('secret/VCS member refused')
        tar.extractall(destination, filter='data')


def staged_spawner(text):
    # Staged closure ONLY: keep creator-ticket hooks/security; transport secrets via env.
    for line in ('    `--provision-token=${provision.provisionToken}`,\n',
                 '    `--room-creator-ticket=${provision.roomCreatorTicket}`,\n',
                 '    `--provision-instance-id=${provision.provisionInstanceId}`,\n'):
        if text.count(line) != 1:
            raise ValueError('Noray spawner source differs from verified closure')
        text=text.replace(line, '')
    needle='      NOIKAR_WORLD_SERVER_CREDENTIAL: provision.worldServerCredential,'
    if text.count(needle) != 1:
        raise ValueError('Noray credential hook absent')
    return text.replace(needle, needle+'\n      NOIKAR_PROVISION_TOKEN: provision.provisionToken,\n      NOIKAR_ROOM_CREATOR_TICKET: provision.roomCreatorTicket,\n      NOIKAR_PROVISION_INSTANCE_ID: provision.provisionInstanceId,')


def rule_prefix():
    return ['/usr/sbin/ufw'] if os.geteuid() == 0 else ['sudo', '-n', '/usr/sbin/ufw']


def cleanup_timeout(deadline, maximum=5):
    if deadline is None:return maximum
    remaining=deadline-time.monotonic()
    if remaining<=0:raise TimeoutError('owned cleanup deadline exhausted')
    return min(maximum,remaining)


def rule_status(deadline=None):
    return subprocess.run(rule_prefix()+['status'],capture_output=True,text=True,check=True,
                          timeout=cleanup_timeout(deadline)).stdout


def own_rule_lines(text, rule):
    return [line for line in text.splitlines() if rule['tag'] in line]


def rule_spec(rule):
    ip=ipaddress.IPv4Address(rule['source'])
    if not ip.is_global or not re.fullmatch(r'noikar-bench-[a-f0-9]{12}', rule['tag']):
        raise ValueError('invalid source/tag')
    return ['proto', 'tcp', 'from', str(ip)+'/32', 'to', 'any', 'port', '24691']


def rule_matches(text, rule):
    rows=own_rule_lines(text, rule)
    return len(rows)==1 and '24691/tcp' in rows[0] and rule['source'] in rows[0] and 'ALLOW' in rows[0]


def add_rule(root, allow):
    if not allow:
        raise RuntimeError('explicit reviewed temporary-firewall flag required')
    parts=os.environ.get('SSH_CONNECTION', '').split()
    source=str(ipaddress.IPv4Address(parts[0])) if parts else ''
    rule=dict(source=source, tag='noikar-bench-'+root.name.rsplit('-',1)[-1])
    rule_spec(rule)
    status=rule_status()
    if 'Status: active' not in status or any('24691' in line and 'tcp' in line for line in status.splitlines()):
        raise RuntimeError('UFW active/absent-rule prerequisite failed')
    # Persist intent BEFORE mutation, so the autonomous watchdog can reconcile a disconnect.
    with state_lock(root) as data: data['rule']=rule
    subprocess.run(rule_prefix()+['allow']+rule_spec(rule)+['comment', rule['tag']],
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=5, check=True)
    if not rule_matches(rule_status(), rule):
        raise RuntimeError('owned firewall rule readback failed')
    return dict(source_prefix_sha256=hashlib.sha256(source.encode()).hexdigest(), tcp_port=24691, owned=True)


def remove_rule(rule, deadline=None):
    status=rule_status() if deadline is None else rule_status(deadline)
    if not own_rule_lines(status, rule): return True
    if not rule_matches(status, rule): return False
    # Delete by EXACT spec, never a mutable rule index or broad port deletion.
    subprocess.run(rule_prefix()+['--force', 'delete', 'allow']+rule_spec(rule),
                   stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, timeout=cleanup_timeout(deadline), check=True)
    return not own_rule_lines(rule_status() if deadline is None else rule_status(deadline), rule)


def safe_line(line):
    if line.startswith('[PROFILE_READINESS] '):
        try:row=sanitize_readiness_row(json.loads(line.split(' ',1)[1]),'server')
        except ValueError:return None
        return '[PROFILE_READINESS] '+json.dumps(row)+'\n' if row is not None else None
    prefixes=('[PROFILE_CAPACITY] {', '[PROFILE_TRANSPORT] {', '[NETFOX_PROFILE] {', '[PERF] ', '[PROFILE_POPULATION_READY] ',
              '[PROFILE_POPULATION_FAILED] ', '[PROFILE_SERVER_WINDOW] ', '[PROFILE_SERVER_OBSERVATION] ')
    if line.startswith(prefixes) and len(line) <= 65536:
        return line
    if re.search(r'\b(ERROR|SCRIPT ERROR|FAILED)\b', line):
        return '[BENCHMARK_RUNTIME_ERROR] game/script/network error observed\n'
    return None


def register_process(root, proc, role):
    row=process_sample(proc.pid)
    if row is None or row['pgid'] != proc.pid:
        raise RuntimeError('owned session leader identity unavailable')
    with state_lock(root) as data:
        if data.get('stop_requested'): raise RuntimeError('lease stopping')
        data['processes'].append(dict(row, role=role))
    return row


def launch_game(root):
    data=json.loads((root/'manifest.json').read_text())
    command=game_command(root, data['config'])
    if data.get('stop_requested') or time.time() >= data['active_until_unix']:
        raise RuntimeError('lease expired before server launch')
    # Inherited auth fields are environment-only; this argv is secret-free.
    with state_lock(root) as state:
        if state.get('stop_requested') or time.time() >= state['active_until_unix']:
            raise RuntimeError('lease stopping before spawn')
        proc=subprocess.Popen(command,
                              cwd=root, env=os.environ.copy(), stdin=subprocess.DEVNULL,
                              stdout=subprocess.PIPE, stderr=subprocess.STDOUT, start_new_session=True, text=True)
        identity=process_sample(proc.pid)
        if identity is None or identity['pgid'] != proc.pid:
            proc.terminate();raise RuntimeError('spawn identity unavailable')
        state['processes'].append(dict(identity, role='server'))
    with (root/'server-safe.log').open('a', buffering=1) as log:
        os.chmod(root/'server-safe.log', 0o600)
        for line in proc.stdout:
            sanitized=safe_line(line)
            if sanitized: log.write(sanitized)
            if log.tell() > 8*1024*1024:
                with state_lock(root) as state: state['stop_requested']=True;state['failure']='sanitized log budget exceeded'
                break
    return proc.wait(timeout=5)


def initialize(root, config):
    validate_config(config)
    archive=root/'noray-runtime.tar.gz'
    if hashlib.sha256(archive.read_bytes()).hexdigest() != NORAY_SHA:
        raise RuntimeError('Noray closure checksum mismatch')
    pack=root/'game.pck'
    if pack.stat().st_size >= 1024**3 or hashlib.sha256(pack.read_bytes()).hexdigest() != config['pck_sha256']:
        raise RuntimeError('PCK checksum/size mismatch')
    stage_release_runtime(root, config)
    safe_extract(archive, root)
    spawner=root/'noray-runtime/src/hosts/host.spawner.mjs'
    original=spawner.read_text();spawner.write_text(staged_spawner(original))
    launcher=root/'game-launcher'
    launcher.write_text('#!/bin/sh\nexec /usr/bin/python3 '+str(root/'agent.py')+' game '+str(root)+'\n')
    launcher.chmod(0o700)
    # Staged launcher has no adjacent pck, so Noray passes --path; wrapper ignores
    # these harmless arguments and uses the verified PCK. Creator security stays normal.
    private_json(root/'manifest.json', dict(schema=1, root=str(root), config=config, processes=[],
        initialized=True, stop_requested=False, rule=None, completion=None,
        original_spawner_sha256=hashlib.sha256(original.encode()).hexdigest(),
        staged_spawner_sha256=hashlib.sha256(spawner.read_bytes()).hexdigest()))
    return dict(initialized=True, pck_bytes=pack.stat().st_size, closure_sha256=NORAY_SHA)


def start(root, request):
    data=json.loads((root/'manifest.json').read_text());config=data['config']
    if data.get('active_until_unix') or data.get('completion'):
        raise RuntimeError('single-use arm lease already started')
    now=time.time()
    with state_lock(root) as state:
        state['active_until_unix']=now+150;state['cleanup_until_unix']=now+180
    # Watchdog is detached with all stdio closed BEFORE firewall or game services.
    watchdog=subprocess.Popen(['/usr/bin/python3', str(root/'agent.py'), 'watchdog', str(root)],
        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True, close_fds=True)
    with state_lock(root) as state: state['watchdog']=process_sample(watchdog.pid)
    rule=add_rule(root, request.get('allow_firewall') is True)
    provisioner=request['provisioner']
    if not isinstance(provisioner,str) or len(provisioner)<32: raise ValueError('invalid ephemeral provisioner')
    env=dict(PATH='/usr/bin:/bin', HOME=str(root), LANG='C.UTF-8',
        NOIKAR_BENCHMARK_REMOTE='1', NOIKAR_NORAY_HOST=config['host'], NOIKAR_NORAY_PORT='24691',
        NOIKAR_NORAY_REGISTRAR_PORT='24693', NOIKAR_NORAY_BIND_PORT='24690',
        NOIKAR_BACKEND_URL='http://127.0.0.1:24689', NOIKAR_PROVISIONER_CREDENTIAL=provisioner,
        GODOT_EXECUTABLE_PATH=str(root/'game-launcher'), GODOT_PROJECT_PATH=str(root),
        NORAY_SOCKET_HOST='0.0.0.0',NORAY_SOCKET_PORT='24691',NORAY_HTTP_HOST='127.0.0.1',NORAY_HTTP_PORT='24692',
        NORAY_UDP_RELAY_PORTS='24600-24639', NORAY_UDP_REGISTRAR_PORT='24693', NORAY_LOGLEVEL='silent',
        **server_benchmark_env(config, root))
    private_json(root/'environment.json', env)
    with state_lock(root) as state:
        if state.get('stop_requested') or time.time() >= state['active_until_unix']:
            raise RuntimeError('lease stopping before Noray')
        proc=subprocess.Popen([config['node'], 'bin/noray.mjs'], cwd=root/'noray-runtime',env=env,
            stdin=subprocess.DEVNULL,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,start_new_session=True,close_fds=True)
        identity=process_sample(proc.pid)
        if identity is None or identity['pgid'] != proc.pid:
            proc.terminate();raise RuntimeError('spawn identity unavailable')
        state['processes'].append(dict(identity,role='noray'))
    return dict(started=True, firewall=rule, active_seconds=150, inclusive_lease_seconds=180)


def cleanup(root, reason):
    started=time.monotonic();errors=[];unresolved=[];remaining=None;firewall_clear=False
    with state_lock(root) as data:
        data['stop_requested']=True
        processes=list(data['processes']);rule=data['rule']
        lease_remaining=max(0,data.get('cleanup_until_unix',time.time()+30)-time.time())
    deadline=started+min(30,lease_remaining)
    def current_owned(identity):
        row=process_sample(identity['pid'])
        if same_identity(identity,row):return row
        # A new starttime proves PID reuse: never signal the foreign successor.
        # A still-live original whose UID/PGID changed is unproved ownership.
        if row is not None and row.get('starttime')==identity['starttime'] and row.get('state')!='Z':
            if identity['pid'] not in unresolved:unresolved.append(identity['pid'])
            errors.append('owned process identity changed')
        return None
    def any_owned_alive():
        for identity in processes:
            row=current_owned(identity)
            if row is not None and row['state']!='Z':return True
        return False
    try:
        for sig,seconds in ((signal.SIGTERM,6),(signal.SIGKILL,2)):
            for identity in reversed(processes):
                try:
                    cleanup_timeout(deadline,1)
                    row=current_owned(identity)
                    if row is not None and row['state']!='Z':os.killpg(identity['pgid'],sig)
                except ProcessLookupError:
                    pass  # Expected sample->signal disappearance; idempotent.
                except Exception as exc:errors.append('signal '+type(exc).__name__)
            until=min(deadline,time.monotonic()+seconds)
            while time.monotonic()<until and any_owned_alive():
                time.sleep(min(.1,until-time.monotonic()))
        for identity in processes:
            row=current_owned(identity)
            if row is not None and row['state']!='Z' and identity['pid'] not in unresolved:
                unresolved.append(identity['pid'])
    except Exception as exc:
        errors.append('process teardown '+type(exc).__name__)
        unresolved=list({*unresolved,*(p['pid'] for p in processes)})
    finally:
        # Rule and completion are independent of process teardown success. Never
        # lose the firewall cleanup because an owned process disappeared/error'd.
        try:
            firewall_clear=remove_rule(rule,deadline=deadline) if rule else True
        except Exception as exc:
            errors.append('rule cleanup '+type(exc).__name__)
        try:
            cleanup_timeout(deadline,1)
            remaining=[row for row in port_inventory() if row['port']!=24689]
        except Exception as exc:
            errors.append('port readback '+type(exc).__name__)
        try:(root/'environment.json').unlink(missing_ok=True)
        except Exception as exc:errors.append('credential cleanup '+type(exc).__name__)
        expired=time.monotonic()>=deadline
        completion=dict(reason=reason,completed_unix_usec=time.time_ns()//1000,
            actual_cleanup_seconds=time.monotonic()-started,shared_cleanup_budget_seconds=30,
            cleanup_budget_exhausted=expired,errors=errors,
            owned_processes_clear=not unresolved,unresolved_owned_pids=unresolved,
            temporary_rule_clear=firewall_clear,benchmark_ports_clear=remaining==[],
            remaining_benchmark_ports=remaining,
            ok=not unresolved and firewall_clear and remaining==[] and not errors and not expired)
        with state_lock(root) as data:data['completion']=completion
    return completion


def watchdog(root):
    before=host_counters();bad=0;rows=[];failure=None
    try:
        while True:
            data=json.loads((root/'manifest.json').read_text())
            if data.get('stop_requested') or time.time()>=data['active_until_unix']: break
            time.sleep(1);after=host_counters();host=host_delta(before,after);before=after
            memory=memory_row();readings=[]
            for identity in data['processes']:
                row=process_sample(identity['pid'])
                if same_identity(identity,row): readings.append(dict(row,role=identity['role']))
                elif identity['role']=='server': raise RuntimeError('owned server exited or identity changed')
            if data.get('watchdog'):
                watch=process_sample(data['watchdog']['pid'])
                if same_identity(data['watchdog'],watch): readings.append(dict(watch,role='observer'))
            rss=sum(row['rss_kib'] for row in readings)
            bad=runtime_guard(host,memory,rss,bad)
            rows.append(dict(unix_usec=time.time_ns()//1000,host=host,memory=memory,owned_rss_kib=rss,processes=readings))
            private_json(root/'observations.json', rows)
    except Exception as exc:
        failure=str(exc)
    finally:
        if failure:
            with state_lock(root) as data:data['failure']=failure
        cleanup(root,failure or 'requested stop/active lease expired')


def status(root):
    data=json.loads((root/'manifest.json').read_text())
    rows=json.loads((root/'observations.json').read_text()) if (root/'observations.json').exists() else []
    return dict(schema=1, failure=data.get('failure'), completion=data.get('completion'),
        processes=[{k:p[k] for k in ('pid','pgid','starttime','uid','role')} for p in data['processes']],
        observations=rows, server_text=(root/'server-safe.log').read_text() if (root/'server-safe.log').exists() else '',
        active_until_unix=data.get('active_until_unix'))


def main():
    action=sys.argv[1] if len(sys.argv)>1 else 'request'
    if action in ('game','watchdog'):
        root=owned_root(sys.argv[2]);return launch_game(root) if action=='game' else watchdog(root)
    request=json.load(sys.stdin);action=request['action']
    if action=='preflight': result=preflight(request['config'])
    elif action=='reserve':
        root=owned_root(request['root']);root.mkdir(mode=0o700,exist_ok=False);result=dict(reserved=True)
    else:
        root=owned_root(request['root'])
        if not root.is_dir() or root.stat().st_uid!=os.getuid(): raise ValueError('scratch ownership unavailable')
        if action=='initialize':result=initialize(root,request['config'])
        elif action=='start':result=start(root,request)
        elif action=='workload':
            data=json.loads((root/'manifest.json').read_text())
            if data.get('stop_requested') or time.time()>=data['active_until_unix']: raise RuntimeError('expired workload lease')
            (root/'start-workload').write_text('ordinary workload intentions\n');result=dict(released=True)
        elif action=='stop':
            with state_lock(root) as data:data['stop_requested']=True
            result=dict(stop_requested=True)
        elif action=='status':result=status(root)
        else:raise ValueError('unsupported action')
    print(json.dumps(result))

if __name__=='__main__':
    try: result=main();sys.exit(result if isinstance(result,int) else 0)
    except Exception:
        # Do not print raw command/environment/credential exception contents.
        print(json.dumps(dict(ok=False,error='benchmark agent action failed')),file=sys.stderr);sys.exit(1)
