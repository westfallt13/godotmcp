@tool
extends RefCounted
## Asynchronous client of Godot's built-in Debug Adapter Protocol server.
const Codec = preload("res://addons/hermes_mcp/core/codec.gd")
var host: EditorPlugin
var port := 6006
var peer := StreamPeerTCP.new()
var buffer := PackedByteArray()
var output := PackedByteArray()
var pending: Dictionary = {}
var sequence := 0
var initialized := false
var events: Callable


func _init(plugin: EditorPlugin, on_event: Callable) -> void:
	host = plugin
	events = on_event


func poll() -> void:
	peer.poll()
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		if initialized:
			initialized = false
			events.call("dap", {"event": "disconnected"})
		for key in pending:
			pending[key] = {"error": "Debug adapter disconnected"}
		return
	if not output.is_empty():
		var sent := peer.put_partial_data(output.slice(0, mini(output.size(), 65536)))
		if sent[0] != OK:
			close()
			return
		output = output.slice(sent[1])
	var available := mini(peer.get_available_bytes(), 262144)
	if available > 0:
		var received := peer.get_partial_data(available)
		if received[0] != OK:
			close()
			return
		buffer.append_array(received[1])
	if buffer.size() > 8388608:
		close()
		return
	for _index in range(64):
		var end := _find_header()
		if end < 0: break
		var length := -1
		for line in buffer.slice(0, end).get_string_from_utf8().split("\r\n"):
			if line.to_lower().begins_with("content-length:"):
				length = line.substr(15).strip_edges().to_int()
		if length < 0 or length > 8388608:
			close()
			return
		if buffer.size() < end + 4 + length: break
		var message: Variant = JSON.parse_string(buffer.slice(end + 4, end + 4 + length).get_string_from_utf8())
		buffer = buffer.slice(end + 4 + length)
		if not message is Dictionary: continue
		if message.get("type") == "response":
			var id := int(message.get("request_seq", -1))
			if pending.has(id): pending[id] = message
		elif message.get("type") == "event":
			events.call("dap", message)


func connect_adapter() -> Dictionary:
	if initialized: return {"connected": true, "port": port}
	close()
	var err := peer.connect_to_host("127.0.0.1", port)
	if err != OK: return Codec.error("Cannot connect to Godot DAP: " + error_string(err))
	var deadline := Time.get_ticks_msec() + 3000
	while Time.get_ticks_msec() < deadline:
		peer.poll()
		if peer.get_status() == StreamPeerTCP.STATUS_CONNECTED: break
		if peer.get_status() == StreamPeerTCP.STATUS_ERROR: break
		await host.get_tree().process_frame
	if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED:
		return Codec.error("Godot DAP is unavailable on port %d. Enable Editor Settings > Network > Debug Adapter and set hermes_mcp/dap_port to match." % port)
	var result := await request("initialize", {"clientID": "hermes-godot-mcp", "adapterID": "godot", "pathFormat": "path", "linesStartAt1": true, "columnsStartAt1": true, "supportsVariableType": true})
	if result.has("error"):
		close()
		return result
	initialized = true
	var configured := await request("configurationDone", {})
	if configured.has("error"):
		close()
		return configured
	return {"connected": true, "port": port, "capabilities": result.get("body", {})}


func run(args: Dictionary) -> Dictionary:
	var command: String = args.command
	if command == "connect": return await connect_adapter()
	if command == "disconnect":
		# Close the TCP peer without DAP disconnect, which can stop a game Godot considers launched.
		close()
		return {"connected": false}
	if not initialized:
		var connected := await connect_adapter()
		if connected.has("error"): return connected
	var arguments: Dictionary = args.get("arguments", {}).duplicate(true)
	match command:
		"pause", "continue", "next", "stepIn", "stackTrace": arguments["threadId"] = 1
		"scopes":
			if not _positive_int(arguments.get("frameId")): return Codec.error("arguments.frameId is required (from stackTrace)")
		"variables":
			if not _positive_int(arguments.get("variablesReference")): return Codec.error("arguments.variablesReference is required (from scopes)")
		"evaluate":
			if not arguments.get("expression") is String or not _positive_int(arguments.get("frameId")):
				return Codec.error("evaluate requires expression and frameId from stackTrace")
			arguments["context"] = arguments.get("context", "repl")
		"setBreakpoints":
			if not arguments.get("source") is Dictionary or not arguments.source.get("path") is String or not arguments.get("breakpoints") is Array:
				return Codec.error("setBreakpoints requires source.path and breakpoints array")
			var path := Codec.safe_path(arguments.source.path)
			if path == "" or not FileAccess.file_exists(path): return Codec.error("source.path must be an existing res:// script")
			arguments.source.path = ProjectSettings.globalize_path(path)
			for point in arguments.breakpoints:
				if not point is Dictionary or not _positive_int(point.get("line")) or point.line < 1:
					return Codec.error("Each breakpoint requires a 1-based line")
	return await request(command, arguments)


func request(command: String, arguments: Dictionary) -> Dictionary:
	sequence += 1
	var id := sequence
	pending[id] = null
	var packet := JSON.stringify({"seq": id, "type": "request", "command": command, "arguments": arguments}).to_utf8_buffer()
	output.append_array(("Content-Length: %d\r\n\r\n" % packet.size()).to_utf8_buffer())
	output.append_array(packet)
	var deadline := Time.get_ticks_msec() + 15000
	while pending.has(id) and pending[id] == null and Time.get_ticks_msec() < deadline:
		await host.get_tree().process_frame
	var response: Variant = pending.get(id)
	pending.erase(id)
	if not response is Dictionary: return Codec.error("DAP request timed out: " + command)
	if response.has("error"): return response
	if not response.get("success", false): return {"error": response.get("message", "DAP request failed"), "details": response.get("body", {})}
	return {"command": command, "body": response.get("body", {})}


func close() -> void:
	peer.disconnect_from_host()
	initialized = false
	buffer.clear()
	output.clear()
	for id in pending: pending[id] = Codec.error("DAP connection closed")

func _find_header() -> int:
	for index in range(mini(buffer.size() - 3, 8192)):
		if buffer[index] == 13 and buffer[index + 1] == 10 and buffer[index + 2] == 13 and buffer[index + 3] == 10: return index
	return -1

func _positive_int(value: Variant) -> bool:
	return (value is int or value is float) and is_finite(value) and float(value) == floor(float(value)) and value >= 0
