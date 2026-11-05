#!/usr/bin/env python3
"""Multi-step Python execution harness for iphone-use.

Inspired by phone-harness's single-turn heredoc execution (`exec <<'PY'`) and
persistent `agent_helpers.py` workspace, backed by iphone-use's local HTTP API
(USB capture + Bluetooth HID + Vision OCR + stillness detection).
"""

from __future__ import annotations

import argparse
from dataclasses import dataclass
import functools
import json
import os
from pathlib import Path
import sys
import time
from typing import Any
import urllib.error
import urllib.parse
import urllib.request

DEFAULT_AGENT_HELPERS_TEMPLATE = '''"""Persistent agent-editable helpers for iphone-use.

Add custom multi-step workflows or app-specific helpers here. Every symbol
defined in this file is automatically imported into `iphone-use exec` scripts.
"""
'''


def _base_url() -> str:
    explicit = os.environ.get("IPHONE_USE_URL", "").strip()
    if explicit:
        return explicit.rstrip("/")
    port = os.environ.get("IPHONE_USE_PORT", "7390").strip() or "7390"
    return f"http://127.0.0.1:{port}"


def _default_device() -> str | None:
    dev = os.environ.get("IPHONE_USE_DEVICE", "").strip()
    return dev or None


def _default_lease() -> str | None:
    lease = os.environ.get("IPHONE_USE_LEASE", "").strip()
    return lease or None


def ensure_agent_workspace() -> Path:
    raw = os.environ.get("IPHONE_USE_AGENT_WORKSPACE", "").strip()
    workspace = Path(raw).expanduser() if raw else (Path.home() / ".iphone-use" / "agent-workspace")
    workspace.mkdir(parents=True, exist_ok=True)
    helpers_file = workspace / "agent_helpers.py"
    if not helpers_file.exists():
        helpers_file.write_text(DEFAULT_AGENT_HELPERS_TEMPLATE, encoding="utf-8")
    return workspace


def api_request(
    method: str,
    path: str,
    payload: dict[str, Any] | None = None,
    *,
    timeout: float = 30.0,
) -> dict[str, Any]:
    url = f"{_base_url()}{path}"
    data: bytes | None = None
    headers = {"Accept": "application/json"}
    if payload is not None:
        clean = {k: v for k, v in payload.items() if v is not None}
        if "device" not in clean and _default_device():
            clean["device"] = _default_device()
        if "lease" not in clean and _default_lease():
            clean["lease"] = _default_lease()
        data = json.dumps(clean).encode("utf-8")
        headers["Content-Type"] = "application/json"

    req = urllib.request.Request(url, data=data, headers=headers, method=method.upper())
    try:
        with urllib.request.urlopen(req, timeout=timeout) as resp:
            raw = resp.read().decode("utf-8", errors="replace")
            return json.loads(raw) if raw.strip() else {"ok": True}
    except urllib.error.HTTPError as exc:
        raw = exc.read().decode("utf-8", errors="replace")
        try:
            parsed = json.loads(raw)
        except Exception:
            parsed = {"error": raw or str(exc)}
        msg = parsed.get("error") or parsed.get("message") or raw or str(exc)
        raise RuntimeError(f"{method} {path} failed ({exc.code}): {msg}") from exc
    except urllib.error.URLError as exc:
        raise RuntimeError(
            f"Cannot connect to iphone-use server at {_base_url()}: {exc.reason}"
        ) from exc


def _helper_trace(fn):
    @functools.wraps(fn)
    def wrapper(*args, **kwargs):
        trace_enabled = os.environ.get("IPHONE_USE_TRACE", "1").strip().lower() not in (
            "0",
            "false",
            "no",
            "off",
        )
        start = time.monotonic()
        try:
            result = fn(*args, **kwargs)
            if trace_enabled:
                elapsed_ms = int((time.monotonic() - start) * 1000)
                arg_preview = ", ".join(
                    [repr(a) for a in args[:2]]
                    + [f"{k}={v!r}" for k, v in list(kwargs.items())[:2]]
                )
                print(f"[trace] {fn.__name__}({arg_preview}) -> ok ({elapsed_ms}ms)", file=sys.stderr)
            return result
        except Exception as exc:
            if trace_enabled:
                elapsed_ms = int((time.monotonic() - start) * 1000)
                print(
                    f"[trace] {fn.__name__} FAILED ({elapsed_ms}ms): {exc}",
                    file=sys.stderr,
                )
            raise

    return wrapper


