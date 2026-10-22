extends GutTest
## Startup isolation is not an account or multiplayer authorization bypass.

func test_test_mode_does_not_open_a_peer_or_contact_services() -> void:
	assert_eq(GameManager.bootstrap_mode_for(["--noikar-test-mode"], true), GameManager.BootstrapMode.TEST)
	assert_false(NetworkEvents.is_server())
	assert_true(GameManager.validated_room_creator_account_id.is_empty())

func test_production_exports_reject_test_bootstrap_request() -> void:
	assert_eq(GameManager.bootstrap_mode_for(["--noikar-test-mode"], false), GameManager.BootstrapMode.REJECTED)

func test_normal_and_unrelated_arguments_keep_normal_startup() -> void:
	assert_eq(GameManager.bootstrap_mode_for([], true), GameManager.BootstrapMode.NORMAL)
	assert_eq(GameManager.bootstrap_mode_for(["--noikar-test-mode=no"], true), GameManager.BootstrapMode.NORMAL)

func test_imported_texture_checksum_inputs_resolve_the_actual_output() -> void:
	var config := ConfigFile.new()
	assert_eq(config.load("res://assets/models/enemies/kogmaw/deep_sea_kogmaw_riotRig_phong1.png.import"), OK)
	for output in config.get_value("deps", "dest_files", []):
		assert_true(FileAccess.file_exists(output), "Importer checksum inputs must name the actual texture, not a backslash-escaped filename")
