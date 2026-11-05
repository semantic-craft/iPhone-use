#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$root/scripts/mcp.sh"
source_skill="$root/codex/skills/iphone-use"

if [[ "${SKIP_BUILD:-0}" != "1" ]] || [[ ! -x "$root/.build/release/iphone-use" ]]; then
    swift build -c release --package-path "$root"
fi

agy_config_dir="${AGY_CONFIG_DIR:-$HOME/.gemini/config}"
mkdir -p "$agy_config_dir"
agy_mcp_config="$agy_config_dir/mcp_config.json"

python3 - "$agy_mcp_config" "$launcher" <<'PY'
import json
import pathlib
import sys

config_path = pathlib.Path(sys.argv[1])
launcher_path = sys.argv[2]

if config_path.exists():
    try:
        data = json.loads(config_path.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        data = {}
else:
    data = {}

if not isinstance(data, dict):
    data = {}

servers = data.setdefault("mcpServers", {})
if not isinstance(servers, dict):
    servers = {}
    data["mcpServers"] = servers

servers["iphone-use"] = {
    "command": launcher_path,
    "args": [],
}

config_path.write_text(json.dumps(data, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PY
echo "Registered Antigravity Desktop MCP: $agy_mcp_config -> $launcher"

mkdir -p "$root/.agents/skills"
ln -sfn "../../codex/skills/iphone-use" "$root/.agents/skills/iphone-use"
echo "Installed workspace skill: $root/.agents/skills/iphone-use -> $source_skill"

if [[ -n "${AGY_SKILLS_DIR:-}" ]]; then
    mkdir -p "$AGY_SKILLS_DIR"
    ln -sfn "$source_skill" "$AGY_SKILLS_DIR/iphone-use"
    echo "Installed AGY skill: $AGY_SKILLS_DIR/iphone-use -> $source_skill"
fi

"$root/scripts/install-codex-mcp.sh"