@dataclass
class ScreenState:
    width: int
    height: int
    items: list[dict[str, Any]]

    def texts(self) -> list[str]:
        return [str(item.get("text", "")) for item in self.items if item.get("text")]

    def find(self, query: str, *, exact: bool = False) -> list[dict[str, Any]]:
        needle = query.strip().lower()
        matches: list[dict[str, Any]] = []
        for item in self.items:
            text = str(item.get("text", "")).strip()
            hay = text.lower()
            if (hay == needle) if exact else (needle in hay):
                matches.append(item)
        return matches

    def has(self, query: str, *, exact: bool = False) -> bool:
        return bool(self.find(query, exact=exact))


@_helper_trace
def ensure_device(device: str | None = None) -> dict[str, Any]:
    dev = device or _default_device()
    query = f"?device={urllib.parse.quote(dev)}" if dev else ""
    return api_request("GET", f"/setup_status{query}")


@_helper_trace
def screen(
    *,
    min_confidence: float | None = None,
    content_only: bool = False,
    max_edge: int | None = None,
    device: str | None = None,
) -> ScreenState:
    resp = api_request(
        "POST",
        "/ocr",
        {
            "device": device,
            "maxEdge": max_edge,
            "min_confidence": min_confidence,
            "content_only": content_only if content_only else None,
        },
    )
    return ScreenState(
        width=int(resp.get("width", 0)),
        height=int(resp.get("height", 0)),
        items=list(resp.get("items", [])),
    )


@_helper_trace
def screentext(
    *,
    min_confidence: float | None = None,
    content_only: bool = False,
    device: str | None = None,
) -> str:
    resp = api_request(
        "POST",
        "/screentext",
        {
            "device": device,
            "min_confidence": min_confidence,
            "content_only": content_only if content_only else None,
        },
    )
    return str(resp.get("text", ""))


@_helper_trace
def find_text(
    query: str,
    *,
    exact: bool = False,
    min_confidence: float | None = None,
    content_only: bool = False,
    device: str | None = None,
) -> list[dict[str, Any]]:
    st = screen(min_confidence=min_confidence, content_only=content_only, device=device)
    return st.find(query, exact=exact)


@_helper_trace
def tap_text(
    text: str,
    *,
    exact: bool = False,
    index: int = 0,
    hold: float | None = None,
    offset_x: int = 0,
    offset_y: int = 0,
    icon: bool = False,
    wait_text: str | None = None,
    timeout_ms: int | None = None,
    settle: bool | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "text": text,
        "exact": exact if exact else None,
        "index": index if index else None,
        "hold": hold,
        "offset_x": offset_x if offset_x else None,
        "offset_y": offset_y if offset_y else None,
        "icon": True if icon else None,
        "wait_text": wait_text,
        "timeout_ms": timeout_ms,
        "settle": settle,
        "device": device,
    }
    return api_request("POST", "/tap_text", payload)


