@tool
extends RefCounted
## JSON-safe Godot values. Objects are references, never serialized recursively.

static func encode(value: Variant, depth: int = 0) -> Variant:
	if depth > 12:
		return {"truncated": true}
	match typeof(value):
		TYPE_NIL, TYPE_BOOL, TYPE_INT, TYPE_STRING:
			return value
		TYPE_FLOAT:
			return value if is_finite(value) else str(value)
		TYPE_STRING_NAME, TYPE_NODE_PATH:
			return {"$type": type_string(typeof(value)), "value": str(value)}
		TYPE_VECTOR2, TYPE_VECTOR2I:
			return {"$type": type_string(typeof(value)), "x": value.x, "y": value.y}
		TYPE_VECTOR3, TYPE_VECTOR3I:
			return {"$type": type_string(typeof(value)), "x": value.x, "y": value.y, "z": value.z}
		TYPE_VECTOR4, TYPE_VECTOR4I, TYPE_QUATERNION:
			return {"$type": type_string(typeof(value)), "x": value.x, "y": value.y, "z": value.z, "w": value.w}
		TYPE_COLOR:
			return {"$type": "Color", "r": value.r, "g": value.g, "b": value.b, "a": value.a}
		TYPE_RECT2, TYPE_RECT2I:
			return {"$type": type_string(typeof(value)), "position": encode(value.position), "size": encode(value.size)}
		TYPE_TRANSFORM2D:
			return {"$type": "Transform2D", "x": encode(value.x), "y": encode(value.y), "origin": encode(value.origin)}
		TYPE_BASIS:
			return {"$type": "Basis", "x": encode(value.x), "y": encode(value.y), "z": encode(value.z)}
		TYPE_TRANSFORM3D:
			return {"$type": "Transform3D", "basis": encode(value.basis), "origin": encode(value.origin)}
		TYPE_OBJECT:
			if not is_instance_valid(value):
				return null
			var result := {"$type": "Object", "id": value.get_instance_id(), "class": value.get_class()}
			if value is Resource:
				result["$type"] = "Resource"
				result["path"] = value.resource_path
			if value is Node and value.is_inside_tree():
				result["path"] = str(value.get_path())
			return result
		TYPE_DICTIONARY:
			var result := {}
			for key in value:
				result[str(key)] = encode(value[key], depth + 1)
			return result
		TYPE_ARRAY, TYPE_PACKED_BYTE_ARRAY, TYPE_PACKED_INT32_ARRAY, TYPE_PACKED_INT64_ARRAY, TYPE_PACKED_FLOAT32_ARRAY, TYPE_PACKED_FLOAT64_ARRAY, TYPE_PACKED_STRING_ARRAY, TYPE_PACKED_VECTOR2_ARRAY, TYPE_PACKED_VECTOR3_ARRAY, TYPE_PACKED_COLOR_ARRAY, TYPE_PACKED_VECTOR4_ARRAY:
			var result: Array = []
			for item in value:
				if result.size() >= 4096:
					result.append({"truncated": true, "total": value.size()})
					break
				result.append(encode(item, depth + 1))
			return result
	return {"$type": type_string(typeof(value)), "value": str(value)}


static func decode(value: Variant) -> Variant:
	if value is Array:
		return value.map(func(v: Variant) -> Variant: return decode(v))
	if not value is Dictionary:
		return value
	match value.get("$type", ""):
		"Vector2": return Vector2(value.get("x", 0), value.get("y", 0))
		"Vector2i": return Vector2i(value.get("x", 0), value.get("y", 0))
		"Vector3": return Vector3(value.get("x", 0), value.get("y", 0), value.get("z", 0))
		"Vector3i": return Vector3i(value.get("x", 0), value.get("y", 0), value.get("z", 0))
		"Vector4": return Vector4(value.get("x", 0), value.get("y", 0), value.get("z", 0), value.get("w", 0))
		"Vector4i": return Vector4i(value.get("x", 0), value.get("y", 0), value.get("z", 0), value.get("w", 0))
		"Quaternion": return Quaternion(value.get("x", 0), value.get("y", 0), value.get("z", 0), value.get("w", 1))
		"Color": return Color(value.get("r", 0), value.get("g", 0), value.get("b", 0), value.get("a", 1))
		"NodePath": return NodePath(value.get("value", ""))
		"StringName": return StringName(value.get("value", ""))
		"Rect2": return Rect2(decode(value.position), decode(value.size))
		"Rect2i": return Rect2i(decode(value.position), decode(value.size))
		"Transform2D": return Transform2D(decode(value.x), decode(value.y), decode(value.origin))
		"Basis": return Basis(decode(value.x), decode(value.y), decode(value.z))
		"Transform3D": return Transform3D(decode(value.basis), decode(value.origin))
		"Resource":
			var path: String = value.get("path", "")
			if safe_path(path) != "" and ResourceLoader.exists(path):
				return load(path)
			return null
		"Object": return instance_from_id(int(value.get("id", 0)))
	var result := {}
	for key in value:
		result[key] = decode(value[key])
	return result


