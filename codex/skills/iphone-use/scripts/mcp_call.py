#!/usr/bin/env python3
"""Call one tool through a fresh stdio connection when Codex's transport is closed."""

import argparse
import base64
import json
import os
from pathlib import Path
import selectors
import subprocess
import sys
import tempfile
import time


TOOLS = (
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
    "task", "switch_track_mode", "get_track_status", "get_ax_tree",
)
READ_ONLY = {
    "list_devices", "screenshot", "ocr_screen", "screentext", "setup_status",
    "photo_list", "photo_pull", "file_list", "file_pull",
    "app_list", "device_info", "device_logs",
    "get_track_status", "get_ax_tree",
}


class TransportError(Exception):
    pass


class Connection:
    def __init__(self, command, timeout):
        self.timeout = timeout
        self.buffer = b""
        self.call_sent = False
        # A file avoids deadlocking on a full stderr pipe and keeps diagnostics
        # away from stdout's JSON-RPC stream.
        self.errors = tempfile.TemporaryFile()
        try:
            self.process = subprocess.Popen(
                command, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=self.errors,
                bufsize=0, close_fds=True,
            )
            os.set_blocking(self.process.stdin.fileno(), False)
        except OSError:
            self.errors.close()
            raise

    def close(self):
        self.process.stdin.close()
        try:
            self.process.wait(timeout=1)
        except subprocess.TimeoutExpired:
            self.process.terminate()
            try:
                self.process.wait(timeout=1)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait()
        self.process.stdout.close()
        self.errors.close()

    def send(self, message):
        try:
            data = json.dumps(message, ensure_ascii=False, allow_nan=False).encode() + b"\n"
            # Bound both writes and reads. A stalled child must not strand a
            # chat, including when a large type_text fills the input pipe.
            view = memoryview(data)
            deadline = time.monotonic() + self.timeout
            with selectors.DefaultSelector() as selector:
                selector.register(self.process.stdin, selectors.EVENT_WRITE)
                while view:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise TransportError("Timed out sending MCP request")
                    try:
                        written = os.write(self.process.stdin.fileno(), view)
                    except BlockingIOError:
                        continue
                    if not written:
                        raise TransportError("MCP stdin closed")
                    view = view[written:]
        except (BrokenPipeError, OSError) as error:
            raise TransportError("MCP transport closed while sending") from error

    def request(self, number, method, params):
        if method == "tools/call":
            # If sending or reading fails, an action may already have arrived.
            self.call_sent = True
        self.send({"jsonrpc": "2.0", "id": number, "method": method, "params": params})
        deadline = time.monotonic() + self.timeout
        with selectors.DefaultSelector() as selector:
            selector.register(self.process.stdout, selectors.EVENT_READ)
            while True:
                while b"\n" not in self.buffer:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise TransportError("Timed out waiting for MCP response")
                    chunk = os.read(self.process.stdout.fileno(), 65536)
                    if not chunk:
                        self.errors.seek(0)
                        detail = self.errors.read(2000).decode(errors="replace").strip()
                        raise TransportError("MCP transport closed" + (f": {detail}" if detail else ""))
                    self.buffer += chunk
                    if len(self.buffer) > 16 * 1024 * 1024:
                        raise TransportError("MCP response exceeds 16 MiB")
                line, self.buffer = self.buffer.split(b"\n", 1)
                try:
                    reply = json.loads(line)
                except (ValueError, UnicodeError) as error:
                    raise TransportError("MCP stdout contains invalid JSON") from error
                if not isinstance(reply, dict) or reply.get("jsonrpc") != "2.0":
                    raise TransportError("Invalid JSON-RPC response")
                if "id" not in reply and isinstance(reply.get("method"), str):
                    if time.monotonic() >= deadline:
                        raise TransportError("Timed out waiting for MCP response")
                    continue  # Notifications do not consume a request's response.
                if reply.get("id") != number:
                    raise TransportError("Unexpected MCP response ID")
                if "error" in reply:
                    raise TransportError(f"MCP RPC error: {reply['error']}")
                if not isinstance(reply.get("result"), dict):
                    raise TransportError("Missing MCP result")
                return reply["result"]

    def initialize(self):
        result = self.request(1, "initialize", {
            "protocolVersion": "2025-06-18", "capabilities": {},
            "clientInfo": {"name": "iphone-use-recovery", "version": "1.0.0"},
        })
        if result.get("protocolVersion") != "2025-06-18" or "tools" not in result.get("capabilities", {}):
            raise TransportError("MCP initialization did not negotiate tools")
        self.send({"jsonrpc": "2.0", "method": "notifications/initialized"})


def save_content(content, output_dir):
    if not isinstance(content, list):
        raise TransportError("Missing tool content")
    saved = []
    for item in content:
        if not isinstance(item, dict):
            raise TransportError("Invalid tool content")
        if item.get("type") == "text" and isinstance(item.get("text"), str):
            saved.append(item)
        elif item.get("type") == "image":
            extension = {"image/jpeg": ".jpg", "image/png": ".png"}.get(item.get("mimeType"))
            if not extension:
                raise TransportError("Unsupported screenshot MIME type")
            try:
                data = base64.b64decode(item["data"], validate=True)
            except (ValueError, KeyError, TypeError) as error:
                raise TransportError("Invalid screenshot encoding") from error
            if output_dir:
                Path(output_dir).mkdir(parents=True, exist_ok=True)
            fd, path = tempfile.mkstemp(prefix="iphone-use-", suffix=extension, dir=output_dir)
            with os.fdopen(fd, "wb") as image:
                image.write(data)
            saved.append({"type": "image", "path": str(Path(path).resolve()), "mimeType": item["mimeType"]})
        else:
            raise TransportError("Unsupported tool content")
    return saved


def call(command, tool, arguments, output_dir=None, timeout=75):
    connection = None
    try:
        connection = Connection(command, timeout)
        connection.initialize()
        result = connection.request(2, "tools/call", {"name": tool, "arguments": arguments})
        failed = bool(result.get("isError"))
        return {
            "ok": not failed, "connection": "fresh-stdio", "tool": tool,
            "may_have_executed": failed and tool not in READ_ONLY,
            "content": save_content(result.get("content"), output_dir),
        }
    except (TransportError, OSError, ValueError) as error:
        return {
            "ok": False, "connection": "fresh-stdio", "tool": tool, "error": str(error),
            "may_have_executed": bool(connection and connection.call_sent and tool not in READ_ONLY),
        }
    finally:
        if connection:
            connection.close()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("tool", choices=TOOLS)
    parser.add_argument("--arguments", default="{}", help="JSON object matching the MCP tool schema")
    parser.add_argument("--output-dir", help="Directory for unique screenshot files (default: system temp)")
    args = parser.parse_args()
    try:
        arguments = json.loads(args.arguments)
        if not isinstance(arguments, dict):
            raise ValueError("--arguments must be a JSON object")
        # Validate before opening a process; JSON NaN/Infinity are not MCP values.
        json.dumps(arguments, allow_nan=False)
    except ValueError as error:
        print(json.dumps({"ok": False, "error": str(error), "may_have_executed": False}))
        return 1
    launcher = Path(
        os.environ.get("IPHONE_USE_LAUNCHER")
        or str(Path(__file__).resolve().parents[4] / "scripts/mcp.sh")
    )
    result = call([str(launcher)], args.tool, arguments, args.output_dir)
    print(json.dumps(result, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
