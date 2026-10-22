@tool
extends RefCounted
const Catalog = preload("res://addons/hermes_mcp/tools/catalog.gd")
const Codec = preload("res://addons/hermes_mcp/core/codec.gd")
const ProjectTools = preload("res://addons/hermes_mcp/tools/project_tools.gd")
const EditorTools = preload("res://addons/hermes_mcp/tools/editor_tools.gd")
const VERSIONS := ["2025-11-25", "2025-06-18"]
var plugin: EditorPlugin
var transport: RefCounted
var sessions: Dictionary = {}
var catalog: Array = Catalog.definitions()
var schemas: Dictionary = {}
var project_tools := ProjectTools.new()
var editor_tools: RefCounted
var busy := false
var stopping := false


func _init(owner_plugin: EditorPlugin, server: RefCounted) -> void:
	plugin = owner_plugin
	transport = server
	editor_tools = EditorTools.new(plugin)
	for tool in catalog: schemas[tool.name] = tool.inputSchema


func handle(client: int, body: PackedByteArray, headers: Dictionary, method: String) -> void:
	for key in sessions.keys():
		if Time.get_ticks_msec() - sessions[key].last_seen > 3600000: sessions.erase(key)
	if headers.has("mcp-protocol-version") and headers["mcp-protocol-version"] not in VERSIONS:
		transport.respond(client, 400, {"error": "Unsupported MCP-Protocol-Version"})
		return
	if method == "GET":
		transport.respond(client, 405, null, {"Allow": "POST, DELETE"})
		return
	var session: String = headers.get("mcp-session-id", "")
	if method == "DELETE":
		if not sessions.has(session):
			transport.respond(client, 404, {"error": "Unknown session"})
			return
		sessions.erase(session)
		transport.respond(client, 204)
		return
	var parser := JSON.new()
	if parser.parse(body.get_string_from_utf8()) != OK:
		_rpc_error(client, null, -32700, "Parse error")
		return
	var request: Variant = parser.data
	if not request is Dictionary or request.get("jsonrpc") != "2.0" or not request.get("method") is String:
		_rpc_error(client, null, -32600, "Invalid Request")
		return
	var id: Variant = request.get("id")
	if request.has("id") and not (id is String or id is int or id is float):
		_rpc_error(client, null, -32600, "Invalid request ID")
		return
	# Godot's JSON parser represents every number as float; MCP SDKs require
	# integer JSON request IDs and reject a serialized 0.0 response ID.
	if id is float:
		if not is_finite(id) or id != floor(id) or abs(id) > 9007199254740991:
			_rpc_error(client, null, -32600, "Request ID must be a safe integer or string")
			return
		id = int(id)
	if not request.get("params", {}) is Dictionary:
		_rpc_error(client, id, -32602, "params must be an object")
		return
	var params: Dictionary = request.get("params", {})
	if request.method == "initialize":
		if not request.has("id") or not params.get("protocolVersion") is String or not params.get("capabilities") is Dictionary or not params.get("clientInfo") is Dictionary:
			_rpc_error(client, id, -32602, "initialize requires protocolVersion, capabilities and clientInfo")
			return
		if sessions.size() >= 16:
			transport.respond(client, 429, {"error": "Too many MCP sessions; DELETE unused sessions"})
			return
		session = Crypto.new().generate_random_bytes(24).hex_encode()
		var version: String = params.protocolVersion if params.protocolVersion in VERSIONS else VERSIONS[0]
		sessions[session] = {"initialized": false, "version": version, "last_seen": Time.get_ticks_msec()}
		transport.respond(client, 200, {"jsonrpc": "2.0", "id": id, "result": {"protocolVersion": version, "capabilities": {"tools": {"listChanged": false}, "resources": {"subscribe": false, "listChanged": false}, "prompts": {"listChanged": false}}, "serverInfo": {"name": "hermes-godot-mcp", "version": "1.0.1"}, "instructions": "Control the currently open Godot project. Start with project_info and godot://guide. Use scene/node tools for undoable changes, play + runtime tools for playtests, debug for breakpoints/stack/variables. Connect debug before playing to capture output. Tools execute serially. Execute code only when trusted; it has full local access."}}, {"Mcp-Session-Id": session})
		return
	if not sessions.has(session):
		transport.respond(client, 404 if session != "" else 400, {"error": "Initialize and provide Mcp-Session-Id"})
		return
	sessions[session].last_seen = Time.get_ticks_msec()
	if not request.has("id"):
		if request.method == "notifications/initialized": sessions[session].initialized = true
		# Notifications are acknowledged. Synchronous engine operations cannot be interrupted.
		transport.respond(client, 202)
		return
	if request.method == "ping":
		_result(client, id, {})
		return
	if not sessions[session].initialized:
		_rpc_error(client, id, -32000, "Send notifications/initialized first")
		return
	match request.method:
		"tools/list": _result(client, id, {"tools": catalog})
		"tools/call":
			if not params.get("name") is String or not schemas.has(params.name):
				_rpc_error(client, id, -32602, "Unknown tool")
				return
			var arguments: Variant = params.get("arguments", {})
			var issue := Catalog.validate(arguments, schemas[params.name])
			if issue == "": issue = Codec.validate_value(arguments)
			if issue != "":
				_rpc_error(client, id, -32602, issue)
				return
			if busy:
				_result(client, id, _tool_result(Codec.error("Another tool is running. Retry after it completes; parallel calls are disabled.")))
				return
			busy = true
			var completion := {"done": false, "value": {}}
			_run_tool(params.name, arguments, completion)
			var deadline := Time.get_ticks_msec() + 90000
			while not completion.done and Time.get_ticks_msec() < deadline and not stopping:
				await plugin.get_tree().process_frame
			if stopping: return
			if not completion.done:
				_result(client, id, _tool_result(Codec.error("Tool exceeded 90 seconds. It may still be running; further tools are locked until completion. Disable/re-enable the plugin if code raised an engine error.")))
				return
			_result(client, id, _tool_result(completion.value))
		"resources/list": _result(client, id, {"resources": _resources()})
		"resources/templates/list": _result(client, id, {"resourceTemplates": []})
		"resources/read":
			var uri: Variant = params.get("uri", "")
			var value: Variant
			match uri:
				"godot://project": value = editor_tools.info()
				"godot://scene": value = await editor_tools.run("scene_tree", {})
				"godot://runtime": value = {"playing": EditorInterface.is_playing_scene(), "sessions": plugin.debugger.status()}
				"godot://guide": value = FileAccess.get_file_as_string("res://addons/hermes_mcp/AGENT_GUIDE.md")
				_:
					_rpc_error(client, id, -32002, "Resource not found")
					return
			_result(client, id, {"contents": [{"uri": uri, "mimeType": "text/markdown" if uri == "godot://guide" else "application/json", "text": value if value is String else JSON.stringify(value)}]})
		"prompts/list": _result(client, id, {"prompts": [{"name": "playtest", "description": "Inspect, run, exercise and debug a Godot project", "arguments": [{"name": "objective", "description": "What behavior to verify", "required": true}]}]})
		"prompts/get":
			if params.get("name") != "playtest" or not params.get("arguments", {}) is Dictionary or not params.get("arguments", {}).get("objective") is String:
				_rpc_error(client, id, -32602, "playtest requires arguments.objective")
				return
			_result(client, id, {"description": "Godot playtest workflow", "messages": [{"role": "user", "content": {"type": "text", "text": "Playtest this Godot project: " + params.arguments.objective + "\nRead godot://guide and project_info. Connect debug before starting play; inspect runtime tree, send input, capture screenshots, inspect metrics and debug_events. If broken, use stackTrace/scopes/variables. Stop play when done and report observed evidence and any failures. Never claim a screenshot was seen if capture failed."}}]})
		_: _rpc_error(client, id, -32601, "Method not found")


