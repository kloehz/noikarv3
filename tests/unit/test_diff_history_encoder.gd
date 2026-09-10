extends GutTest

class InstrumentedPropertyEntry:
	extends PropertyEntry
	static var string_calls := 0

	func _to_string() -> String:
		string_calls += 1
		return _path

func _make_property(path: String) -> PropertyEntry:
	var entry := InstrumentedPropertyEntry.new()
	entry._path = path
	return entry

func _make_properties(paths: Array[String]) -> Array[PropertyEntry]:
	var result: Array[PropertyEntry] = []
	for path in paths:
		result.append(_make_property(path))
	return result

func before_each() -> void:
	InstrumentedPropertyEntry.string_calls = 0

func _make_encoder(history: _PropertyHistoryBuffer) -> _DiffHistoryEncoder:
	var root := Node.new()
	add_child_autofree(root)
	return _DiffHistoryEncoder.new(history, PropertyCache.new(root))

func test_encode_uses_allowed_properties_for_filtering() -> void:
	var history := _PropertyHistoryBuffer.new()
	var encoder := _make_encoder(history)
	var properties := _make_properties([":health", ":mana"])
	var allowed_properties := _make_properties([":health"])
	encoder.add_properties(properties)
	var registration_calls := InstrumentedPropertyEntry.string_calls
	history.set_snapshot(0, {})
	history.set_snapshot(1, {":health": 10, ":mana": 5})

	encoder.encode(1, 0, allowed_properties)

	assert_gt(InstrumentedPropertyEntry.string_calls, registration_calls,
		"encode should stringify the supplied allowlist because the lookup drives filtering")
	assert_eq(encoder.get_encoded_snapshot(), {":health": 10})

func test_changed_property_roundtrips_as_diff() -> void:
	var sender_history := _PropertyHistoryBuffer.new()
	var receiver_history := _PropertyHistoryBuffer.new()
	var properties := _make_properties([":health", ":mana"])
	var sender := _make_encoder(sender_history)
	var receiver := _make_encoder(receiver_history)
	sender.add_properties(properties)
	receiver.add_properties(properties)
	sender_history.set_snapshot(1, {":health": 10, ":mana": 5})
	receiver_history.set_snapshot(1, {":health": 10, ":mana": 5})
	sender_history.set_snapshot(2, {":health": 7, ":mana": 5})

	var data := sender.encode(2, 1, properties)
	var diff := receiver.decode(data, properties)
	assert_true(receiver.apply(2, diff, 1), "decoded diff should apply")

	assert_eq(receiver_history.get_snapshot(2).as_dictionary(), {":health": 7, ":mana": 5})

func test_unchanged_snapshot_encodes_empty_payload() -> void:
	var history := _PropertyHistoryBuffer.new()
	var encoder := _make_encoder(history)
	var properties := _make_properties([":health", ":mana"])
	encoder.add_properties(properties)
	history.set_snapshot(3, {":health": 10, ":mana": 5})
	history.set_snapshot(4, {":health": 10, ":mana": 5})

	assert_eq(encoder.encode(4, 3, properties).size(), 0)

func test_all_changed_properties_roundtrip() -> void:
	var sender_history := _PropertyHistoryBuffer.new()
	var receiver_history := _PropertyHistoryBuffer.new()
	var properties := _make_properties([":health", ":mana"])
	var sender := _make_encoder(sender_history)
	var receiver := _make_encoder(receiver_history)
	sender.add_properties(properties)
	receiver.add_properties(properties)
	sender_history.set_snapshot(5, {":health": 10, ":mana": 5})
	receiver_history.set_snapshot(5, {":health": 10, ":mana": 5})
	sender_history.set_snapshot(6, {":health": 8, ":mana": 2})

	var data := sender.encode(6, 5, properties)
	assert_true(receiver.apply(6, receiver.decode(data, properties), 5))

	assert_eq(receiver_history.get_snapshot(6).as_dictionary(), {":health": 8, ":mana": 2})

func test_empty_snapshot_payload_stays_empty() -> void:
	var history := _PropertyHistoryBuffer.new()
	var encoder := _make_encoder(history)
	var properties := _make_properties([":health"])
	encoder.add_properties(properties)

	assert_eq(encoder.encode(8, 0, properties), PackedByteArray())