static func validate_value(value: Variant, depth: int = 0) -> String:
	if depth > 32: return "Value nesting exceeds 32 levels"
	if value is Array:
		for item in value:
			var issue := validate_value(item, depth + 1)
			if issue != "": return issue
	if not value is Dictionary: return ""
	if value.has("$type"):
		var type: Variant = value["$type"]
		if not type is String: return "$type must be a string"
		var fields: Array = []
		match type:
			"Vector2", "Vector2i": fields = ["x", "y"]
			"Vector3", "Vector3i": fields = ["x", "y", "z"]
			"Vector4", "Vector4i", "Quaternion": fields = ["x", "y", "z", "w"]
			"Color": fields = ["r", "g", "b", "a"]
			"NodePath", "StringName":
				if not value.get("value") is String: return type + " requires a string value"
			"Resource":
				if not value.get("path") is String or safe_path(value.path) == "" or not ResourceLoader.exists(value.path):
					return "Resource requires an existing safe res:// path"
			"Object":
				if not value.get("id") is float and not value.get("id") is int: return "Object requires an instance id"
				if not is_finite(value.id) or value.id < 1 or value.id > 9007199254740991 or value.id != floor(value.id): return "Object id must be a positive safe integer"
				if not is_instance_valid(instance_from_id(int(value.id))): return "Object instance no longer exists"
			"Rect2", "Rect2i":
				var component := "Vector2i" if type == "Rect2i" else "Vector2"
				for field in ["position", "size"]:
					if not value.get(field) is Dictionary or value[field].get("$type") != component: return type + " requires tagged " + component + " components"
			"Transform2D", "Basis", "Transform3D":
				var components: Dictionary = {"Transform2D": {"x": "Vector2", "y": "Vector2", "origin": "Vector2"}, "Basis": {"x": "Vector3", "y": "Vector3", "z": "Vector3"}, "Transform3D": {"basis": "Basis", "origin": "Vector3"}}[type]
				for field in components:
					if not value.get(field) is Dictionary or value[field].get("$type") != components[field]: return type + " has invalid " + field
			_: return "Unsupported tagged value type: " + type
		for field in fields:
			var component: Variant = value.get(field, 1 if field in ["a", "w"] else 0)
			if not (component is int or component is float) or not is_finite(component): return type + "." + field + " must be a finite number"
	for key in value:
		var issue := validate_value(value[key], depth + 1)
		if issue != "": return issue
	return ""


static func safe_path(path: String) -> String:
	# Reject traversal and symlink components, including existing ancestors of new files.
	if not path.begins_with("res://") or "\\" in path or path.to_utf8_buffer().has(0):
		return ""
	var parts := path.substr(6).split("/", false)
	var current := ProjectSettings.globalize_path("res://").trim_suffix("/")
	for part in parts:
		if part == ".." or part == "." or part == ".godot" or part == ".git":
			return ""
		var parent := DirAccess.open(current)
		if parent and parent.is_link(part):
			return ""
		current = current.path_join(part)
	return "res://" + "/".join(parts)


static func error(message: String) -> Dictionary:
	return {"error": message}


