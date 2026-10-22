extends Node
## Inert outside editor debug sessions, including exported release games.
const Codec = preload("res://addons/hermes_mcp/core/codec.gd")
var enabled := false


func _ready() -> void:
	process_mode = Node.PROCESS_MODE_ALWAYS
	if Engine.is_editor_hint() or not OS.has_feature("editor") or not EngineDebugger.is_active():
		return
	enabled = true
	EngineDebugger.register_message_capture("hermes_mcp", _capture)
	EngineDebugger.send_message("hermes_mcp:ready", [])

func _exit_tree() -> void:
	if enabled and EngineDebugger.is_active(): EngineDebugger.unregister_message_capture("hermes_mcp")

func _capture(message: String, data: Array) -> bool:
	if message != "request" or data.size() != 3: return false
	_handle.call_deferred(int(data[0]), str(data[1]), data[2])
	return true

func _handle(id: int, command: String, args: Dictionary) -> void:
	var result := await _run(command, args)
	if enabled and EngineDebugger.is_active(): EngineDebugger.send_message("hermes_mcp:result", [id, result])

func _node(path: String) -> Node:
	if path == "": return get_tree().current_scene
	if path.begins_with("/"): return get_node_or_null(NodePath(path))
	var root := get_tree().current_scene
	return root.get_node_or_null(NodePath(path)) if root else null

func _run(command: String, args: Dictionary) -> Dictionary:
	if command == "input": return await _inject_input(args)
	if command == "screenshot": return await _screenshot(args)
	match args.get("action", ""):
		"tree":
			var node := _node(args.get("path", "/root"))
			return {"tree": Codec.tree(node, int(args.get("depth", 8)), [1500])} if node else Codec.error("Runtime node not found")
		"inspect":
			var node := _node(args.get("path", ""))
			if not node: return Codec.error("Runtime node not found")
			return {"object": Codec.encode(node), "properties": Codec.properties(node), "methods": Codec.encode(node.get_method_list()), "signals": Codec.encode(node.get_signal_list())}
		"set_properties":
			var node := _node(args.get("path", ""))
			if not node: return Codec.error("Runtime node not found")
			if not args.has("properties"): return Codec.error("properties is required")
			var checked := Codec.prepare_properties(node, args.properties)
			if checked.has("error"): return checked
			for key in checked.values: node.set(key, checked.values[key])
			return {"properties": Codec.encode(checked.values)}
		"call":
			var node := _node(args.get("path", ""))
			if not node: return Codec.error("Runtime node not found")
			if not args.get("args", []) is Array: return Codec.error("call args must be an array")
			return Codec.invoke(node, args.get("method", ""), args.get("args", []))
		"evaluate": return await _evaluate(args)
		"pause":
			get_tree().paused = args.get("paused", true)
			return {"paused": get_tree().paused}
		"wait":
			for _frame in int(args.get("frames", 1)): await get_tree().process_frame
			return {"frames": args.get("frames", 1), "process_frame": Engine.get_process_frames()}
		"metrics":
			return {"fps": Performance.get_monitor(Performance.TIME_FPS), "process_seconds": Performance.get_monitor(Performance.TIME_PROCESS), "physics_seconds": Performance.get_monitor(Performance.TIME_PHYSICS_PROCESS), "memory_bytes": Performance.get_monitor(Performance.MEMORY_STATIC), "nodes": Performance.get_monitor(Performance.OBJECT_NODE_COUNT), "resources": Performance.get_monitor(Performance.OBJECT_RESOURCE_COUNT), "draw_calls": Performance.get_monitor(Performance.RENDER_TOTAL_DRAW_CALLS_IN_FRAME), "paused": get_tree().paused, "process_frame": Engine.get_process_frames()}
		"reload_scene":
			var err := get_tree().reload_current_scene()
			return {"reloaded": true} if err == OK else Codec.error(error_string(err))
	return Codec.error("Unknown runtime action")

func _evaluate(args: Dictionary) -> Dictionary:
	if not ProjectSettings.get_setting("hermes_mcp/allow_code_execution", true): return Codec.error("Code execution disabled")
	if args.get("code", "") == "": return Codec.error("code is required")
	var script := GDScript.new()
	script.source_code = "extends RefCounted\nfunc execute(tree, root, args):\n\t" + String(args.code).replace("\n", "\n\t") + "\n"
	var err := script.reload()
	if err != OK: return Codec.error("GDScript compilation failed: " + error_string(err))
	var instance: RefCounted = script.new()
	var value: Variant = await instance.call("execute", get_tree(), get_tree().current_scene, Codec.decode(args.get("args", {})))
	return {"value": Codec.encode(value)}

func _inject_input(args: Dictionary) -> Dictionary:
	var event: InputEvent
	var pressed: bool = args.get("pressed", true)
	match args.kind:
		"action":
			var action: String = args.get("action", "")
			if not InputMap.has_action(action): return Codec.error("Input action does not exist")
			var action_event := InputEventAction.new()
			action_event.action = action
			action_event.pressed = pressed
			action_event.strength = float(args.get("strength", 1.0)) if pressed else 0.0
			event = action_event
		"key":
			var code := OS.find_keycode_from_string(args.get("key", ""))
			if code == KEY_NONE: return Codec.error("Unknown key name")
			var key_event := InputEventKey.new()
			key_event.keycode = code
			key_event.physical_keycode = code
			key_event.pressed = pressed
			event = key_event
		"mouse_button":
			var mouse := InputEventMouseButton.new()
			mouse.position = Vector2(args.get("x", 0), args.get("y", 0))
			mouse.global_position = mouse.position
			mouse.button_index = int(args.get("button", MOUSE_BUTTON_LEFT))
			mouse.pressed = pressed
			event = mouse
		"mouse_motion":
			var mouse := InputEventMouseMotion.new()
			mouse.position = Vector2(args.get("x", 0), args.get("y", 0))
			mouse.global_position = mouse.position
			mouse.relative = Vector2(args.get("relative_x", 0), args.get("relative_y", 0))
			event = mouse
		_: return Codec.error("Unsupported input kind")
	Input.parse_input_event(event)
	var frames := int(args.get("hold_frames", 0))
	if frames > 0 and pressed and not event is InputEventMouseMotion:
		for _frame in frames: await get_tree().process_frame
		var release: InputEvent = event.duplicate()
		release.set("pressed", false)
		if release is InputEventAction: release.strength = 0.0
		Input.parse_input_event(release)
	return {"sent": event.as_text(), "released": frames > 0 and pressed and not event is InputEventMouseMotion}

func _screenshot(args: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless": return Codec.error("Screenshots require graphical play; headless renderer has no image")
	RenderingServer.force_draw(false)
	var picture := get_viewport().get_texture().get_image()
	if not picture or picture.is_empty(): return Codec.error("Viewport image is unavailable")
	var width := int(args.get("max_width", 1280))
	if picture.get_width() > width: picture.resize(width, maxi(1, roundi(picture.get_height() * float(width) / picture.get_width())))
	return {"_image": Marshalls.raw_to_base64(picture.save_png_to_buffer()), "width": picture.get_width(), "height": picture.get_height()}
