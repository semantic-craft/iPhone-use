#!/usr/bin/env python3
"""Start/recover the local GUI service, without sending any phone input."""

import argparse
import fcntl
import json
import os
from pathlib import Path
import signal
import subprocess
import sys
import time
from urllib.error import URLError
from urllib.request import ProxyHandler, build_opener


class RecoveryError(Exception):
    pass


class Service:
    def __init__(self, repo, port, config, log):
        self.repo = repo
        self.port = port
        self.config = config
        self.binary = (repo / ".build" / config / "iphone-use").resolve()
        self.log = log
        self.http = build_opener(ProxyHandler({}))
        self.child = None

    def snapshot(self):
        try:
            with self.http.open(f"http://127.0.0.1:{self.port}/status", timeout=1) as response:
                status = json.load(response)
            if not isinstance(status, dict) or not isinstance(status.get("devices"), list):
                raise RecoveryError("The configured port returned an unexpected /status response.")
            if "bluetooth" not in status or "unmatchedHosts" not in status:
                raise RecoveryError("The configured port does not look like iPhone Use.")
            return status
        except (URLError, TimeoutError, ConnectionError):
            return None
        except (ValueError, UnicodeError) as error:
            raise RecoveryError("The configured port did not return iPhone Use JSON.") from error

    def listeners(self):
        result = subprocess.run(
            ["/usr/sbin/lsof", "-nP", f"-iTCP:{self.port}", "-sTCP:LISTEN", "-t"],
            capture_output=True, text=True, timeout=5,
        )
        if result.returncode not in (0, 1):
            raise RecoveryError(f"Could not identify the service on port {self.port}: {result.stderr.strip()}")
        return {int(pid) for pid in result.stdout.split()}

    def owns(self, pid):
        # Verify the executable path, not just its name. MCP stdio processes are
        # excluded explicitly; they must survive a GUI restart.
        result = subprocess.run(
            ["/usr/sbin/lsof", "-a", "-p", str(pid), "-d", "txt", "-Fn"],
            capture_output=True, text=True, timeout=5,
        )
        paths = {Path(line[1:]).resolve() for line in result.stdout.splitlines() if line.startswith("n")}
        allowed = {(self.repo / ".build" / config / "iphone-use").resolve() for config in ("debug", "release")}
        command = subprocess.run(
            ["/bin/ps", "-p", str(pid), "-o", "args="], capture_output=True, text=True, timeout=5,
        )
        return bool(paths & allowed) and command.returncode == 0 and not command.stdout.strip().endswith(" mcp")

    def stop(self, pids):
        for pid in pids:
            if not self.owns(pid):
                raise RecoveryError(f"Port {self.port} belongs to another process (PID {pid}); left it running.")
        for pid in pids:
            try:
                os.kill(pid, signal.SIGTERM)
            except ProcessLookupError:
                pass
        deadline = time.monotonic() + 5
        while time.monotonic() < deadline:
            if not (pids & self.listeners()):
                return
            time.sleep(0.2)
        raise RecoveryError("The GUI did not release its port after SIGTERM; stopped recovery.")

    def start(self):
        if not self.binary.is_file() or not os.access(self.binary, os.X_OK):
            raise RecoveryError(
                f"Missing executable. Build it with: swift build --package-path {self.repo} -c {self.config}"
            )
        env = dict(os.environ, CONFIG=self.config, IPHONE_USE_PORT=str(self.port))
        # Detach the GUI from this short-lived helper and from the agent's terminal.
        # Never inherit MCP stdout or stdin.
        with self.log.open("ab") as log:
            self.child = subprocess.Popen(
                [str(self.binary)], cwd=self.repo, env=env,
                stdin=subprocess.DEVNULL, stdout=log, stderr=log, start_new_session=True,
            )

    def check_child(self):
        if self.child is not None and self.child.poll() is not None:
            raise RecoveryError(f"The GUI exited with code {self.child.returncode}; see {self.log}.")


def has_device(status, device):
    if status is None:
        return False
    return any(
        isinstance(phone, dict) and (
            not device or phone.get("id", "").casefold() == device.casefold()
            or phone.get("name", "").casefold() == device.casefold()
        )
        for phone in status["devices"]
    )


def wait_for_device(service, device, seconds):
    deadline = time.monotonic() + seconds
    while True:
        service.check_child()
        status = service.snapshot()
        if has_device(status, device) or time.monotonic() >= deadline:
            return status
        time.sleep(min(0.5, max(0, deadline - time.monotonic())))


def is_stale_binary(service, status):
    if not isinstance(status, dict):
        return False
    running_mtime = status.get("binaryMtime")
    if not isinstance(running_mtime, int) or isinstance(running_mtime, bool):
        return False
    try:
        disk_mtime = int(service.binary.stat().st_mtime)
    except OSError:
        return False
    return disk_mtime != running_mtime


