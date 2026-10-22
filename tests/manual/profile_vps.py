#!/usr/bin/env python3
"""One isolated VPS arm: historical REAL20/3x30s or explicit short REAL10/5v5.

Explicit --execute/--allow-temporary-firewall are required. No production API,
Noray, runtime replacement, simultaneous arms, or credential argv/logging.
"""
from __future__ import annotations
import argparse
import hashlib
import ipaddress
import json
import os
import re
import secrets
import signal
import shlex
import shutil
import socket
import subprocess
import sys
import tempfile
import time
from pathlib import Path
import profile_room_scaling as local
import vps_benchmark_agent as agent
import package_vps_benchmark as package_builder


def parse_args(argv=None):
    parser=argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binding',type=Path,required=True,help='private0600 SSH binding outside checkout')
    parser.add_argument('--package',type=Path,required=True,help='new PCK package directory with manifest.json')
    parser.add_argument('--noray-closure',type=Path,required=True)
    parser.add_argument('--node',required=True,help='already installed VPS absolute Node20.19.2 path')
    parser.add_argument('--netfox-profile',choices=['compare30','compare60'],required=True)
    parser.add_argument('--player-count',type=int,choices=[10,20],default=20)
    parser.add_argument('--sample-windows',type=int,choices=[1,3],default=3)
    parser.add_argument('--sample-seconds',type=int,choices=[30],default=30,help='seconds per measured window')
    parser.add_argument('--warmup-seconds',type=int,choices=[5,10],default=10)
    parser.add_argument('--preparation-timeout-seconds',type=int,choices=[5,15],default=5)
    parser.add_argument('--dedupe-phase-trace',action='store_true')
    parser.add_argument('--replication-profile',choices=['baseline','diff_ack_100ms'],default='baseline',help='explicit ACK tuning experiment; count ACK bytes before claiming savings')
    parser.add_argument('--readiness-trace',action='store_true',help='bounded opt-in readiness/lifetime observations, not a gameplay fix')
    parser.add_argument('--godot',type=Path,default=Path('/Applications/Godot.app/Contents/MacOS/Godot'))
    parser.add_argument('--output',type=Path,required=True,help='NEW sanitized result path; never overwrite history')
    parser.add_argument('--execute',action='store_true')
    parser.add_argument('--allow-temporary-firewall',action='store_true')
    args=parser.parse_args(argv)
    try: agent.workload_plan(vars(args))
    except ValueError as exc: parser.error(str(exc))
    return args


def runtime_binding_fields(binding):
    names=('runtime_path','runtime_version','runtime_sha256')
    present=[name in binding for name in names]
    if any(present) and not all(present):
        raise ValueError('runtime binding requires all three identity fields')
    fields=(dict(runtime=binding['runtime_path'],runtime_version=binding['runtime_version'],runtime_sha256=binding['runtime_sha256'])
            if all(present) else dict(runtime=agent.RUNTIME,runtime_version=agent.VERSION,runtime_sha256=agent.RUNTIME_SHA256))
    if "runtime_kind" in binding:
        fields["runtime_kind"] = binding["runtime_kind"]
    agent.validate_runtime(fields)
    return fields


def generator_guard(total, measured, player_count, consecutive):
    if (type(player_count) is not int or player_count not in (10,20)
            or type(measured) is not int or not 0 <= measured <= player_count):
        raise ValueError('invalid generator observation count')
    if measured != player_count:
        return None, 0
    return total, consecutive + 1 if total >= 850 else 0


def load_binding(path, repo):
    if path.stat().st_mode & 0o777 != 0o600 or path.resolve().is_relative_to(repo.resolve()):
        raise ValueError('binding must be0600 outside checkout')
    data=json.loads(path.read_text())
    if not re.fullmatch(r'[A-Za-z0-9_.@-]+',data['target']):raise ValueError('invalid SSH target')
    host=ipaddress.IPv4Address(data['endpoint'])
    if not host.is_global:raise ValueError('public IPv4 binding required')
    for key in ('ssh_config_path','known_hosts_path'):
        if not Path(data[key]).is_file():raise ValueError('binding SSH files unavailable')
    runtime_binding_fields(data)
    return data


