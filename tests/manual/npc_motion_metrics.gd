extends RefCounted
## Acceptance for the straight-following, non-dashing pet fixture. Use the
## render delta that advanced presentation, not compositor callback spacing.

static func evaluate(rows: Array, source_speed: float) -> Dictionary:
	var buffered_frames := 0
	var travel := 0.0
	var max_speed_ratio := 0.0
	for index in range(rows.size()):
		var row: Dictionary = rows[index]
		if row.get("buffered", false): buffered_frames += 1
		if index == 0: continue
		var previous: Array = rows[index - 1].position
		var current: Array = row.position
		var distance := Vector3(current[0], current[1], current[2]).distance_to(Vector3(previous[0], previous[1], previous[2]))
		travel += distance
		var delta := float(row.get("delta", 0.0))
		if not is_finite(delta) or delta <= 0.0 or source_speed <= 0.0:
			max_speed_ratio = INF
		elif distance > 0.0001:
			max_speed_ratio = maxf(max_speed_ratio, distance / (delta * source_speed))
	return {"ok": rows.size() > 60 and travel > 0.5 and buffered_frames == rows.size() and max_speed_ratio <= 1.12,
		"frames": rows.size(), "buffered_frames": buffered_frames, "travel_m": travel, "max_render_delta_speed_ratio": max_speed_ratio}