@_helper_trace
def tap_icon(
    label: str,
    *,
    exact: bool = False,
    index: int = 0,
    offset_x: int = 0,
    offset_y: int = 0,
    wait_text: str | None = None,
    timeout_ms: int | None = None,
    settle: bool | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    payload: dict[str, Any] = {
        "text": label,
        "exact": exact if exact else None,
        "index": index if index else None,
        "offset_x": offset_x if offset_x else None,
        "offset_y": offset_y if offset_y else None,
        "icon": True,
        "wait_text": wait_text,
        "timeout_ms": timeout_ms,
        "settle": settle,
        "device": device,
    }
    return api_request("POST", "/tap_icon", payload)


@_helper_trace
def scroll_screen(
    direction: str = "down",
    *,
    ticks: int = 5,
    x: float | None = None,
    y: float | None = None,
    settle: bool | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/scroll",
        {
            "direction": direction,
            "ticks": ticks,
            "x": x,
            "y": y,
            "settle": settle,
            "device": device,
        },
    )


@_helper_trace
def scroll_until(
    text: str,
    *,
    direction: str = "down",
    exact: bool = False,
    max_scrolls: int = 10,
    ticks: int = 5,
    end_after: int = 2,
    min_confidence: float | None = None,
    device: str | None = None,
) -> dict[str, Any] | None:
    resp = api_request(
        "POST",
        "/scroll_until",
        {
            "until_text": text,
            "direction": direction,
            "exact": exact if exact else None,
            "max_scrolls": max_scrolls,
            "ticks": ticks,
            "end_after": end_after,
            "min_confidence": min_confidence,
            "device": device,
        },
        timeout=max(30.0, max_scrolls * 4.0),
    )
    if resp.get("found"):
        return resp.get("match") or resp
    return None


@_helper_trace
def scroll_collect(
    *,
    direction: str = "down",
    max_scrolls: int = 8,
    ticks: int = 5,
    end_after: int = 2,
    min_confidence: float | None = None,
    device: str | None = None,
) -> list[str]:
    resp = api_request(
        "POST",
        "/scroll_collect",
        {
            "collect": True,
            "direction": direction,
            "max_scrolls": max_scrolls,
            "ticks": ticks,
            "end_after": end_after,
            "min_confidence": min_confidence,
            "device": device,
        },
        timeout=max(30.0, max_scrolls * 4.0),
    )
    texts = resp.get("texts")
    if isinstance(texts, list):
        return [str(t) for t in texts]
    return [str(item.get("text", item)) if isinstance(item, dict) else str(item) for item in resp.get("items", [])]


@_helper_trace
def wait_for_text(
    text: str,
    *,
    timeout_ms: int = 5000,
    poll_ms: int = 350,
    exact: bool = False,
    min_confidence: float | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    deadline = time.monotonic() + max(0.1, timeout_ms / 1000.0)
    last_state: ScreenState | None = None
    while True:
        last_state = screen(min_confidence=min_confidence, device=device)
        matches = last_state.find(text, exact=exact)
        if matches:
            return matches[0]
        if time.monotonic() >= deadline:
            saw = last_state.texts()[:25] if last_state else []
            raise TimeoutError(f"Timed out waiting for text {text!r} (saw: {saw})")
        time.sleep(max(0.05, poll_ms / 1000.0))


@_helper_trace
def open_app(
    app: str,
    *,
    bundle_id: str | None = None,
    wait_text: str | None = None,
    timeout_ms: int | None = None,
    settle: bool = True,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/open_app",
        {
            "app": app,
            "bundle_id": bundle_id,
            "wait_text": wait_text,
            "timeout_ms": timeout_ms,
            "settle": settle,
            "device": device,
        },
    )


@_helper_trace
def tap(
    x: float,
    y: float,
    *,
    hold: float | None = None,
    settle: bool | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/tap",
        {"x": x, "y": y, "hold": hold, "settle": settle, "device": device},
    )


@_helper_trace
def double_tap(
    x: float | None = None,
    y: float | None = None,
    *,
    text: str | None = None,
    exact: bool = False,
    index: int = 0,
    offset_x: int = 0,
    offset_y: int = 0,
    icon: bool = False,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/double_tap",
        {
            "x": x,
            "y": y,
            "text": text,
            "exact": exact if exact else None,
            "index": index if index else None,
            "offset_x": offset_x if offset_x else None,
            "offset_y": offset_y if offset_y else None,
            "icon": True if icon else None,
            "device": device,
        },
    )


@_helper_trace
def triple_tap(
    x: float | None = None,
    y: float | None = None,
    *,
    text: str | None = None,
    exact: bool = False,
    index: int = 0,
    offset_x: int = 0,
    offset_y: int = 0,
    icon: bool = False,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/triple_tap",
        {
            "x": x,
            "y": y,
            "text": text,
            "exact": exact if exact else None,
            "index": index if index else None,
            "offset_x": offset_x if offset_x else None,
            "offset_y": offset_y if offset_y else None,
            "icon": True if icon else None,
            "device": device,
        },
    )


@_helper_trace
def hold(
    x: float | None = None,
    y: float | None = None,
    *,
    text: str | None = None,
    duration_ms: int = 1000,
    offset_x: int = 0,
    offset_y: int = 0,
    icon: bool = False,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/hold",
        {
            "x": x,
            "y": y,
            "text": text,
            "durationMs": duration_ms,
            "offset_x": offset_x if offset_x else None,
            "offset_y": offset_y if offset_y else None,
            "icon": True if icon else None,
            "device": device,
        },
    )


@_helper_trace
def swipe(
    points: list[dict[str, float]],
    *,
    duration: float = 0.3,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/swipe",
        {"points": points, "duration": duration, "device": device},
    )


@_helper_trace
def type_text(
    text: str,
    *,
    clear_before: bool = False,
    commit_ime: bool = False,
    press_enter: bool = False,
    ensure_chinese_ime: bool = False,
    use_clipboard: bool = False,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/type",
        {
            "text": text,
            "clear_before": True if clear_before else None,
            "commit_ime": True if commit_ime else None,
            "press_enter": True if press_enter else None,
            "ensure_chinese_ime": True if ensure_chinese_ime else None,
            "use_clipboard": True if use_clipboard else None,
            "device": device,
        },
    )


@_helper_trace
def press(
    key: str,
    *,
    modifiers: list[str] | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/key",
        {"key": key, "modifiers": modifiers or [], "device": device},
    )


@_helper_trace
def home(*, device: str | None = None) -> dict[str, Any]:
    return api_request("POST", "/home", {"device": device})


@_helper_trace
def device_info(*, device: str | None = None) -> dict[str, Any]:
    return api_request("POST", "/device_info", {"device": device})


@_helper_trace
def device_logs(
    *,
    seconds: float = 2.0,
    lines: int = 200,
    contains: str | None = None,
    device: str | None = None,
) -> dict[str, Any]:
    return api_request(
        "POST",
        "/device_logs",
        {"seconds": seconds, "lines": lines, "contains": contains, "device": device},
    )


def build_exec_globals() -> dict[str, Any]:
    workspace = ensure_agent_workspace()
    if str(workspace) not in sys.path:
        sys.path.insert(0, str(workspace))

    env: dict[str, Any] = {
        "__name__": "__main__",
        "api_request": api_request,
        "ScreenState": ScreenState,
        "ensure_device": ensure_device,
        "screen": screen,
        "screentext": screentext,
        "find_text": find_text,
        "tap_text": tap_text,
        "tap_icon": tap_icon,
        "scroll_screen": scroll_screen,
        "scroll_until": scroll_until,
        "scroll_collect": scroll_collect,
        "wait_for_text": wait_for_text,
        "open_app": open_app,
        "tap": tap,
        "double_tap": double_tap,
        "triple_tap": triple_tap,
        "hold": hold,
        "swipe": swipe,
        "type_text": type_text,
        "press": press,
        "home": home,
        "device_info": device_info,
        "device_logs": device_logs,
        "AGENT_WORKSPACE": workspace,
    }

    helpers_path = workspace / "agent_helpers.py"
    if helpers_path.is_file():
        code = compile(helpers_path.read_text(encoding="utf-8"), str(helpers_path), "exec")
        exec(code, env)
    return env


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(
        prog="iphone-use exec",
        description="Execute a multi-step Python script with iphone-use helpers pre-imported.",
    )
    parser.add_argument("-c", "--code", help="Inline Python code to execute")
    parser.add_argument("-d", "--device", help="Default device UDID or name")
    parser.add_argument("-l", "--lease", help="Default lease ID")
    parser.add_argument("-q", "--quiet", action="store_true", help="Disable stderr helper trace")
    parser.add_argument("script", nargs="?", help="Path to Python script (or '-' / stdin)")
    args = parser.parse_args(argv)

    if args.device:
        os.environ["IPHONE_USE_DEVICE"] = args.device
    if args.lease:
        os.environ["IPHONE_USE_LEASE"] = args.lease
    if args.quiet:
        os.environ["IPHONE_USE_TRACE"] = "0"

    if args.code is not None:
        source = args.code
        filename = "<inline>"
    elif args.script and args.script != "-":
        script_path = Path(args.script)
        source = script_path.read_text(encoding="utf-8")
        filename = str(script_path)
    else:
        if sys.stdin.isatty():
            parser.error("Provide -c CODE, a script path, or pipe Python via stdin (e.g. <<'PY')")
        source = sys.stdin.read()
        filename = "<stdin>"

    env = build_exec_globals()
    compiled = compile(source, filename, "exec")
    exec(compiled, env)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
