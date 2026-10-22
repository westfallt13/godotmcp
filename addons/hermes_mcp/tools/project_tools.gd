@tool
extends RefCounted
const Codec = preload("res://addons/hermes_mcp/core/codec.gd")
const TEXT_LIMIT := 2097152


func run(name: String, args: Dictionary) -> Dictionary:
	match name:
		"files_list":
			var path := Codec.safe_path(args.get("path", "res://"))
			if path == "" or not DirAccess.dir_exists_absolute(path): return Codec.error("Project directory does not exist")
			var files: Array = []
			_collect(path, args.get("recursive", true), files)
			files.sort()
			var offset := int(args.get("offset", 0))
			return {"files": files.slice(offset, offset + int(args.get("limit", 200))), "total": files.size(), "truncated": files.size() >= 20000}
		"file_read": return _read(args)
		"file_write": return _write(args)
		"file_delete":
			var path := Codec.safe_path(args.path)
			if path == "" or not FileAccess.file_exists(path): return Codec.error("File does not exist or path is disallowed")
			if FileAccess.get_sha256(path) != args.expected_sha256: return Codec.error("SHA-256 mismatch; read the file again")
			var err := DirAccess.remove_absolute(path)
			if err != OK: return Codec.error(error_string(err))
			EditorInterface.get_resource_filesystem().scan()
			return {"deleted": path}
		"files_search": return _search(args)
		"project_setting": return _setting(args)
		"input_map": return _input_map(args)
	return Codec.error("Unknown project tool")


func _collect(path: String, recursive: bool, result: Array, depth: int = 0) -> void:
	if depth > 32 or result.size() >= 20000: return
	var dir := DirAccess.open(path)
	if not dir: return
	for file in dir.get_files():
		if file.begins_with(".") or dir.is_link(file): continue
		result.append(path.path_join(file))
		if result.size() >= 20000: return
	if recursive:
		for folder in dir.get_directories():
			if not folder.begins_with(".") and not dir.is_link(folder):
				_collect(path.path_join(folder), true, result, depth + 1)


func _read(args: Dictionary) -> Dictionary:
	var path := Codec.safe_path(args.path)
	if path == "": return Codec.error("Use a safe res:// path")
	var file := FileAccess.open(path, FileAccess.READ)
	if not file: return Codec.error("Cannot open file: " + error_string(FileAccess.get_open_error()))
	if file.get_length() > TEXT_LIMIT: return Codec.error("Text file exceeds 2 MiB")
	var bytes := file.get_buffer(file.get_length())
	if bytes.has(0): return Codec.error("Binary file is not supported by file_read")
	var content := bytes.get_string_from_utf8()
	var lines := content.split("\n")
	var start := int(args.get("start_line", 1))
	var end := int(args.get("end_line", lines.size()))
	if end < start: return Codec.error("end_line must be >= start_line")
	return {"path": path, "content": "\n".join(lines.slice(start - 1, end)), "start_line": start, "total_lines": lines.size(), "sha256": FileAccess.get_sha256(path)}


func _write(args: Dictionary) -> Dictionary:
	var path := Codec.safe_path(args.path)
	if path == "" or path == "res://": return Codec.error("Use a safe file path under res://")
	var exists := FileAccess.file_exists(path)
	if args.has("expected_sha256"):
		if not exists or FileAccess.get_sha256(path) != args.expected_sha256:
			return Codec.error("SHA-256 mismatch; read the file again")
	elif exists and not args.get("overwrite", false):
		return Codec.error("File exists; provide expected_sha256 or overwrite=true")
	var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
	if err != OK: return Codec.error(error_string(err))
	var temporary := path + ".hermes-" + Crypto.new().generate_random_bytes(8).hex_encode() + ".tmp"
	var file := FileAccess.open(temporary, FileAccess.WRITE)
	if not file: return Codec.error(error_string(FileAccess.get_open_error()))
	file.store_string(args.content)
	file.flush()
	err = file.get_error()
	file.close()
	if err == OK:
		err = DirAccess.rename_absolute(temporary, path)
	if err != OK:
		DirAccess.remove_absolute(temporary)
		return Codec.error(error_string(err))
	EditorInterface.get_resource_filesystem().scan()
	return {"path": path, "bytes": args.content.to_utf8_buffer().size(), "sha256": FileAccess.get_sha256(path)}


