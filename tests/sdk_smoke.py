#!/usr/bin/env python3
"""Test with the official MCP client SDK (pip install 'mcp>=1.12,<2')."""
import argparse
import asyncio
from datetime import timedelta
import json
from pathlib import Path

import httpx
from mcp import ClientSession
from mcp.client.streamable_http import streamable_http_client

from integration import Environment


async def verify(connection_path):
    data = json.loads(Path(connection_path).read_text())
    async with httpx.AsyncClient(headers={"Authorization": f"Bearer {data['token']}"}, timeout=120) as http:
        async with streamable_http_client(data["url"], http_client=http) as (read, write, get_session_id):
            async with ClientSession(read, write, read_timeout_seconds=timedelta(seconds=20)) as session:
                result = await session.initialize()
                assert result.serverInfo.name == "hermes-godot-mcp"
                assert get_session_id()
                tools = await session.list_tools()
                assert len(tools.tools) == 27
                result = await session.call_tool("project_info", {})
                assert not result.isError
                assert result.structuredContent["godot"]["major"] == 4
                assert len((await session.list_resources()).resources) == 4
                guide = await session.read_resource("godot://guide")
                assert "playtest" in guide.contents[0].text.lower()
                prompts = await session.list_prompts()
                assert prompts.prompts[0].name == "playtest"
                prompt = await session.get_prompt("playtest", {"objective": "verify player movement"})
                assert "verify player movement" in prompt.messages[0].content.text
                result = await session.call_tool("runtime", {"action": "tree"})
                assert result.isError
                await session.send_ping()
                print(f"Official MCP SDK passed: {len(tools.tools)} tools, resources, prompts, errors, ping and session cleanup")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--godot", default="godot")
    parser.add_argument("--connection", type=Path, help="Use an existing project's connection.json instead")
    args = parser.parse_args()
    environment = None
    try:
        if args.connection:
            connection = args.connection
        else:
            environment = Environment(args.godot)
            connection = environment.project / ".godot/hermes_mcp/connection.json"
        asyncio.run(verify(connection))
    finally:
        if environment:
            environment.close()


if __name__ == "__main__":
    main()
