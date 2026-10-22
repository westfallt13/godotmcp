@tool
extends RefCounted
## Bounded, nonblocking HTTP/1.1 transport. One request per connection.
signal request_received(client_id: int, body: PackedByteArray, headers: Dictionary, method: String)

const MAX_BODY := 2097152
const MAX_HEADER := 16384
const MAX_CLIENTS := 32
var listener := TCPServer.new()
var clients: Dictionary = {}
var next_id := 0
var port := 4960
var token := ""


func start(listen_port: int, bearer_token: String) -> Error:
	port = listen_port
	token = bearer_token
	return listener.listen(port, "127.0.0.1")


func stop() -> void:
	listener.stop()
	for client in clients.values():
		client.peer.disconnect_from_host()
	clients.clear()


func poll() -> void:
	for _index in range(4):
		if not listener.is_connection_available():
			break
		var peer := listener.take_connection()
		if clients.size() >= MAX_CLIENTS:
			peer.disconnect_from_host()
			continue
		next_id += 1
		clients[next_id] = {"peer": peer, "input": PackedByteArray(), "output": PackedByteArray(), "offset": 0, "waiting": false, "headers": {}, "length": -1, "created": Time.get_ticks_msec()}
	for id in clients.keys():
		var client: Dictionary = clients[id]
		var peer: StreamPeerTCP = client.peer
		peer.poll()
		if peer.get_status() != StreamPeerTCP.STATUS_CONNECTED or Time.get_ticks_msec() - client.created > 125000:
			_close(id)
			continue
		if not client.output.is_empty():
			var chunk: PackedByteArray = client.output.slice(client.offset, mini(client.offset + 65536, client.output.size()))
			var sent := peer.put_partial_data(chunk)
			if sent[0] != OK:
				_close(id)
				continue
			client.offset += sent[1]
			if client.offset >= client.output.size():
				_close(id)
			continue
		if client.waiting:
			continue
		if Time.get_ticks_msec() - client.created > 10000:
			respond(id, 408, {"error": "Request timeout"})
			continue
		var available := mini(peer.get_available_bytes(), 65536)
		if available == 0:
			continue
		var received := peer.get_partial_data(available)
		if received[0] != OK:
			_close(id)
			continue
		client.input.append_array(received[1])
		_parse(id, client)


func _parse(id: int, client: Dictionary) -> void:
	if client.length == -1:
		var marker := _header_end(client.input)
		if marker == -1:
			if client.input.size() > MAX_HEADER:
				respond(id, 431, {"error": "Headers too large"})
			return
		if marker > MAX_HEADER:
			respond(id, 431, {"error": "Headers too large"})
			return
		var lines: PackedStringArray = client.input.slice(0, marker).get_string_from_utf8().split("\r\n")
		var first := lines[0].split(" ")
		if first.size() != 3 or first[2] != "HTTP/1.1":
			respond(id, 400, {"error": "Expected HTTP/1.1"})
			return
		client.method = first[0]
		client.path = first[1]
		for line in lines.slice(1):
			var split := line.find(":")
			if split < 1:
				respond(id, 400, {"error": "Malformed header"})
				return
			var key := line.left(split).to_lower()
			if client.headers.has(key):
				respond(id, 400, {"error": "Duplicate header"})
				return
			client.headers[key] = line.substr(split + 1).strip_edges()
		var headers: Dictionary = client.headers
		var allowed_hosts := ["127.0.0.1:%d" % port, "localhost:%d" % port]
		if headers.get("host", "") not in allowed_hosts:
			respond(id, 403, {"error": "Invalid Host"})
			return
		if headers.has("origin") and headers.origin not in ["http://127.0.0.1:%d" % port, "http://localhost:%d" % port]:
			respond(id, 403, {"error": "Invalid Origin"})
			return
		if not _equal_secret(headers.get("authorization", ""), "Bearer " + token):
			respond(id, 401, {"error": "Bearer token required"}, {"WWW-Authenticate": "Bearer"})
			return
		if client.path != "/mcp":
			respond(id, 404, {"error": "Use /mcp"})
			return
		if client.method not in ["POST", "GET", "DELETE"]:
			respond(id, 405, {}, {"Allow": "POST, GET, DELETE"})
			return
		if headers.has("transfer-encoding"):
			respond(id, 400, {"error": "Use Content-Length; chunked requests are unsupported"})
			return
		var length_text: String = headers.get("content-length", "0")
		if not length_text.is_valid_int() or length_text.begins_with("-"):
			respond(id, 400, {"error": "Invalid Content-Length"})
			return
		client.length = length_text.to_int()
		if client.length > MAX_BODY:
			respond(id, 413, {"error": "Body exceeds 2 MiB"})
			return
		if client.method == "POST":
			if headers.get("content-type", "").split(";")[0].strip_edges() != "application/json":
				respond(id, 415, {"error": "Expected application/json"})
				return
			var accept: String = headers.get("accept", "")
			if "application/json" not in accept or "text/event-stream" not in accept:
				respond(id, 406, {"error": "Accept must include application/json and text/event-stream"})
				return
		client.input = client.input.slice(marker + 4)
	if client.input.size() >= client.length:
		client.waiting = true
		request_received.emit(id, client.input.slice(0, client.length), client.headers, client.method)


func respond(id: int, status: int, body: Variant = null, extra_headers: Dictionary = {}) -> void:
	if not clients.has(id):
		return
	var payload := PackedByteArray() if body == null else JSON.stringify(body).to_utf8_buffer()
	var reasons := {200: "OK", 202: "Accepted", 204: "No Content", 400: "Bad Request", 401: "Unauthorized", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable", 408: "Request Timeout", 413: "Content Too Large", 415: "Unsupported Media Type", 429: "Too Many Requests", 431: "Request Header Fields Too Large", 500: "Internal Server Error", 503: "Service Unavailable"}
	var head := "HTTP/1.1 %d %s\r\nContent-Type: application/json\r\nContent-Length: %d\r\nConnection: close\r\nCache-Control: no-store\r\nX-Content-Type-Options: nosniff\r\n" % [status, reasons.get(status, "Error"), payload.size()]
	for key in extra_headers:
		head += "%s: %s\r\n" % [key, extra_headers[key]]
	var packet := (head + "\r\n").to_utf8_buffer()
	packet.append_array(payload)
	clients[id].output = packet
	clients[id].offset = 0
	clients[id].waiting = true


func _close(id: int) -> void:
	clients[id].peer.disconnect_from_host()
	clients.erase(id)


static func _header_end(bytes: PackedByteArray) -> int:
	for index in range(maxi(0, bytes.size() - 65539), bytes.size() - 3):
		if bytes[index] == 13 and bytes[index + 1] == 10 and bytes[index + 2] == 13 and bytes[index + 3] == 10:
			return index
	return -1


static func _equal_secret(left: String, right: String) -> bool:
	var a := left.to_utf8_buffer()
	var b := right.to_utf8_buffer()
	var difference := a.size() ^ b.size()
	for index in range(b.size()):
		difference |= (a[index] if index < a.size() else 0) ^ b[index]
	return difference == 0