class Remote:
    def __init__(self,binding,root):
        self.binding=binding;self.root=root
        self.options=['-F',binding['ssh_config_path'],'-o','UserKnownHostsFile='+binding['known_hosts_path'],
            '-o','StrictHostKeyChecking=yes','-o','BatchMode=yes','-o','ConnectTimeout=8']
        self.bootstrap=Path(agent.__file__).read_text()
        self.ready=False

    def request(self,action,timeout=10,**fields):
        payload=dict(action=action,root=self.root,**fields)
        command=('python3 '+shlex.quote(self.root+'/agent.py') if self.ready else
                 'python3 -c '+shlex.quote(self.bootstrap))
        result=subprocess.run(['ssh',*self.options,self.binding['target'],command],
            input=json.dumps(payload),capture_output=True,text=True,timeout=timeout)
        if result.returncode:raise RuntimeError('remote '+action+' action failed (exit '+str(result.returncode)+')')
        value=json.loads(result.stdout)
        if value.get('ok') is False:raise RuntimeError('remote '+action+' refused')
        return value

    def upload(self,files,timeout):
        result=subprocess.run(['scp',*self.options,*map(str,files),self.binding['target']+':'+self.root+'/'],
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=timeout)
        if result.returncode:raise RuntimeError('secret-free payload upload failed')
        self.ready=True

    def forward(self,cleanup,tmp):
        # Both SSH listeners bind LOOPBACK explicitly; no wildcard reverse backend.
        return local.start_process(['ssh',*self.options,'-o','ExitOnForwardFailure=yes','-N',
            '-R','127.0.0.1:24689:127.0.0.1:18090','-L','127.0.0.1:24692:127.0.0.1:24692',self.binding['target']],
            cwd=tmp,env=local.complete_env({}),log_path=tmp/'ssh-forward.log',cleanup=cleanup)


def remote_client_env(account,index,profile,host,tmp,oid,preparation,dedupe,*,
                      player_count=20,sample_windows=3,sample_seconds=30,warmup_seconds=10,readiness_trace=False,replication_profile="baseline"):
    if type(readiness_trace) is not bool:raise ValueError('readiness trace requires boolean')
    plan=agent.workload_plan(dict(player_count=player_count,sample_windows=sample_windows,
                                 sample_seconds=sample_seconds,warmup_seconds=warmup_seconds))
    env=local.client_probe_env(account=account,lobby_hold_seconds=0,warmup_seconds=float(warmup_seconds),sample_seconds=float(sample_seconds*sample_windows),
        mob_count=20,player_count=plan['player_count'],player_index=index,room_oid=oid,release_file=tmp/'release',
        netfox_profile=profile,selection_file=tmp/'selection',start_file=tmp/'start',observe_clients=True,
        preparation_timeout_seconds=preparation,dedupe_phase_trace=dedupe)
    env.update(NOIKAR_BENCHMARK_REMOTE='1',NOIKAR_NORAY_HOST=host,NOIKAR_NORAY_PORT='24691',
               NOIKAR_NORAY_REGISTRAR_PORT='24693',NOIKAR_NORAY_BIND_PORT='0')
    if readiness_trace:env['NOIKAR_PROFILE_READINESS_TRACE']='1'
    tuning=agent.replication_profile(dict(replication_profile=replication_profile))
    if tuning != "baseline":env["NOIKAR_REPLICATION_PROFILE"]=tuning
    return env


