# Hermes Godot MCP

A native **Godot 4.5+ editor plugin** that exposes the open project to
[Hermes Agent](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp)
through MCP Streamable HTTP. Enabling the addon starts the server inside the
editor; reopening that project starts it again. No Node.js, Python, sidecar
server, or external Godot process is needed for the installed addon.

The server provides **27 tools**, four resources, and a playtest prompt. Tools
cover scene and node editing, scripts, resources, project settings, input maps,
runtime inspection, simulated input, screenshots, performance metrics, and
GDScript debugging. Reflection and trusted GDScript execution provide access to
the rest of Godot's editor and runtime APIs.

## Install

1. Copy `addons/hermes_mcp` into your Godot project's `addons` directory, or
   extract the release ZIP into the project root.
2. Open the project with Godot 4.5 or newer.
3. Enable **Project → Project Settings → Plugins → Hermes MCP**.
4. The **Hermes MCP** dock shows the endpoint. Click **Copy Hermes configuration**
   and merge the copied block into `~/.hermes/config.yaml`.
5. Start Hermes, or use `/reload-mcp` in an existing session. Check the connection
   with `hermes mcp test godot`.

Godot requires plugins to be enabled once per project; merely copying files
does not bypass that switch. The enabled plugin registers a `HermesMCPRuntime`
autoload in `project.godot` for playtesting. Disabling the plugin stops the
listener and removes its autoload. The bridge is inert outside editor-launched
debug sessions, including exported games.

**Updating from v1.0.0:** Close Godot and replace only `addons/hermes_mcp` with
the folder from the v1.0.1 ZIP, then reopen the project. Enable the plugin if
you previously disabled it. This fixes the dock pushing FileSystem and the
bottom panel offscreen, and the false `HermesMCPRuntime` conflict when Godot
stores its autoload as a resource UID. Existing connection settings are retained.

