#!/bin/bash
#
# Builds the MCP bridge and prints the config each client needs.
#
# Usage: Scripts/install-mcp.sh [--prefix /usr/local/bin] [--configure-claude]

set -euo pipefail

cd "$(dirname "$0")/.."

PREFIX="/usr/local/bin"
CONFIGURE_CLAUDE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prefix) PREFIX="$2"; shift 2 ;;
        --configure-claude) CONFIGURE_CLAUDE=1; shift ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

echo "==> Building silicon-mcp"
swift build --configuration release --arch arm64 --product silicon-mcp
BINARY="$(swift build --configuration release --arch arm64 --show-bin-path)/silicon-mcp"

echo "==> Installing to $PREFIX"
mkdir -p "$PREFIX"
# Needs sudo if the prefix is root-owned; try without first so the common case is quiet.
if ! install -m 755 "$BINARY" "$PREFIX/silicon-mcp" 2>/dev/null; then
    echo "    (requires sudo)"
    sudo install -m 755 "$BINARY" "$PREFIX/silicon-mcp"
fi

TARGET="$PREFIX/silicon-mcp"
echo "==> Installed $TARGET"
echo

CLAUDE_CONFIG="$HOME/Library/Application Support/Claude/claude_desktop_config.json"

if [[ "$CONFIGURE_CLAUDE" == "1" ]]; then
    echo "==> Configuring Claude Desktop"
    mkdir -p "$(dirname "$CLAUDE_CONFIG")"
    [[ -f "$CLAUDE_CONFIG" ]] || echo '{}' > "$CLAUDE_CONFIG"
    # Merge rather than overwrite: the user almost certainly has other servers configured.
    python3 - "$CLAUDE_CONFIG" "$TARGET" <<'PYTHON'
import json, sys
path, binary = sys.argv[1], sys.argv[2]
with open(path) as handle:
    try:
        config = json.load(handle)
    except json.JSONDecodeError:
        config = {}
config.setdefault("mcpServers", {})["silicon-optimizer"] = {"command": binary}
with open(path, "w") as handle:
    json.dump(config, handle, indent=2)
print(f"    Updated {path}")
PYTHON
    echo "    Restart Claude Desktop to pick it up."
else
    cat <<EOF
Claude Desktop
  Add to $CLAUDE_CONFIG

  {
    "mcpServers": {
      "silicon-optimizer": { "command": "$TARGET" }
    }
  }

  Or re-run this script with --configure-claude to do it automatically.

Claude Code
  claude mcp add --scope user silicon-optimizer $TARGET

ChatGPT
  The ChatGPT desktop app only accepts internet-hosted connectors, so there
  is no local hook. ChatGPT plans include Codex, which connects fully:

  codex mcp add silicon-optimizer -- $TARGET

Or skip the terminal entirely: the app's Settings pane has a "Your other AIs"
section with one-click Connect buttons for everything it finds.
EOF
fi

echo
echo "The Silicon Optimizer app must be running for the tools to work —"
echo "the bridge talks to it, so an assistant uses the model you already have loaded."
