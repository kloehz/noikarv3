extends Node3D
## Temporary particle-free impact feedback. The original vendor asset is retained.
var _playing := false

func play() -> void:
	if _playing: return
	_playing = true
	var tween := create_tween()
	tween.tween_property(self, "scale", Vector3.ONE * 0.01, 0.18)
	tween.tween_callback(queue_free)
