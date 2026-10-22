extends Node
## Opt-in process-start configuration. Must be the FIRST autoload: Netfox caches
## ProjectSettings during instance construction, before _ready(). Never live-switch.
const PROFILE_PATH := "res://tools/benchmark_profiles.json"
const PROFILE_ENV := "NOIKAR_NETFOX_PROFILE"
var selected_profile := ""
var settings: Dictionary = {}
var valid := true
var failure := ""
var player_limit := 0
var headless_client := false
var remote_transport := false
var remote_host := ""

static func validate_remote_options(profile: String, options: Dictionary) -> bool:
	var remote := str(options.get("remote", ""))
	if remote.is_empty():
		return str(options.get("registrar", "")).is_empty() and str(options.get("bind_port", "")).is_empty()
	if remote != "1" or profile not in ["compare30", "compare60"] or options.get("limit") not in ["10", "20"] or options.get("perf") != "1":
		return false
	var host := str(options.get("host", ""))
	var octets := host.split(".")
	if octets.size() != 4:
		return false
	for octet in octets:
		if not octet.is_valid_int() or str(octet.to_int()) != octet or octet.to_int() < 0 or octet.to_int() > 255:
			return false
	# A benchmark must advertise the actual public IPv4, not a private substitute.
	var first := int(octets[0]); var second := int(octets[1])
	if first in [0, 10, 127] or first >= 224 or (first == 172 and second >= 16 and second <= 31) or (first == 192 and second == 168) or (first == 169 and second == 254):
		return false
	var client: bool = options.get("client") == "1"
	return options.get("control") == "24691" and options.get("registrar") == "24693" \
		and options.get("bind_port") == ("0" if client else "24690") \
		and options.get("backend") == ("http://127.0.0.1:18090" if client else "http://127.0.0.1:24689")

static func preparation_seconds(value: String, load20: bool) -> float:
	if value in ["", "5"]:
		return 5.0
	return 15.0 if value == "15" and load20 else -1.0

static func server_window_plan(count: String, warmup: String, limit: int, remote: bool) -> Dictionary:
	if count == "3" and warmup == "10.0" and limit == 20:
		return {"window_count": 3, "warmup_seconds": 10.0}
	if count == "1" and warmup == "5.0" and limit == 10 and remote:
		return {"window_count": 1, "warmup_seconds": 5.0}
	return {}


static func trace_transition(last: Dictionary, source: String, phase: int, before: int, after: int, dedupe: bool) -> bool:
	var signature := [phase, before, after]
	if dedupe and last.get(source) == signature:
		return false
	last[source] = signature
	return true


static func validate_load20_options(profile: String, options: Dictionary) -> bool:
	var limit := str(options.get("limit", ""))
	var client := str(options.get("client", ""))
	if limit.is_empty() and client.is_empty():
		return true
	if limit not in ["10", "20"] or client not in ["", "1"] or profile not in ["compare30", "compare60"]:
		return false
	if limit == "10" and options.get("remote") != "1":
		return false
	var expected_backend := "http://127.0.0.1:24689" if options.get("remote") == "1" and client.is_empty() else "http://127.0.0.1:18090"
	if options.get("perf") != "1" or options.get("backend") != expected_backend:
		return false
	if client == "1":
		var index := str(options.get("index", ""))
		return options.get("players") == limit and options.get("expected_mobs") == "20" \
			and options.get("fixed_route") == "1" and index.is_valid_int() \
			and str(index.to_int()) == index and index.to_int() >= 0 and index.to_int() < limit.to_int()
	return options.get("fixed_population") == "1" and options.get("mobs") == "20"

static func capacity_matches(local: int, remote: int) -> bool:
	return local in [0, 10, 20] and local == remote

static func scoped_match_rules(authored: MatchRules, limit: int) -> MatchRules:
	if limit == 0:
		return authored
	if limit not in [10, 20] or authored == null or authored.max_players_per_team != 3:
		return null
	var runtime := authored.duplicate(true) as MatchRules
	runtime.max_players_per_team = int(limit / 2)
	return runtime


