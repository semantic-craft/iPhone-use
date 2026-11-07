# iPhoneUse

## Overview
Main executable target for `iphone-use`, dispatching process startup across four operating modes in `main.swift` (isolated USB screenshotr worker, stdio Model Context Protocol server, one-shot CLI runner, and the AppKit/HTTP resident daemon) and coordinating the 12 core subsystems under `Sources/iPhoneUse`.

## Interface
- `[main.swift:USBIdentityScreenshot.workerArgument]` — Subprocess worker entrypoint mode: when `CommandLine.arguments.dropFirst().first` matches `USBIdentityScreenshot.workerArgument`, runs `USBIdentityScreenshot.write(physicalID:output:)` and exits with its status code.
- `[main.swift:mcp]` — Stdio MCP server entrypoint mode: when the first CLI argument is `"mcp"`, runs `MCPServer.run()`.
- `[main.swift:CLIRunner.shouldRunCLI]` — One-shot CLI entrypoint mode: when `CLIRunner.shouldRunCLI(arguments: CommandLine.arguments)` returns `true`, runs `CLIRunner.runAndExit()`.
- `[main.swift:Application.run]` — Default resident daemon and desktop GUI entrypoint mode: launches `Application.run()`.
- Subdirectory Contracts:
  - [API](./API/README.md) — Localhost HTTP server (`HTTPServer`), web viewer (`WebPreview`), and `ControlAPI` request router.
  - [App](./App/README.md) — Application lifecycle (`Application`, `AppDelegate`), run mode persistence (`AppRunModeStore`), and resident-quiet idle suspension (`QuietModeActivityController`).
  - [Bluetooth](./Bluetooth/README.md) — CoreBluetooth BLE HID-over-GATT peripheral (`HIDPeripheral`), per-host GATT subscription state (`HIDConnectionState`), and HID report builders (`HIDReports`).
  - [CLI](./CLI/README.md) — Command-line subcommand and flag parser (`CLIRunner`) dispatching to `ControlAPI` or `phone_exec.py`.
  - [Capture](./Capture/README.md) — AVFoundation/CoreMediaIO USB video capture (`ScreenCaptureManager`), multi-device identity verification (`CaptureIdentityVerifier`), dormant USB Valeria recovery (`USBValeriaConfigurator`), Vision OCR (`ScreenOCR`), and MP4 recording (`ScreenRecorderManager`).
  - [Devices](./Devices/README.md) — Device discovery, deterministic addressing (`DeviceAddressing`), USB-to-BLE pairing (`DeviceRegistry`, `DevicePairing`), lock monitoring (`DeviceLockMonitor`), readiness checks (`SetupReadiness`), and SQLite device leases (`LeaseStore`).
  - [Input](./Input/README.md) — Bluetooth HID gesture/keyboard synthesis (`DeviceInput`), dual-track enhanced/standard routing (`DualTrackInputCoordinator`, `JevTrackRouter`), post-action stillness/OCR verification (`StillnessDetector`, `ListScrollWalker`), and [LegacyPointer](./Input/LegacyPointer/README.md) calibration.
  - [Localization](./Localization/README.md) — Compile-time checked bilingual (`zh`/`en`) string tables (`AppLanguage`, `StringsAPI`, `StringsMCP`, `StringsUI`, `StringsWeb`).
  - [MCP](./MCP/README.md) — Stdio JSON-RPC 2.0 MCP server (`MCPServer`), 50-tool catalog (`MCPToolCatalog`), flock serialization (`MCPAccess`), and daemon auto-launcher (`MCPServiceLauncher`).
  - [Task](./Task/README.md) — Autonomous multi-step mobile task execution (`GeminiTaskExecutor`) backed by `gemini-3.8-flash`, 3-layer safety guard (`GeminiSafetyGuard`), and persistent task store (`TaskSessionStore`).
  - [UI](./UI/README.md) — AppKit device windows (`ControlWindowCoordinator`), live video canvas and input steering (`PhoneControlView`), shortcut sidebar (`ControlSidebar`), and overlays (`ControlConnectionOverlay`, `ControlLockNotice`).
  - [USB](./USB/README.md) — USB AFC/house-arrest/lockdownd channels (`USBSystemProvider`, `StateDirUSBSystemProvider`, `MobileDeviceLockdownBridge`).

## Invariants
- `[main.swift:USBIdentityScreenshot.workerArgument]` — When invoked with `USBIdentityScreenshot.workerArgument`, `CommandLine.arguments.count` must equal `4` (`[executable, workerArgument, physicalID, outputPath]`); otherwise the process exits immediately with `USBIdentityScreenshot.failedExitCode` without initializing AppKit, CoreBluetooth, or `HTTPServer`.
- `[Devices/DeviceAddressing.swift:RuntimeEnvironment.isLiveHardwareAllowed]` — Direct checks against `IPHONE_USE_STATE_DIR == nil` outside `DeviceAddressing.swift` and any coupling to `.ghosthand/daemon.sock` are forbidden and enforced by `scripts/lint-structure.py`.
- `[API/ControlAPI.swift:ControlAPI.shouldWakeControl]` — Must delegate directly to `Action.parse(path: normalizedPath) != nil` (enforced by `scripts/lint-structure.py`).

## Side Effects
- `[main.swift:exit]` — Terminates the process immediately with the worker exit status when invoked in `USBIdentityScreenshot.workerArgument` mode.
- `[main.swift:USBIdentityScreenshot.write]` — Queries `com.apple.mobile.screenshotr` over USB and writes the captured screenshot to `CommandLine.arguments[3]`.
- `[main.swift:MCPServer.run]` — Reads JSON-RPC 2.0 requests from `stdin`, acquires flock locks, auto-starts the resident daemon if needed, and forwards requests over localhost HTTP.
- `[main.swift:CLIRunner.runAndExit]` — Executes CLI commands against `ControlAPI.handle` or spawns `phone_exec.py`, writes output to `stdout`/`stderr`, and exits.
- `[main.swift:Application.run]` — Starts `DeviceRegistry`, `HIDPeripheral`, `ScreenCaptureManager`, `HTTPServer`, and the `NSApplication` run loop.

## Verification
- Run: `swift test`
