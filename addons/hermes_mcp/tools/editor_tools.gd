@tool
extends RefCounted
const Codec = preload("res://addons/hermes_mcp/core/codec.gd")
var plugin: EditorPlugin


func _init(owner_plugin: EditorPlugin) -> void:
	plugin = owner_plugin


func run(name: String, args: Dictionary) -> Dictionary:
	match name:
		"project_info": return info()
		"scene": return await _scene(args)
		"scene_tree":
			var target := _node(args.get("path", "."))
			return {"tree": Codec.tree(target, int(args.get("depth", 8)), [1000])} if target else Codec.error("Scene node not found")
		"node": return _node_action(args)
		"node_inspect":
			var target := _node(args.path)
			return _inspect(target) if target else Codec.error("Scene node not found")
		"node_set_properties": return _set_properties(args)
		"node_call":
			var target := _node(args.path)
			return Codec.invoke(target, args.method, args.get("args", [])) if target else Codec.error("Scene node not found")
		"signal_connection": return _signal(args)
		"resource": return _resource(args)
		"script": return _script(args)
		"editor": return _editor(args)
		"editor_execute": return await _execute(args)
		"editor_screenshot": return await _screenshot(args)
		"class_info": return _class_info(args)
	return Codec.error("Unknown editor tool")


func info() -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	var selected: Array = []
	for node in EditorInterface.get_selection().get_selected_nodes():
		selected.append(str(root.get_path_to(node)) if root else str(node.get_path()))
	return {"name": ProjectSettings.get_setting("application/config/name", ""), "path": ProjectSettings.globalize_path("res://"), "godot": Engine.get_version_info(), "main_scene": ProjectSettings.get_setting("application/run/main_scene", ""), "open_scenes": Array(EditorInterface.get_open_scenes()), "current_scene": root.scene_file_path if root else null, "selected_nodes": selected, "playing": EditorInterface.is_playing_scene(), "display": DisplayServer.get_name(), "server_version": "1.0.1", "trusted_code_execution": ProjectSettings.get_setting("hermes_mcp/allow_code_execution", true), "dap_port": plugin.dap.port, "runtime_sessions": plugin.debugger.status()}


func _node(path: String) -> Node:
	var root := EditorInterface.get_edited_scene_root()
	if not root or path.begins_with("/"): return null
	var target := root.get_node_or_null(NodePath(path))
	if target and (target == root or root.is_ancestor_of(target)): return target
	return null


func _scene(args: Dictionary) -> Dictionary:
	var path := Codec.safe_path(args.get("path", ""))
	match args.action:
		"list": return {"scenes": Array(EditorInterface.get_open_scenes())}
		"open":
			if path == "" or not ResourceLoader.exists(path, "PackedScene"): return Codec.error("Scene does not exist")
			EditorInterface.open_scene_from_path(path)
			await plugin.get_tree().process_frame
		"new":
			if path == "" or path.get_extension() not in ["tscn", "scn"]: return Codec.error("Provide a new .tscn or .scn path")
			if FileAccess.file_exists(path): return Codec.error("Scene already exists")
			var type: String = args.get("root_type", "Node2D")
			if not _can_create(type, "Node"): return Codec.error("Invalid root node type")
			var root: Node = ClassDB.instantiate(type)
			root.name = args.get("name", path.get_file().get_basename().to_pascal_case())
			var packed := PackedScene.new()
			var err := packed.pack(root)
			root.free()
			if err != OK: return Codec.error(error_string(err))
			err = DirAccess.make_dir_recursive_absolute(path.get_base_dir())
			if err == OK: err = ResourceSaver.save(packed, path)
			if err != OK: return Codec.error(error_string(err))
			EditorInterface.get_resource_filesystem().scan()
			EditorInterface.open_scene_from_path(path)
			await plugin.get_tree().process_frame
		"save":
			if not EditorInterface.get_edited_scene_root(): return Codec.error("No edited scene")
			if args.has("path"):
				if path == "" or path.get_extension() not in ["tscn", "scn"]: return Codec.error("Invalid scene path")
				EditorInterface.save_scene_as(path)
				if not FileAccess.file_exists(path): return Codec.error("Scene save failed")
			else:
				if EditorInterface.get_edited_scene_root().scene_file_path == "": return Codec.error("Unsaved scene requires path")
				var err := EditorInterface.save_scene()
				if err != OK: return Codec.error(error_string(err))
		"save_all": EditorInterface.save_all_scenes()
		"close":
			if not EditorInterface.has_method("close_scene"): return Codec.error("This Godot version has no public close_scene API")
			var err: int = EditorInterface.call("close_scene")
			if err != OK: return Codec.error(error_string(err))
	return {"scenes": Array(EditorInterface.get_open_scenes()), "current": EditorInterface.get_edited_scene_root().scene_file_path if EditorInterface.get_edited_scene_root() else null}


