#!/bin/bash
#
# Smoke-tests the MCP bridge by speaking the protocol to it the way a client would.
#
# `tools/list` must work without the app running — the bridge only needs the app for tools that
# actually touch a model, and a client that cannot enumerate tools is broken regardless.
#
# Usage: Scripts/verify-mcp.sh [--configuration release]

set -euo pipefail

cd "$(dirname "$0")/.."

CONFIGURATION="release"
while [[ $# -gt 0 ]]; do
    case "$1" in
        --configuration) CONFIGURATION="$2"; shift 2 ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

BIN="$(swift build --configuration "$CONFIGURATION" --show-bin-path)/silicon-mcp"
if [[ ! -x "$BIN" ]]; then
    echo "silicon-mcp not built at $BIN" >&2
    exit 1
fi

TRANSCRIPT="$(mktemp -t mcp-verify)"
trap 'rm -f "$TRANSCRIPT"' EXIT

printf '%s\n' \
  '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-06-18","capabilities":{},"clientInfo":{"name":"verify","version":"1"}}}' \
  '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' \
  | "$BIN" > "$TRANSCRIPT"

python3 - "$TRANSCRIPT" <<'PYTHON'
import json
import sys

with open(sys.argv[1]) as handle:
    frames = [json.loads(line) for line in handle if line.strip()]

initialize = next((f for f in frames if f.get("id") == 1), None)
assert initialize is not None, "no response to initialize"
assert "result" in initialize, f"initialize failed: {initialize}"

server = initialize["result"]["serverInfo"]["name"]
version = initialize["result"]["protocolVersion"]

listing = next((f for f in frames if f.get("id") == 2), None)
assert listing is not None, "no response to tools/list"
tools = listing["result"]["tools"]
assert len(tools) >= 10, f"expected the full tool set, got {len(tools)}"

# Every tool needs a schema a model can actually call against.
for tool in tools:
    assert tool.get("description"), f"{tool['name']} has no description"
    schema = tool.get("inputSchema", {})
    assert schema.get("type") == "object", f"{tool['name']} has no object schema"

print(f"{server} speaks MCP {version}, {len(tools)} tools advertised")
PYTHON
