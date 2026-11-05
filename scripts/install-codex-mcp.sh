#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
launcher="$root/scripts/mcp.sh"

if [[ "${SKIP_BUILD:-0}" != "1" ]] || [[ ! -x "$root/.build/release/iphone-use" ]]; then
    swift build -c release --package-path "$root"
fi

if [[ -n "${CODEX_HOME:-}" ]] || ! command -v codex >/dev/null 2>&1; then
    target_home="${CODEX_HOME:-$HOME/.codex}"
    mkdir -p "$target_home"
    config_file="$target_home/config.toml"
    python3 - "$config_file" "$launcher" <<'PY'
import pathlib
import re
import sys

config_path = pathlib.Path(sys.argv[1])
launcher_path = sys.argv[2]
existing = config_path.read_text(encoding="utf-8") if config_path.exists() else ""
pattern = re.compile(r"(?ms)^\[mcp_servers\.iphone-use\]\n(?:^(?!\[).*\n?)*")
block = f'[mcp_servers.iphone-use]\ncommand = "{launcher_path}"\nargs = []\n'
if pattern.search(existing):
    updated = pattern.sub(block, existing)
else:
    sep = "" if (not existing or existing.endswith("\n\n")) else ("\n" if existing.endswith("\n") else "\n\n")
    updated = existing + sep + block
config_path.write_text(updated, encoding="utf-8")
PY
    echo "Registered iphone-use MCP in $config_file -> $launcher"
else
    codex mcp remove iphone-use >/dev/null 2>&1 || true
    codex mcp add iphone-use -- "$launcher"
fi

"$root/scripts/install-codex-skill.sh"
if [[ -z "${CODEX_HOME:-}" ]] && [[ "${SKIP_ENSURE_SERVICE:-0}" != "1" ]]; then
    python3 "$root/codex/skills/iphone-use/scripts/ensure_service.py" --wait 6 || true
fi