static func properties(object: Object, include_values: bool = true) -> Array:
	var result: Array = []
	for property in object.get_property_list():
		if property.usage & PROPERTY_USAGE_CATEGORY or property.usage & PROPERTY_USAGE_GROUP:
			continue
		var entry := {"name": property.name, "type": type_string(property.type), "hint": property.hint_string, "usage": property.usage}
		if include_values:
			entry["value"] = encode(object.get(property.name))
		result.append(entry)
	return result


static func has_property(object: Object, name: String) -> bool:
	for property in object.get_property_list():
		if property.name == name:
			return true
	return false


static func prepare_properties(object: Object, changes: Dictionary) -> Dictionary:
	var known := {}
	for property in object.get_property_list(): known[property.name] = property
	var values := {}
	for key in changes:
		if not known.has(key): return error("Unknown property: " + str(key))
		var property: Dictionary = known[key]
		if property.usage & PROPERTY_USAGE_READ_ONLY: return error("Read-only property: " + str(key))
		var value: Variant = decode(changes[key])
		var expected: int = property.type
		if expected == TYPE_OBJECT:
			if value != null and not value is Object: return error("Expected object/resource for " + str(key))
			if value != null and property.class_name != "" and not value.is_class(property.class_name):
				return error("Expected " + str(property.class_name) + " for " + str(key))
		elif expected != TYPE_NIL and typeof(value) != expected:
			var numeric := typeof(value) in [TYPE_INT, TYPE_FLOAT] and expected in [TYPE_INT, TYPE_FLOAT]
			var text := typeof(value) == TYPE_STRING and expected in [TYPE_STRING_NAME, TYPE_NODE_PATH]
			var packed := value is Array and expected >= TYPE_PACKED_BYTE_ARRAY and expected <= TYPE_PACKED_VECTOR4_ARRAY
			if not (numeric or text or packed): return error("Invalid type for " + str(key))
			value = type_convert(value, expected)
		values[key] = value
	return {"values": values}


static func invoke(object: Object, method: String, args: Array) -> Dictionary:
	if not object.has_method(method): return error("Unknown method: " + method)
	var decoded: Array = decode(args)
	for spec in object.get_method_list():
		if spec.name != method: continue
		var required: int = spec.args.size() - spec.default_args.size()
		if args.size() < required or (not (spec.flags & METHOD_FLAG_VARARG) and args.size() > spec.args.size()):
			return error("Argument count mismatch for " + method)
		for index in mini(decoded.size(), spec.args.size()):
			var definition: Dictionary = spec.args[index]
			var value: Variant = decoded[index]
			var expected: int = definition.type
			if expected == TYPE_NIL: continue
			if expected == TYPE_OBJECT:
				if value == null: continue
				if not value is Object: return error("Argument %d requires an object" % index)
				if definition.class_name != "" and not value.is_class(definition.class_name): return error("Argument %d requires %s" % [index, definition.class_name])
			elif typeof(value) != expected:
				var numeric := typeof(value) in [TYPE_INT, TYPE_FLOAT] and expected in [TYPE_INT, TYPE_FLOAT]
				var text := typeof(value) in [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH] and expected in [TYPE_STRING, TYPE_STRING_NAME, TYPE_NODE_PATH]
				var packed := value is Array and expected >= TYPE_PACKED_BYTE_ARRAY and expected <= TYPE_PACKED_VECTOR4_ARRAY
				if not (numeric or text or packed): return error("Invalid type for argument %d of %s" % [index, method])
				decoded[index] = type_convert(value, expected)
		break
	return {"value": encode(object.callv(method, decoded))}


static func tree(node: Node, depth: int, budget: Array = [1000]) -> Dictionary:
	budget[0] -= 1
	var result := {"name": str(node.name), "class": node.get_class(), "path": str(node.get_path()), "id": node.get_instance_id()}
	if node.get_script():
		result["script"] = node.get_script().resource_path
	if depth > 0 and budget[0] > 0:
		var children: Array = []
		for child in node.get_children():
			if budget[0] <= 0:
				result["truncated"] = true
				break
			children.append(tree(child, depth - 1, budget))
		result["children"] = children
	elif node.get_child_count() > 0:
		result["truncated"] = true
	return result