static func resolve_selection(args: Array, env: String) -> Dictionary:
	var selected := env
	var seen := false
	for arg in args:
		var text := str(arg)
		if not text.begins_with("--netfox-profile="):
			continue
		var value := text.trim_prefix("--netfox-profile=")
		if seen or value.is_empty() or (not env.is_empty() and env != value):
			return {"valid": false, "profile": ""}
		seen = true
		selected = value
	return {"valid": selected in ["", "compare30", "compare60"], "profile": selected}

static func profile_matches(local: String, remote: String) -> bool:
	return local == remote

static func validate_settings(config: Dictionary, profile: String) -> bool:
	if profile not in ["compare30", "compare60"]:
		return false
	var hz := 30 if profile == "compare30" else 60
	var expected := {"network_hz": hz, "physics_hz": 50, "sync_to_physics": false,
		"server_max_fps": 75, "client_max_fps": 60, "history_ticks": hz * 5,
		"display_offset_ticks": 2, "input_delay_ticks": 0, "input_redundancy": 3,
		"npc_snapshot_hz": hz}
	if config.size() != expected.size():
		return false
	for key in expected:
		if not config.has(key):
			return false
		var kind := typeof(config[key])
		if key == "sync_to_physics":
			if kind != TYPE_BOOL:
				return false
		elif kind not in [TYPE_INT, TYPE_FLOAT]:
			return false
		# JSON numbers are floats. Reject fractions/types without truncating them.
		if config[key] != expected[key]:
			return false
	return true

func _init() -> void:
	if Engine.is_editor_hint():
		return
	var selection := resolve_selection(OS.get_cmdline_user_args(), OS.get_environment(PROFILE_ENV))
	if not selection.valid:
		_reject("expected compare30 or compare60; conflicting/duplicate selections are invalid")
		return
	selected_profile = selection.profile
	var options := {"limit": OS.get_environment("NOIKAR_BENCHMARK_PLAYER_LIMIT"),
		"client": OS.get_environment("NOIKAR_BENCHMARK_CLIENT"),
		"perf": OS.get_environment("NOIKAR_PERF_PROBE"), "backend": OS.get_environment("NOIKAR_BACKEND_URL"),
		"players": OS.get_environment("NOIKAR_PROFILE_PLAYER_COUNT"), "index": OS.get_environment("NOIKAR_PROFILE_PLAYER_INDEX"),
		"expected_mobs": OS.get_environment("NOIKAR_PROFILE_EXPECTED_MOB_COUNT"),
		"fixed_route": OS.get_environment("NOIKAR_PROFILE_FIXED_ROUTE"),
		"fixed_population": OS.get_environment("NOIKAR_PROFILE_FIXED_POPULATION"), "mobs": OS.get_environment("NOIKAR_PROFILE_MOB_COUNT"),
		"remote": OS.get_environment("NOIKAR_BENCHMARK_REMOTE"), "host": OS.get_environment("NOIKAR_NORAY_HOST"),
		"control": OS.get_environment("NOIKAR_NORAY_PORT"), "registrar": OS.get_environment("NOIKAR_NORAY_REGISTRAR_PORT"),
		"bind_port": OS.get_environment("NOIKAR_NORAY_BIND_PORT")}
	if not validate_remote_options(selected_profile, options):
		_reject("invalid benchmark-only remote transport contract")
		return
	remote_transport = options.remote == "1"
	remote_host = str(options.host) if remote_transport else ""
	if not validate_load20_options(selected_profile, options):
		_reject("benchmark load requires explicit comparison profile, validated transport and exact player/mob limits")
		return
	player_limit = int(options.limit) if options.limit in ["10", "20"] else 0
	headless_client = options.client == "1"
	if headless_client and OS.has_feature("dedicated_server"):
		_reject("dedicated-server export cannot act as a benchmark client")
		return
	if selected_profile.is_empty():
		return
	var document = JSON.parse_string(FileAccess.get_file_as_string(PROFILE_PATH))
	if not document is Dictionary or document.get("schema_version") != 1:
		_reject("invalid benchmark profile manifest")
		return
	var catalog = document.get("profiles")
	if not catalog is Dictionary or not catalog.get(selected_profile) is Dictionary:
		_reject("invalid benchmark profile manifest")
		return
	settings = catalog[selected_profile]
	var hz := 30 if selected_profile == "compare30" else 60
	if not validate_settings(settings, selected_profile):
		_reject("manifest does not match supported profile contract")
		return
	for entry in [["NOIKAR_NPC_SNAPSHOT_HZ", str(hz)], ["NOIKAR_SERVER_MAX_FPS", "75"]]:
		var override := OS.get_environment(entry[0])
		if not override.is_empty() and override != entry[1]:
			_reject("conflicting " + entry[0])
			return
	ProjectSettings.set_setting("netfox/time/tickrate", hz)
	ProjectSettings.set_setting("netfox/time/sync_to_physics", false)
	ProjectSettings.set_setting("netfox/time/tickrate_mismatch_action", 1)
	ProjectSettings.set_setting("netfox/rollback/history_limit", int(settings.history_ticks))
	ProjectSettings.set_setting("netfox/rollback/display_offset", 2)
	ProjectSettings.set_setting("netfox/rollback/input_delay", 0)
	ProjectSettings.set_setting("netfox/rollback/input_redundancy", 3)
	Engine.physics_ticks_per_second = 50