def recover(service, device=None, wait=15):
    status = service.snapshot()
    actions = []
    if is_stale_binary(service, status):
        if not service.binary.is_file() or not os.access(service.binary, os.X_OK):
            raise RecoveryError(f"Build the GUI first: swift build --package-path {service.repo} -c {service.config}")
        pids = service.listeners()
        if pids:
            service.stop(pids)
            actions.append("restarted")
        else:
            actions.append("started")
        service.start()
        status = wait_for_device(service, device, wait)
    if not has_device(status, device):
        # Allow normal USB discovery/reconnection before disrupting a running GUI.
        if status is not None:
            status = wait_for_device(service, device, min(3, wait))
        # Restarting the shared GUI for a missing phone would disconnect phones
        # that other chats can still use. Leave those sessions running.
        if not has_device(status, device) and not (status and status["devices"]):
            if not service.binary.is_file() or not os.access(service.binary, os.X_OK):
                raise RecoveryError(f"Build the GUI first: swift build --package-path {service.repo} -c {service.config}")
            pids = service.listeners()
            if pids:
                service.stop(pids)
                actions.append("restarted")
            else:
                actions.append("started")
            service.start()
            status = wait_for_device(service, device, wait)
            # A cold start can also leave discovery stale. Make at most one
            # restart per invocation, including when the app was initially down.
            if not has_device(status, device) and not (status and status["devices"]) and "restarted" not in actions:
                pids = service.listeners()
                if pids:
                    service.stop(pids)
                    service.start()
                    actions.append("restarted")
                    status = wait_for_device(service, device, wait)
    result = {
        "ok": has_device(status, device),
        "actions": actions,
        "device": device,
        "port": service.port,
        "log": str(service.log),
        "status": status,
    }
    if not result["ok"] and status and status["devices"]:
        result["error"] = "The requested iPhone is missing; other iPhones are available. Shared GUI left running."
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--device", help="Keep waiting for this device ID or exact name.")
    parser.add_argument("--wait", type=int, default=15, help="Seconds to wait after starting (1-30; default 15).")
    args = parser.parse_args()
    repo = Path(__file__).resolve().parents[4]
    log = None
    try:
        if sys.platform != "darwin":
            raise RecoveryError("iPhone Use requires a local macOS session.")
        port = int(os.environ.get("IPHONE_USE_PORT", "7390"))
        config = os.environ.get("CONFIG", "release")
        if not 1 <= port <= 65535 or config not in ("debug", "release") or not 1 <= args.wait <= 30:
            raise RecoveryError("Use IPHONE_USE_PORT=1..65535, CONFIG=debug|release, and --wait=1..30.")
        state = Path(os.environ.get("IPHONE_USE_STATE_DIR", str(Path.home() / "Library/Logs/iPhoneUse")))
        if not state.is_absolute():
            raise RecoveryError("IPHONE_USE_STATE_DIR must be an absolute path shared by all clients.")
        state.mkdir(parents=True, exist_ok=True)
        log = state / f"service-{port}.log"
        # Serialize recovery across chats; the GUI must not inherit this lock.
        with (state / f"service-{port}.lock").open("a") as lock:
            deadline = time.monotonic() + 40
            while True:
                try:
                    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
                    break
                except BlockingIOError:
                    if time.monotonic() >= deadline:
                        raise RecoveryError("Another session is using or recovering this service; left it running.")
                    time.sleep(0.5)
            # Bound repeated restarts by independent chats when discovery stays
            # empty. Healthy checks still succeed during the cooldown.
            service = Service(repo, port, config, log)
            cooldown = state / f"recovery-{port}.json"
            try:
                recent = json.loads(cooldown.read_text())
            except (OSError, ValueError):
                recent = {}
            recent_time = recent.get("time", 0) if isinstance(recent, dict) else 0
            if not isinstance(recent_time, (int, float)):
                recent_time = 0
            status = service.snapshot()
            if not has_device(status, args.device) and 0 <= time.time() - recent_time < 60:
                result = {
                    "ok": False, "actions": [], "device": args.device, "port": port,
                    "log": str(log), "status": status,
                    "error": "Another chat recently attempted recovery. Shared service left running; retry status shortly.",
                }
            else:
                result = recover(service, args.device, args.wait)
                if result["actions"]:
                    cooldown.write_text(json.dumps({"time": time.time()}))
        if not result["ok"]:
            result.setdefault("error", (
                "Automatic recovery finished but the requested iPhone is still unavailable. "
                "Check USB connection, unlock/trust, camera permission, and the service log."
            ))
        print(json.dumps(result, ensure_ascii=False))
        return 0 if result["ok"] else 1
    except (RecoveryError, OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(json.dumps({"ok": False, "error": str(error), "log": str(log) if log else None}, ensure_ascii=False))
        return 1


if __name__ == "__main__":
    sys.exit(main())
