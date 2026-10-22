extends SceneTree
## Metadata-only scan in an empty scratch project: never load scenes/scripts.
func _initialize() -> void:
 var args := OS.get_cmdline_user_args()
 if args.size() != 2:
  quit(1); return
 var request = JSON.parse_string(FileAccess.get_file_as_string(args[0]))
 if not request is Dictionary:
  quit(2); return
 for uid in request.uids:
  var id := ResourceUID.text_to_id(uid)
  if id == ResourceUID.INVALID_ID:
   quit(3); return
  if ResourceUID.has_id(id):
   ResourceUID.set_id(id, "res://" + request.uids[uid])
  else:
   ResourceUID.add_id(id, "res://" + request.uids[uid])
 var dependencies := {}
 for path in request.paths:
  dependencies[path] = Array(ResourceLoader.get_dependencies("res://" + path))
 var import_remaps := {}
 for path in request.import_paths:
  var config := ConfigFile.new()
  if config.load("res://" + path) != OK or not config.has_section("remap"):
   quit(5); return
  var remaps := {}
  for key in config.get_section_keys("remap"):
   if key == "path" or key.begins_with("path."):
    var value = config.get_value("remap", key)
    if not value is String or not value.begins_with("res://"):
     quit(6); return
    remaps[key] = value
  import_remaps[path] = remaps
 var result := {"schema": 1, "dependencies": dependencies, "import_remaps": import_remaps, "builtin_classes": Array(ClassDB.get_class_list()), "version": Engine.get_version_info().string}
 var output := FileAccess.open(args[1], FileAccess.WRITE)
 if output == null:
  quit(4); return
 output.store_string(JSON.stringify(result))
 output.close()
 quit(0)
