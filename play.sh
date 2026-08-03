#!/usr/bin/env bash
## Launcher for noikarv3 — wraps the Godot binary so you don't have to
## remember the path. The Godot binary is detected automatically.
##
## Usage:
##   ./play.sh                # open the game as a CLIENT (with display)
##   ./play.sh server         # open the game as a HOST (headless server)
##   ./play.sh up server     # verify infra, then start server
##   ./play.sh up client     # verify infra, then start client
##   ./play.sh up server+client
##   ./play.sh status         # print which infra ports are alive
##   ./play.sh server+client  # headless server in bg, then client window
##   ./play.sh tests          # run all GUT tests headless
##   ./play.sh test <name>    # run a single GUT test by substring
##
## Infra contract:
##   - PostgreSQL on 5432   (auth DB; needed for any login flow)
##   - Go backend on 8080   (auth API + room creator tickets)
##   - Noray on 8890        (NAT traversal / port registry / relay)
## `up` and `status` probe these so a missing service gives a clear
## error instead of a confusing ENet timeout.

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"

PG_PORT="${PG_PORT:-5432}"
BACKEND_PORT="${BACKEND_PORT:-8080}"
NORAY_PORT="${NORAY_PORT:-8890}"

if [[ ! -x "$GODOT_BIN" ]]; then
	echo "Godot binary not found at $GODOT_BIN"
	echo "Edit GODOT_BIN at the top of this script to point at your install."
	exit 1
fi

## Returns 0 if a TCP port is open and accepting, non-zero otherwise.
port_open() {
	local port="$1"
	nc -z -G 1 localhost "$port" 2>/dev/null
}

probe_postgres() {
	# Postgres listens on /tmp/.s.PGSQL.<port> or on TCP localhost.
	# Check TCP first; if absent, also try the unix socket path.
	if port_open "$PG_PORT"; then
		printf "ok"
		return 0
	fi
	if [[ -S "/tmp/.s.PGSQL.${PG_PORT}" ]]; then
		printf "ok (socket)"
		return 0
	fi
	printf "DOWN"
	return 1
}

probe_backend() {
	# Backend exposes /api/v1/auth/me (needs auth header but returns 401,
	# which is enough to know the server is up).
	local code
	code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
		"http://127.0.0.1:${BACKEND_PORT}/api/v1/auth/me" 2>/dev/null || echo "000")
	if [[ "$code" == "000" ]]; then
		printf "DOWN"
		return 1
	fi
	printf "ok (HTTP %s)" "$code"
	return 0
}

probe_noray() {
	if port_open "$NORAY_PORT"; then
		printf "ok"
		return 0
	fi
	printf "DOWN"
	return 1
}

## Probes all three infra services and prints a one-line summary per row.
## Returns the number of services that are DOWN.
status_check() {
	local pg be no
	pg=$(probe_postgres) && pg_ok=1 || pg_ok=0
	be=$(probe_backend) && be_ok=1 || be_ok=0
	no=$(probe_noray)   && no_ok=1 || no_ok=0
	echo "Infra status:"
	printf "  postgres (5432)  : %s\n" "$pg"
	printf "  backend  (8080)  : %s\n" "$be"
	printf "  noray    (8890)  : %s\n" "$no"
	local down=$(( (1 - pg_ok) + (1 - be_ok) + (1 - no_ok) ))
	return $down
}

## Probes each service and exits non-zero on the first failure with a
## hint about how to start it. Skips a service that is optional for the
## requested mode (e.g. backend is optional for manual-mode server).
preflight() {
	local mode="${1:-full}"
	local fail=0

	if ! port_open "$PG_PORT" && [[ ! -S "/tmp/.s.PGSQL.${PG_PORT}" ]]; then
		echo "[infra] postgres is DOWN on port ${PG_PORT}."
		echo "       brew services start postgresql@16"
		echo "       or:  cd backend && docker compose up -d"
		fail=1
	else
		echo "[infra] postgres up"
	fi

	if [[ "$mode" != "manual-server" ]]; then
		local code
		code=$(curl -s -o /dev/null -w "%{http_code}" --max-time 2 \
			"http://127.0.0.1:${BACKEND_PORT}/api/v1/auth/me" 2>/dev/null || echo "000")
		if [[ "$code" == "000" ]]; then
			echo "[infra] backend is DOWN on port ${BACKEND_PORT}."
			echo "       cd backend && go run ./cmd/server"
			fail=1
		else
			echo "[infra] backend up (HTTP ${code})"
		fi
	else
		echo "[infra] backend skipped (manual-server mode)"
	fi

	if ! port_open "$NORAY_PORT"; then
		echo "[infra] noray is DOWN on port ${NORAY_PORT}."
		echo "       cd noikar-noray && pnpm start"
		fail=1
	else
		echo "[infra] noray up"
	fi

	if [[ $fail -ne 0 ]]; then
		echo
		echo "Fix the missing services above, then re-run."
		echo "For a quick view: ./play.sh status"
		exit 1
	fi
}

cmd="${1:-client}"

case "$cmd" in
	client|"")
		echo "Starting noikarv3 (CLIENT)..."
		exec "$GODOT_BIN" --path "$PROJECT_DIR"
		;;
	server)
		echo "Starting noikarv3 (HEADLESS SERVER)..."
		exec "$GODOT_BIN" --headless --path "$PROJECT_DIR"
		;;
	up)
		shift
		target="${1:-server}"
		case "$target" in
			server)
				preflight manual-server
				echo "Starting noikarv3 (HEADLESS SERVER)..."
				exec "$GODOT_BIN" --headless --path "$PROJECT_DIR"
				;;
			client)
				preflight
				echo "Starting noikarv3 (CLIENT)..."
				exec "$GODOT_BIN" --path "$PROJECT_DIR"
				;;
			server+client)
				preflight manual-server
				echo "Starting headless server in background..."
				( "$GODOT_BIN" --headless --path "$PROJECT_DIR" ) &
				SERVER_PID=$!
				trap "kill $SERVER_PID 2>/dev/null" EXIT INT TERM
				echo "Server PID $SERVER_PID — give it ~3s to register with Noray."
				sleep 3
				echo "Starting client..."
				"$GODOT_BIN" --path "$PROJECT_DIR"
				;;
			*)
				echo "Unknown target for 'up': $target"
				echo "Use: ./play.sh up server | client | server+client"
				exit 1
				;;
		esac
		;;
	status)
		status_check
		;;
	server+client)
		echo "Starting headless server in background..."
		( "$GODOT_BIN" --headless --path "$PROJECT_DIR" ) &
		SERVER_PID=$!
		trap "kill $SERVER_PID 2>/dev/null" EXIT INT TERM
		echo "Server PID $SERVER_PID — give it ~3s to register with Noray."
		sleep 3
		echo "Starting client..."
		"$GODOT_BIN" --path "$PROJECT_DIR"
		;;
	tests)
		echo "Running all GUT tests..."
		exec "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
			-s addons/gut/gut_cmdln.gd \
			-gdir=res://tests/unit,res://tests/integration \
			-ginclude_subdirs \
			-gexit
		;;
	test)
		shift
		pattern="${1:-.}"
		echo "Running GUT tests matching: $pattern"
		exec "$GODOT_BIN" --headless --path "$PROJECT_DIR" \
			-s addons/gut/gut_cmdln.gd -gselect="$pattern" -gexit
		;;
	*)
		echo "Unknown command: $cmd"
		echo "Use: client | server | up <target> | status | server+client | tests | test <pattern>"
		exit 1
		;;
esac