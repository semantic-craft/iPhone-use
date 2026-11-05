"""Recovery decisions and HTTP checks without restarting hardware in tests."""

import importlib.util
import io
import json
import os
from pathlib import Path
import subprocess
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from unittest.mock import Mock, patch


ROOT = Path(__file__).resolve().parents[2]
SCRIPT = ROOT / "codex/skills/iphone-use/scripts/ensure_service.py"
spec = importlib.util.spec_from_file_location("service_recovery", SCRIPT)
recovery = importlib.util.module_from_spec(spec)
spec.loader.exec_module(recovery)

EMPTY = {"devices": [], "bluetooth": "poweredOn", "unmatchedHosts": []}
READY = dict(EMPTY, devices=[{"id": "phone-1", "name": "iPhone", "bluetooth": True}])
OTHER = dict(EMPTY, devices=[{"id": "phone-2", "name": "Other", "bluetooth": True}])


class FakeService:
    def __init__(self, snapshots, running=False):
        self.snapshots = list(snapshots)
        self.current = None
        self.events = []
        self.running = running
        self.port = 7400
        self.repo = ROOT
        self.config = "release"
        self.binary = SCRIPT
        self.log = Path("/tmp/unused-recovery.log")

    def snapshot(self):
        if self.snapshots:
            self.current = self.snapshots.pop(0)
        return self.current

    def listeners(self):
        return {123} if self.running else set()

    def stop(self, pids):
        self.events.append(("stop", pids))
        self.running = False

    def start(self):
        self.events.append(("start",))
        self.running = True

    def check_child(self):
        pass


