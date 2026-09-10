extends GutTest

const PERF_PROBE_SCRIPT := preload("res://common/perf_probe.gd")

func test_probe_requires_env_flag_and_headless() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)

	assert_false(probe._should_enable_probe("", true))
	assert_false(probe._should_enable_probe("1", false))
	assert_true(probe._should_enable_probe("1", true))

func test_rollback_summary_counts_only_positive_resimulation_events() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)

	probe._record_rollback_loop(0)
	probe._record_rollback_loop(3)
	probe._record_rollback_loop(1)

	var summary: Dictionary = probe._consume_rollback_summary()
	assert_eq(summary.events, 2)
	assert_eq(summary.avg_ticks, 2.0)
	assert_eq(summary.max_ticks, 3)

	var empty_summary: Dictionary = probe._consume_rollback_summary()
	assert_eq(empty_summary.events, 0)
	assert_eq(empty_summary.avg_ticks, 0.0)
	assert_eq(empty_summary.max_ticks, 0)

func test_perf_line_includes_metrics_and_explicit_limitations() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)
	var metrics := {
		"fps": 60.0,
		"frame_ms": 1.25,
		"physics_ms": 2.5,
		"players": 2,
		"entities": 4,
		"rollback_events": 3,
		"rollback_avg_ticks": 1.5,
		"rollback_max_ticks": 4,
		"netfox": {
			"network_loop_ms": 0.3,
			"rollback_loop_ms": 0.4,
			"rollback_tick_ms": 0.2,
			"rollback_nodes": 5,
			"rollback_nodes_per_tick": 1.25,
			"full_state_props": 12,
			"sent_state_props": 6,
			"sent_state_ratio": 0.5,
		},
	}

	var line: String = probe._format_perf_line(metrics)

	assert_true(line.contains("players=2"))
	assert_true(line.contains("entities=4"))
	assert_true(line.contains("rollback_events=3"))
	assert_true(line.contains("rollback_avg_ticks=1.50"))
	assert_true(line.contains("rollback_max_ticks=4"))
	assert_true(line.contains("network_loop_ms=0.30"))
	assert_true(line.contains("full_state_props=12"))
	assert_true(line.contains("bandwidth_rx_kbps=na"))
	assert_true(line.contains("bandwidth_tx_kbps=na"))
	assert_true(line.contains("cpu=external"))
	assert_true(line.contains("rss=external"))

func test_npc_cost_probe_requires_base_probe_and_explicit_cost_flag() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)

	assert_false(probe._should_enable_npc_costs("", true, "1"))
	assert_false(probe._should_enable_npc_costs("1", false, "1"))
	assert_false(probe._should_enable_npc_costs("1", true, ""))
	assert_true(probe._should_enable_npc_costs("1", true, "1"))

func test_npc_cost_summary_accumulates_bounds_and_resets() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)

	probe._set_npc_cost_recording_for_tests(true)
	probe.record_npc_cost("ai", 10)
	probe.record_npc_cost("ai", 30)
	probe.record_npc_cost("movement", 5)
	probe.record_npc_counter("target_scan", 4)
	probe.record_npc_counter("avoidance", 2)
	probe.record_npc_counter("avoidance", 3)

	var summary: Dictionary = probe._consume_npc_cost_summary()
	assert_eq(summary.ai.total_usec, 40)
	assert_eq(summary.ai.calls, 2)
	assert_eq(summary.ai.max_usec, 30)
	assert_eq(summary.movement.total_usec, 5)
	assert_eq(summary.movement.calls, 1)
	assert_eq(summary.movement.max_usec, 5)
	assert_eq(summary.combat.total_usec, 0)
	assert_eq(summary.target_scan.visits, 4)
	assert_eq(summary.avoidance.visits, 5)

	var empty_summary: Dictionary = probe._consume_npc_cost_summary()
	assert_eq(empty_summary.ai.total_usec, 0)
	assert_eq(empty_summary.target_scan.visits, 0)