func _search(args: Dictionary) -> Dictionary:
	var path := Codec.safe_path(args.get("path", "res://"))
	if path == "" or args.query == "": return Codec.error("Provide a directory and nonempty query")
	var files: Array = []
	_collect(path, true, files)
	var matches: Array = []
	var query: String = args.query
	var sensitive: bool = args.get("case_sensitive", false)
	if not sensitive: query = query.to_lower()
	for file_path in files:
		var file := FileAccess.open(file_path, FileAccess.READ)
		if not file or file.get_length() > TEXT_LIMIT: continue
		var bytes := file.get_buffer(file.get_length())
		if bytes.has(0): continue
		var text := bytes.get_string_from_utf8()
		var lines := text.split("\n")
		for index in lines.size():
			var line: String = lines[index] if sensitive else lines[index].to_lower()
			if query in line:
				matches.append({"path": file_path, "line": index + 1, "text": lines[index].left(1000)})
				if matches.size() >= int(args.get("limit", 100)):
					return {"matches": matches, "truncated": true}
	return {"matches": matches, "truncated": files.size() >= 20000}


func _setting(args: Dictionary) -> Dictionary:
	var key: String = args.get("key", "")
	if args.action == "list":
		var settings := {}
		for property in ProjectSettings.get_property_list():
			if String(property.name).begins_with(key):
				settings[property.name] = Codec.encode(ProjectSettings.get_setting(property.name))
		return {"settings": settings}
	if key == "": return Codec.error("key is required")
	if args.action == "get":
		if not ProjectSettings.has_setting(key): return Codec.error("Unknown setting")
		return {"key": key, "value": Codec.encode(ProjectSettings.get_setting(key))}
	if args.action == "set" and not args.has("value"): return Codec.error("value is required")
	ProjectSettings.set_setting(key, Codec.decode(args.get("value")) if args.action == "set" else null)
	if args.get("save", false):
		var err := ProjectSettings.save()
		if err != OK: return Codec.error(error_string(err))
	return {"key": key, "saved": args.get("save", false)}


func _input_map(args: Dictionary) -> Dictionary:
	if args.action == "list":
		var actions := {}
		for action in InputMap.get_actions():
			var events: Array = []
			for event in InputMap.action_get_events(action):
				events.append({"class": event.get_class(), "text": event.as_text(), "properties": Codec.properties(event)})
			actions[str(action)] = {"deadzone": InputMap.action_get_deadzone(action), "events": events}
		return {"actions": actions}
	var name: String = args.get("name", "")
	if name == "": return Codec.error("name is required")
	if args.action == "erase":
		if InputMap.has_action(name): InputMap.erase_action(name)
		ProjectSettings.set_setting("input/" + name, null)
	else:
		var events: Array = []
		for spec in args.get("events", []):
			var type: String = spec.get("class", "")
			if not ClassDB.class_exists(type) or not ClassDB.is_parent_class(type, "InputEvent") or not ClassDB.can_instantiate(type):
				return Codec.error("Invalid InputEvent class: " + type)
			var event: InputEvent = ClassDB.instantiate(type)
			if not spec.get("properties", {}) is Dictionary: return Codec.error("Event properties must be an object")
			var check := Codec.prepare_properties(event, spec.get("properties", {}))
			if check.has("error"): return check
			for key in check.values: event.set(key, check.values[key])
			events.append(event)
		if not InputMap.has_action(name): InputMap.add_action(name)
		InputMap.action_erase_events(name)
		InputMap.action_set_deadzone(name, args.get("deadzone", 0.2))
		for event in events: InputMap.action_add_event(name, event)
		ProjectSettings.set_setting("input/" + name, {"deadzone": args.get("deadzone", 0.2), "events": events})
	var err := ProjectSettings.save()
	return {"name": name, "saved": true} if err == OK else Codec.error(error_string(err))
