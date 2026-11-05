import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parents[2]
_SPEC = importlib.util.spec_from_file_location(
    "mcp_call_dual",
    ROOT / "codex/skills/iphone-use/scripts/mcp_call.py",
)
MCP_CALL = importlib.util.module_from_spec(_SPEC)
_SPEC.loader.exec_module(MCP_CALL)

EXPECTED_46_TOOLS = (
    "list_devices", "screenshot", "ocr_screen", "screentext", "tap_text",
    "move_pointer", "adjust_pointer", "click_pointer",
    "tap", "double_tap", "triple_tap", "hold", "long_press",
    "swipe", "hold_drag", "scroll",
    "type_text", "press_key", "keyboard_sequence", "home",
    "wake", "lock", "unlock", "mute", "unmute",
    "record_start", "record_stop", "act",
    "setup_status", "acquire", "wait", "release",
    "photo_list", "photo_pull", "photo_delete", "photo_push",
    "file_list", "file_pull", "file_push", "file_remove",
    "app_list", "open_app", "device_info", "device_logs", "assistivetouch",
    "task",
)

EXPECTED_12_READ_ONLY = {
    "list_devices", "screenshot", "ocr_screen", "screentext", "setup_status",
    "photo_list", "photo_pull", "file_list", "file_pull",
    "app_list", "device_info", "device_logs",
}


class DualInstallAndSkillTests(unittest.TestCase):
    def test_mcp_call_exposes_all_46_tools_and_12_read_only_tools(self):
        self.assertEqual(len(MCP_CALL.TOOLS), 46)
        self.assertEqual(tuple(MCP_CALL.TOOLS), EXPECTED_46_TOOLS)
        self.assertEqual(set(MCP_CALL.READ_ONLY), EXPECTED_12_READ_ONLY)

    def test_skill_markdown_documents_ghosthand_operational_rules(self):
        skill_md = (ROOT / "codex/skills/iphone-use/SKILL.md").read_text(encoding="utf-8")
        for required_term in (
            "name: iphone-use",
            "--resident-quiet",
            "setup_status",
            "acquire",
            "wait",
            "release",
            "screentext",
            "wait_text",
            "unlock",
            "native: true",
            "photo_delete",
            "dcim-remove-forbidden",
            "gemini-3.8-flash",
            "yield_to_user",
        ):
            self.assertIn(required_term, skill_md)

    def test_install_mcp_registers_both_agy_desktop_and_codex_idempotently(self):
        with tempfile.TemporaryDirectory() as tmp:
            tmp_path = Path(tmp)
            agy_config_dir = tmp_path / "agy_config"
            agy_skills_dir = tmp_path / "agy_skills"
            codex_home = tmp_path / "codex_home"

            agy_config_dir.mkdir(parents=True, exist_ok=True)
            codex_home.mkdir(parents=True, exist_ok=True)

            (agy_config_dir / "mcp_config.json").write_text(
                json.dumps({"mcpServers": {"existing-server": {"command": "/bin/echo", "args": ["ok"]}}}),
                encoding="utf-8",
            )
            (codex_home / "config.toml").write_text(
                '[mcp_servers.other]\ncommand = "/bin/true"\n',
                encoding="utf-8",
            )

            env = dict(os.environ)
            env["AGY_CONFIG_DIR"] = str(agy_config_dir)
            env["AGY_SKILLS_DIR"] = str(agy_skills_dir)
            env["CODEX_HOME"] = str(codex_home)
            env["SKIP_BUILD"] = "1"

            for _ in range(2):
                completed = subprocess.run(
                    ["/bin/bash", str(ROOT / "scripts/install-mcp.sh")],
                    env=env,
                    capture_output=True,
                    text=True,
                    check=True,
                )
                self.assertEqual(completed.returncode, 0)

            mcp_json = json.loads((agy_config_dir / "mcp_config.json").read_text(encoding="utf-8"))
            self.assertIn("existing-server", mcp_json["mcpServers"])
            self.assertEqual(
                mcp_json["mcpServers"]["iphone-use"],
                {"command": str(ROOT / "scripts/mcp.sh"), "args": []},
            )

            codex_toml = (codex_home / "config.toml").read_text(encoding="utf-8")
            self.assertIn('[mcp_servers.other]', codex_toml)
            self.assertEqual(codex_toml.count("[mcp_servers.iphone-use]"), 1)
            self.assertIn(f'command = "{ROOT / "scripts/mcp.sh"}"', codex_toml)

            self.assertTrue((agy_skills_dir / "iphone-use" / "SKILL.md").is_file())
            self.assertTrue((codex_home / "skills" / "iphone-use" / "SKILL.md").is_file())
            self.assertTrue((ROOT / ".agents" / "skills" / "iphone-use" / "SKILL.md").is_file())


if __name__ == "__main__":
    unittest.main()
