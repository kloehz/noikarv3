extends GutTest

const METRICS_PATH := "res://tests/manual/npc_motion_metrics.gd"

func _trace(bursty: bool, buffered := true) -> Array:
	var rows: Array = []
	for frame in range(100):
		var x := float(frame) / 12.0
		if bursty: x = float(int(frame / 4) * 4) / 12.0
		rows.append({"position": [x, 0.0, 0.0], "delta": 1.0 / 120.0, "buffered": buffered})
	return rows

func test_motion_acceptance_rejects_old_hold_and_burst_even_when_pet_moves() -> void:
	if not ResourceLoader.exists(METRICS_PATH):
		fail_test("Pet acceptance requires an executable motion quality gate")
		return
	var metrics: Script = load(METRICS_PATH)
	assert_false(metrics.evaluate(_trace(true), 10.0).ok)
	assert_false(metrics.evaluate(_trace(false, false), 10.0).ok)
	assert_true(metrics.evaluate(_trace(false), 10.0).ok)

func test_motion_acceptance_uses_render_delta_not_compositor_wall_timing() -> void:
	if not ResourceLoader.exists(METRICS_PATH):
		fail_test("Motion quality must tolerate variable frame duration without allowing speed bursts")
		return
	var rows := _trace(false)
	rows[50].position[0] += 0.25
	rows[50].delta = 1.0 / 30.0
	for frame in range(51, rows.size()): rows[frame].position[0] += 0.25
	var metrics: Script = load(METRICS_PATH)
	assert_true(metrics.evaluate(rows, 10.0).ok)