def sanitized_client_text(text,known):
    allowed=('[LIVE-PROBE] ','[PROFILE_PHASE] ','[PROFILE_CLIENT_OBSERVATION] ',
             '[PROFILE_CLIENT_CLOCK] ','[PROFILE_CAPACITY] ','[NETFOX_PROFILE] ')
    rows=[]
    for line in text.splitlines():
        if line.startswith('[PROFILE_READINESS] '):
            for row in local.readiness_trace_rows(line,'client'):
                rows.append('[PROFILE_READINESS] '+json.dumps(row))
        elif line.startswith(allowed):rows.append(local.redact(line,known))
        elif re.search(r'\b(ERROR|SCRIPT ERROR|FAILED)\b',line):rows.append('[BENCHMARK_RUNTIME_ERROR] client error observed')
    return '\n'.join(rows)+'\n'


def validate_package(package,repo):
    manifest=json.loads((package/'manifest.json').read_text());pack=package/'game.pck'
    if manifest.get('godot_version')!=agent.VERSION or pack.stat().st_size>=1024**3:
        raise ValueError('package runtime/size mismatch')
    if hashlib.sha256(pack.read_bytes()).hexdigest()!=manifest['pck_sha256']:raise ValueError('PCK changed')
    for path,digest in manifest['source_sha256'].items():
        source=package_builder.safe_resource(repo,path)
        if not source.is_file() or hashlib.sha256(source.read_bytes()).hexdigest()!=digest:
            raise ValueError('source snapshot drift; rebuild package before running')
    return manifest


def public_ready(host,port,deadline):
    while time.monotonic()<deadline:
        with socket.socket() as sock:
            sock.settimeout(1)
            if sock.connect_ex((host,port))==0:return
        time.sleep(.5)
    raise RuntimeError('source-scoped public Noray control not reachable')



def cleanup_timeout(deadline, maximum):
    remaining=deadline-time.monotonic()
    if remaining <= 0:
        raise TimeoutError('shared cleanup deadline exhausted')
    return min(maximum, remaining)


def cleanup_owned_local(plan, deadline):
    """VPS-only teardown; inherited ordinary CleanupPlan defaults are untouched."""
    errors=[];docker_clear=dict(container=plan.container is None, volume=plan.volume is None)
    def signal_groups(sig):
        for proc in reversed(plan.processes):
            if proc.poll() is not None:continue
            try:
                cleanup_timeout(deadline,1)
                # start_process creates a new session. A changed group is never
                # accepted just because a stale integer PID appears in our list.
                if os.getpgid(proc.pid) != proc.pid:
                    errors.append('local process group ownership mismatch');continue
                os.killpg(proc.pid,sig)
            except ProcessLookupError:
                pass
            except Exception as exc:
                errors.append('local signal '+type(exc).__name__)
    def wait_groups(maximum):
        until=min(deadline,time.monotonic()+maximum)
        while time.monotonic()<until and any(proc.poll() is None for proc in plan.processes):
            time.sleep(min(.1,until-time.monotonic()))
    try:
        if plan.server_pids:
            errors.append('unexpected local server PID ownership; no signals sent')
        signal_groups(signal.SIGTERM);wait_groups(6)
        signal_groups(signal.SIGKILL);wait_groups(2)
        for kind,command in [('container',['docker','rm','-f',plan.container]),
                             ('volume',['docker','volume','rm','-f',plan.volume])]:
            if command[-1] is None:continue
            try:
                value=subprocess.run(command,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,
                                     timeout=cleanup_timeout(deadline,8))
                docker_clear[kind]=value.returncode==0
                if not docker_clear[kind]:errors.append('owned Docker '+kind+' removal unproved')
            except Exception as exc:
                errors.append('owned Docker '+kind+' '+type(exc).__name__)
        ports={}
        for port in (15432,18090,24692):
            try:
                with socket.socket() as sock:
                    sock.settimeout(cleanup_timeout(deadline,.2))
                    ports[str(port)]=sock.connect_ex(('127.0.0.1',port))!=0
            except Exception as exc:
                ports[str(port)]=None;errors.append('local port readback '+type(exc).__name__)
        alive=[proc.pid for proc in plan.processes if proc.poll() is None]
        if alive:errors.append('owned local process remains')
    except Exception as exc:
        errors.append('local teardown '+type(exc).__name__);ports={};alive=None
    finally:
        for handle in plan.log_files:
            try:handle.close()
            except Exception as exc:errors.append('local log close '+type(exc).__name__)
    expired=time.monotonic()>=deadline
    return dict(ok=not errors and not expired and all(docker_clear.values()) and bool(ports)
                and all(value is True for value in ports.values()),
                deadline_exhausted=expired,errors=errors,remaining_owned_pids=alive,
                docker_clear=docker_clear,loopback_ports_clear=ports)