Example configuration (replace the token with the dock's generated value):

```yaml
mcp_servers:
  godot:
    url: "http://127.0.0.1:4960/mcp"
    headers:
      Authorization: "Bearer YOUR_PROJECT_TOKEN"
    timeout: 120
    supports_parallel_tool_calls: false
```

If `mcp_servers` already exists, add `godot` underneath it instead of creating
a second YAML key. Hermes must run on the same machine/network namespace as
Godot, or connect through an explicitly configured local tunnel. Container
localhost and host localhost are different endpoints.

For a terminal workflow, while the editor is open:

```bash
python3 scripts/hermes_config.py /absolute/path/to/project
```

This prints the connection block; it never changes your Hermes configuration.
The connection details live in `.godot/hermes_mcp/connection.json`, which is
excluded from the release ZIP and should never be committed or shared.

## Tools

| Area | Tools | Main operations |
| --- | --- | --- |
| Project and files | `project_info`, `files_list`, `file_read`, `file_write`, `file_delete`, `files_search`, `project_setting`, `input_map` | Inspect project, edit text, search, configure settings/actions |
| Scenes and nodes | `scene`, `scene_tree`, `node`, `node_inspect`, `node_set_properties`, `node_call`, `signal_connection` | Create/open/save scenes; add, instance, duplicate, delete, rename, reparent and select nodes; edit properties and signals |
| Scripts/resources | `script`, `resource`, `class_info` | Compile-check GDScript, attach scripts, create/edit resources, discover Godot APIs |
| Editor | `editor`, `editor_execute`, `editor_screenshot` | Inspect/call editor subsystems and UI objects, undo/redo, filesystem scan, arbitrary trusted GDScript, visual inspection |
| Playtesting | `play`, `runtime`, `runtime_input`, `runtime_screenshot` | Start/stop scenes; inspect/call/mutate runtime nodes; evaluate code; inject keyboard, mouse and action input; capture images and performance metrics |
| Debugger | `debug`, `debug_events` | Attach, breakpoints, pause/continue, step over/in, stack frames, scopes, variables, expression evaluation, output/errors and lifecycle events |

Tool schemas contain action enums and parameter descriptions. The
[agent guide](addons/hermes_mcp/AGENT_GUIDE.md) gives examples, typed value
formats, and recommended workflows. Hermes can read it as `godot://guide`.
Other resources are `godot://project`, `godot://scene`, and `godot://runtime`.

Try asking Hermes:

> Inspect this project, add a player scene, save it, run it, hold Right for
> 30 frames, capture a screenshot, and check debugger output for errors.

Or:

> Connect the debugger, put a breakpoint in the player's movement function,
> run the project, inspect the stopped stack and local variables, then continue.

## Settings and debugging

Project Settings → **Hermes MCP** (enable Advanced Settings if needed):

| Setting | Default | Meaning |
| --- | --- | --- |
| `hermes_mcp/port` | `4960` | MCP HTTP port, bound only to `127.0.0.1` |
| `hermes_mcp/dap_port` | `6006` | Godot's native Debug Adapter Protocol port |
| `hermes_mcp/allow_code_execution` | `true` | Enable the explicit editor/runtime code execution tools |

Re-enable the plugin after changing either port. For several open projects,
assign each a different MCP port and a different **Editor Settings → Network →
Debug Adapter → Remote Port** (Godot can also override it with
`--dap-port`). Point each project's `hermes_mcp/dap_port` at its own adapter.
Godot's native debug adapter targets the default running session; the custom
runtime bridge supports explicit session IDs for multiple game instances.

Connect `debug` **before** play to collect output and errors. Breakpoints use
1-based line numbers. `next` steps over and `stepIn` steps in. `stackTrace`,
`scopes`, `variables` and `evaluate` use Godot's native DAP implementation;
its evaluation capabilities and language support determine what is available.
This implementation does not add a C# debugger or implement step-out, memory
inspection, or CPU profiling beyond the exposed runtime performance monitors.

## Scope and trust

The plugin provides broad programmatic control. “Anything in the editor” is
bounded by what Godot exposes to editor plugins, its UI object tree, and
GDScript. Complex operations without dedicated tools can be implemented with
`editor_execute`; this does not promise a separately tested wrapper for every
Godot editor panel, export target, importer or third-party plugin. Native OS
dialogs and platform SDK installation are outside its built-in controls.

The token authorizes **full local editor control**, including code execution.
Loopback binding, Host/Origin checks, request size limits and bearer
authentication protect the HTTP entry point. The token is randomly generated,
stored per project under `.godot`, and owner-only on Unix. Keep it private.
Delete the connection file while the plugin is disabled to rotate it.

File tools reject traversal and symlink paths, and provide optimistic SHA-256
checks. These are safeguards for routine editing, **not a security sandbox**:
generic method calls, script/resource loading, project setting changes and
trusted code execute with Godot's permissions. Turning off explicit code
execution is a convenience restriction, not an isolation boundary.

Dedicated structural scene edits, property edits, script attachment and signal
connections are undoable. File writes, resource updates, project settings,
arbitrary calls and code execution are not automatically undoable.

## Transport and limits

- Native MCP Streamable HTTP at `/mcp`, with JSON responses, session IDs,
  initialization, ping, tools, resources and prompts. Protocol versions
  `2025-06-18` and `2025-11-25` are supported. Unsupported versions negotiate
  the latest supported version. The optional GET SSE stream returns HTTP 405.
- 2 MiB request bodies, 16 KiB headers, 32 simultaneous connections,
  16 MCP sessions, one-hour idle session expiry. Sessions are in memory;
  reconnect after toggling the plugin or restarting the editor.
- One tool executes at a time. Parallel attempts get a retryable tool error.
  Runtime calls time out at 30 seconds, DAP at 15, and outer tool requests at 90.
  Arbitrary code cannot be safely preempted. A timeout does not undo a mutation.
  A stalled script can require re-enabling the plugin; an infinite synchronous
  loop can freeze Godot itself. Cancellation notifications are acknowledged,
  but cannot interrupt or roll back engine operations.
- Screenshots need a graphical renderer. A headless editor returns a clear
  error for its own screenshots; a game it launches can still use a display.
- Runtime inspection/input requires the bridge handshake and a game that is
  not stopped at a debugger breakpoint. Use DAP while broken.
- File listings, searches, trees, collections and event histories are bounded;
  responses indicate truncation where applicable. Event history stores 1,000
  events and exposes a cursor plus a gap flag.
- Editor UI dialogs can block an operation. Inspect `editor` with `ui_tree`
  or `editor_screenshot` and resolve the dialog through its exposed methods.

## Development and verification

Open this repository's `project.godot` for the included playground. Arrow keys
move a square and Space/Enter increments a counter. The addon is enabled in
this development project.

```bash
# Real editor, HTTP, editing, runtime input and debugger integration tests.
python3 tests/integration.py --godot /path/to/godot

# Also verify editor screenshots; requires a display (or xvfb-run on Linux).
python3 tests/integration.py --godot /path/to/godot --graphical

# Compatibility with the official MCP Python client used by Hermes.
python3 -m pip install 'mcp>=1.12,<2'
python3 tests/sdk_smoke.py --godot /path/to/godot

# Create the installable addon ZIP.
python3 scripts/package.py
```

The test runner copies the addon into a temporary project and isolates Godot's
editor settings and user data. It tests real engine behavior rather than mocked
editor APIs. See [architecture](docs/architecture.md) for the implementation.
The installed plugin has no Python dependency; Python is used only by development
tests, configuration printing and packaging.

Verified locally with **Godot 4.5.1 and 4.6.1 on Linux**, including a graphical
editor and game: all twelve integration cases pass, including dock bounds and
autoload cleanup across re-enable and restart. One earlier 4.6.1 run returned
an intermittent DAP `unknown` error while inspecting variables; the full rerun
passed. Transport compatibility was previously verified with the official
**MCP Python SDK 1.30.0** for discovery, tool calls, resources, prompts and session cleanup. Windows,
macOS, other Godot versions and Hermes itself have not been run in this workspace.
The test harness uses POSIX process groups; run it on Linux/macOS or CI.

## References

- [Hermes MCP configuration](https://hermes-agent.nousresearch.com/docs/user-guide/features/mcp)
- [MCP Streamable HTTP specification](https://modelcontextprotocol.io/specification/2025-06-18/basic/transports)
- [Godot EditorInterface](https://docs.godotengine.org/en/stable/classes/class_editorinterface.html)
- [Godot EditorDebuggerPlugin](https://docs.godotengine.org/en/stable/classes/class_editordebuggerplugin.html)
- [Godot DAP implementation](https://github.com/godotengine/godot/tree/4.5/editor/debugger/debug_adapter)

MIT licensed. Godot and Hermes Agent are separate projects; this addon is an
independent integration.