func _run_tool(name: String, args: Dictionary, completion: Dictionary) -> void:
	var value: Dictionary
	match name:
		"files_list", "file_read", "file_write", "file_delete", "files_search", "project_setting", "input_map": value = project_tools.run(name, args)
		"play": value = await _play(args)
		"runtime", "runtime_input", "runtime_screenshot":
			if name == "runtime" and args.get("action") == "evaluate" and not ProjectSettings.get_setting("hermes_mcp/allow_code_execution", true):
				value = Codec.error("Code execution disabled")
			else:
				value = await plugin.debugger.request({"runtime": "runtime", "runtime_input": "input", "runtime_screenshot": "screenshot"}[name], args)
		"debug": value = await plugin.dap.run(args)
		"debug_events": value = plugin.read_events(int(args.get("after", 0)), int(args.get("limit", 100)))
		_: value = await editor_tools.run(name, args)
	completion.value = value
	completion.done = true
	busy = false


func _play(args: Dictionary) -> Dictionary:
	match args.action:
		"start":
			if EditorInterface.is_playing_scene(): return Codec.error("Already playing; stop first")
			if args.has("scene_path"):
				var path := Codec.safe_path(args.scene_path)
				if path == "" or not ResourceLoader.exists(path, "PackedScene"): return Codec.error("Invalid scene_path")
				EditorInterface.play_custom_scene(path)
			elif args.get("current", false):
				if not EditorInterface.get_edited_scene_root(): return Codec.error("No current scene")
				EditorInterface.play_current_scene()
			else:
				if ProjectSettings.get_setting("application/run/main_scene", "") == "": return Codec.error("No main scene configured")
				EditorInterface.play_main_scene()
			var deadline := Time.get_ticks_msec() + 15000
			while Time.get_ticks_msec() < deadline:
				for session in plugin.debugger.status():
					if session.ready and session.active: return {"playing": true, "runtime_ready": true, "session_id": session.id}
				await plugin.get_tree().process_frame
			return {"error": "Play did not establish the runtime bridge within 15 seconds; inspect debug_events and the editor output", "playing": EditorInterface.is_playing_scene()}
		"stop":
			EditorInterface.stop_playing_scene()
			var deadline := Time.get_ticks_msec() + 5000
			while EditorInterface.is_playing_scene() and Time.get_ticks_msec() < deadline: await plugin.get_tree().process_frame
	return {"playing": EditorInterface.is_playing_scene(), "scene": EditorInterface.get_playing_scene(), "sessions": plugin.debugger.status()}


func _resources() -> Array:
	return [{"uri": "godot://project", "name": "Project and editor state", "mimeType": "application/json"}, {"uri": "godot://scene", "name": "Edited scene tree", "mimeType": "application/json"}, {"uri": "godot://runtime", "name": "Runtime session status", "mimeType": "application/json"}, {"uri": "godot://guide", "name": "Agent usage guide", "mimeType": "text/markdown"}]

func _result(client: int, id: Variant, result: Dictionary) -> void:
	transport.respond(client, 200, {"jsonrpc": "2.0", "id": id, "result": result})

func _rpc_error(client: int, id: Variant, code: int, message: String) -> void:
	transport.respond(client, 200, {"jsonrpc": "2.0", "id": id, "error": {"code": code, "message": message}})

func _tool_result(value: Dictionary) -> Dictionary:
	if value.has("_image"):
		return {"content": [{"type": "image", "data": value._image, "mimeType": "image/png"}, {"type": "text", "text": JSON.stringify({"width": value.width, "height": value.height})}], "isError": false}
	return {"content": [{"type": "text", "text": JSON.stringify(value)}], "structuredContent": value, "isError": value.has("error")}
