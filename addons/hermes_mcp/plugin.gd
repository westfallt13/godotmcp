@tool
extends EditorPlugin
const HTTPServer = preload("res://addons/hermes_mcp/core/http_server.gd")
const Protocol = preload("res://addons/hermes_mcp/core/protocol.gd")
const DebuggerBridge = preload("res://addons/hermes_mcp/core/debugger_bridge.gd")
const DAPClient = preload("res://addons/hermes_mcp/core/dap_client.gd")
const CONFIG_PATH := "res://.godot/hermes_mcp/connection.json"
const AUTOLOAD_NAME := "HermesMCPRuntime"
const RUNTIME_PATH := "res://addons/hermes_mcp/runtime/runtime_bridge.gd"
var server: RefCounted
var protocol: RefCounted
var debugger: EditorDebuggerPlugin
var dap: RefCounted
var dock: ScrollContainer
var status_label: Label
var endpoint := ""
var bearer_token := ""
var events: Array = []
var event_sequence := 0


func _disable_plugin() -> void:
	if _owns_runtime_autoload():
		remove_autoload_singleton(AUTOLOAD_NAME)

func _enter_tree() -> void:
	_setting("hermes_mcp/port", 4960, TYPE_INT, PROPERTY_HINT_RANGE, "1024,65535")
	_setting("hermes_mcp/dap_port", 6006, TYPE_INT, PROPERTY_HINT_RANGE, "1024,65535")
	_setting("hermes_mcp/allow_code_execution", true, TYPE_BOOL)
	_ensure_autoload()
	debugger = DebuggerBridge.new(self, record_event)
	add_debugger_plugin(debugger)
	dap = DAPClient.new(self, record_event)
	dap.port = int(ProjectSettings.get_setting("hermes_mcp/dap_port", 6006))
	server = HTTPServer.new()
	protocol = Protocol.new(self, server)
	server.request_received.connect(protocol.handle)
	var port := int(ProjectSettings.get_setting("hermes_mcp/port", 4960))
	endpoint = "http://127.0.0.1:%d/mcp" % port
	bearer_token = _load_token()
	_build_dock()
	if bearer_token == "":
		status_label.text = "MCP could not create its connection file.\nCheck project filesystem permissions."
		return
	var err: Error = server.start(port, bearer_token)
	if err != OK:
		status_label.text = "MCP failed: " + error_string(err) + "\nChange hermes_mcp/port and re-enable."
		push_error("Hermes MCP could not listen: " + error_string(err))
		return
	status_label.text = "MCP listening\n" + endpoint
	record_event("server", {"event": "started", "endpoint": endpoint})
	print("Hermes MCP listening at ", endpoint, " (connection details in ", CONFIG_PATH, ")")
	set_process(true)

func _exit_tree() -> void:
	set_process(false)
	if protocol: protocol.stopping = true
	if server: server.stop()
	if dap: dap.close()
	if debugger: remove_debugger_plugin(debugger)
	if dock:
		remove_control_from_docks(dock)
		dock.queue_free()
	# Break RefCounted cycles to make plugin reloads clean.
	if protocol:
		protocol.plugin = null
		protocol.editor_tools.plugin = null
	if debugger: debugger.host = null
	if dap: dap.host = null

func _process(_delta: float) -> void:
	if server: server.poll()
	if dap: dap.poll()

func _ensure_autoload() -> void:
	if not ProjectSettings.has_setting("autoload/" + AUTOLOAD_NAME):
		add_autoload_singleton(AUTOLOAD_NAME, RUNTIME_PATH)
	elif not _owns_runtime_autoload():
		push_error("Hermes MCP: autoload name HermesMCPRuntime is already in use. Runtime tools will not work until the conflict is resolved.")

func _owns_runtime_autoload() -> bool:
	var path := str(ProjectSettings.get_setting("autoload/" + AUTOLOAD_NAME, "")).trim_prefix("*")
	# Godot 4.6 saves autoloads as resource UIDs; older projects use res:// paths.
	if path.begins_with("uid://"):
		var uid := ResourceUID.text_to_id(path)
		if not ResourceUID.has_id(uid):
			return false
		path = ResourceUID.get_id_path(uid)
	return path == RUNTIME_PATH

func _setting(key: String, value: Variant, type: int, hint: int = PROPERTY_HINT_NONE, hint_string: String = "") -> void:
	if not ProjectSettings.has_setting(key): ProjectSettings.set_setting(key, value)
	ProjectSettings.set_initial_value(key, value)
	ProjectSettings.add_property_info({"name": key, "type": type, "hint": hint, "hint_string": hint_string})

func _load_token() -> String:
	var token := ""
	if FileAccess.file_exists(CONFIG_PATH):
		var data: Variant = JSON.parse_string(FileAccess.get_file_as_string(CONFIG_PATH))
		if data is Dictionary and data.get("token") is String and data.token.length() == 64: token = data.token
	if token == "": token = Crypto.new().generate_random_bytes(32).hex_encode()
	if DirAccess.make_dir_recursive_absolute(CONFIG_PATH.get_base_dir()) != OK: return ""
	var file := FileAccess.open(CONFIG_PATH, FileAccess.WRITE)
	if not file: return ""
	file.store_string(JSON.stringify({"url": endpoint, "token": token, "project": ProjectSettings.globalize_path("res://"), "pid": OS.get_process_id()}, "\t"))
	file.close()
	if OS.has_feature("linux") or OS.has_feature("macos"):
		FileAccess.set_unix_permissions(CONFIG_PATH, FileAccess.UNIX_READ_OWNER | FileAccess.UNIX_WRITE_OWNER)
	return token

func _build_dock() -> void:
	# Wrapped labels can report enormous heights before a hidden dock gets its
	# first layout. Keep that minimum size from expanding the whole editor.
	dock = ScrollContainer.new()
	dock.name = "Hermes MCP"
	dock.custom_minimum_size = Vector2(160, 120) * EditorInterface.get_editor_scale()
	dock.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	var content := VBoxContainer.new()
	content.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	dock.add_child(content)
	status_label = Label.new()
	status_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(status_label)
	var copy := Button.new()
	copy.text = "Copy Hermes configuration"
	copy.pressed.connect(func() -> void: DisplayServer.clipboard_set(hermes_config()))
	content.add_child(copy)
	var help := Label.new()
	help.text = "Paste into ~/.hermes/config.yaml.\nProject Settings > Hermes MCP controls\nports and trusted code execution.\nRe-enable after changing ports."
	help.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	content.add_child(help)
	add_control_to_dock(DOCK_SLOT_RIGHT_UL, dock)

func hermes_config() -> String:
	return "mcp_servers:\n  godot:\n    url: \"%s\"\n    headers:\n      Authorization: \"Bearer %s\"\n    timeout: 120\n    supports_parallel_tool_calls: false\n" % [endpoint, bearer_token]

func record_event(source: String, data: Dictionary) -> void:
	event_sequence += 1
	events.append({"cursor": event_sequence, "time_msec": Time.get_ticks_msec(), "source": source, "data": data})
	if events.size() > 1000: events.pop_front()

func read_events(after: int, limit: int) -> Dictionary:
	var result: Array = []
	for event in events:
		if event.cursor > after:
			result.append(event)
			if result.size() >= limit: break
	return {"events": result, "cursor": result.back().cursor if not result.is_empty() else after, "latest_cursor": event_sequence, "gap": not events.is_empty() and after < events.front().cursor - 1}