func _reject(reason: String) -> void:
	valid = false
	failure = reason
	printerr("[NETFOX_PROFILE] invalid: " + reason)

func before_network_start(is_server: bool) -> bool:
	if player_limit in [10, 20] and ((headless_client and is_server) or DisplayServer.get_name() != "headless"):
		_reject("benchmark load requires headless presentation with an explicit client/server role")
	if not valid:
		get_tree().quit(64)
		return false
	Engine.max_fps = int(settings.server_max_fps if is_server else settings.client_max_fps)
	var actual := readback()
	if int(actual.network_hz) != int(settings.network_hz) or actual.sync_to_physics \
		or int(actual.physics_hz) != 50 or int(actual.history_ticks) != int(settings.history_ticks) \
		or int(actual.display_offset_ticks) != 2 or int(actual.input_delay_ticks) != 0 \
		or int(actual.input_redundancy) != 3:
		_reject("cached Netfox singleton readback differs from requested profile")
		get_tree().quit(64)
		return false
	actual["role"] = "server" if is_server else "client"
	actual["stage"] = "before_network_start"
	printerr("[NETFOX_PROFILE] " + JSON.stringify(actual))
	return true

func readback() -> Dictionary:
	var hz := int(NetworkTime.tickrate)
	return {"profile": selected_profile, "network_hz": hz,
		"remote_transport": remote_transport, "control_port": 24691 if remote_transport else 8890, "registrar_port": 24693 if remote_transport else 8809, "requested_bind_port": (0 if headless_client else 24690) if remote_transport else 0,
		"player_limit": player_limit, "headless_client": headless_client, "display_server": DisplayServer.get_name(),
		"physics_hz": Engine.physics_ticks_per_second, "max_fps": Engine.max_fps,
		"sync_to_physics": NetworkTime.sync_to_physics,
		"history_ticks": NetworkRollback.history_limit,
		"history_ms": 1000.0 * NetworkRollback.history_limit / hz,
		"display_offset_ticks": NetworkRollback.display_offset,
		"display_offset_ms": 1000.0 * NetworkRollback.display_offset / hz,
		"input_delay_ticks": NetworkRollback.input_delay,
		"input_delay_ms": 1000.0 * NetworkRollback.input_delay / hz,
		"input_redundancy": NetworkRollback.input_redundancy,
		"npc_snapshot_hz": hz, "match_snapshot_hz": hz / 6.0,
		"player_full_state_interval_ticks": 8, "player_full_state_interval_ms": 8000.0 / hz,
		"npc_full_state_interval_ticks": 12, "npc_full_state_interval_ms": 12000.0 / hz,
		"stale_input_ms": "not_equivalent", "replicate_queue_ms": "not_equivalent"}
