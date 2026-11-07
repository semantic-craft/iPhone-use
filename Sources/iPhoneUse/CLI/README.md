# CLI

## Overview
Parses command-line subcommands and flags when `iPhoneUse` is invoked in CLI mode, translating CLI invocations into internal `HTTPRequest` calls dispatched directly to `ControlAPI.handle` or spawning the external Python `phone_exec.py` harness for `exec`/`run` subcommands.

## Interface
- `[CLIRunner.swift:CLIRunner]` — CLI parser and execution namespace:
  - `[CLIRunner.swift:supportedCommands]` — Set of recognized CLI subcommands: `task`, `setup_status`, `setup-status`, `list`, `list_devices`, `devices`, `status`, `acquire`, `wait`, `release`, `screentext`, `tap_text`, `tap-text`, `tap_icon`, `tap-icon`, `scroll`, `scroll_until`, `scroll-until`, `scroll_collect`, `scroll-collect`, `exec`, `run`, `photo_list`, `photo_pull`, `photo_delete`, `photo_push`, `photo`, `photos`, `file_list`, `file_pull`, `file_push`, `file_remove`, `file`, `files`, `app_list`, `open_app`, `app`, `apps`, `device_info`, `info`, `device_logs`, `logs`, `assistivetouch`, `assistive-touch`.
  - `[CLIRunner.swift:shouldRunCLI]` — `static func shouldRunCLI(arguments: [String]) -> Bool`.
  - `[CLIRunner.swift:runAndExit]` — `static func runAndExit(arguments: [String] = CommandLine.arguments) -> Never`.
  - `[CLIRunner.swift:execute]` — `static func execute(arguments args: [String], runtimeHooks: GhosthandRuntimeHooks? = nil) -> (exitCode: Int32, stdout: String, stderr: String)`.
  - `[CLIRunner.swift:buildRequest]` — `static func buildRequest(from args: [String]) throws -> HTTPRequest`.
  - Two-word subcommand aliases in `[CLIRunner.swift:buildRequest]`:
    - `(photo|photos) (list|ls)` -> `photo_list`, `(pull|get)` -> `photo_pull`, `(delete|rm)` -> `photo_delete`, `(push|import)` -> `photo_push`.
    - `(file|files) (list|ls)` -> `file_list`, `(pull|get)` -> `file_pull`, `(push|put)` -> `file_push`, `(remove|rm)` -> `file_remove`.
    - `(app|apps) (list|ls)` -> `app_list`, `(open|launch)` -> `open_app`.
  - CLI flags parsed by `[CLIRunner.swift:buildRequest]`:
    - Target & lease: `-d` / `--device`, `-l` / `--lease`, `--reason`, `--label`, `--force`.
    - Task & execution: `-p` / `--prompt`, `-r` / `--resume` / `--task` / `--task-id`, `--thinking-level` / `--thinking`, `--max-steps`, `--approve` / `--confirm-safety`, `--no-approve`.
    - Post-action & OCR: `--screentext`, `--settle`, `--wait-text`, `--timeout-ms`, `--min-confidence`, `--content-only`.
    - Tap & scroll: `--exact`, `--index`, `--offset-x`, `--offset-y`, `--icon`, `--direction` / `--dir`, `--ticks`, `--until-text` / `--until`, `--collect`, `--max-scrolls`, `--end-after`.
    - Photos, files, apps, logs, and AssistiveTouch: `--path`, `--source` / `--file`, `-o` / `--output` / `--destination`, `--filename` / `--name`, `--data` / `--base64`, `--content` / `--text`, `-b` / `--bundle-id` / `--bundle`, `--app`, `--limit`, `--seconds`, `--lines` / `--max-lines`, `--contains` / `--filter` / `--process`, `-R` / `--recursive`, `--enabled`, `--on` / `--enable`, `--off` / `--disable`.

## Invariants
- `[CLIRunner.swift:shouldRunCLI]` drops the first argument (executable path) and returns `true` if and only if the next lowercased token is a member of `supportedCommands`.
- `[CLIRunner.swift:execute]` returns `exitCode = 0` with `bodyText` on `stdout` and empty `stderr` when `ControlAPI.handle` returns an HTTP status in `200..<300`; statuses outside `200..<300` or thrown errors return `exitCode = 1` with identical error text in both `stdout` and `stderr`.
- `[CLIRunner.swift:buildRequest]` throws `GhosthandError.invalidArgument` if `args` is empty, if an unknown two-word subcommand is supplied for `photo`/`photos`/`file`/`files`/`app`/`apps`, if a required flag value is missing or fails numeric/boolean conversion, if an unrecognized token starts with `-`, or if the resolved command remains a bare group keyword (`photo`, `file`, `app`).
- `[CLIRunner.swift:buildRequest]` enforces `Int` parsing on `--max-steps`, `--limit`, `--lines`/`--max-lines`, `--timeout-ms`, `--index`, `--offset-x`, `--offset-y`, `--ticks`, `--max-scrolls`, and `--end-after`; `Double` parsing on `--seconds` and `--min-confidence`; and `PostActionOptions.parseBoolFlag` parsing on `--enabled`.
- `[CLIRunner.swift:buildRequest]` forces `body["icon"] = true` for `tap_icon`/`tap-icon`, defaults `body["direction"] = "down"` for `scroll`/`scroll_until`/`scroll_collect` when unset, forces `body["collect"] = true` for `scroll_collect`/`scroll-collect`, and validates positional `assistivetouch` arguments against `on`/`true`/`1`/`enable`/`enabled`, `off`/`false`/`0`/`disable`/`disabled`, or `status`/`get`.

## Side Effects
- `[CLIRunner.swift:runAndExit]` writes `stdout` and `stderr` to `FileHandle.standardOutput` and `FileHandle.standardError` and terminates the process via `exit(result.exitCode)`.
- `[CLIRunner.swift:execute]` dispatches constructed `HTTPRequest` values directly to `ControlAPI.handle(request, runtimeHooks: runtimeHooks)` in-process for all commands except `exec` and `run`.
- `[CLIRunner.swift:executePythonHarness]` searches for `phone_exec.py` across candidate paths (`cwd/codex/...`, `cwd/.agents/...`, `~/Projects/iphone-use/codex/...`, `~/.gemini/config/skills/...`) using `FileManager.default` and spawns `/usr/bin/env python3` via `Process` with inherited `standardInput` and piped `stdout`/`stderr`.

## Verification
- Run: `swift test`