func test_encode_filters_predicted_server_owned_state_from_allowed_client_state() -> void:
	var sender_history := _PropertyHistoryBuffer.new()
	var receiver_history := _PropertyHistoryBuffer.new()
	var all_properties := _make_properties([":position", "Combat:sync_attack_count", "Combat:current_attack_state"])
	var client_owned_properties := _make_properties([":position"])
	var sender := _make_encoder(sender_history)
	var receiver := _make_encoder(receiver_history)
	sender.add_properties(all_properties)
	receiver.add_properties(all_properties)
	sender_history.set_snapshot(10, {":position": Vector3.ZERO, "Combat:sync_attack_count": 1, "Combat:current_attack_state": 0})
	receiver_history.set_snapshot(10, {":position": Vector3.ZERO, "Combat:sync_attack_count": 1, "Combat:current_attack_state": 0})
	sender_history.set_snapshot(11, {":position": Vector3.RIGHT, "Combat:sync_attack_count": 2, "Combat:current_attack_state": 1})

	var data := sender.encode(11, 10, client_owned_properties)
	var decoded := receiver.decode(data, all_properties)
	assert_true(receiver.apply(11, decoded, 10), "decoded owned diff should apply")

	assert_true(decoded.has(":position"), "Client-owned movement should be sent")
	assert_false(decoded.has("Combat:sync_attack_count"), "Server-owned predicted combat counter must not be sent")
	assert_false(decoded.has("Combat:current_attack_state"), "Server-owned predicted combat phase must not be sent")
	assert_eq(receiver_history.get_snapshot(11).as_dictionary(), {":position": Vector3.RIGHT, "Combat:sync_attack_count": 1, "Combat:current_attack_state": 0})
	assert_eq(sender_history.get_snapshot(11).as_dictionary()["Combat:sync_attack_count"], 2,
		"Filtering must not mutate recorded local prediction history")
	assert_eq(sender.get_encoded_snapshot(), {":position": Vector3.RIGHT},
		"Encoded diagnostics should only report allowed properties")
	assert_eq(sender.get_full_snapshot(), {":position": Vector3.RIGHT},
		"Current diagnostics should only report allowed properties")

func test_non_allowed_only_change_encodes_empty_payload() -> void:
	var history := _PropertyHistoryBuffer.new()
	var encoder := _make_encoder(history)
	var all_properties := _make_properties([":position", "Combat:sync_attack_count"])
	var client_owned_properties := _make_properties([":position"])
	encoder.add_properties(all_properties)
	history.set_snapshot(20, {":position": Vector3.ZERO, "Combat:sync_attack_count": 1})
	history.set_snapshot(21, {":position": Vector3.ZERO, "Combat:sync_attack_count": 2})

	assert_eq(encoder.encode(21, 20, client_owned_properties), PackedByteArray())
	assert_eq(encoder.get_encoded_snapshot(), {}, "Non-allowed changes should not appear in sent-state metrics")

func test_empty_allowed_properties_encode_empty_without_erasing_history() -> void:
	var history := _PropertyHistoryBuffer.new()
	var encoder := _make_encoder(history)
	var all_properties := _make_properties([":position", "Combat:sync_attack_count"])
	var empty_properties: Array[PropertyEntry] = []
	encoder.add_properties(all_properties)
	history.set_snapshot(30, {":position": Vector3.ZERO, "Combat:sync_attack_count": 1})
	history.set_snapshot(31, {":position": Vector3.RIGHT, "Combat:sync_attack_count": 2})

	assert_eq(encoder.encode(31, 30, empty_properties), PackedByteArray())
	assert_eq(history.get_snapshot(31).as_dictionary(), {":position": Vector3.RIGHT, "Combat:sync_attack_count": 2})

func test_reordered_allowed_subset_preserves_registered_packet_order() -> void:
	var history := _PropertyHistoryBuffer.new()
	var canonical_encoder := _make_encoder(history)
	var reordered_encoder := _make_encoder(history)
	var all_properties := _make_properties([":health", ":mana", ":stamina"])
	var canonical_allowed := _make_properties([":health", ":mana"])
	var reordered_allowed := _make_properties([":mana", ":health"])
	canonical_encoder.add_properties(all_properties)
	reordered_encoder.add_properties(all_properties)
	history.set_snapshot(40, {":health": 10, ":mana": 5, ":stamina": 2})
	history.set_snapshot(41, {":health": 7, ":mana": 3, ":stamina": 1})

	var canonical_data := canonical_encoder.encode(41, 40, canonical_allowed)
	var reordered_data := reordered_encoder.encode(41, 40, reordered_allowed)

	assert_eq(reordered_data, canonical_data,
		"Allowed-list order must not change wire order; registered snapshot order remains authoritative")
	assert_eq(canonical_encoder.get_encoded_snapshot(), {":health": 7, ":mana": 3})
	assert_eq(reordered_encoder.get_encoded_snapshot(), {":health": 7, ":mana": 3})