def finish_cleanup(remote, plan, armed, initial_status):
    """Stop early; remote watchdog cleans while local teardown shares one 30s budget."""
    start=time.monotonic();deadline=start+30;errors=[];status=initial_status;completion=None
    stop_verified=not armed
    if armed:
        try:
            stop_verified=remote.request('stop',timeout=cleanup_timeout(deadline,3)).get('stop_requested') is True
            if not stop_verified:errors.append('remote stop acknowledgement unproved')
        except Exception as exc:errors.append('remote stop '+type(exc).__name__)
    try:local_result=cleanup_owned_local(plan,deadline)
    except Exception as exc:local_result=dict(ok=False,errors=['local cleanup '+type(exc).__name__])
    # No up-front completion wait. Poll ONLY after local teardown and only in
    # the shared remainder. SSH uncertainty never disables the autonomous lease.
    if armed:
        while time.monotonic()<deadline:
            try:
                status=remote.request('status',timeout=cleanup_timeout(deadline,5))
                completion=status.get('completion')
                if completion is not None:break
                time.sleep(cleanup_timeout(deadline,.5))
            except Exception as exc:
                errors.append('remote completion '+type(exc).__name__);break
    elapsed=time.monotonic()-start;expired=time.monotonic()>=deadline
    ok=bool(armed and stop_verified and local_result.get('ok') is True and completion
            and completion.get('ok') is True and not status.get('failure') and not errors and not expired)
    return dict(ok=ok,actual_seconds=elapsed,deadline_exhausted=expired,shared_budget_seconds=30,
                local=local_result,remote_stop_verified=stop_verified,remote_completion=completion,
                remote_status=status,errors=errors)


def cleanup_qualified(metrics_ok, transport_ok, readback):
    return bool(metrics_ok and transport_ok and readback.get('ok') is True
                and not readback.get('deadline_exhausted') and readback.get('actual_seconds',float('inf')) < 30)


