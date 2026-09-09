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
