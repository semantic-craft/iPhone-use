# Task

## Overview

Implements autonomous multi-step mobile task execution powered by the Gemini Interactions API (`gemini-3.8-flash`). Coordinates screen observation and OCR stillness detection, 0..999 grid-to-normalized coordinate conversion, three-layer sensitive-action safety evaluation, HID and USB action dispatch, and persistent session state management across multi-turn interactions and safety yields.

## Interface

- `[GeminiTaskExecutor.swift:GeminiThinkingLevel]` - `Codable`, `CaseIterable`, `Equatable` enum (`.minimal`, `.low`, `.medium`, `.high`) representing `thinking_level` values for the `gemini-3.8-flash` Interactions API, with `parse(_ raw: String?) throws -> GeminiThinkingLevel`.
- `[GeminiTaskExecutor.swift:GeminiCoordinateSpace]` - Coordinate conversion namespace (`gridMax`, `gridScale`, `clampGrid(_:)`, `toUnitFraction(_:)`, `toPixel(_:dimension:)`, `toNormalizedPoint(x:y:)`) mapping Gemini `0..999` mobile grid coordinates to normalized `0.0..1.0` fractions and pixel coordinates.
- `[GeminiTaskExecutor.swift:GeminiFunctionCall]` - `Codable`, `Equatable` struct representing a model `function_call` step (`id`, `name`, `argumentsJSON`, computed `arguments`, and nested `SafetyDecision` with `decision` and `explanation`).
- `[GeminiTaskExecutor.swift:GeminiInteractionTurn]` - `Equatable` struct representing a parsed `POST /v1beta/interactions` response (`id`, `functionCalls`, `modelText`).
- `[GeminiTaskExecutor.swift:GeminiInteractionRequest]` - Outgoing `POST /v1beta/interactions` payload builder (`canonicalModel`, `model`, `previousInteractionID`, `thinkingLevel`, `systemInstruction`, `tools`, `input`, `sanitizeModelName(_:)`, `defaultMobileTools()`, `toJSONObject()`).
- `[GeminiTaskExecutor.swift:GeminiInteractionsTransport]` - Protocol defining `sendInteraction(_ request: GeminiInteractionRequest) throws -> GeminiInteractionTurn`.
- `[GeminiTaskExecutor.swift:LiveGeminiInteractionsTransport]` - Live `GeminiInteractionsTransport` implementation posting requests to `https://generativelanguage.googleapis.com/v1beta/interactions` and parsing turns via `parseInteractionResponse(_ data: Data) throws -> GeminiInteractionTurn`.
- `[GeminiTaskExecutor.swift:GeminiSafetyGuard]` - Three-layer sensitive-action guard (`Verdict`, `evaluate(call:ocrItems:screenSize:userApprovedCurrentStep:)`, `intArg(_:)`) inspecting explicit model yields, model safety decisions, and OCR-matched consequential actions.
- `[GeminiTaskExecutor.swift:TaskRecord]` - `Codable`, `Equatable` session record (`State` enum `.running`, `.yielded`, `.completed`, `.failed`; `StepTrace` struct; `toJSON()`) tracking execution history, interaction chaining (`previousInteractionID`), and pending safety approvals.
- `[GeminiTaskExecutor.swift:TaskSessionStore]` - Thread-safe store (`shared`, `init(baseDirectory:)`, `save(_:)`, `load(taskID:)`) persisting `TaskRecord` JSON files on disk.
- `[GeminiTaskExecutor.swift:GeminiTaskExecutor]` - Autonomous task runner (`RequestOptions`, `systemInstruction(deviceInfo:screenSize:)`, `run(options:hooks:store:)`) executing multi-step mobile perception-action loops.

## Invariants