func _node_action(args: Dictionary) -> Dictionary:
	var root := EditorInterface.get_edited_scene_root()
	if not root: return Codec.error("No edited scene; create or open a scene first")
	var undo := plugin.get_undo_redo()
	var action: String = args.action
	var target := _node(args.get("path", "."))
	var parent := _node(args.get("parent", "."))
	if action == "select":
		if not target: return Codec.error("Node not found")
		EditorInterface.get_selection().clear()
		EditorInterface.get_selection().add_node(target)
		EditorInterface.edit_node(target)
		return {"selected": str(root.get_path_to(target))}
	if action in ["create", "instantiate", "duplicate"]:
		var created: Node
		if action == "create":
			var type: String = args.get("type", "Node")
			if not _can_create(type, "Node"): return Codec.error("Invalid node type")
			created = ClassDB.instantiate(type)
		elif action == "instantiate":
			var path := Codec.safe_path(args.get("scene_path", ""))
			if path == "" or not ResourceLoader.exists(path, "PackedScene"): return Codec.error("Invalid scene_path")
			var packed: PackedScene = load(path)
			created = packed.instantiate(PackedScene.GEN_EDIT_STATE_INSTANCE)
		else:
			if not target or target == root: return Codec.error("Cannot duplicate the root or missing node")
			created = target.duplicate()
			parent = target.get_parent()
		if not parent:
			created.free()
			return Codec.error("Parent not found")
		if args.has("name"): created.name = args.name
		undo.create_action("MCP " + action + " node", UndoRedo.MERGE_DISABLE, root)
		undo.add_do_method(parent, "add_child", created, true)
		undo.add_do_method(self, "_own_created", created, root)
		if args.has("index"): undo.add_do_method(parent, "move_child", created, mini(int(args.index), parent.get_child_count()))
		undo.add_do_reference(created)
		undo.add_undo_method(parent, "remove_child", created)
		undo.commit_action()
		return {"path": str(root.get_path_to(created)), "class": created.get_class()}
	if not target or target == root: return Codec.error("Operation requires a non-root scene node")
	var old_parent := target.get_parent()
	var old_index := target.get_index()
	var owners: Array = []
	_collect_owners(target, owners)
	match action:
		"delete":
			undo.create_action("MCP delete node", UndoRedo.MERGE_DISABLE, root)
			undo.add_do_method(old_parent, "remove_child", target)
			undo.add_undo_method(old_parent, "add_child", target)
			undo.add_undo_method(old_parent, "move_child", target, old_index)
			undo.add_undo_method(self, "_restore_owners", owners)
			undo.add_undo_reference(target)
		"rename":
			if args.get("name", "") == "": return Codec.error("name is required")
			undo.create_action("MCP rename node", UndoRedo.MERGE_DISABLE, root)
			undo.add_do_property(target, "name", args.name)
			undo.add_undo_property(target, "name", target.name)
		"reparent":
			if not parent or parent == target or target.is_ancestor_of(parent): return Codec.error("Invalid parent; cannot create a cycle")
			undo.create_action("MCP reparent node", UndoRedo.MERGE_DISABLE, root)
			undo.add_do_method(target, "reparent", parent, true)
			undo.add_do_method(self, "_restore_owners", owners)
			if args.has("index"): undo.add_do_method(parent, "move_child", target, mini(int(args.index), parent.get_child_count()))
			undo.add_undo_method(target, "reparent", old_parent, true)
			undo.add_undo_method(old_parent, "move_child", target, old_index)
			undo.add_undo_method(self, "_restore_owners", owners)
		_:
			return Codec.error("Unknown node action")
	undo.commit_action()
	return {"action": action, "success": true}


func _own_created(node: Node, root: Node) -> void:
	node.owner = root
	# Preserve instantiated subscene internals; duplicate descendants retain the edited root owner.
	if node.scene_file_path == "":
		for child in node.get_children(): _own_created(child, root)

func _collect_owners(node: Node, result: Array) -> void:
	result.append([node, node.owner])
	for child in node.get_children(): _collect_owners(child, result)

func _restore_owners(owners: Array) -> void:
	for entry in owners:
		if is_instance_valid(entry[0]) and is_instance_valid(entry[1]) and entry[1].is_ancestor_of(entry[0]):
			entry[0].owner = entry[1]


