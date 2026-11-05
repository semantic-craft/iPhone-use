#!/bin/bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
source_dir="$root/codex/skills/iphone-use"

mkdir -p "$root/.agents/skills"
ln -sfn "../../codex/skills/iphone-use" "$root/.agents/skills/iphone-use"
echo "Installed workspace skill: $root/.agents/skills/iphone-use -> $source_dir"

if [[ -n "${CODEX_HOME:-}" ]]; then
    target_dir="$CODEX_HOME/skills"
    mkdir -p "$target_dir"
    ln -sfn "$source_dir" "$target_dir/iphone-use"
    echo "Installed Codex skill: $target_dir/iphone-use -> $source_dir"
elif [[ ! -f "$HOME/Projects/xw-skills/xw-tooling/skills.toml" ]] || grep -q 'name = "iphone-use"' "$HOME/Projects/xw-skills/xw-tooling/skills.toml" 2>/dev/null; then
    target_dir="$HOME/.codex/skills"
    mkdir -p "$target_dir"
    ln -sfn "$source_dir" "$target_dir/iphone-use"
    echo "Installed Codex skill: $target_dir/iphone-use -> $source_dir"
else
    echo "Global ~/.codex/skills is managed by xw-tooling/skills.toml; using workspace skill at $root/.agents/skills/iphone-use"
fi
