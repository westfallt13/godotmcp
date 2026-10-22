#!/usr/bin/env python3
"""Print the live project's Hermes configuration; never edits ~/.hermes."""
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("project", type=Path, help="Godot project with the enabled plugin")
    parser.add_argument("--name", default="godot", help="Hermes MCP server name")
    args = parser.parse_args()
    if not args.name.replace("_", "").replace("-", "").isalnum():
        parser.error("name must contain only letters, numbers, underscores or hyphens")
    connection = args.project / ".godot/hermes_mcp/connection.json"
    try:
        data = json.loads(connection.read_text())
    except (OSError, ValueError) as exc:
        parser.error(f"Enable Hermes MCP in the Godot editor first: {exc}")
    print(f"mcp_servers:\n  {args.name}:\n    url: {json.dumps(data['url'])}\n"
          f"    headers:\n      Authorization: {json.dumps('Bearer ' + data['token'])}\n"
          "    timeout: 120\n    supports_parallel_tool_calls: false")


if __name__ == "__main__":
    main()