func _set_properties(args: Dictionary) -> Dictionary:
	var target := _node(args.path)
	if not target: return Codec.error("Node not found")
	var checked := Codec.prepare_properties(target, args.properties)
	if checked.has("error"): return checked
	var undo := plugin.get_undo_redo()
	undo.create_action("MCP set node properties", UndoRedo.MERGE_DISABLE, target)
	for key in checked.values:
		undo.add_do_property(target, key, checked.values[key])
		undo.add_undo_property(target, key, target.get(key))
	undo.commit_action()
	return {"path": args.path, "properties": Codec.encode(checked.values)}


func _inspect(object: Object) -> Dictionary:
	var connections := {}
	for sig in object.get_signal_list(): connections[sig.name] = Codec.encode(object.get_signal_connection_list(sig.name))
	return {"object": Codec.encode(object), "properties": Codec.properties(object), "methods": Codec.encode(object.get_method_list()), "signals": Codec.encode(object.get_signal_list()), "connections": connections}


func _signal(args: Dictionary) -> Dictionary:
	var source := _node(args.source)
	var target := _node(args.target)
	if not source or not target: return Codec.error("Source or target not found")
	if not source.has_signal(args.signal) or not target.has_method(args.method): return Codec.error("Signal or target method does not exist")
	var callback := Callable(target, args.method)
	var connected := source.is_connected(args.signal, callback)
	if connected == (args.action == "connect"): return {"connected": connected, "changed": false}
	var undo := plugin.get_undo_redo()
	undo.create_action("MCP " + args.action + " signal", UndoRedo.MERGE_DISABLE, source)
	if args.action == "connect":
		undo.add_do_method(source, "connect", args.signal, callback, CONNECT_PERSIST)
		undo.add_undo_method(source, "disconnect", args.signal, callback)
	else:
		var flags := CONNECT_PERSIST
		for connection in source.get_signal_connection_list(args.signal):
			if connection.callable == callback: flags = connection.flags
		undo.add_do_method(source, "disconnect", args.signal, callback)
		undo.add_undo_method(source, "connect", args.signal, callback, flags)
	undo.commit_action()
	return {"connected": source.is_connected(args.signal, callback)}


func _resource(args: Dictionary) -> Dictionary:
	var path := Codec.safe_path(args.path)
	if path == "": return Codec.error("Invalid resource path")
	var resource: Resource
	if args.action == "create":
		if FileAccess.file_exists(path): return Codec.error("Resource already exists")
		var type: String = args.get("type", "Resource")
		if not _can_create(type, "Resource"): return Codec.error("Invalid Resource type")
		resource = ClassDB.instantiate(type)
	else:
		if not ResourceLoader.exists(path): return Codec.error("Resource not found")
		resource = load(path)
	if not resource: return Codec.error("Could not load resource")
	if args.action == "inspect": return _inspect(resource)
	var checked := Codec.prepare_properties(resource, args.get("properties", {}))
	if checked.has("error"): return checked
	for key in checked.values: resource.set(key, checked.values[key])
	resource.emit_changed()
	if args.get("save", true):
		var err := DirAccess.make_dir_recursive_absolute(path.get_base_dir())
		if err == OK: err = ResourceSaver.save(resource, path)
		if err != OK: return Codec.error(error_string(err))
		EditorInterface.get_resource_filesystem().scan()
	return {"path": path, "saved": args.get("save", true), "resource": Codec.encode(resource)}


func _script(args: Dictionary) -> Dictionary:
	if args.action == "validate":
		var source: String = args.get("source", "")
		if args.has("path"):
			var path := Codec.safe_path(args.path)
			if path == "" or not FileAccess.file_exists(path): return Codec.error("Script not found")
			source = FileAccess.get_file_as_string(path)
		if source == "": return Codec.error("source or path is required")
		var script := GDScript.new()
		script.source_code = source
		var err := script.reload()
		return {"valid": err == OK, "error_code": err, "message": error_string(err)}
	var target := _node(args.get("node_path", "."))
	if not target: return Codec.error("Scene node not found")
	var script: Script
	if args.action == "attach":
		var path := Codec.safe_path(args.get("path", ""))
		if path == "" or not ResourceLoader.exists(path, "Script"): return Codec.error("Script path not found")
		script = load(path)
		if not script: return Codec.error("Script failed to load")
		# Non-@tool scripts deliberately cannot instantiate in the editor; placeholders
		# still support attachment and persistent signal wiring.
		if script is GDScript and script.reload(true) != OK: return Codec.error("Script failed to compile")
		if not target.is_class(script.get_instance_base_type()): return Codec.error("Script base type is incompatible with node")
	var undo := plugin.get_undo_redo()
	undo.create_action("MCP " + args.action + " script", UndoRedo.MERGE_DISABLE, target)
	undo.add_do_method(target, "set_script", script)
	undo.add_undo_method(target, "set_script", target.get_script())
	undo.commit_action()
	return {"attached": Codec.encode(script)}


