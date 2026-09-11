extends GutTest

const MatchManagerScript := preload("res://common/match_manager.gd")
const PerfProbeScript := preload("res://common/perf_probe.gd")
const AIComponentScript := preload("res://core/AIComponent.gd")

func test_benchmark_argument_accepts_only_named_scenarios() -> void:
	assert_eq(MatchManagerScript.benchmark_scenario_from_args(["--benchmark=A"]), "A")
	assert_eq(MatchManagerScript.benchmark_scenario_from_args(["--benchmark=f"]), "F")
	assert_eq(MatchManagerScript.benchmark_scenario_from_args(["--benchmark=Z"]), "")
	assert_eq(MatchManagerScript.benchmark_scenario_from_args([]), "")

func test_benchmark_scenario_config_encodes_required_population_and_client_probe_cases() -> void:
	var scenario_b := MatchManagerScript.benchmark_config_for_scenario("B")
	assert_eq(scenario_b.players, 0)
	assert_eq(scenario_b.mobs, 20)
	assert_false(scenario_b.ai_decisions)
	assert_false(scenario_b.requires_client_probe)

	var scenario_f := MatchManagerScript.benchmark_config_for_scenario("F")
	assert_eq(scenario_f.players, 1)
	assert_eq(scenario_f.mobs, 20)
	assert_true(scenario_f.ai_decisions)
	assert_true(scenario_f.requires_client_probe)
	assert_true(scenario_f.rollback_check)

func test_ai_decision_gate_only_disables_scenario_b() -> void:
	var ai := AIComponentScript.new()
	add_child_autofree(ai)

	assert_true(ai.benchmark_npc_ai_decisions_disabled(["--benchmark=B"]))
	assert_true(ai.benchmark_npc_ai_decisions_disabled(["--benchmark=b"]))
	assert_false(ai.benchmark_npc_ai_decisions_disabled(["--benchmark=C"]))
	assert_false(ai.benchmark_npc_ai_decisions_disabled(["--benchmark=F"]))
	assert_false(ai.benchmark_npc_ai_decisions_disabled([]))

func test_benchmark_perf_line_uses_benchmark_prefix_and_reliable_fields() -> void:
	var probe := PerfProbeScript.new()
	add_child_autofree(probe)
	var line := probe._format_perf_line({
		"scenario": "E",
		"uptime_sec": 65.0,
		"configured_players": 1,
		"configured_mobs": 20,
		"live_players": 1,
		"live_mobs": 20,
		"fps": 60.0,
		"frames": 3000,
		"frame_ms": 1.0,
		"physics_ms": 2.0,
		"physics_ticks_per_second": 60,
		"max_fps": 60,
		"players": 1,
		"entities": 21,
		"rollback_events": 0,
		"rollback_avg_ticks": 0.0,
		"rollback_max_ticks": 0,
		"rollback_nodes_observable": 1,
		"snapshot_nodes_observable": 20,
		"synchronized_entities_observable": 21,
		"netfox": {"rollback_nodes": 1, "sent_state_props": 10},
	})

	assert_true(line.begins_with("[BENCHMARK]"))
	assert_true(line.contains("scenario=E"))
	assert_true(line.contains("uptime_sec=65.0"))
	assert_true(line.contains("configured_players=1"))
	assert_true(line.contains("live_mobs=20"))
	assert_true(line.contains("physics_ticks_per_second=60"))
	assert_true(line.contains("rollback_nodes_observable=1"))
	assert_true(line.contains("snapshot_nodes_observable=20"))
	assert_true(line.contains("sent_state_props=10"))
	assert_true(line.contains("cpu=external"))
	assert_true(line.contains("rss=external"))
