#!/usr/bin/env python3
"""Real-engine integration tests; only Python's standard library is required.

python3 tests/integration.py --godot /path/to/godot [--graphical]
Runs an isolated project and editor profile under /tmp; never edits your project.
"""
import argparse
import concurrent.futures
import hashlib
import http.client
import json
import os
from pathlib import Path
import shutil
import signal
import socket
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
OPTIONS = None
ENVIRONMENT = None


def free_port():
    with socket.socket() as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


class Client:
    def __init__(self, connection):
        self.port = int(connection["url"].split(":")[2].split("/")[0])
        self.token = connection["token"]
        self.session = None
        self.sequence = 0

    def http(self, payload=None, *, method="POST", headers=None, raw=None):
        connection = http.client.HTTPConnection("127.0.0.1", self.port, timeout=100)
        actual = {"Content-Type": "application/json", "Accept": "application/json, text/event-stream",
                  "Authorization": f"Bearer {self.token}", "MCP-Protocol-Version": "2025-06-18"}
        if self.session:
            actual["Mcp-Session-Id"] = self.session
        actual.update(headers or {})
        data = raw if raw is not None else (json.dumps(payload).encode() if payload is not None else b"")
        connection.request(method, "/mcp", body=data, headers=actual)
        response = connection.getresponse()
        body = response.read()
        result = (response.status, dict(response.getheaders()), json.loads(body) if body else None)
        connection.close()
        return result

    def rpc(self, method, params=None):
        self.sequence += 1
        status, _, data = self.http({"jsonrpc": "2.0", "id": self.sequence, "method": method, "params": params or {}})
        if status != 200 or "error" in data:
            raise AssertionError(f"{method}: HTTP {status}: {data}")
        return data["result"]

    def initialize(self):
        status, headers, data = self.http({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {
            "protocolVersion": "2025-06-18", "capabilities": {}, "clientInfo": {"name": "integration", "version": "1"}}})
        assert status == 200 and data["result"]["protocolVersion"] == "2025-06-18", data
        self.session = headers["Mcp-Session-Id"]
        status, _, _ = self.http({"jsonrpc": "2.0", "method": "notifications/initialized"})
        assert status == 202

    def tool(self, tool_name, error=False, **args):
        result = self.rpc("tools/call", {"name": tool_name, "arguments": args})
        if bool(result.get("isError")) != error:
            detail = {**result, "content": [{k: v for k, v in block.items() if k != "data"} for block in result.get("content", [])]}
            raise AssertionError(f"{tool_name} {args}: {detail}")
        if result["content"][0]["type"] == "image":
            return result
        return json.loads(result["content"][0]["text"])


class Environment:
    def __init__(self, godot, graphical=False):
        self.directory = Path(tempfile.mkdtemp(prefix="hermes-mcp-test-"))
        self.project = self.directory / "project"
        self.project.mkdir()
        for folder in ("addons", "examples"):
            shutil.copytree(ROOT / folder, self.project / folder)
        port, dap_port, debug_port = free_port(), free_port(), free_port()
        config = (ROOT / "project.godot").read_text()
        config += f'\n[hermes_mcp]\nport={port}\ndap_port={dap_port}\n'
        (self.project / "project.godot").write_text(config)
        self.log_path = self.directory / "editor.log"
        self.log = self.log_path.open("w")
        env = os.environ.copy()
        for name in ("DATA", "CONFIG", "CACHE"):
            env[f"XDG_{name}_HOME"] = str(self.directory / name.lower())
        settings_dir = self.directory / "config/godot"
        settings_dir.mkdir(parents=True)
        version = subprocess.check_output([godot, "--version"], text=True).split(".")
        settings = '[gd_resource type="EditorSettings" format=3]\n\n[resource]\n'
        settings += f'network/debug_adapter/remote_port = {dap_port}\nnetwork/debug/remote_port = {debug_port}\n'
        settings += 'run/window_placement/game_embed_mode = 0\n'
        (settings_dir / f"editor_settings-{version[0]}.{version[1]}.tres").write_text(settings)
        command = [godot, "--editor", "--path", str(self.project), "--audio-driver", "Dummy"]
        if not graphical:
            command.append("--headless")
        self.process = subprocess.Popen(command, stdout=self.log, stderr=subprocess.STDOUT, env=env, start_new_session=True)
        target = self.project / ".godot/hermes_mcp/connection.json"
        deadline = time.monotonic() + 45
        while time.monotonic() < deadline:
            if self.process.poll() is not None:
                raise RuntimeError(self.log_path.read_text())
            if target.exists():
                try:
                    self.client = Client(json.loads(target.read_text()))
                    self.client.initialize()
                    return
                except (OSError, ValueError, KeyError):
                    pass
            time.sleep(.1)
        raise TimeoutError(self.log_path.read_text())

    def close(self):
        try:
            self.client.tool("play", action="stop")
            self.client.http(method="DELETE")
        except Exception:
            pass
        if self.process.poll() is None:
            os.killpg(self.process.pid, signal.SIGTERM)
            try:
                self.process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGKILL)
                self.process.wait()
        self.log.close()


