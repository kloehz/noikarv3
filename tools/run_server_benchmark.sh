#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat >&2 <<'USAGE'
Usage:
  tools/run_server_benchmark.sh <A|B|C|D|E|F> -- <explicit server command including --benchmark=<scenario>>

Examples:
  tools/run_server_benchmark.sh A -- godot --headless --path . -- --benchmark=A
  tools/run_server_benchmark.sh E -- ./noikar_server.x86_64 --headless -- --benchmark=E

Samples the owned server child for at least 60 seconds and prints timestamp, PID,
%CPU, RSS KiB, and elapsed time. CPU/RSS are external process metrics; the Godot
[BENCHMARK] log intentionally labels them unavailable.
USAGE
}

if [[ $# -lt 3 ]]; then
  usage
  exit 64
fi

scenario="$1"
shift
case "$scenario" in
A | B | C | D | E | F) ;;
*)
  echo "Invalid scenario '$scenario'; expected A, B, C, D, E, or F." >&2
  exit 64
  ;;
esac

if [[ "${1:-}" != "--" ]]; then
  usage
  exit 64
fi
shift

if [[ $# -eq 0 ]]; then
  usage
  exit 64
fi

benchmark_arg="--benchmark=${scenario}"
found_benchmark_arg=0
for arg in "$@"; do
  if [[ "$arg" == "$benchmark_arg" ]]; then
    found_benchmark_arg=1
    break
  fi
done

if [[ "$found_benchmark_arg" -ne 1 ]]; then
  echo "Command must explicitly include ${benchmark_arg}." >&2
  exit 64
fi

sample_seconds="${NOIKAR_BENCHMARK_SAMPLE_SECONDS:-65}"
if ! [[ "$sample_seconds" =~ ^[0-9]+$ ]]; then
  echo "NOIKAR_BENCHMARK_SAMPLE_SECONDS must be an integer." >&2
  exit 64
fi
if ((sample_seconds < 60)); then
  echo "NOIKAR_BENCHMARK_SAMPLE_SECONDS must be at least 60." >&2
  exit 64
fi

sample_interval="${NOIKAR_BENCHMARK_SAMPLE_INTERVAL:-5}"
if ! [[ "$sample_interval" =~ ^[0-9]+$ ]] || ((sample_interval < 1)); then
  echo "NOIKAR_BENCHMARK_SAMPLE_INTERVAL must be a positive integer." >&2
  exit 64
fi

"$@" &
server_pid=$!

cleanup() {
  local status=$?
  if kill -0 "$server_pid" 2>/dev/null; then
    echo "Stopping owned server child PID ${server_pid}" >&2
    kill "$server_pid" 2>/dev/null || true
    wait "$server_pid" 2>/dev/null || true
  fi
  exit "$status"
}
trap cleanup INT TERM

start_epoch=$(date +%s)
samples=0
cpu_sum="0"
cpu_max="0"
rss_latest=0
rss_max=0

printf 'timestamp,pid,cpu_percent,rss_kib,elapsed\n'
while kill -0 "$server_pid" 2>/dev/null; do
  now=$(date +%s)
  elapsed=$((now - start_epoch))
  ps_line=$(ps -p "$server_pid" -o %cpu= -o rss= -o etime= 2>/dev/null || true)
  if [[ -n "$ps_line" ]]; then
    read -r cpu rss etime <<<"$ps_line"
    timestamp=$(date -u +%Y-%m-%dT%H:%M:%SZ)
    printf '%s,%s,%s,%s,%s\n' "$timestamp" "$server_pid" "$cpu" "$rss" "$etime"
    samples=$((samples + 1))
    cpu_sum=$(awk -v a="$cpu_sum" -v b="$cpu" 'BEGIN { printf "%.2f", a + b }')
    cpu_max=$(awk -v a="$cpu_max" -v b="$cpu" 'BEGIN { printf "%.2f", (b > a ? b : a) }')
    rss_latest="$rss"
    if ((rss > rss_max)); then
      rss_max="$rss"
    fi
  fi
  if ((elapsed >= sample_seconds)); then
    break
  fi
  sleep "$sample_interval"
done

if ((samples == 0)); then
  echo "No process samples collected; server exited before first sample." >&2
else
  cpu_avg=$(awk -v sum="$cpu_sum" -v n="$samples" 'BEGIN { printf "%.2f", sum / n }')
  echo "summary scenario=${scenario} samples=${samples} avg_cpu_percent=${cpu_avg} max_cpu_percent=${cpu_max} latest_rss_kib=${rss_latest} max_rss_kib=${rss_max}"
fi

if kill -0 "$server_pid" 2>/dev/null; then
  kill "$server_pid" 2>/dev/null || true
  wait "$server_pid" 2>/dev/null || true
else
  wait "$server_pid" || true
fi
trap - INT TERM
