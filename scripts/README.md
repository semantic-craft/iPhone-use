# scripts

## Overview
Build, verification, pointer calibration, Bluetooth diagnostics, MCP registration, icon generation, screen recording, and release packaging scripts for `iphone-use`.

## Interface
- `[build-app.sh:CONFIG]` Env var (`debug`|`release`, default `release`) controlling `swift build -c` configuration.
- `[build-app.sh:BUILD_ARCH]` Env var (`native`|`arm64`|`x86_64`|`universal`, default `native`) controlling target architecture(s).
- `[build-app.sh:APP_VERSION]` Optional env var (`^[0-9]+\.[0-9]+\.[0-9]+$`) written to `CFBundleShortVersionString` in `build/iPhoneUse.app/Contents/Info.plist`.
- `[build-app.sh:APP_BUILD]` Optional env var (`^[1-9][0-9]*$`) written to `CFBundleVersion` in `build/iPhoneUse.app/Contents/Info.plist`.
- `[build-app.sh:CODESIGN_IDENTITY]` Optional env var specifying explicit `codesign` identity (disables ad-hoc fallback).
- `[build-app.sh:sign]` Shell function signing `build/iPhoneUse.app` with `--force --options runtime --entitlements Resources/iPhoneUse.entitlements`.
- `[calibrate-pointer.py:CALIBRATION_PAGE]` HTML/JS payload served to iPhone Safari that posts `{type:'loaded',screenWidth,screenHeight,dpr}` and 50ms-throttled `{type:'move',x,y,time}` events.
- `[calibrate-pointer.py:PhoneAPI]` HTTP client for the local `iphone-use` API (`select_device`, `nudge`, `post`, `open_safari`) calling `/devices`, `/nudge`, `/key`, `/type`, `/move`, and `/calibration/reload`.
- `[calibrate-pointer.py:PointerMeasurements]` Thread-safe store (`record`, `wait_for_page`, `position`) synchronizing Safari HTTP observations with the calibration loop.
- `[calibrate-pointer.py:CalibrationRequestHandler]` `BaseHTTPRequestHandler` serving `CALIBRATION_PAGE` on `do_GET` and recording JSON measurements on `do_POST` at `self.server.token`.
- `[calibrate-pointer.py:CalibrationHTTPServer]` `ThreadingHTTPServer` binding `(address, listen_port)` with a random token path and `PointerMeasurements` instance.
- `[calibrate-pointer.py:PointerCalibration]` Curve measurement engine (`measure`, `_enter_calibration_area`, `_enter_horizontal_area`, `_measure_horizontal_curve`, `_verify_vertical_curve`, `_verify_diagonal_curve`).
- `[calibrate-pointer.py:verify_mapping]` Function verifying coordinate movement deltas across `[(0.3, 0.4), (0.6, 0.6), (0.4, 0.5)]` via `/nudge` and `/move` (`fraction=True`) within `tolerance=5` px.
- `[calibrate-pointer.py:baseline_profile]` Function loading and validating a candidate calibration JSON profile for matching screen dimensions.
- `[calibrate-pointer.py:apply_verified_profile]` Function saving a profile, posting `/calibration/reload`, verifying live mapping, and rolling back files and `/calibration/reload` on failure.
- `[calibrate-pointer.py:calibration_access]` Context manager acquiring `fcntl` locks (`service-<port>.lock` `LOCK_SH`, `device-<port>-<hex_id>.lock` `LOCK_EX`) in `IPHONE_USE_STATE_DIR`.
- `[calibrate-pointer.py:save_profile]` Function atomically writing calibration JSON to `pointer-calibration/<HOST>.json` and `pointer-calibration/by-screen/<screenID_hex>.json`.
- `[calibrate-pointer.py:local_address]` Function determining the local LAN IPv4 address via a UDP socket to `192.0.2.1:80`.
- `[calibrate-pointer.py:parse_arguments]` CLI parser accepting `--device`, `--api` (default `http://127.0.0.1:7390`), `--listen-port` (default `7391`), `--address`, `--auto`, `--force`, and `--baseline`.
- `[calibrate-pointer.py:run_calibration]` Orchestrator executing Safari page load, existing mapping verification, baseline trials, full curve measurement, and live verification.
- `[calibrate-pointer.py:main]` CLI entry point starting `CalibrationHTTPServer` and invoking `run_calibration` under `calibration_access`.
- `[check:ROOT_DIR]` Script entry point running `scripts/lint-structure.py`, `swift test`, `swift build -c release`, `unittest discover -s Tests/PythonTests -p 'test_*.py'`, `scripts/check-mcp.py`, and optional `scripts/pstack-relay selftest`.
- `[check-mcp.py:check]` Function validating MCP stdio JSON-RPC (`initialize`, `notifications/initialized`, `tools/list`, `ping`, and optional `tools/call` `list_devices` when `live=True`).
- `[check-mcp.py:main]` CLI entry point accepting `--live` and optional `command` remainder (defaulting to `scripts/mcp.sh`).
- `[diagnose-bluetooth.sh:--help|-h]` CLI flag printing usage instructions and exiting 0.
- `[diagnose-bluetooth.sh:minutes]` Optional positional arg (`1..60`, default `10`) specifying the `log show --last` window in minutes.
- `[diagnose-bluetooth.sh:IPHONE_USE_PORT]` Env var (`1..65535`, default `7390`) specifying the local HTTP port for `/status`.
- `[diagnose-bluetooth.sh:collect]` Shell function running a diagnostic command section and setting `report_exit=1` on failure.
- `[diagnose-bluetooth.sh:process_snapshot]` Shell function listing running `iphone-use` processes via `/bin/ps -axo pid=,lstart=,comm=`.
- `[generate-icon.swift:color]`, `[generate-icon.swift:rounded]`, `[generate-icon.swift:gradient]`, `[generate-icon.swift:glow]`, `[generate-icon.swift:stroke]`, `[generate-icon.swift:translated]`, `[generate-icon.swift:polygon]`, and `[generate-icon.swift:inset]` CoreGraphics path/drawing helper functions used to construct the app icon artwork.
- `[generate-icon.swift:artwork]` Swift function rendering the 1024x1024 master `CGImage` icon.
- `[generate-icon.swift:image]` Swift function downsampling `master` to a given pixel `size`.
- `[generate-icon.swift:writePNG]` Swift function writing a `CGImage` to disk as PNG.
- `[install-codex-mcp.sh:SKIP_BUILD]` Env var (default `0`); when not `1` or when `.build/release/iphone-use` is missing, triggers `swift build -c release`.
- `[install-codex-mcp.sh:CODEX_HOME]` Optional env var overriding `$HOME/.codex` for `config.toml` registration and skipping `ensure_service.py`.
- `[install-codex-mcp.sh:SKIP_ENSURE_SERVICE]` Env var (default `0`); when `1`, skips running `codex/skills/iphone-use/scripts/ensure_service.py --wait 6`.
- `[install-codex-skill.sh:CODEX_HOME]` Optional env var overriding target skill directory (`$CODEX_HOME/skills/iphone-use`).
- `[install-mcp.sh:SKIP_BUILD]` Env var (default `0`); when not `1` or when `.build/release/iphone-use` is missing, triggers `swift build -c release`.
- `[install-mcp.sh:AGY_CONFIG_DIR]` Optional env var (default `$HOME/.gemini/config`) specifying directory for `mcp_config.json`.
- `[install-mcp.sh:AGY_SKILLS_DIR]` Optional env var; when set, symlinks `codex/skills/iphone-use` into `$AGY_SKILLS_DIR/iphone-use`.
- `[lint-structure.py:check_swift_content]` Function checking a Swift file's relative path and content against `STATE_DIR_NIL_RE`, `GHOSTHAND_SOCK_RE`, and `WAKE_ACTION_PARSE_RE`.
- `[lint-structure.py:run_selftest]` Function verifying `check_swift_content` catches synthetic violations for all three lint rules.
- `[lint-structure.py:main]` CLI entry point supporting `--selftest` and scanning all `Sources/**/*.swift` files.
- `[mcp.sh:CONFIG]` Env var (`debug`|`release`, default `release`) selecting `.build/$CONFIG/iphone-use mcp`.
- `[record.sh:OUT]` Positional arg `$1` (default `demo.mp4`) specifying output MP4 file path.
- `[record.sh:FPS]` Positional arg `$2` (default `8`) specifying screenshot polling rate.
- `[record.sh:IPHONE_USE_PORT]` Env var (default `7390`) specifying local HTTP port for `/screenshot`.
- `[record.sh:DEVICE]` Positional arg `$3` appended as `&device=$3` to `/screenshot?maxWidth=590`.
- `[record.sh:finish]` Signal handler (`INT`, `TERM`) encoding captured frames with `ffmpeg` and removing temporary directory.
- `[release.sh:--help|-h]` CLI flag printing usage and exiting 0.
- `[release.sh:release_tag]` Required first positional arg (`^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$`).
- `[release.sh:--publish]` Optional CLI flag enabling GitHub release creation/upload/publishing via `gh`.
- `[release.sh:CODESIGN_IDENTITY]` Env var (default `-`) passed to `./scripts/build-app.sh`.
- `[release.sh:APP_BUILD]` Env var (default `${GITHUB_RUN_NUMBER:-1}`) passed to `./scripts/build-app.sh`.
- `[release.sh:GITHUB_REPOSITORY]` Optional env var (`OWNER/REPO`) overriding `gh repo view` lookup.
- `[run.sh:CONFIG]` Env var (default `release`) passed to `swift run -c "$CONFIG" iphone-use "$@"`.

