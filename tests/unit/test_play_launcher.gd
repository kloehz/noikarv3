extends GutTest

const PLAY_SH_PATH := "res://play.sh"

func _read_play_sh() -> String:
	var file := FileAccess.open(PLAY_SH_PATH, FileAccess.READ)
	assert_not_null(file, "play.sh must be readable from the Godot project")
	if file == null:
		return ""
	return file.get_as_text()

func test_local_command_wraps_human_profile_harness_with_detected_godot() -> void:
	var script := _read_play_sh()

	assert_true(script.contains("local)"))
	assert_true(script.contains("tests/manual/profile_room_scaling.py\" --human --godot \"$GODOT_BIN\""))

func test_godot_bin_is_environment_overridable_with_macos_default() -> void:
	var script := _read_play_sh()

	assert_true(script.contains("GODOT_BIN=\"${GODOT_BIN:-/Applications/Godot.app/Contents/MacOS/Godot}\""))
	assert_true(script.contains("Set GODOT_BIN=/absolute/path/to/Godot"))

func test_local_command_has_dry_run_seam_and_usage() -> void:
	var script := _read_play_sh()

	assert_true(script.contains("PLAY_SH_DRY_RUN=1 ./play.sh local"))
	assert_true(script.contains("DRY RUN:"))
	assert_true(script.contains("local | tests"))