class Integration(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.env = ENVIRONMENT
        cls.client = ENVIRONMENT.client

    def test_00_protocol_and_authentication(self):
        c = self.client
        tools = c.rpc("tools/list")["tools"]
        self.assertEqual(len(tools), 27)
        self.assertEqual(len({t["name"] for t in tools}), 27)
        self.assertEqual(c.rpc("ping"), {})
        self.assertEqual(len(c.rpc("resources/list")["resources"]), 4)
        self.assertIn("Godot", c.rpc("resources/read", {"uri": "godot://guide"})["contents"][0]["text"])
        self.assertEqual(c.rpc("prompts/list")["prompts"][0]["name"], "playtest")
        self.assertIn("test movement", c.rpc("prompts/get", {"name": "playtest", "arguments": {"objective": "test movement"}})["messages"][0]["content"]["text"])
        self.assertEqual(c.http(method="GET")[0], 405)
        for headers, expected in [({"Authorization": "Bearer invalid"}, 401), ({"Origin": "https://evil.example"}, 403),
                                  ({"Host": "evil.example"}, 403), ({"Mcp-Session-Id": "absent"}, 404),
                                  ({"MCP-Protocol-Version": "bad"}, 400), ({"Content-Type": "text/plain"}, 415),
                                  ({"Accept": "text/html"}, 406)]:
            self.assertEqual(c.http({"jsonrpc": "2.0", "id": 9, "method": "ping"}, headers=headers)[0], expected)
        self.assertEqual(c.http(raw=b"{broken")[2]["error"]["code"], -32700)
        self.assertEqual(c.http(raw=b"[]")[2]["error"]["code"], -32600)
        invalid = {"jsonrpc": "2.0", "id": 9, "method": "tools/call", "params": {"name": "node", "arguments": {"action": "unknown"}}}
        self.assertEqual(c.http(invalid)[2]["error"]["code"], -32602)
        invalid["params"] = {"name": "runtime", "arguments": {"action": "wait", "frames": 1.5}}
        self.assertEqual(c.http(invalid)[2]["error"]["code"], -32602)

    def test_01_fragmented_http_and_limits(self):
        c = self.client
        body = json.dumps({"jsonrpc": "2.0", "id": "fragmented", "method": "ping"}).encode()
        header = (f"POST /mcp HTTP/1.1\r\nHost: 127.0.0.1:{c.port}\r\nAuthorization: Bearer {c.token}\r\n"
                  f"Mcp-Session-Id: {c.session}\r\nContent-Type: application/json\r\nAccept: application/json, text/event-stream\r\nContent-Length: {len(body)}\r\n\r\n").encode()
        with socket.create_connection(("127.0.0.1", c.port), timeout=10) as sock:
            for part in (header[:20], header[20:-1], header[-1:], body[:3], body[3:]):
                sock.sendall(part)
                time.sleep(.02)
            response = http.client.HTTPResponse(sock)
            response.begin()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read())["id"], "fragmented")
        self.assertEqual(c.http(raw=b"", headers={"Content-Length": "2097153"})[0], 413)
        self.assertEqual(c.http(raw=b"", headers={"Transfer-Encoding": "chunked"})[0], 400)

    def test_02_sessions_and_invalid_tagged_values(self):
        c = self.client
        other = Client({"url": f"http://127.0.0.1:{c.port}/mcp", "token": c.token})
        other.initialize()
        self.assertNotEqual(c.session, other.session)
        self.assertEqual(other.rpc("ping"), {})
        self.assertEqual(other.http(method="DELETE")[0], 204)
        self.assertEqual(other.http({"jsonrpc": "2.0", "id": 1, "method": "ping"})[0], 404)
        for tagged in ({"$type": "Rect2"}, {"$type": "Vector2", "x": "bad"}, {"$type": "Object", "id": -1},
                       {"$type": "Resource", "path": "res://.godot/hermes_mcp/connection.json"}):
            packet = {"jsonrpc": "2.0", "id": 1, "method": "tools/call", "params": {
                "name": "editor_execute", "arguments": {"code": "return args", "args": {"value": tagged}}}}
            self.assertEqual(c.http(packet)[2]["error"]["code"], -32602)
        packet = {"jsonrpc": "2.0", "id": 1.5, "method": "ping"}
        self.assertEqual(c.http(packet)[2]["error"]["code"], -32600)
        self.assertIsInstance(c.http({"jsonrpc": "2.0", "id": 7, "method": "ping"})[2]["id"], int)

    def test_10_files_and_path_confinement(self):
        c = self.client
        path = "res://generated/hello.txt"
        text = "First line\nこんにちは 🌍\nThird line\n"
        result = c.tool("file_write", path=path, content=text)
        self.assertEqual(result["sha256"], hashlib.sha256(text.encode()).hexdigest())
        self.assertEqual(c.tool("file_read", path=path, start_line=2, end_line=2)["content"], "こんにちは 🌍")
        c.tool("file_write", error=True, path=path, content="collision")
        c.tool("file_write", error=True, path=path, content="bad", expected_sha256="bad")
        c.tool("file_write", path=path, content=text + "tail", expected_sha256=result["sha256"])
        self.assertTrue(c.tool("files_search", query="こんにちは", path="res://generated")["matches"])
        self.assertIn(path, c.tool("files_list", path="res://generated")["files"])
        for forbidden in ("res://../escape.txt", "/tmp/escape.txt", "res://.godot/hermes_mcp/connection.json"):
            c.tool("file_write", error=True, path=forbidden, content="blocked")
        (self.env.project / "external").symlink_to(self.env.directory, target_is_directory=True)
        c.tool("file_write", error=True, path="res://external/escape.txt", content="blocked")
        current = c.tool("file_read", path=path)
        c.tool("file_delete", error=True, path=path, expected_sha256="bad")
        c.tool("file_delete", path=path, expected_sha256=current["sha256"])
        c.tool("file_read", error=True, path=path)

    def test_20_scene_nodes_and_undo(self):
        c = self.client
        c.tool("scene", action="new", path="res://generated/test_scene.tscn", root_type="Node2D", name="TestRoot")
        c.tool("node", action="create", type="Node2D", name="Player")
        c.tool("node_set_properties", path="Player", properties={"position": {"$type": "Vector2", "x": 25, "y": 40}})
        self.assertEqual(c.tool("node_call", path="Player", method="get_position")["value"]["x"], 25)
        self.assertTrue(c.tool("editor", action="undo")["changed"])
        self.assertEqual(c.tool("node_call", path="Player", method="get_position")["value"]["x"], 0)
        self.assertTrue(c.tool("editor", action="redo")["changed"])
        c.tool("node", action="duplicate", path="Player", name="Copy")
        c.tool("node", action="create", type="Node2D", name="Container")
        c.tool("node", action="reparent", path="Copy", parent="Container")
        c.tool("node", action="rename", path="Container/Copy", name="Child")
        c.tool("node", action="select", path="Container/Child")
        self.assertIn("Container/Child", c.tool("project_info")["selected_nodes"])
        c.tool("node", action="delete", path="Container/Child")
        c.tool("editor", action="undo")
        self.assertEqual(c.tool("node_inspect", path="Container/Child")["object"]["class"], "Node2D")
        c.tool("node", error=True, action="reparent", path="Container", parent="Container/Child")
        c.tool("node_set_properties", error=True, path="Player", properties={"does_not_exist": 1})
        c.tool("node_call", error=True, path="Player", method="unknown")
        c.tool("node_call", error=True, path="Player", method="get_node", args=[42])
        c.tool("scene", action="save")
        saved = c.tool("file_read", path="res://generated/test_scene.tscn")["content"]
        self.assertIn('name="Child"', saved)
        self.assertIn("Vector2(25, 40)", saved)
        self.assertEqual(c.tool("scene_tree")["tree"]["name"], "TestRoot")

    def test_21_resources_scripts_signals(self):
        c = self.client
        c.tool("scene", action="open", path="res://generated/test_scene.tscn")
        source = 'extends Node2D\nsignal fired\nvar count := 0\nfunc receive():\n\tcount += 1\n'
        c.tool("file_write", path="res://generated/actor.gd", content=source)
        self.assertTrue(c.tool("script", action="validate", source=source)["valid"])
        c.tool("script", action="attach", path="res://generated/actor.gd", node_path="Player")
        c.tool("script", action="attach", path="res://generated/actor.gd", node_path="Container")
        c.tool("signal_connection", action="connect", source="Player", signal="fired", target="Container", method="receive")
        c.tool("scene", action="save")
        self.assertIn('[connection signal="fired"', c.tool("file_read", path="res://generated/test_scene.tscn")["content"])
        c.tool("signal_connection", action="disconnect", source="Player", signal="fired", target="Container", method="receive")
        c.tool("resource", action="create", type="StandardMaterial3D", path="res://generated/material.tres",
               properties={"albedo_color": {"$type": "Color", "r": .2, "g": .5, "b": .8, "a": 1}})
        self.assertEqual(c.tool("resource", action="inspect", path="res://generated/material.tres")["object"]["class"], "StandardMaterial3D")
        c.tool("resource", action="update", path="res://generated/material.tres", properties={"roughness": .75})
        self.assertIn("StandardMaterial3D", c.tool("class_info", filter="StandardMaterial")["classes"])
        self.assertEqual(c.tool("class_info", **{"class": "Node2D"})["parent"], "CanvasItem")
        c.tool("input_map", action="set", name="test_action", events=[{"class": "InputEventKey", "properties": {"physical_keycode": 75}}])
        self.assertIn("test_action", c.tool("input_map", action="list")["actions"])
        c.tool("input_map", action="erase", name="test_action")

    def test_22_code_and_serialization(self):
        c = self.client
        ui = c.tool("editor", action="ui_tree", depth=1)["tree"]
        inspected = c.tool("editor", action="inspect", object_id=ui["id"])
        self.assertEqual(inspected["object"]["id"], ui["id"])
        result = c.tool("editor_execute", code="return {\"answer\": args.value + 1, \"vector\": Vector3(1, 2, 3)}", args={"value": 41})
        self.assertEqual(result["value"]["answer"], 42)
        self.assertEqual(result["value"]["vector"]["$type"], "Vector3")
        c.tool("project_setting", action="set", key="hermes_mcp/allow_code_execution", value=False)
        c.tool("editor_execute", error=True, code="return 1")
        c.tool("project_setting", action="set", key="hermes_mcp/allow_code_execution", value=True)
        with concurrent.futures.ThreadPoolExecutor() as pool:
            pending = pool.submit(c.tool, "editor_execute", code="await plugin.get_tree().create_timer(0.5).timeout\nreturn 7")
            time.sleep(.15)
            c.tool("project_info", error=True)
            self.assertEqual(pending.result()["value"], 7)
        if OPTIONS.graphical:
            result = c.tool("editor_screenshot", max_width=640)
            self.assertEqual(result["content"][0]["mimeType"], "image/png")
            import base64
            (self.env.directory / "editor.png").write_bytes(base64.b64decode(result["content"][0]["data"]))
        else:
            c.tool("editor_screenshot", error=True)

    def test_30_playtest_and_debugger(self):
        c = self.client
        c.tool("scene", action="open", path="res://examples/playground.tscn")
        self.assertTrue(c.tool("debug", command="connect")["connected"])
        self.assertTrue(c.tool("play", action="start")["runtime_ready"])
        c.tool("debug", command="attach")
        self.assertTrue(c.tool("runtime", action="tree")["tree"]["children"])
        self.assertEqual(c.tool("runtime", action="call", method="add_numbers", args=[2, 3])["value"], 5)
        before = c.tool("runtime", action="evaluate", code="return root.presses")["value"]
        c.tool("runtime_input", kind="action", action="ui_accept", hold_frames=3)
        self.assertEqual(c.tool("runtime", action="evaluate", code="return root.presses")["value"], before + 1)
        initial_x = c.tool("runtime", action="evaluate", code="return root.get_node('Player').position.x")["value"]
        c.tool("runtime_input", kind="key", key="Right", hold_frames=8)
        final_x = c.tool("runtime", action="evaluate", code="return root.get_node('Player').position.x")["value"]
        self.assertGreater(final_x, initial_x)
        c.tool("runtime", action="set_properties", path="Player", properties={"position": {"$type": "Vector2", "x": 100, "y": 200}})
        self.assertEqual(c.tool("runtime", action="call", path="Player", method="get_position")["value"]["x"], 100)
        c.tool("runtime", action="pause", paused=True)
        self.assertTrue(c.tool("runtime", action="metrics")["paused"])
        c.tool("runtime", action="pause", paused=False)
        c.tool("runtime", action="wait", frames=2)
        runtime_display = c.tool("runtime", action="evaluate", code="return DisplayServer.get_name()")["value"]
        if runtime_display != "headless":
            image = c.tool("runtime_screenshot", max_width=640)
            self.assertEqual(image["content"][0]["mimeType"], "image/png")
            import base64
            (self.env.directory / "runtime.png").write_bytes(base64.b64decode(image["content"][0]["data"]))
        else:
            c.tool("runtime_screenshot", error=True)
        # Hit an actual GDScript breakpoint and inspect a real stack and variables.
        source = (self.env.project / "examples/playground.gd").read_text().splitlines()
        line = next(i + 1 for i, text in enumerate(source) if "steps += 1" in text)
        c.tool("debug", command="setBreakpoints", arguments={"source": {"path": "res://examples/playground.gd"}, "breakpoints": [{"line": line}]})
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            sessions = c.tool("play", action="status")["sessions"]
            if any(s["breaked"] for s in sessions):
                break
            time.sleep(.05)
        self.assertTrue(any(s["breaked"] for s in sessions))
        c.tool("runtime", action="tree", error=True)

        frames = c.tool("debug", command="stackTrace")["body"]["stackFrames"]
        self.assertTrue(frames)
        scopes = c.tool("debug", command="scopes", arguments={"frameId": frames[0]["id"]})["body"]["scopes"]
        self.assertTrue(scopes)
        variables = c.tool("debug", command="variables", arguments={"variablesReference": scopes[0]["variablesReference"]})
        self.assertIn("variables", variables["body"])
        c.tool("debug", command="evaluate", arguments={"expression": "steps", "frameId": frames[0]["id"]})
        c.tool("debug", command="setBreakpoints", arguments={"source": {"path": "res://examples/playground.gd"}, "breakpoints": []})
        c.tool("debug", command="next")
        c.tool("debug", command="continue")
        events = c.tool("debug_events", limit=500)
        self.assertTrue(any(e["data"].get("event") == "output" for e in events["events"]))
        self.assertFalse(c.tool("play", action="stop")["playing"])
        c.tool("runtime", action="tree", error=True)

    def test_90_plugin_lifecycle(self):
        c = self.client
        original_token = c.token
        code = ('editor.set_plugin_enabled.call_deferred("hermes_mcp", false)\n'
                'editor.get_base_control().get_tree().create_timer(0.5).timeout.connect('
                'func(): editor.set_plugin_enabled("hermes_mcp", true))\nreturn true')
        # The disable closes the in-flight connection; either outcome is valid.
        try:
            c.tool("editor_execute", code=code)
        except (OSError, http.client.HTTPException):
            pass
        deadline = time.monotonic() + 10
        saw_restart = False
        while time.monotonic() < deadline:
            try:
                status, _, _ = c.http({"jsonrpc": "2.0", "id": 1, "method": "ping"})
                if status == 404:
                    saw_restart = True
                    break
            except (OSError, http.client.HTTPException):
                pass
            time.sleep(.1)
        self.assertTrue(saw_restart, "Plugin did not restart with cleared sessions")
        c.initialize()
        self.assertEqual(c.token, original_token)
        self.assertTrue(c.tool("project_info")["name"])
        self.assertEqual(c.tool("project_setting", action="get", key="autoload/HermesMCPRuntime")["value"],
                         "*res://addons/hermes_mcp/runtime/runtime_bridge.gd")


def main():
    global OPTIONS, ENVIRONMENT
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default=os.environ.get("GODOT", "godot"))
    parser.add_argument("--graphical", action="store_true", help="Run with a display, e.g. xvfb-run")
    OPTIONS, remaining = parser.parse_known_args()
    ENVIRONMENT = Environment(OPTIONS.godot, OPTIONS.graphical)
    print(f"Test project/log: {ENVIRONMENT.directory}", flush=True)
    try:
        suite = unittest.defaultTestLoader.loadTestsFromTestCase(Integration)
        if remaining:
            suite = unittest.TestSuite(test for test in suite if any(pattern in test.id() for pattern in remaining))
        result = unittest.TextTestRunner(verbosity=2).run(suite)
    finally:
        ENVIRONMENT.close()
    if not result.wasSuccessful():
        print("\nEditor log tail:\n" + ENVIRONMENT.log_path.read_text()[-15000:])
    raise SystemExit(0 if result.wasSuccessful() else 1)


if __name__ == "__main__":
    main()