class RecoveryTests(unittest.TestCase):
    def test_healthy_app_is_reused(self):
        service = FakeService([READY], running=True)
        result = recovery.recover(service, wait=0)
        self.assertTrue(result["ok"])
        self.assertEqual(service.events, [])

    def test_stale_binary_mtime_triggers_restart(self):
        stale_ready = dict(READY, binaryMtime=100)
        fresh_ready = dict(READY, binaryMtime=int(SCRIPT.stat().st_mtime))
        service = FakeService([stale_ready, fresh_ready], running=True)
        result = recovery.recover(service, wait=0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["actions"], ["restarted"])
        self.assertEqual(service.events, [("stop", {123}), ("start",)])

    def test_missing_app_starts_and_waits_for_device(self):
        service = FakeService([None, READY])
        result = recovery.recover(service, wait=0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["actions"], ["started"])
        self.assertEqual(service.events, [("start",)])

    def test_delayed_usb_discovery_does_not_restart(self):
        service = FakeService([EMPTY, READY], running=True)
        self.assertTrue(recovery.recover(service, wait=0)["ok"])
        self.assertEqual(service.events, [])

    def test_empty_running_app_is_restarted_once(self):
        service = FakeService([EMPTY, EMPTY, READY], running=True)
        result = recovery.recover(service, wait=0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["actions"], ["restarted"])
        self.assertEqual(service.events, [("stop", {123}), ("start",)])

    def test_cold_start_can_retry_once_but_stops_if_device_remains_missing(self):
        service = FakeService([None, EMPTY, EMPTY])
        result = recovery.recover(service, wait=0)
        self.assertFalse(result["ok"])
        self.assertEqual(result["actions"], ["started", "restarted"])
        self.assertEqual(service.events, [("start",), ("stop", {123}), ("start",)])

    def test_missing_target_does_not_switch_to_another_phone(self):
        service = FakeService([OTHER, OTHER, OTHER], running=True)
        result = recovery.recover(service, device="phone-1", wait=0)
        self.assertFalse(result["ok"])
        self.assertEqual(result["device"], "phone-1")
        self.assertEqual(result["status"]["devices"], OTHER["devices"])
        self.assertEqual(service.events, [])
        self.assertIn("Shared GUI left running", result["error"])

    def test_cold_start_finding_another_phone_does_not_restart_it(self):
        service = FakeService([None, OTHER])
        result = recovery.recover(service, device="phone-1", wait=0)
        self.assertFalse(result["ok"])
        self.assertEqual(service.events, [("start",)])
        self.assertIn("Shared GUI left running", result["error"])

    def test_unrelated_listener_is_not_signalled(self):
        service = recovery.Service(ROOT, 7400, "release", Path("/tmp/unused-recovery.log"))
        with patch.object(service, "owns", return_value=False), patch.object(recovery.os, "kill") as kill:
            with self.assertRaisesRegex(recovery.RecoveryError, "another process"):
                service.stop({456})
            kill.assert_not_called()

    def test_missing_build_does_not_stop_existing_service(self):
        service = FakeService([EMPTY, EMPTY], running=True)
        service.binary = ROOT / ".build/missing/iphone-use"
        with self.assertRaisesRegex(recovery.RecoveryError, "Build the GUI first"):
            recovery.recover(service, wait=0)
        self.assertEqual(service.events, [])

    def test_process_identity_excludes_mcp_and_other_checkouts(self):
        service = recovery.Service(ROOT, 7400, "release", Path("/tmp/unused-recovery.log"))
        binary = service.binary
        for executable, command, expected in (
            (binary, f"{binary} mcp", False),
            (binary, str(binary), True),
            (Path("/tmp/other/iphone-use"), "/tmp/other/iphone-use", False),
        ):
            with self.subTest(command=command):
                replies = [
                    subprocess.CompletedProcess([], 0, f"p123\nn{executable}\n", ""),
                    subprocess.CompletedProcess([], 0, command + "\n", ""),
                ]
                with patch.object(recovery.subprocess, "run", side_effect=replies):
                    self.assertEqual(service.owns(123), expected)

    def test_launch_detaches_and_preserves_port_without_mcp_arguments(self):
        with tempfile.TemporaryDirectory() as tmp:
            service = recovery.Service(ROOT, 7400, "release", Path(tmp) / "service.log")
            service.binary = SCRIPT
            with patch.object(recovery.os, "access", return_value=True), patch.object(recovery.subprocess, "Popen") as popen:
                service.start()
            args, kwargs = popen.call_args
            self.assertEqual(args[0], [str(SCRIPT)])
            self.assertTrue(kwargs["start_new_session"])
            self.assertEqual(kwargs["stdin"], subprocess.DEVNULL)
            self.assertEqual(kwargs["env"]["IPHONE_USE_PORT"], "7400")
            self.assertEqual(kwargs["env"]["CONFIG"], "release")
            self.assertEqual(kwargs["stdout"], kwargs["stderr"])

    def test_gui_exit_is_reported(self):
        service = recovery.Service(ROOT, 7400, "release", Path("/tmp/recovery.log"))
        service.child = Mock(returncode=1)
        service.child.poll.return_value = 1
        with self.assertRaisesRegex(recovery.RecoveryError, "exited with code 1"):
            recovery.wait_for_device(service, None, 0)

    def test_other_chats_recent_recovery_prevents_repeat_restart_but_allows_healthy_checks(self):
        for status, expected_code in ((EMPTY, 1), (READY, 0)):
            with self.subTest(status=status), tempfile.TemporaryDirectory() as tmp:
                (Path(tmp) / "recovery-7400.json").write_text(json.dumps({"time": time.time()}))
                service = FakeService([status], running=True)
                output = io.StringIO()
                env = {"IPHONE_USE_STATE_DIR": tmp, "IPHONE_USE_PORT": "7400", "CONFIG": "release"}
                with patch.dict(os.environ, env), patch.object(recovery.sys, "argv", ["ensure_service.py"]), \
                        patch.object(recovery.sys, "platform", "darwin"), patch.object(recovery, "Service", return_value=service), \
                        patch.object(recovery.sys, "stdout", output):
                    code = recovery.main()
                self.assertEqual(code, expected_code)
                self.assertEqual(service.events, [])
                result = json.loads(output.getvalue())
                self.assertEqual(result["ok"], expected_code == 0)
                if expected_code:
                    self.assertIn("recently attempted", result["error"])


class StatusHandler(BaseHTTPRequestHandler):
    def log_message(self, *args):
        pass

    def do_GET(self):
        self.server.requests.append(self.path)
        body = json.dumps(self.server.status).encode()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)


class RecoveryHTTPTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), StatusHandler)
        self.server.status = READY
        self.server.requests = []
        self.thread = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.thread.start()

    def tearDown(self):
        self.server.shutdown()
        self.server.server_close()
        self.thread.join(timeout=3)

    def test_real_http_health_check_uses_only_status_and_custom_port(self):
        service = recovery.Service(ROOT, self.server.server_port, "release", Path("/tmp/unused-recovery.log"))
        with patch.object(service, "start") as start, patch.object(service, "stop") as stop:
            result = recovery.recover(service, device="phone-1", wait=0)
        self.assertTrue(result["ok"])
        self.assertEqual(result["port"], self.server.server_port)
        self.assertEqual(self.server.requests, ["/status"])
        start.assert_not_called()
        stop.assert_not_called()

    def test_unexpected_http_service_is_left_untouched(self):
        self.server.status = {"devices": []}
        service = recovery.Service(ROOT, self.server.server_port, "release", Path("/tmp/unused-recovery.log"))
        with patch.object(service, "start") as start, patch.object(service, "stop") as stop:
            with self.assertRaisesRegex(recovery.RecoveryError, "does not look like iPhone Use"):
                recovery.recover(service, wait=0)
        start.assert_not_called()
        stop.assert_not_called()


if __name__ == "__main__":
    unittest.main()