func test_npc_cost_summary_ignores_unknown_keys_and_disabled_recording() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)

	probe.record_npc_cost("ai", 99)
	probe.record_npc_counter("target_scan", 99)
	probe._set_npc_cost_recording_for_tests(true)
	probe.record_npc_cost("render", 99)
	probe.record_npc_counter("path_cache", 99)

	var summary: Dictionary = probe._consume_npc_cost_summary()
	assert_eq(summary.ai.total_usec, 0)
	assert_eq(summary.target_scan.visits, 0)

func test_perf_line_includes_npc_cost_summary_with_inclusive_ai_label() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)
	var metrics := {
		"fps": 0.0,
		"frame_ms": 0.0,
		"physics_ms": 0.0,
		"players": 0,
		"entities": 0,
		"rollback_events": 0,
		"rollback_avg_ticks": 0.0,
		"rollback_max_ticks": 0,
		"netfox": {},
		"npc_costs": {
			"ai": {"total_usec": 40, "calls": 2, "max_usec": 30},
			"movement": {"total_usec": 5, "calls": 1, "max_usec": 5},
			"combat": {"total_usec": 7, "calls": 1, "max_usec": 7},
			"target_scan": {"visits": 4},
			"avoidance": {"visits": 5},
		},
	}

	var line: String = probe._format_perf_line(metrics)

	assert_true(line.contains("npc_ai_inclusive_total_usec=40"))
	assert_true(line.contains("npc_ai_inclusive_calls=2"))
	assert_true(line.contains("npc_ai_inclusive_max_usec=30"))
	assert_true(line.contains("npc_movement_inclusive_total_usec=5"))
	assert_true(line.contains("npc_combat_total_usec=7"))
	assert_true(line.contains("npc_target_scan_visits=4"))
	assert_true(line.contains("npc_avoidance_visits=5"))

func test_npc_movement_child_cost_summary_reports_and_resets_under_same_opt_in_flag() -> void:
	var probe := PERF_PROBE_SCRIPT.new()
	add_child_autofree(probe)

	probe._set_npc_cost_recording_for_tests(true)
	probe.record_npc_cost(&"movement", 100)
	probe.record_npc_cost(&"movement_prepare", 10)
	probe.record_npc_cost(&"movement_slide", 20)
	probe.record_npc_cost(&"movement_flush", 30)

	var summary: Dictionary = probe._consume_npc_cost_summary()
	assert_eq(summary.movement.total_usec, 100)
	assert_eq(summary.movement.calls, 1)
	assert_eq(summary.movement_prepare.total_usec, 10)
	assert_eq(summary.movement_prepare.calls, 1)
	assert_eq(summary.movement_slide.total_usec, 20)
	assert_eq(summary.movement_slide.calls, 1)
	assert_eq(summary.movement_flush.total_usec, 30)
	assert_eq(summary.movement_flush.calls, 1)

	var line: String = probe._format_perf_line({
		"fps": 0.0,
		"frame_ms": 0.0,
		"physics_ms": 0.0,
		"players": 0,
		"entities": 0,
		"rollback_events": 0,
		"rollback_avg_ticks": 0.0,
		"rollback_max_ticks": 0,
		"netfox": {},
		"npc_costs": summary,
	})
	assert_true(line.contains("npc_movement_inclusive_total_usec=100"))
	assert_true(line.contains("npc_movement_prepare_child_total_usec=10"))
	assert_true(line.contains("npc_movement_slide_child_calls=1"))
	assert_true(line.contains("npc_movement_flush_child_calls=1"))

	var empty_summary: Dictionary = probe._consume_npc_cost_summary()
	assert_eq(empty_summary.movement_prepare.total_usec, 0)
	assert_eq(empty_summary.movement_slide.calls, 0)
	assert_eq(empty_summary.movement_flush.calls, 0)