def run(argv=None):
    args=parse_args(argv);repo=local.repo_root_from_script()
    if not args.execute or not args.allow_temporary_firewall:
        raise ValueError('explicit execution and reviewed source-scoped firewall flags required')
    if args.output.exists():raise ValueError('result exists; preserve historical reports')
    binding=load_binding(args.binding,repo);manifest=validate_package(args.package,repo)
    if hashlib.sha256(args.noray_closure.read_bytes()).hexdigest()!=agent.NORAY_SHA:raise ValueError('Noray checksum mismatch')
    for port in (15432,18090,24692):
        if not local.port_is_free(port):raise RuntimeError('required disposable local port occupied')
    local.guard_load20(local.memory_free_percent(),0)
    tmp=Path(tempfile.mkdtemp(prefix='noikar-vps-'));tmp.chmod(0o700)
    cleanup=local.CleanupPlan(temp_dir=tmp,keep_artifacts=True)
    root='/tmp/noikar-netfox-bench-'+secrets.token_hex(6);remote=Remote(binding,root)
    plan=agent.workload_plan(vars(args));player_count=plan['player_count']
    config=dict(host=binding['endpoint'],profile=args.netfox_profile,node=args.node,**runtime_binding_fields(binding),
        **{key:plan[key] for key in ('player_count','sample_windows','sample_seconds','warmup_seconds')},
        preparation_seconds=args.preparation_timeout_seconds,active_seconds=150,cleanup_seconds=30,pck_sha256=manifest['pck_sha256'],
        readiness_trace=args.readiness_trace,replication_profile=args.replication_profile)
    clients=[];known=[];previous={};cpu_rows=[];guard_rows=[];last_status={};prepared=False;armed=False
    started=time.monotonic();prepare_deadline=started+120;arm_started=None;failure=None;success=False;completion=None
    result=dict(schema=1,profile=args.netfox_profile,operational=False,qualified=False,
        requested_workload=dict(rooms=1,real_authenticated_clients=player_count,team_size_each=plan['team_size'],fixed_live_mobs=20,
            warmup_seconds=plan['warmup_seconds'],window_count=plan['sample_windows'],window_seconds=plan['sample_seconds'],
            aggregate_sample_seconds=plan['sample_windows']*plan['sample_seconds'],independent_runs=False),
        measurement_scope='short REAL10 single-window measurement, not REAL20 comparison' if player_count==10 else 'REAL20 three consecutive windows',
        budgets=dict(preparation_seconds=120,active_arm_seconds=150,cleanup_seconds=30,inclusive_arm_seconds=180),
        replication_profile=args.replication_profile,runtime_kind=config.get('runtime_kind','editor'),
        readiness_trace_requested=args.readiness_trace,preparation_timeout_seconds=args.preparation_timeout_seconds,cpu_units='percent of one core',rss_units='KiB',
        package_manifest=manifest,source_sha256={p:hashlib.sha256((repo/p).read_bytes()).hexdigest() for p in
            ['tests/manual/profile_vps.py','tests/manual/vps_benchmark_agent.py','tests/manual/profile_room_scaling.py','tests/manual/live_gameplay_probe.gd','backend/cmd/server/main.go']})
    stop=local.StopRequest()
    with local.install_stop_handlers(stop):
      try:
        result['remote_preflight']=remote.request('preflight',timeout=25,config=config)
        if time.monotonic()>=prepare_deadline:raise RuntimeError('preparation budget expired after preflight')
        remote.request('reserve');prepared=True
        shutil.copyfile(Path(agent.__file__),tmp/'agent.py')
        remote.upload([tmp/'agent.py',args.package/'game.pck',args.noray_closure],min(60,prepare_deadline-time.monotonic()))
        result['remote_initialize']=remote.request('initialize',timeout=15,config=config)
        suffix=secrets.token_hex(6);cleanup.container='noikar-vps-pg-'+suffix;cleanup.volume='noikar-vps-pgdata-'+suffix
        subprocess.run(local.postgres_spec(cleanup.container,cleanup.volume).command,check=True,
            stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL,timeout=min(30,prepare_deadline-time.monotonic()))
        local.wait_pg(cleanup.container,min(prepare_deadline,time.monotonic()+30))
        jwt=secrets.token_urlsafe(32);provisioner=secrets.token_urlsafe(32);known.extend([jwt,provisioner])
        local.start_process(['go','run','./cmd/server'],cwd=repo/'backend',
            env=local.complete_env(dict(DATABASE_URL='postgres://postgres@127.0.0.1:15432/postgres?sslmode=disable',
                 BIND_HOST='127.0.0.1',PORT='18090',JWT_SECRET=jwt,PROVISIONER_CREDENTIAL=provisioner)),
            log_path=tmp/'backend.log',cleanup=cleanup)
        local.wait_http('http://127.0.0.1:18090/api/v1/health',min(prepare_deadline,time.monotonic()+45))
        accounts=local.generate_accounts(player_count);known.extend(a.password for a in accounts)
        for account in accounts:
            if time.monotonic()>=prepare_deadline or stop.requested:raise RuntimeError('preparation deadline/stop registering accounts')
            local.register_account('http://127.0.0.1:18090',account,known)
        forward=remote.forward(cleanup,tmp)
        # SSH control readiness must be real, not configured. It is not gameplay readiness.
        for _ in range(10):
            if forward.poll() is not None:raise RuntimeError('SSH forward exited before readiness')
            if not local.port_is_free(24692):break
            time.sleep(.2)
        else:raise RuntimeError('SSH loopback forward not ready')
        if time.monotonic()>=prepare_deadline:raise RuntimeError('cold-start preparation budget expired')
        result['preparation_actual_seconds']=time.monotonic()-started
        arm_started=time.monotonic();deadline=arm_started+150
        # armed BEFORE action: an uncertain SSH outcome must still request stop.
        armed=True;result['remote_start']=remote.request('start',timeout=12,provisioner=provisioner,allow_firewall=True)
        public_ready(binding['endpoint'],24691,min(deadline,time.monotonic()+10))
        def launch(i,oid=None):
            env=remote_client_env(accounts[i],i,args.netfox_profile,binding['endpoint'],tmp,oid,
                args.preparation_timeout_seconds,args.dedupe_phase_trace,readiness_trace=args.readiness_trace,replication_profile=args.replication_profile,
                **{key:plan[key] for key in ('player_count','sample_windows','sample_seconds','warmup_seconds')})
            log=tmp/f'client-{i}.log'
            proc=local.start_process(local.client_command(args.godot,repo,player_count),cwd=repo,env=env,log_path=log,cleanup=cleanup)
            log.chmod(0o600)
            clients.append(local.ClientProcess(index=i,account=accounts[i],process=proc,log_path=log,parser=local.ClientLogParser(20)))
        def refresh():
            for cp in clients:
                cp.parser=local.ClientLogParser(20);cp.parser.feed(cp.log_path.read_text(errors='replace'))
                if cp.process.poll() is not None and cp.end_monotonic is None:cp.end_monotonic=time.monotonic()
        overload=0
        def local_guard():
            nonlocal overload
            process_rows=local.read_process_rows();roots={p.pid for p in cleanup.processes}
            owned=roots|local.descendants(process_rows,roots);rss=sum(r.rss_kb for r in process_rows if r.pid in owned)
            free=local.memory_free_percent();local.guard_load20(free,rss)
            total=0.;measured=0
            for cp in clients:
                reading=local.timed_ps_sample(cp.process.pid);old=previous.get(cp.process.pid);cpu=None
                if reading and old:
                    elapsed=(reading['unix_usec']-old['unix_usec'])/1e6
                    cpu=local.cpu_percent_delta(old['cpu_seconds'],reading['cpu_seconds'],elapsed);total+=cpu;measured+=1
                if reading:previous[cp.process.pid]=reading
                if len(cpu_rows)<180*player_count:cpu_rows.append(dict(index=cp.index,pid=cp.process.pid,sample=reading,cpu_percent_one_core=cpu))
            observed_cpu,overload=generator_guard(total,measured,player_count,overload)
            guard_rows.append(dict(unix_usec=time.time_ns()//1000,free_reclaimable_percent=free,owned_rss_kib=rss,
                generator_cpu_percent_one_core=observed_cpu))
            if overload>=3:raise RuntimeError(f'load{player_count} generator CPU guard >=850% for 3 intervals')
        launch(0)
        oid_deadline=min(deadline,time.monotonic()+30)
        while time.monotonic()<oid_deadline and not stop.requested:
            refresh();local_guard()
            if clients[0].parser.admitted_oid:break
            if clients[0].process.poll() is not None:raise RuntimeError('creator client exited before OID')
            time.sleep(.5)
        if not clients[0].parser.admitted_oid:raise RuntimeError('creator OID preparation timeout')
        for i in range(1,player_count):
            if time.monotonic()>=deadline or stop.requested:raise RuntimeError('arm deadline/stop during normal client ramp')
            local_guard();launch(i,clients[0].parser.admitted_oid);time.sleep(.25)
        selection=False;workload=False;server_text='';frozen_text=None
        while time.monotonic()<deadline and not stop.requested:
            refresh();local_guard();last_status=remote.request('status',timeout=min(8,max(.1,deadline-time.monotonic())))
            server_text=last_status['server_text']
            if last_status.get('failure') or last_status.get('completion'):raise RuntimeError('autonomous VPS lease/guard ended arm')
            if any(cp.process.poll() is not None and not cp.parser.passed for cp in clients):raise RuntimeError('real client failed before completion')
            if not selection and local.verified_owners(local.owner_markers(clients,'SELECTION_PREPARED'),player_count):
                if len({cp.parser.admitted_oid for cp in clients})!=1:raise RuntimeError('different room OIDs')
                (tmp/'selection').write_text('ordinary selection ready\n');selection=True
            markers=local.owner_markers(clients,'OWNER_READY')
            population=local.json_marker_rows(server_text,'owner_population=')
            if not workload and local.verified_owners(markers,player_count) and population:
                ids={m['owner'] for m in markers}
                if local.verified_owner_population(population[-1],ids,player_count):
                    if not local.verified_capacity_readback(server_text,'server',player_count) or not all(local.verified_capacity_readback(cp.log_path.read_text(),'client',player_count) for cp in clients):raise RuntimeError('capacity readback mismatch')
                    remote.request('workload',timeout=5);(tmp/'start').write_text('ordinary workload intentions\n');workload=True
            if local.fixed_workload_completion_seen(clients) and frozen_text is None:frozen_text=server_text
            if all(cp.parser.passed for cp in clients):(tmp/'release').write_text('release\n')
            if all(cp.process.poll() is not None for cp in clients):break
            time.sleep(.5)
        refresh()
        if stop.requested:raise RuntimeError('user interrupted arm')
        if any(cp.process.poll() is None for cp in clients):raise RuntimeError('150s whole-arm deadline expired')
        last_status=remote.request('status',timeout=5);server_text=frozen_text or last_status['server_text']
        readings=[row for interval in last_status['observations'] for row in interval['processes'] if row['role']=='server']
        proof=local.load20_proof(clients,server_text,args.netfox_profile,player_count)
        windows=local.build_consecutive_windows(server_text,readings,args.netfox_profile,player_count,plan['sample_windows'],plan['sample_seconds'])
        for window in windows['windows']:window['cpu_source']='Linux /proc/stat user+system/CLK_TCK, interpolated to same-host native boundaries'
        readback=(local.verify_profile_readback(local.profile_readbacks(server_text),args.netfox_profile,'server') and
            all(local.verify_profile_readback(local.profile_readbacks(cp.log_path.read_text()),args.netfox_profile,'client') for cp in clients))
        stride=local.npc_stride_proof([dict(telemetry=cp.parser.telemetry) for cp in clients],
            30 if args.netfox_profile=='compare30' else 60,20,
            [r for line in server_text.splitlines() if (r:=local.parse_authoritative_stride_interval(line)) is not None],
            netfox_profile=args.netfox_profile,verified_native_hz=(30 if args.netfox_profile=='compare30' else 60) if readback else None)
        clients_ok=all(cp.process.returncode==0 and cp.parser.passed and cp.parser.fixed_workload_ended
            and not cp.parser.active_errors and not cp.parser.metrics.get('dead',True)
            and cp.parser.metrics.get('movement',0)>=1 and cp.parser.metrics.get('mob_displacement',0)>.1
            and cp.parser.metrics.get('max_projectiles',0)>0 and not cp.parser.metrics.get('workload_invalid',True)
            and cp.parser.metrics.get('mobs_start')==20 and cp.parser.metrics.get('mobs_end')==20
            and cp.parser.metrics.get('observed_npcs_within_90m',{}).get('max',0)>0 for cp in clients)
        success=proof['ok'] and windows['ok'] and stride['ok'] and readback and clients_ok and '[BENCHMARK_RUNTIME_ERROR]' not in server_text
        result['load10' if player_count==10 else 'load20']=proof
        result.update(consecutive_windows=windows,npc_stride_observed=stride,
            readback_verified=readback,client_gates_verified=clients_ok,operational=bool(workload),qualified=bool(success))
      except Exception as exc:
        failure=local.redact(str(exc),known);result['failure']=failure
      finally:
        result['active_actual_seconds']=time.monotonic()-arm_started if arm_started is not None else None
        cleanup_result=finish_cleanup(remote,cleanup,armed,last_status)
        last_status=cleanup_result['remote_status'];completion=cleanup_result['remote_completion']
        result['cleanup']= {key:value for key,value in cleanup_result.items() if key!='remote_status'}
        result['cleanup_actual_seconds']=cleanup_result['actual_seconds'];result['remote_completion']=completion
        result['qualified']=False
        if not cleanup_result['ok']:
            result['remote_cleanup']='Cleanup timeout/exception/unproved ownership; autonomous lease remains authoritative; verify completion before next arm'
        result['local_resource_guard']=dict(cpu_ceiling_percent_one_core=850,cpu_intervals=3,
            memory_floor_percent=15,owned_rss_ceiling_kib=8*1024*1024,samples=guard_rows)
        result['remote_observation']=last_status
        result['remote_server_transport']=local.json_marker_rows(last_status.get('server_text',''),'[PROFILE_TRANSPORT] ')
        transport=result['remote_server_transport']
        transport_ok=len(transport)==1 and transport[0].get('server_bind_port')==24690 and transport[0].get('enet_error')==0 and transport[0].get('creator_ticket_validated') is True
        result['remote_server_transport_verified']=transport_ok
        result['qualified']=cleanup_qualified(success,transport_ok,cleanup_result)
        result['observation']=local.observation_artifact(clients,cpu_rows,last_status.get('server_text',''))
        result['server_readiness_trace']=local.readiness_trace_rows(last_status.get('server_text',''),'server')
        result['clients']=[dict(index=cp.index,passed=cp.parser.passed,ready=cp.parser.ready,
            returncode=cp.process.returncode,metrics=cp.parser.metrics,phase_trace=local.safe_phase_trace(cp.log_path.read_text()),
            readiness_trace=local.readiness_trace_rows(cp.log_path.read_text(),'client',cp.index)) for cp in clients]
        result['limitations']=['No production services/runtime modified; one disposable room','One short REAL10 window, not REAL20/three-window comparison' if player_count==10 else 'Three consecutive windows, not independent repetitions',
            'Headless local full-game clients; FishNet caps/physics/prediction/variable population remain non-equivalent',
            'No phase/UI behavior fix or causal claim for original5s failures','CPU /proc boundary interpolation is an estimator; missing metrics null',
            'Actual Linux PCK/Noray20.19.2/auth/firewall/UDP reachability qualification required']
        for cp in clients:cp.log_path.write_text(sanitized_client_text(cp.log_path.read_text(errors='replace'),known))
        for path in (tmp/'backend.log',tmp/'ssh-forward.log'):
            if path.exists():path.unlink()
        args.output.parent.mkdir(parents=True,exist_ok=True)
        with args.output.open('x') as handle:json.dump(result,handle,indent=2)
        print(json.dumps(dict(qualified=result['qualified'],operational=result['operational'],failure=failure,
            cleanup_verified=cleanup_result['ok'],result=str(args.output))))
    return 0 if result['qualified'] else 2

if __name__=='__main__':
    try:sys.exit(run())
    except Exception:print('VPS benchmark preflight/configuration failed; no qualified sample',file=sys.stderr);sys.exit(1)