## Invariants
- `[build-app.sh:CONFIG]` Must be `debug` or `release`; otherwise exits 1.
- `[build-app.sh:BUILD_ARCH]` Must be `native`, `arm64`, `x86_64`, or `universal`; otherwise exits 1.
- `[build-app.sh:APP_VERSION]` If set, must match `^[0-9]+\.[0-9]+\.[0-9]+$`; otherwise exits 1.
- `[build-app.sh:APP_BUILD]` If set, must match `^[1-9][0-9]*$`; otherwise exits 1.
- `[build-app.sh:CODESIGN_IDENTITY]` Explicit `CODESIGN_IDENTITY` must succeed without falling back to ad-hoc `-` signing, and `codesign --verify --strict` must pass.
- `[calibrate-pointer.py:PhoneAPI.select_device]` Exactly one device matching `--device` must exist and have truthy `bluetooth` field.
- `[calibrate-pointer.py:PointerMeasurements.record]` Only updates `state['move']` when incoming `move` event `time` is strictly greater than the recorded `time`.
- `[calibrate-pointer.py:PointerCalibration._measure_horizontal_curve]` For counts `1..32`, `after[0] < width - 10`, `abs(returned[0] - before[0]) <= 3`, and `distance` must be finite and strictly monotonically increasing (`distance > distances[-1]`).
- `[calibrate-pointer.py:PointerCalibration._verify_vertical_curve]` Vertical 3x16 nudge delta must match `distances[16] * 3` within 3 px and return within 3 px.
- `[calibrate-pointer.py:PointerCalibration._verify_diagonal_curve]` Sets `vectorModel = 'radialQuantized'` only if all 4 test vectors `[(12, 16), (16, 12), (7, 7), (16, 16)]` match `distances[int(hypot(dx, dy))] * component / magnitude` within `0.6` px and return within `3` px.
- `[calibrate-pointer.py:baseline_profile]` Rejects baselines with mismatched `(screenWidth, screenHeight)` by returning `None`; raises `RuntimeError` unless `2 <= len(distances) <= 128`, `distances[0] == 0`, all values are finite non-bool numbers strictly increasing with `distances[1] >= 0.05`, `0.01 <= reportInterval <= 0.1`, `ceil(width / distances[-1]) + ceil(height / distances[-1]) <= 512`, and `vectorModel` (if present) is `'radialQuantized'`.
- `[calibrate-pointer.py:calibration_access]` `IPHONE_USE_STATE_DIR` must be an absolute path; for localhost APIs (`127.0.0.1`, `localhost`, `::1`), acquires shared lock on `service-<port>.lock` and exclusive lock on `device-<port>-<hex_id>.lock` within 10s.
- `[calibrate-pointer.py:parse_arguments]` `--baseline` requires `--auto`.
- `[calibrate-pointer.py:run_calibration]` `page['screenWidth'] * dpr == device['width']` and `page['screenHeight'] * dpr == device['height']` must hold.
- `[check-mcp.py:check]` MCP process must exit 0, emit only valid JSON-RPC 2.0 lines on stdout with exact reply IDs `[1, 2, 3]` (or `[1, 2, 3, 4]` with `--live`), negotiate `protocolVersion == '2025-06-18'`, advertise `tools` capability including all 12 required tools (`list_devices`, `screenshot`, `move_pointer`, `adjust_pointer`, `click_pointer`, `tap`, `long_press`, `swipe`, `type_text`, `press_key`, `keyboard_sequence`, `home`) with `inputSchema.type == 'object'`, and return `{}` for `ping`.
- `[diagnose-bluetooth.sh:minutes]` Must have `<= 1` positional argument and `minutes` must be an integer `1..60`, else exits 2.
- `[diagnose-bluetooth.sh:IPHONE_USE_PORT]` Must be an integer `1..65535`, else exits 2.
- `[lint-structure.py:STATE_DIR_NIL_RE]` No file in `Sources/**/*.swift` except `Sources/iPhoneUse/Devices/DeviceAddressing.swift` may directly check `"IPHONE_USE_STATE_DIR"] == nil` or `!= nil`.
- `[lint-structure.py:GHOSTHAND_SOCK_RE]` No file in `Sources/**/*.swift` may reference `.ghosthand/daemon.sock`.
- `[lint-structure.py:WAKE_ACTION_PARSE_RE]` `Sources/iPhoneUse/API/ControlAPI.swift` must define `func shouldWakeControl(...) -> Bool` delegating directly to `Action.parse(path: normalizedPath) != nil`.
- `[mcp.sh:CONFIG]` `CONFIG` must be `debug` or `release` and `.build/$CONFIG/iphone-use` must be executable before `exec`, keeping stdout exclusively for MCP JSON-RPC.
- `[release.sh:release_tag]` Tag must match `^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-[0-9A-Za-z]+([.-][0-9A-Za-z]+)*)?$`, OS must be `Darwin`, and `swift`, `python3`, `codesign`, `ditto`, `lipo`, `shasum` must be on `PATH`.
- `[release.sh:publish]` When `--publish` is passed, `gh` must be installed, working tree must be clean (`git status --porcelain --untracked-files=normal`), `HEAD` and remote tag commit on GitHub must match `refs/tags/${release_tag}^{commit}`, and any existing GitHub release for `release_tag` must be a draft (`isDraft == true`).