- `[GeminiTaskExecutor.swift:GeminiThinkingLevel.parse]` - Nil or empty raw `thinking_level` values default to `.low`; any value outside `minimal`, `low`, `medium`, or `high` throws `GhosthandError.invalidArgument`.
- `[GeminiTaskExecutor.swift:GeminiCoordinateSpace]` - Grid coordinates are clamped to `0...999` (`gridMax = 999`, `gridScale = 1000.0`); `toPixel(_:dimension:)` returns `0` when `dimension <= 0` and clamps results to `0...(dimension - 1)`.
- `[GeminiTaskExecutor.swift:GeminiInteractionRequest.sanitizeModelName]` - Empty, nil, or legacy/deprecated model identifiers (prefixes `gemini-2.5`, `gemini-2.0`, `gemini-1.5`, or containing `computer-use-preview`) are rewritten to `canonicalModel` (`"gemini-3.8-flash"`).
- `[GeminiTaskExecutor.swift:LiveGeminiInteractionsTransport.sendInteraction]` - Requires a non-empty API key from `apiKeyProvider` (reading `GEMINI_API_KEY` or `GOOGLE_API_KEY`), throwing `GhosthandError(code: "missing-gemini-api-key", httpStatus: 503)` when absent, and requires an HTTP `200..<300` status code.
- `[GeminiTaskExecutor.swift:GeminiSafetyGuard.evaluate]` - Yields execution whenever `call.name == "yield_to_user"`, whenever `call.safetyDecision.decision` is `"require_confirmation"` or `"blocked"` without `userApprovedCurrentStep`, or whenever an unapproved tap/press targets a consequential OCR label (payment, publishing, account deletion, passcode entry) or a `type` action with `press_enter` submits sensitive credential tokens.
- `[GeminiTaskExecutor.swift:GeminiTaskExecutor.RequestOptions.parse]` - Requires either a non-empty `prompt` or a non-empty `resumeTaskID`, and enforces `maxSteps` within `1...50` (defaulting to `12`).
- `[GeminiTaskExecutor.swift:GeminiTaskExecutor.run]` - Rejects execution with `GhosthandError.deviceLocked` if `hooks.isLocked()` is `true`, throws `GhosthandError(code: "task-not-found", httpStatus: 404)` when `resumeTaskID` cannot be loaded from `TaskSessionStore`, throws `GhosthandError.invalidArgument` when resuming a pending safety-gated call with `approvePendingSafety == false`, executes at most `options.maxSteps` function calls per invocation before yielding, and clamps `long_press` duration to `0.1...10.0` seconds and `wait` duration to `0.05...5.0` seconds.

## Side Effects

- `[GeminiTaskExecutor.swift:LiveGeminiInteractionsTransport.sendInteraction]` - Reads `GEMINI_API_KEY` or `GOOGLE_API_KEY` from `ProcessInfo.processInfo.environment` and executes synchronous HTTPS `POST` requests via `URLSession` to `https://generativelanguage.googleapis.com/v1beta/interactions`.
- `[GeminiTaskExecutor.swift:TaskSessionStore.save]` - Acquires `NSLock`, updates the in-memory task dictionary, creates `<baseDirectory>/tasks` via `FileManager.default`, and atomically writes `TaskRecord` JSON files to `<baseDirectory>/tasks/<taskID>.json`.
- `[GeminiTaskExecutor.swift:TaskSessionStore.load]` - Acquires `NSLock`, reads `<baseDirectory>/tasks/<taskID>.json` from disk on cache miss, and populates the in-memory cache.
- `[GeminiTaskExecutor.swift:GeminiTaskExecutor.run]` - Captures screen frames and OCR observations via `StillnessDetector.observeAfterAction`, sends multi-turn interaction requests over `GeminiInteractionsTransport`, dispatches Bluetooth HID pointer/keyboard/consumer actions via `hooks.input`, queries and launches apps over USB via `hooks.usbProvider` (`openApp`, `listApps`, `deviceInfo`), blocks between steps via `hooks.sleep`, and persists `TaskRecord` transitions to `TaskSessionStore`.

## Verification

- Run: `swift test`
