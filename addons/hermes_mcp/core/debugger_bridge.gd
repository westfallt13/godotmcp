@tool
extends EditorDebuggerPlugin
const Codec = preload("res://addons/hermes_mcp/core/codec.gd")
var host: EditorPlugin
var events: Callable
var ready_sessions: Dictionary = {}
var pending: Dictionary = {}
var sequence := 0


func _init(plugin: EditorPlugin, on_event: Callable) -> void:
	host = plugin
	events = on_event

func _has_capture(capture: String) -> bool:
	return capture == "hermes_mcp"

func _setup_session(session_id: int) -> void:
	var session := get_session(session_id)
	session.started.connect(func() -> void: events.call("runtime", {"event": "started", "session_id": session_id}))
	session.stopped.connect(func() -> void:
		ready_sessions.erase(session_id)
		for key in pending:
			if pending[key].session_id == session_id: pending[key].result = Codec.error("Runtime session stopped")
		events.call("runtime", {"event": "stopped", "session_id": session_id}))
	session.breaked.connect(func(can_debug: bool) -> void: events.call("runtime", {"event": "breaked", "can_debug": can_debug, "session_id": session_id}))
	session.continued.connect(func() -> void: events.call("runtime", {"event": "continued", "session_id": session_id}))

func _capture(message: String, data: Array, session_id: int) -> bool:
	if message == "hermes_mcp:ready":
		ready_sessions[session_id] = true
		events.call("runtime", {"event": "ready", "session_id": session_id})
		return true
	if message == "hermes_mcp:result" and data.size() == 2:
		var id := int(data[0])
		if pending.has(id) and pending[id].session_id == session_id:
			pending[id].result = data[1]
		return true
	return false

func status() -> Array:
	var result: Array = []
	var sessions := get_sessions()
	for id in sessions.size():
		var session: EditorDebuggerSession = sessions[id]
		result.append({"id": id, "active": session.is_active(), "breaked": session.is_breaked(), "ready": ready_sessions.has(id)})
	return result

func request(command: String, args: Dictionary) -> Dictionary:
	var id := int(args.get("session_id", -1))
	if id == -1:
		for key in ready_sessions:
			if get_session(key).is_active():
				id = key
				break
	if id < 0 or id >= get_sessions().size() or not ready_sessions.has(id): return Codec.error("No runtime bridge ready; start play and wait for the handshake")
	var session := get_session(id)
	if not session.is_active(): return Codec.error("Runtime is disconnected")
	if session.is_breaked(): return Codec.error("Runtime is stopped at a debugger break. Use debug continue before runtime tools; use debug stackTrace/scopes/variables while broken.")
	sequence += 1
	var request_id := sequence
	pending[request_id] = {"session_id": id, "result": null}
	session.send_message("hermes_mcp:request", [request_id, command, args])
	var deadline := Time.get_ticks_msec() + 30000
	while pending.has(request_id) and pending[request_id].result == null and Time.get_ticks_msec() < deadline:
		await host.get_tree().process_frame
	var result: Variant = pending.get(request_id, {}).get("result")
	pending.erase(request_id)
	if not result is Dictionary: return Codec.error("Runtime request timed out; inspect debug_events for errors or a breakpoint")
	return result
