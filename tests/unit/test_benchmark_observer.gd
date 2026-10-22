extends GutTest
const OBSERVER := preload("res://common/benchmark_observer.gd")

func test_observer_is_inert_without_explicit_start() -> void:
	var observer := OBSERVER.new()
	add_child_autofree(observer)
	assert_false(observer._enabled)
	assert_eq(observer._rows, 0)
	assert_false(observer.is_in_group(&"benchmark_observer"))
	observer._process(1.0)
	assert_eq(observer._rows, 0)

func test_empty_percentiles_are_null_not_fabricated_zero() -> void:
	var empty: Array[float] = []
	assert_null(OBSERVER.percentile(empty, 0.95))
	var samples: Array[float] = [0.0, 33.3, 40.0, 50.0]
	assert_eq(OBSERVER.percentile(samples, 0.95), 50.0)

func test_callbacks_activation_and_catchup_are_interval_counts_not_last_loop_snapshots() -> void:
	var observer := OBSERVER.new()
	add_child_autofree(observer)
	observer._enabled = true
	observer._index = 2
	observer._row_start = Time.get_ticks_usec() - 1000000
	observer._process_start = Engine.get_process_frames()
	observer._physics_start = Engine.get_physics_frames()
	observer._before_network_loop()
	observer._on_native_tick(1.0/30, 1)
	observer._on_native_tick(1.0/30, 2)
	observer._after_network_loop()
	observer._before_rollback_loop()
	observer._on_rollback_tick(1); observer._on_rollback_tick(2)
	observer._after_rollback_loop()
	observer.record_activation(1, 100)
	observer.record_activation(2, 200)
	var row := observer.take_client_row(Time.get_ticks_usec())
	assert_eq(row.native_ticks, 2)
	assert_eq(row.catchup_extra_native_ticks, 1)
	assert_eq(row.network_max_ticks_per_loop, 2)
	assert_eq(row.rollback_process_tick_callbacks, 2)
	assert_eq(row.activation.actor_load_usec, 100)
	assert_eq(row.activation.entity_ready_usec, 200)
	assert_eq(observer._native_total, 2)
	assert_eq(observer._rollback_ticks, 0)
	assert_eq(observer._activation.actor_load_calls, 0)
	assert_true(row.last_loop_monitors.has("rollback_nodes"))

func test_row_cap_disables_reporting_without_changing_any_engine_clock() -> void:
	var observer := OBSERVER.new()
	add_child_autofree(observer)
	var fps := Engine.max_fps
	var physics := Engine.physics_ticks_per_second
	observer._enabled = true
	observer._rows = 180
	observer._process(1.0)
	assert_false(observer._enabled)
	assert_eq(observer._rows, 180)
	assert_eq(Engine.max_fps, fps)
	assert_eq(Engine.physics_ticks_per_second, physics)

func test_window_uses_actual_native_callback_count_and_elapsed_not_configured_rate() -> void:
	var observer := OBSERVER.new()
	add_child_autofree(observer)
	observer._window_start = 1000000
	observer._window_unix_start = 100000000
	observer._window_native_start = 100
	observer._native_total = 990
	var row := observer.finish_window(31000000, 130000000)
	assert_eq(row.native_ticks, 890)
	assert_eq(row.duration_usec, 30000000)
	assert_almost_eq(row.native_achieved_hz, 890.0/30.0, 0.0001)
	assert_null(row.native_interval_p95_ms)
	assert_eq(row.population_start, {})
