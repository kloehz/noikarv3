extends GutTest
const Profile := preload("res://common/benchmark_profile.gd")
const Probe := preload("res://common/perf_probe.gd")

func test_default_selection_is_inert() -> void:
	assert_eq(Profile.resolve_selection([], ""), {"valid": true, "profile": ""})

func test_explicit_profiles_and_equal_env_arg_are_accepted() -> void:
	for profile in ["compare30", "compare60"]:
		assert_true(Profile.resolve_selection(["--netfox-profile=" + profile], profile).valid)

func test_invalid_empty_duplicate_and_conflicting_options_fail() -> void:
	for args in [["--netfox-profile="], ["--netfox-profile=bad"],
		["--netfox-profile=compare30", "--netfox-profile=compare30"],
		["--netfox-profile=compare60"]]:
		assert_false(Profile.resolve_selection(args, "compare30").valid)
	assert_false(Profile.resolve_selection([], " compare30").valid)

func test_admission_requires_matching_explicit_profile_or_both_default() -> void:
	assert_true(Profile.profile_matches("", ""))
	assert_true(Profile.profile_matches("compare30", "compare30"))
	assert_false(Profile.profile_matches("compare30", ""))
	assert_false(Profile.profile_matches("", "compare30"))
	assert_false(Profile.profile_matches("compare30", "compare60"))

func test_cadence_percentiles_use_actual_samples_and_mark_empty_unavailable() -> void:
	var samples: Array[float] = [40.0, 10.0, 30.0, 20.0]
	assert_eq(Probe.cadence_percentile(samples, 0.95), 40.0)
	assert_eq(Probe.cadence_percentile(samples, 0.50), 20.0)
	assert_eq(Probe.cadence_percentile([], 0.99), -1.0)

func test_real_json_manifest_and_roundtrip_validate_without_numeric_truncation() -> void:
	var document: Dictionary = JSON.parse_string(FileAccess.get_file_as_string(Profile.PROFILE_PATH))
	for profile in ["compare30", "compare60"]:
		var config: Dictionary = document.profiles[profile]
		assert_true(Profile.validate_settings(config, profile))
		var roundtrip: Dictionary = JSON.parse_string(JSON.stringify(config))
		assert_true(Profile.validate_settings(roundtrip, profile))
		for invalid in [30.5, "30", true, null, []]:
			var bad := config.duplicate(true)
			bad.network_hz = invalid
			assert_false(Profile.validate_settings(bad, profile))
		var bad := config.duplicate(true)
		bad.sync_to_physics = 0
		assert_false(Profile.validate_settings(bad, profile))
		bad = config.duplicate(true)
		bad.extra_option = 1
		assert_false(Profile.validate_settings(bad, profile))

func test_scenario_empty_fixed_population_emits_actual_twenty_npc_stride_counts() -> void:
	var old_fixed := OS.get_environment("NOIKAR_PROFILE_FIXED_POPULATION")
	OS.set_environment("NOIKAR_PROFILE_FIXED_POPULATION", "1")
	var probe := Probe.new()
	add_child_autofree(probe)
	for index in range(20):
		var mob := Node.new()
		mob.name = "stride_fixture_%d" % index
		mob.add_to_group("mobs")
		var state := Node.new()
		state.name = "ServerState"
		var sync := Node.new()
		sync.name = "StateSynchronizer"
		sync.set_meta("npc_snapshot_stride", 1)
		state.add_child(sync)
		mob.add_child(state)
		add_child_autofree(mob)
	var metrics: Dictionary = probe._collect_metrics()
	OS.set_environment("NOIKAR_PROFILE_FIXED_POPULATION", old_fixed)
	assert_eq(metrics.scenario, "")
	assert_eq(metrics.npc_authoritative_stride_counts.get("1"), 20)
	assert_eq(metrics.live_mobs, 20)
	assert_true(probe._format_perf_line(metrics).contains("npc_authoritative_stride_counts={1:20}"))
