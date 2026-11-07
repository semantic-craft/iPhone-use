# scripts

## Overview
Python CLI utilities and execution helpers for the `iphone-use` Codex skill, providing service lifecycle recovery (`ensure_service.py`), standalone JSON-RPC 2.0 MCP tool invocation (`mcp_call.py`), and an interactive Python device-control execution environment (`phone_exec.py`).

## Interface
- `[ensure_service.py:RecoveryError]`
- `[ensure_service.py:Service]`, `[ensure_service.py:Service.snapshot]`, `[ensure_service.py:Service.listeners]`, `[ensure_service.py:Service.owns]`, `[ensure_service.py:Service.stop]`, `[ensure_service.py:Service.start]`, `[ensure_service.py:Service.check_child]`
- `[ensure_service.py:has_device]`, `[ensure_service.py:wait_for_device]`, `[ensure_service.py:is_stale_binary]`, `[ensure_service.py:recover]`, `[ensure_service.py:main]`
- `[ensure_service.py:--device]`, `[ensure_service.py:--wait]`
- `[mcp_call.py:TOOLS]`, `[mcp_call.py:READ_ONLY]`, `[mcp_call.py:TransportError]`
- `[mcp_call.py:Connection]`, `[mcp_call.py:Connection.close]`, `[mcp_call.py:Connection.send]`, `[mcp_call.py:Connection.request]`, `[mcp_call.py:Connection.initialize]`
- `[mcp_call.py:save_content]`, `[mcp_call.py:call]`, `[mcp_call.py:main]`
- `[mcp_call.py:tool]`, `[mcp_call.py:--arguments]`, `[mcp_call.py:--output-dir]`
- `[phone_exec.py:DEFAULT_AGENT_HELPERS_TEMPLATE]`, `[phone_exec.py:ensure_agent_workspace]`, `[phone_exec.py:api_request]`, `[phone_exec.py:build_exec_globals]`, `[phone_exec.py:main]`
- `[phone_exec.py:ScreenState]`, `[phone_exec.py:ScreenState.texts]`, `[phone_exec.py:ScreenState.find]`, `[phone_exec.py:ScreenState.has]`
- `[phone_exec.py:ensure_device]`, `[phone_exec.py:screen]`, `[phone_exec.py:screentext]`, `[phone_exec.py:find_text]`, `[phone_exec.py:tap_text]`, `[phone_exec.py:tap_icon]`, `[phone_exec.py:scroll_screen]`, `[phone_exec.py:scroll_until]`, `[phone_exec.py:scroll_collect]`, `[phone_exec.py:wait_for_text]`, `[phone_exec.py:open_app]`, `[phone_exec.py:tap]`, `[phone_exec.py:double_tap]`, `[phone_exec.py:triple_tap]`, `[phone_exec.py:hold]`, `[phone_exec.py:swipe]`, `[phone_exec.py:type_text]`, `[phone_exec.py:press]`, `[phone_exec.py:home]`, `[phone_exec.py:device_info]`, `[phone_exec.py:device_logs]`
- `[phone_exec.py:-c/--code]`, `[phone_exec.py:-d/--device]`, `[phone_exec.py:-l/--lease]`, `[phone_exec.py:-q/--quiet]`, `[phone_exec.py:script]`

