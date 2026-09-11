extends GutTest

const MatchManagerScript := preload("res://common/match_manager.gd")

func test_raw_headless_benchmark_population_accepts_only_a_b_c() -> void:
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=A"], true), 0)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=B"], true), 20)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=c"], true), 20)

func test_raw_headless_benchmark_population_rejects_connected_and_non_headless_cases() -> void:
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=D"], true), -1)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=E"], true), -1)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=F"], true), -1)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=B"], false), -1)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args(["--benchmark=Z"], true), -1)
	assert_eq(MatchManagerScript.raw_headless_benchmark_population_count_from_args([], true), -1)