func _editor(args: Dictionary) -> Dictionary:
	if args.action == "scan":
		EditorInterface.get_resource_filesystem().scan()
		return {"scanning": true}
	if args.action in ["undo", "redo"]:
		var root := EditorInterface.get_edited_scene_root()
		if not root: return Codec.error("No edited scene")
		var manager := plugin.get_undo_redo()
		var history := manager.get_history_undo_redo(manager.get_object_history_id(root))
		return {"changed": history.undo() if args.action == "undo" else history.redo()}
	var targets := {"interface": EditorInterface, "selection": EditorInterface.get_selection(), "filesystem": EditorInterface.get_resource_filesystem(), "inspector": EditorInterface.get_inspector(), "script_editor": EditorInterface.get_script_editor(), "settings": EditorInterface.get_editor_settings(), "base_control": EditorInterface.get_base_control(), "undo_redo": plugin.get_undo_redo()}
	var object: Object = instance_from_id(int(args.object_id)) if args.has("object_id") else targets.get(args.get("target", "interface"))
	if not is_instance_valid(object): return Codec.error("Editor target not found")
	if args.action == "inspect": return _inspect(object)
	if args.action == "ui_tree":
		if not object is Node: object = EditorInterface.get_base_control()
		return {"tree": Codec.tree(object, int(args.get("depth", 5)), [1500])}
	if args.get("method", "") == "": return Codec.error("method is required")
	return Codec.invoke(object, args.method, args.get("args", []))


func _execute(args: Dictionary) -> Dictionary:
	if not ProjectSettings.get_setting("hermes_mcp/allow_code_execution", true): return Codec.error("Code execution disabled in project settings")
	var script := GDScript.new()
	script.source_code = "@tool\nextends RefCounted\nfunc execute(editor, plugin, scene_root, args):\n\t" + String(args.code).replace("\n", "\n\t") + "\n"
	var err := script.reload()
	if err != OK: return Codec.error("GDScript compilation failed: " + error_string(err))
	var instance: RefCounted = script.new()
	var value: Variant = await instance.call("execute", EditorInterface, plugin, EditorInterface.get_edited_scene_root(), Codec.decode(args.get("args", {})))
	return {"value": Codec.encode(value)}


func _screenshot(args: Dictionary) -> Dictionary:
	if DisplayServer.get_name() == "headless": return Codec.error("Screenshots require a rendering display")
	var viewport: Viewport = EditorInterface.get_base_control().get_viewport()
	match args.get("viewport", "editor"):
		"2d": viewport = EditorInterface.get_editor_viewport_2d()
		"3d": viewport = EditorInterface.get_editor_viewport_3d(0)
	# An unfocused editor can suppress rendering indefinitely. Force a draw rather
	# than waiting for a signal that may never arrive in low-processor mode.
	RenderingServer.force_draw(false)
	var picture := viewport.get_texture().get_image()
	if not picture or picture.is_empty(): return Codec.error("Viewport has no rendered image")
	var width := int(args.get("max_width", 1280))
	if picture.get_width() > width: picture.resize(width, maxi(1, roundi(picture.get_height() * float(width) / picture.get_width())))
	return {"_image": Marshalls.raw_to_base64(picture.save_png_to_buffer()), "width": picture.get_width(), "height": picture.get_height()}


func _class_info(args: Dictionary) -> Dictionary:
	var type: String = args.get("class", "")
	if type == "":
		var classes: Array = []
		for name in ClassDB.get_class_list():
			if String(args.get("filter", "")).to_lower() in String(name).to_lower(): classes.append(str(name))
		classes.sort()
		return {"classes": classes}
	if not ClassDB.class_exists(type): return Codec.error("Class not found")
	var constants := {}
	for key in ClassDB.class_get_integer_constant_list(type): constants[key] = ClassDB.class_get_integer_constant(type, key)
	return {"class": type, "parent": str(ClassDB.get_parent_class(type)), "instantiable": ClassDB.can_instantiate(type), "methods": Codec.encode(ClassDB.class_get_method_list(type)), "properties": Codec.encode(ClassDB.class_get_property_list(type)), "signals": Codec.encode(ClassDB.class_get_signal_list(type)), "constants": constants}


func _can_create(type: String, base: String) -> bool:
	return ClassDB.class_exists(type) and ClassDB.is_parent_class(type, base) and ClassDB.can_instantiate(type)