## Side Effects
- `[build-app.sh:APP]` Runs `swift build`, deletes and recreates `build/iPhoneUse.app`, copies binary (or `lipo -create`), `Resources/Info.plist`, `Sources/iPhoneUse/Resources/AppIcon.icns`, and `LICENSE`, mutates `Info.plist` via `PlistBuddy` if `APP_VERSION`/`APP_BUILD` are set, and runs `codesign`.
- `[calibrate-pointer.py:main]` Reads `~/Library/Application Support/iPhoneUse/pairings.json`, binds `CalibrationHTTPServer` on `0.0.0.0:<listen_port>`, creates/locks files in `IPHONE_USE_STATE_DIR` (default `~/Library/Logs/iPhoneUse`), sends HTTP requests (`/devices`, `/nudge`, `/key`, `/type`, `/move`, `/calibration/reload`) to `--api`, and writes/rolls back `~/Library/Application Support/iPhoneUse/pointer-calibration/<HOST>.json` and `by-screen/<screenID_hex>.json`.
- `[check:ROOT_DIR]` Executes `scripts/lint-structure.py`, `swift test`, `swift build -c release`, Python unit tests, `scripts/check-mcp.py`, and optional `scripts/pstack-relay selftest`.
- `[check-mcp.py:check]` Spawns the target MCP server subprocess (default `scripts/mcp.sh`) and communicates over stdin/stdout.
- `[diagnose-bluetooth.sh:collect]` Runs `/bin/date`, `/usr/bin/sw_vers`, `/bin/ps`, `/usr/bin/curl http://127.0.0.1:$port/status`, and `/usr/bin/log show` for `bluetoothd` events, printing output to stdout.
- `[generate-icon.swift:icon]` Creates temporary directory `iphone-use-icon-<UUID>/AppIcon.iconset` (cleaned up via `defer`), writes PNGs into it, writes `Resources/AppIcon.png`, creates `Sources/iPhoneUse/Resources`, and runs `/usr/bin/iconutil` to write `Sources/iPhoneUse/Resources/AppIcon.icns`.
- `[install-codex-mcp.sh:config_file]` Runs `swift build -c release` (unless skipped), updates `$CODEX_HOME/config.toml` or `~/.codex/config.toml` or runs `codex mcp remove/add iphone-use`, executes `scripts/install-codex-skill.sh`, and runs `codex/skills/iphone-use/scripts/ensure_service.py --wait 6` (unless `CODEX_HOME` is set or `SKIP_ENSURE_SERVICE=1`).
- `[install-codex-skill.sh:target_dir]` Creates `.agents/skills/iphone-use` symlink and conditionally creates `$CODEX_HOME/skills/iphone-use` or `$HOME/.codex/skills/iphone-use` symlink.
- `[install-mcp.sh:agy_mcp_config]` Runs `swift build -c release` (unless skipped), writes `mcpServers.iphone-use` into `${AGY_CONFIG_DIR:-$HOME/.gemini/config}/mcp_config.json`, creates `.agents/skills/iphone-use` and optional `$AGY_SKILLS_DIR/iphone-use` symlinks, and executes `scripts/install-codex-mcp.sh`.
- `[lint-structure.py:main]` Reads all `Sources/**/*.swift` files and prints lint status/errors to stdout/stderr.
- `[mcp.sh:exec]` Replaces current process with `.build/$CONFIG/iphone-use mcp`.
- `[record.sh:FRAMES]` Creates a temporary directory via `mktemp -d`, polls `http://127.0.0.1:$PORT/screenshot?maxWidth=590$DEVICE` via `curl` saving JPEGs, and on `INT`/`TERM` runs `ffmpeg` to write `$OUT` and deletes `$FRAMES`.
- `[release.sh:output_dir]` Runs `swift test`, Python unittests, `./scripts/build-app.sh`, `lipo -verify_arch`, `codesign --verify`, and `scripts/check-mcp.py`; writes `build/releases/<tag>/iPhoneUse-<tag>-macOS-universal.zip` and `SHA256SUMS.txt`; when `--publish` is set, writes `RELEASE_NOTES.md` and creates/uploads/publishes the GitHub release via `gh`.
- `[run.sh:exec]` Replaces current process with `swift run -c "$CONFIG" iphone-use "$@"`.

## Verification
- Run: `./scripts/check`