## Invariants
- `[ensure_service.py:main]` Requires `sys.platform == 'darwin'`, `1 <= IPHONE_USE_PORT <= 65535`, `CONFIG in ('debug', 'release')`, `1 <= --wait <= 30`, and an absolute `IPHONE_USE_STATE_DIR` path.
- `[ensure_service.py:Service.snapshot]` `/status` response must be a JSON dict containing a list `'devices'` and keys `'bluetooth'` and `'unmatchedHosts'`.
- `[ensure_service.py:Service.owns]` Only stops processes whose executable resolves to `repo/.build/{debug,release}/iphone-use` and whose command args do not end with `' mcp'` so MCP stdio processes survive GUI restarts.
- `[ensure_service.py:recover]` Never restarts a shared GUI when other iPhones are connected (`status['devices']` is non-empty), and performs at most one restart per invocation.
- `[ensure_service.py:main]` Serializes recovery across sessions via non-blocking `fcntl.flock` on `service-{port}.lock` (up to 40s wait) and enforces a 60s cooldown via `recovery-{port}.json` when discovery remains empty.
- `[mcp_call.py:main]` `--arguments` must parse to a JSON dict without `NaN` or `Infinity` (`allow_nan=False`), and `tool` must be in `TOOLS`.
- `[mcp_call.py:Connection.initialize]` Requires JSON-RPC 2.0 response with `protocolVersion == '2025-06-18'` and `'tools'` in capabilities.
- `[mcp_call.py:Connection.request]` Enforces a 16 MiB maximum response buffer size, ignores JSON-RPC notifications (messages with `'method'` and no `'id'`), and requires response `'id'` to match the request number.
- `[mcp_call.py:save_content]` Tool result content must be a list of dicts of type `'text'` (with string `'text'`) or `'image'` (with `'image/jpeg'` or `'image/png'` `mimeType` and valid base64 `'data'`).
- `[mcp_call.py:call]` Reports `may_have_executed` as `True` only when `tool not in READ_ONLY` and either `result.get('isError')` is truthy or `connection.call_sent` was set before an exception.
- `[phone_exec.py:main]` Requires `-c/--code`, a script path, or non-TTY stdin.

## Side Effects
- `[ensure_service.py:Service.snapshot]` Sends HTTP GET (bypassing proxies) to `http://127.0.0.1:{port}/status`.
- `[ensure_service.py:Service.listeners]` Executes `/usr/sbin/lsof` to find TCP listeners on the configured port.
- `[ensure_service.py:Service.owns]` Executes `/usr/sbin/lsof` and `/bin/ps` to inspect process executable and arguments.
- `[ensure_service.py:Service.stop]` Sends `SIGTERM` via `os.kill` to owned listener PIDs.
- `[ensure_service.py:Service.start]` Spawns detached `.build/{config}/iphone-use` process (`start_new_session=True`) appending stdout/stderr to `service-{port}.log`.
- `[ensure_service.py:main]` Creates `IPHONE_USE_STATE_DIR` (default `~/Library/Logs/iPhoneUse`), locks `service-{port}.lock`, writes `recovery-{port}.json`, and prints JSON result to stdout.
- `[mcp_call.py:Connection.__init__]` Creates a temporary file for stderr and spawns the MCP launcher subprocess (`IPHONE_USE_LAUNCHER` or `scripts/mcp.sh`) with non-blocking stdin.
- `[mcp_call.py:Connection.close]` Closes pipes and waits/terminates/kills the MCP subprocess.
- `[mcp_call.py:save_content]` Creates `output_dir` if specified and writes decoded screenshot files (`iphone-use-*.jpg`/`.png`) via `tempfile.mkstemp`.
- `[mcp_call.py:main]` Prints JSON tool execution result to stdout.
- `[phone_exec.py:ensure_agent_workspace]` Creates `~/.iphone-use/agent-workspace` (or `IPHONE_USE_AGENT_WORKSPACE`) and initializes `agent_helpers.py` if missing.
- `[phone_exec.py:api_request]` Sends HTTP GET/POST requests to the `iphone-use` server (`IPHONE_USE_URL` or `http://127.0.0.1:{IPHONE_USE_PORT}`) across `/setup_status`, `/ocr`, `/screentext`, `/tap_text`, `/tap_icon`, `/scroll`, `/scroll_until`, `/scroll_collect`, `/open_app`, `/tap`, `/double_tap`, `/triple_tap`, `/hold`, `/swipe`, `/type`, `/key`, `/home`, `/device_info`, and `/device_logs`.
- `[phone_exec.py:_helper_trace]` Writes `[trace]` execution timing logs to stderr unless `IPHONE_USE_TRACE` is disabled.
- `[phone_exec.py:build_exec_globals]` Inserts the agent workspace into `sys.path[0]` and executes `agent_helpers.py`.
- `[phone_exec.py:main]` Mutates `os.environ` (`IPHONE_USE_DEVICE`, `IPHONE_USE_LEASE`, `IPHONE_USE_TRACE`) when CLI flags are passed, and executes user-supplied Python code via `exec()`.

## Verification
- Run: `python3 -B -m unittest discover -s Tests/PythonTests -p 'test_*.py'`
