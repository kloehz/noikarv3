#!/usr/bin/env bash
## Launcher for noikarv3 — wraps the Godot binary so you don't have to
## remember the path. The Godot binary is detected automatically.
##
## Usage:
##   ./play.sh                # open the game as a CLIENT (with display)
##   ./play.sh server         # open the game as a HOST (headless server)
##   ./play.sh tests          # run all GUT tests headless
##   ./play.sh server+client  # headless server in bg, then client window
##   ./play.sh test <name>    # run a single GUT test by substring

set -e

PROJECT_DIR="$(cd "$(dirname "$0")" && pwd)"
GODOT_BIN="/Applications/Godot.app/Contents/MacOS/Godot"

if [[ ! -x "$GODOT_BIN" ]]; then
	echo "Godot binary not found at $GODOT_BIN"
	echo "Edit GODOT_BIN at the top of this script to point at your install."
	exit 1
fi

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
		echo "Use: client | server | server+client | tests | test <pattern>"
		exit 1
		;;
esac