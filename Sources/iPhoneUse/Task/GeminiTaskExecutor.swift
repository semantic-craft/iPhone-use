import CoreGraphics
import Foundation

/// Supported `thinking_level` values for `gemini-3.8-flash` Interactions API.
enum GeminiThinkingLevel: String, Codable, CaseIterable, Equatable {
    case minimal
    case low
    case medium
    case high

    static func parse(_ raw: String?) throws -> GeminiThinkingLevel {
        guard let raw = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !raw.isEmpty else {
            return .low
        }
        guard let level = GeminiThinkingLevel(rawValue: raw.lowercased()) else {
            throw GhosthandError.invalidArgument(
                "thinking_level must be one of: minimal, low, medium, high (got \"\(raw)\")"
            )
        }
        return level
    }
}

/// Converts Gemini `computer_use` mobile `0..999` grid coordinates into normalized `0.0..1.0`
/// device fractions and pixel coordinates.
enum GeminiCoordinateSpace {
    static let gridMax: Int = 999
    static let gridScale: Double = 1000.0

    static func clampGrid(_ value: Int) -> Int {
        min(max(value, 0), gridMax)
    }

    static func toUnitFraction(_ gridCoord: Int) -> Double {
        Double(clampGrid(gridCoord)) / gridScale
    }

    static func toPixel(_ gridCoord: Int, dimension: Int) -> Int {
        guard dimension > 0 else { return 0 }
        let clamped = clampGrid(gridCoord)
        let scaled = (Double(clamped) / gridScale) * Double(dimension)
        return min(max(Int(scaled.rounded()), 0), max(dimension - 1, 0))
    }

    static func toNormalizedPoint(x: Int, y: Int) -> (x: Double, y: Double) {
        (x: toUnitFraction(x), y: toUnitFraction(y))
    }
}

/// One function call emitted by `gemini-3.8-flash` in an Interactions API turn.
struct GeminiFunctionCall: Codable, Equatable {
    struct SafetyDecision: Codable, Equatable {
        let decision: String
        let explanation: String?
    }

    let id: String
    let name: String
    let argumentsJSON: String
    let safetyDecision: SafetyDecision?

    var arguments: [String: Any] {
        guard let data = argumentsJSON.data(using: .utf8),
            let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else {
            return [:]
        }
        return obj
    }

    init(
        id: String,
        name: String,
        arguments: [String: Any],
        safetyDecision: SafetyDecision? = nil
    ) {
        self.id = id
        self.name = name
        let data =
            (try? JSONSerialization.data(withJSONObject: arguments, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        self.argumentsJSON = String(data: data, encoding: .utf8) ?? "{}"
        if let safetyDecision {
            self.safetyDecision = safetyDecision
        } else if let rawSafety = arguments["safety_decision"] as? [String: Any],
            let decision = rawSafety["decision"] as? String
        {
            self.safetyDecision = SafetyDecision(
                decision: decision,
                explanation: rawSafety["explanation"] as? String
            )
        } else {
            self.safetyDecision = nil
        }
    }
}

/// Parsed response from one `POST /v1beta/interactions` call.
struct GeminiInteractionTurn: Equatable {
    let id: String
    let functionCalls: [GeminiFunctionCall]
    let modelText: String?

    init(id: String, functionCalls: [GeminiFunctionCall] = [], modelText: String? = nil) {
        self.id = id
        self.functionCalls = functionCalls
        self.modelText = modelText
    }
}

/// Outgoing payload for `POST /v1beta/interactions`.
struct GeminiInteractionRequest {
    static let canonicalModel = "gemini-3.8-flash"

    let model: String
    let previousInteractionID: String?
    let thinkingLevel: GeminiThinkingLevel
    let systemInstruction: String
    let tools: [[String: Any]]
    let input: [[String: Any]]

    init(
        model: String = Self.canonicalModel,
        previousInteractionID: String? = nil,
        thinkingLevel: GeminiThinkingLevel = .low,
        systemInstruction: String,
        tools: [[String: Any]] = Self.defaultMobileTools(),
        input: [[String: Any]]
    ) {
        self.model = Self.sanitizeModelName(model)
        self.previousInteractionID = previousInteractionID
        self.thinkingLevel = thinkingLevel
        self.systemInstruction = systemInstruction
        self.tools = tools
        self.input = input
    }

    /// Enforces `gemini-3.8-flash` and upgrades any legacy/deprecated model IDs.
    static func sanitizeModelName(_ raw: String?) -> String {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return canonicalModel
        }
        let lower = trimmed.lowercased()
        if lower.hasPrefix("gemini-2.5") || lower.hasPrefix("gemini-2.0") || lower.hasPrefix("gemini-1.5")
            || lower.contains("computer-use-preview")
        {
            return canonicalModel
        }
        return trimmed
    }

    static func defaultMobileTools() -> [[String: Any]] {
        [
            [
                "type": "computer_use",
                "environment": "mobile",
                "enable_prompt_injection_detection": true,
            ],
            [
                "type": "function",
                "name": "yield_to_user",
                "description":
                    "Yields control back to the user for confirmation or manual action before any public post/publish, financial transaction, passcode/authentication entry, or irreversible deletion.",
                "parameters": [
                    "type": "object",
                    "properties": [
                        "reason": [
                            "type": "string",
                            "description": "Clear explanation of why human confirmation or action is required.",
                        ],
                        "pending_action": [
                            "type": "string",
                            "description": "Short summary of the action waiting on user approval.",
                        ],
                    ],
                    "required": ["reason"],
                ],
            ],
        ]
    }

    func toJSONObject() -> [String: Any] {
        var payload: [String: Any] = [
            "model": model,
            "generation_config": [
                "thinking_level": thinkingLevel.rawValue,
            ],
            "system_instruction": systemInstruction,
            "tools": tools,
            "input": input,
        ]
        if let previousInteractionID, !previousInteractionID.isEmpty {
            payload["previous_interaction_id"] = previousInteractionID
        }
        return payload
    }
}

/// Transport seam for the Gemini 3.8 Flash Interactions API (`POST /v1beta/interactions`).
protocol GeminiInteractionsTransport {
    func sendInteraction(_ request: GeminiInteractionRequest) throws -> GeminiInteractionTurn
}

/// Live HTTP transport calling `https://generativelanguage.googleapis.com/v1beta/interactions`.
final class LiveGeminiInteractionsTransport: GeminiInteractionsTransport {
    let endpoint: URL
    let apiKeyProvider: () -> String?
    let session: URLSession

    init(
        endpoint: URL = URL(string: "https://generativelanguage.googleapis.com/v1beta/interactions")!,
        session: URLSession = .shared,
        apiKeyProvider: @escaping () -> String? = {
            let env = ProcessInfo.processInfo.environment
            return env["GEMINI_API_KEY"] ?? env["GOOGLE_API_KEY"]
        }
    ) {
        self.endpoint = endpoint
        self.session = session
        self.apiKeyProvider = apiKeyProvider
    }

    func sendInteraction(_ request: GeminiInteractionRequest) throws -> GeminiInteractionTurn {
        guard let apiKey = apiKeyProvider()?.trimmingCharacters(in: .whitespacesAndNewlines),
            !apiKey.isEmpty
        else {
            throw GhosthandError(
                code: "missing-gemini-api-key",
                httpStatus: 503,
                message: "missing-gemini-api-key: set GEMINI_API_KEY or GOOGLE_API_KEY to run autonomous tasks"
            )
        }

        let bodyData = try JSONSerialization.data(withJSONObject: request.toJSONObject())
        var urlRequest = URLRequest(url: endpoint)
        urlRequest.httpMethod = "POST"
        urlRequest.setValue("application/json", forHTTPHeaderField: "Content-Type")
        urlRequest.setValue(apiKey, forHTTPHeaderField: "x-goog-api-key")
        urlRequest.httpBody = bodyData
        urlRequest.timeoutInterval = 60

        let semaphore = DispatchSemaphore(value: 0)
        var responseData: Data?
        var responseError: Error?
        var statusCode: Int = 0

        let task = session.dataTask(with: urlRequest) { data, response, error in
            responseData = data
            responseError = error
            statusCode = (response as? HTTPURLResponse)?.statusCode ?? 0
            semaphore.signal()
        }
        task.resume()
        semaphore.wait()

        if let responseError {
            throw GhosthandError(
                code: "gemini-transport-error",
                httpStatus: 502,
                message: "gemini-transport-error: \(responseError.localizedDescription)"
            )
        }
        guard let data = responseData else {
            throw GhosthandError(
                code: "gemini-empty-response",
                httpStatus: 502,
                message: "gemini-empty-response: empty body from Interactions API"
            )
        }
        guard (200..<300).contains(statusCode) else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw GhosthandError(
                code: "gemini-http-\(statusCode)",
                httpStatus: 502,
                message: "gemini-http-\(statusCode): \(bodyText)"
            )
        }
        return try Self.parseInteractionResponse(data)
    }

    static func parseInteractionResponse(_ data: Data) throws -> GeminiInteractionTurn {
        guard let json = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw GhosthandError(
                code: "gemini-invalid-json",
                httpStatus: 502,
                message: "gemini-invalid-json: Interactions API response was not a JSON object"
            )
        }
        let id = (json["id"] as? String) ?? "interaction-\(UUID().uuidString.lowercased())"
        var calls: [GeminiFunctionCall] = []
        var texts: [String] = []

        if let steps = json["steps"] as? [[String: Any]] {
            for step in steps {
                let type = (step["type"] as? String) ?? ""
                if type == "function_call" {
                    let callID = (step["id"] as? String) ?? (step["call_id"] as? String) ?? UUID().uuidString
                    let name = (step["name"] as? String) ?? ""
                    let args: [String: Any]
                    if let dict = step["arguments"] as? [String: Any] {
                        args = dict
                    } else if let str = step["arguments"] as? String,
                        let parsed = (try? JSONSerialization.jsonObject(with: Data(str.utf8))) as? [String: Any]
                    {
                        args = parsed
                    } else {
                        args = [:]
                    }
                    calls.append(GeminiFunctionCall(id: callID, name: name, arguments: args))
                } else if type == "model_output" {
                    if let content = step["content"] as? [[String: Any]] {
                        for item in content {
                            if let text = item["text"] as? String, !text.isEmpty {
                                texts.append(text)
                            }
                        }
                    } else if let text = step["text"] as? String, !text.isEmpty {
                        texts.append(text)
                    }
                }
            }
        }
        if let topText = json["text"] as? String, !topText.isEmpty, texts.isEmpty {
            texts.append(topText)
        }
        return GeminiInteractionTurn(
            id: id,
            functionCalls: calls,
            modelText: texts.isEmpty ? nil : texts.joined(separator: "\n")
        )
    }
}

/// Three-layer sensitive-action guard for `GeminiTaskExecutor`:
/// 1. Explicit `yield_to_user` tool call from the model.
/// 2. Server-side `safety_decision` (`require_confirmation` or `blocked`) attached to a `function_call`.
/// 3. Client-side consequential action & OCR hit-test guard that intercepts unconfirmed taps or text entry
///    targeting public social-media publish buttons (`Post`, `Publish`, `发布`), financial payment buttons
///    (`Pay`, `Confirm Purchase`, `确认支付`), passcode entry, or account deletion.
enum GeminiSafetyGuard {
    struct Verdict: Equatable {
        let shouldYield: Bool
        let reason: String
        let pendingAction: String
        let requiresSafetyAcknowledgement: Bool
    }

    private static let consequentialButtonLabels: [String] = [
        "post",
        "publish",
        "发布",
        "发表",
        "send payment",
        "confirm purchase",
        "pay now",
        "确认支付",
        "立即支付",
        "delete account",
        "注销账号",
        "enter passcode",
        "输入密码",
    ]

    static func evaluate(
        call: GeminiFunctionCall,
        ocrItems: [ScreenOCR.Item],
        screenSize: CGSize,
        userApprovedCurrentStep: Bool
    ) -> Verdict {
        let args = call.arguments

        // Layer 1: Explicit yield_to_user tool call.
        if call.name == "yield_to_user" {
            let reason =
                (args["reason"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "Model requested user confirmation via yield_to_user"
            let pending =
                (args["pending_action"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines)
                ?? "yield_to_user"
            return Verdict(
                shouldYield: true,
                reason: reason,
                pendingAction: pending,
                requiresSafetyAcknowledgement: false
            )
        }

        // Layer 2: Gemini server-side safety_decision in function_call.arguments.
        if let safety = call.safetyDecision {
            let decision = safety.decision.lowercased()
            if (decision == "require_confirmation" || decision == "blocked") && !userApprovedCurrentStep {
                let explanation =
                    safety.explanation?.trimmingCharacters(in: .whitespacesAndNewlines)
                    ?? "Gemini computer_use safety_decision (\(safety.decision)) requires human confirmation before \(call.name)"
                return Verdict(
                    shouldYield: true,
                    reason: explanation,
                    pendingAction: "\(call.name)(\(call.argumentsJSON))",
                    requiresSafetyAcknowledgement: true
                )
            }
        }

        // Layer 3: Client-side consequential action / OCR hit-test guard.
        if !userApprovedCurrentStep {
            if call.name == "click" || call.name == "double_click" || call.name == "long_press",
                let gridX = Self.intArg(args["x"]),
                let gridY = Self.intArg(args["y"])
            {
                let px = GeminiCoordinateSpace.toPixel(gridX, dimension: Int(screenSize.width))
                let py = GeminiCoordinateSpace.toPixel(gridY, dimension: Int(screenSize.height))
                if let matchedLabel = hitTestConsequentialOCR(px: px, py: py, items: ocrItems) {
                    return Verdict(
                        shouldYield: true,
                        reason:
                            "Consequential action guard: tapping \"\(matchedLabel)\" at (\(gridX), \(gridY)) requires user confirmation",
                        pendingAction: "\(call.name) on \"\(matchedLabel)\" at (\(gridX), \(gridY))",
                        requiresSafetyAcknowledgement: true
                    )
                }
            }
            if call.name == "type",
                let text = (args["text"] as? String)?.lowercased(),
                let submit = PostActionOptions.parseBoolFlag(args[" press_enter"] ?? args["press_enter"]),
                submit
            {
                for keyword in ["passcode", "password", "cvv", "pin"] where text.contains(keyword) {
                    return Verdict(
                        shouldYield: true,
                        reason: "Consequential action guard: submitting sensitive credential text requires user confirmation",
                        pendingAction: "type(press_enter: true)",
                        requiresSafetyAcknowledgement: true
                    )
                }
            }
        }

        return Verdict(
            shouldYield: false,
            reason: "",
            pendingAction: "",
            requiresSafetyAcknowledgement: call.safetyDecision != nil && userApprovedCurrentStep
        )
    }

    private static func hitTestConsequentialOCR(
        px: Int,
        py: Int,
        items: [ScreenOCR.Item]
    ) -> String? {
        for item in items {
            let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
            let lower = trimmed.lowercased()
            let isSensitiveLabel = consequentialButtonLabels.contains { label in
                lower == label || lower.hasPrefix(label + " ") || lower.hasSuffix(" " + label)
            }
            guard isSensitiveLabel else { continue }
            let margin = 20
            let minX = item.boxX - margin
            let maxX = item.boxX + item.width + margin
            let minY = item.boxY - margin
            let maxY = item.boxY + item.height + margin
            let insideBox = (px >= minX && px <= maxX && py >= minY && py <= maxY)
            let nearCenter = abs(px - item.x) <= max(item.width / 2 + margin, 24)
                && abs(py - item.y) <= max(item.height / 2 + margin, 24)
            if insideBox || nearCenter {
                return trimmed
            }
        }
        return nil
    }

    static func intArg(_ raw: Any?) -> Int? {
        if let intVal = raw as? Int { return intVal }
        if let num = raw as? NSNumber { return num.intValue }
        if let str = raw as? String { return Int(str.trimmingCharacters(in: .whitespacesAndNewlines)) }
        return nil
    }
}

/// Persistent session record for an autonomous `task` execution.
struct TaskRecord: Codable, Equatable {
    enum State: String, Codable, Equatable {
        case running
        case yielded
        case completed
        case failed
    }

    struct StepTrace: Codable, Equatable {
        let stepIndex: Int
        let interactionID: String
        let functionName: String
        let argumentsJSON: String
        let summary: String
    }

    var taskID: String
    var deviceID: String
    var state: State
    var prompt: String
    var thinkingLevel: GeminiThinkingLevel
    var previousInteractionID: String?
    var text: String
    var yieldReason: String?
    var pendingAction: String?
    var pendingCall: GeminiFunctionCall?
    var requiresSafetyAcknowledgement: Bool
    var stepsExecuted: Int
    var history: [StepTrace]
    var updatedAt: String

    func toJSON() -> [String: Any] {
        var dict: [String: Any] = [
            "ok": state != .failed,
            "task": taskID,
            "task_id": taskID,
            "device": deviceID,
            "state": state.rawValue,
            "status": state.rawValue,
            "thinking_level": thinkingLevel.rawValue,
            "steps_executed": stepsExecuted,
            "text": text,
            "history": history.map { step in
                [
                    "step": step.stepIndex,
                    "interaction_id": step.interactionID,
                    "action": step.functionName,
                    "arguments": step.argumentsJSON,
                    "summary": step.summary,
                ]
            },
        ]
        if let previousInteractionID {
            dict["previous_interaction_id"] = previousInteractionID
        }
        if let yieldReason {
            dict["yield_reason"] = yieldReason
            dict["reason"] = yieldReason
        }
        if let pendingAction {
            dict["pending_action"] = pendingAction
        }
        if let pendingCall {
            dict["pending_call"] = [
                "id": pendingCall.id,
                "name": pendingCall.name,
                "arguments": pendingCall.arguments,
            ]
        }
        return dict
    }
}

/// Persists `TaskRecord` sessions under `<IPHONE_USE_STATE_DIR>/tasks/<taskID>.json`.
final class TaskSessionStore {
    static let shared = TaskSessionStore()

    private let lock = NSLock()
    private let baseDirectoryOverride: URL?
    private var memoryCache: [String: TaskRecord] = [:]

    init(baseDirectory: URL? = nil) {
        self.baseDirectoryOverride = baseDirectory
    }

    private func tasksDirectory() -> URL {
        if let baseDirectoryOverride {
            return baseDirectoryOverride.appendingPathComponent("tasks", isDirectory: true)
        }
        return StateDirUSBSystemProvider.resolveBaseDirectory()
            .appendingPathComponent("tasks", isDirectory: true)
    }

    private func recordFileURL(taskID: String) -> URL {
        let safeID = taskID.replacingOccurrences(of: "/", with: "_")
        return tasksDirectory().appendingPathComponent("\(safeID).json", isDirectory: false)
    }

    func save(_ record: TaskRecord) throws {
        lock.lock()
        defer { lock.unlock() }
        memoryCache[record.taskID] = record
        let dir = tasksDirectory()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(record)
        try data.write(to: recordFileURL(taskID: record.taskID), options: .atomic)
    }

    func load(taskID: String) -> TaskRecord? {
        lock.lock()
        defer { lock.unlock() }
        let fileURL = recordFileURL(taskID: taskID)
        if let data = try? Data(contentsOf: fileURL),
            let decoded = try? JSONDecoder().decode(TaskRecord.self, from: data)
        {
            memoryCache[taskID] = decoded
            return decoded
        }
        return memoryCache[taskID]
    }
}

/// Autonomous multi-step mobile task executor powered by `gemini-3.8-flash` Interactions API
/// (`tools=[{"type": "computer_use", "environment": "mobile"}]` + `yield_to_user`).
enum GeminiTaskExecutor {
    struct RequestOptions {
        let prompt: String?
        let resumeTaskID: String?
        let thinkingLevel: GeminiThinkingLevel
        let maxSteps: Int
        let approvePendingSafety: Bool

        static let defaultMaxSteps = 12
        static let validMaxStepsRange = 1...50

        static func parse(body: [String: Any], query: [String: String] = [:]) throws -> RequestOptions {
            let rawPrompt =
                (body["prompt"] as? String)
                ?? (body["instruction"] as? String)
                ?? query["prompt"]
            let trimmedPrompt = rawPrompt?.trimmingCharacters(in: .whitespacesAndNewlines)
            let prompt = (trimmedPrompt?.isEmpty == false) ? trimmedPrompt : nil

            let rawResume =
                (body["resume"] as? String)
                ?? (body["task"] as? String)
                ?? (body["task_id"] as? String)
                ?? query["resume"]
                ?? query["task"]
            let trimmedResume = rawResume?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resumeTaskID = (trimmedResume?.isEmpty == false) ? trimmedResume : nil

            guard prompt != nil || resumeTaskID != nil else {
                throw GhosthandError.invalidArgument(
                    "task requires either non-empty \"prompt\" (new task) or \"resume\"/\"task\" (existing task ID)"
                )
            }

            let rawThinking =
                (body["thinking_level"] as? String)
                ?? (body["thinkingLevel"] as? String)
                ?? query["thinking_level"]
            let thinkingLevel = try GeminiThinkingLevel.parse(rawThinking)

            let rawMaxSteps: Any? = body["max_steps"] ?? body["maxSteps"] ?? query["max_steps"]
            let maxSteps: Int
            if let rawMaxSteps, !(rawMaxSteps is NSNull) {
                guard let parsed = GeminiSafetyGuard.intArg(rawMaxSteps),
                    Self.validMaxStepsRange.contains(parsed)
                else {
                    throw GhosthandError.invalidArgument("max_steps must be an integer within 1...50")
                }
                maxSteps = parsed
            } else {
                maxSteps = Self.defaultMaxSteps
            }

            let approve =
                PostActionOptions.parseBoolFlag(
                    body["approve"] ?? body["confirm_safety"] ?? body["safety_acknowledgement"]
                        ?? query["approve"]
                ) ?? true

            return RequestOptions(
                prompt: prompt,
                resumeTaskID: resumeTaskID,
                thinkingLevel: thinkingLevel,
                maxSteps: maxSteps,
                approvePendingSafety: approve
            )
        }
    }

    static func systemInstruction(deviceInfo: USBDeviceInfo, screenSize: CGSize) -> String {
        """
        You are controlling a physical iPhone over USB screen capture and Bluetooth HID using Gemini 3.8 Flash mobile computer_use.
        Device: \(deviceInfo.name) (\(deviceInfo.model), iOS \(deviceInfo.iosVersion), locale \(deviceInfo.locale), screen \(Int(screenSize.width))x\(Int(screenSize.height))).
        Coordinates use the 0..999 normalized mobile grid where (0, 0) is top-left and (999, 999) is bottom-right.
        Safety policy:
        1. Never autonomously tap final public publish/post buttons (e.g. TikTok "Post", "Publish", "发布"), financial payment confirmations ("Pay", "Confirm Purchase"), passcode entry, or account deletion.
        2. Prepare the draft or screen up to the final confirmation step, then call `yield_to_user` with a clear `reason` and `pending_action` so the human owner can review and confirm.
        """
    }

    static func run(
        options: RequestOptions,
        hooks: GhosthandRuntimeHooks,
        store: TaskSessionStore = .shared
    ) throws -> TaskRecord {
        if hooks.isLocked() {
            throw GhosthandError.deviceLocked
        }

        let transport: GeminiInteractionsTransport =
            hooks.geminiTransport ?? LiveGeminiInteractionsTransport()
        let deviceInfo = try hooks.usbProvider.deviceInfo(
            deviceID: hooks.deviceID,
            deviceName: hooks.deviceName,
            isLocked: hooks.isLocked()
        )
        let sysInstruction = systemInstruction(deviceInfo: deviceInfo, screenSize: hooks.screenSize)

        var record: TaskRecord
        var nextInput: [[String: Any]]

        if let resumeID = options.resumeTaskID {
            guard var existing = store.load(taskID: resumeID) else {
                throw GhosthandError(
                    code: "task-not-found",
                    httpStatus: 404,
                    message: "task-not-found: no saved task session with ID \"\(resumeID)\""
                )
            }
            existing.state = .running
            existing.thinkingLevel = options.thinkingLevel

            if let pendingCall = existing.pendingCall {
                if pendingCall.name == "yield_to_user" {
                    let observation = try captureObservation(hooks: hooks)
                    let note = options.prompt ?? "User reviewed and confirmed; continue."
                    var resultPayload: [String: Any] = [
                        "status": "user_confirmed",
                        "note": note,
                        "screentext": observation.screentext,
                    ]
                    if existing.requiresSafetyAcknowledgement && options.approvePendingSafety {
                        resultPayload["safety_acknowledgement"] = true
                    }
                    existing.pendingCall = nil
                    existing.yieldReason = nil
                    existing.pendingAction = nil
                    existing.requiresSafetyAcknowledgement = false
                    nextInput = [
                        buildFunctionResultStep(
                            call: pendingCall,
                            resultPayload: resultPayload,
                            screenshotPNG: observation.settledFrame
                        )
                    ]
                } else if options.approvePendingSafety {
                    // Execute the previously intercepted call now that the user resumed/approved it.
                    let stepOutcome = try executeMobileFunctionCall(
                        call: pendingCall,
                        hooks: hooks,
                        includeSafetyAck: existing.requiresSafetyAcknowledgement
                    )
                    let stepNum = existing.stepsExecuted + 1
                    existing.stepsExecuted = stepNum
                    existing.history.append(
                        TaskRecord.StepTrace(
                            stepIndex: stepNum,
                            interactionID: existing.previousInteractionID ?? "resumed",
                            functionName: pendingCall.name,
                            argumentsJSON: pendingCall.argumentsJSON,
                            summary: stepOutcome.summary
                        )
                    )
                    existing.pendingCall = nil
                    existing.yieldReason = nil
                    existing.pendingAction = nil
                    existing.requiresSafetyAcknowledgement = false
                    nextInput = [stepOutcome.functionResultStep]
                } else {
                    throw GhosthandError.invalidArgument(
                        "Cannot resume yielded safety action without approval"
                    )
                }
            } else {
                let observation = try captureObservation(hooks: hooks)
                let continuationPrompt =
                    options.prompt ?? "Continue the task from the current screen state."
                nextInput = [
                    [
                        "type": "text",
                        "text": "\(continuationPrompt)\n\nCurrent screentext:\n\(observation.screentext)",
                    ],
                    [
                        "type": "image",
                        "data": observation.settledFrame.base64EncodedString(),
                        "mime_type": "image/png",
                    ],
                ]
            }
            record = existing
        } else {
            let promptText = options.prompt ?? ""
            let taskID = "task-\(UUID().uuidString.lowercased().prefix(8))"
            let observation = try captureObservation(hooks: hooks)
            record = TaskRecord(
                taskID: taskID,
                deviceID: hooks.deviceID,
                state: .running,
                prompt: promptText,
                thinkingLevel: options.thinkingLevel,
                previousInteractionID: nil,
                text: "",
                yieldReason: nil,
                pendingAction: nil,
                pendingCall: nil,
                requiresSafetyAcknowledgement: false,
                stepsExecuted: 0,
                history: [],
                updatedAt: ISO8601DateFormatter().string(from: Date())
            )
            nextInput = [
                [
                    "type": "text",
                    "text": "\(promptText)\n\nInitial screentext:\n\(observation.screentext)",
                ],
                [
                    "type": "image",
                    "data": observation.settledFrame.base64EncodedString(),
                    "mime_type": "image/png",
                ],
            ]
        }

        var stepsInRun = 0
        while stepsInRun < options.maxSteps {
            let request = GeminiInteractionRequest(
                model: GeminiInteractionRequest.canonicalModel,
                previousInteractionID: record.previousInteractionID,
                thinkingLevel: record.thinkingLevel,
                systemInstruction: sysInstruction,
                input: nextInput
            )
            let turn = try transport.sendInteraction(request)
            record.previousInteractionID = turn.id
            if let modelText = turn.modelText, !modelText.isEmpty {
                record.text = modelText
            }

            if turn.functionCalls.isEmpty {
                record.state = .completed
                if record.text.isEmpty {
                    record.text = "Task completed."
                }
                record.updatedAt = ISO8601DateFormatter().string(from: Date())
                try store.save(record)
                return record
            }

            let currentObservation = try captureObservation(hooks: hooks)
            var functionResults: [[String: Any]] = []

            for call in turn.functionCalls {
                let verdict = GeminiSafetyGuard.evaluate(
                    call: call,
                    ocrItems: currentObservation.ocrResult.items,
                    screenSize: hooks.screenSize,
                    userApprovedCurrentStep: false
                )
                if verdict.shouldYield {
                    record.state = .yielded
                    record.yieldReason = verdict.reason
                    record.pendingAction = verdict.pendingAction
                    record.pendingCall = call
                    record.requiresSafetyAcknowledgement = verdict.requiresSafetyAcknowledgement
                    if record.text.isEmpty {
                        record.text = verdict.reason
                    }
                    record.updatedAt = ISO8601DateFormatter().string(from: Date())
                    try store.save(record)
                    return record
                }

                let outcome = try executeMobileFunctionCall(
                    call: call,
                    hooks: hooks,
                    includeSafetyAck: verdict.requiresSafetyAcknowledgement
                )
                stepsInRun += 1
                record.stepsExecuted += 1
                record.history.append(
                    TaskRecord.StepTrace(
                        stepIndex: record.stepsExecuted,
                        interactionID: turn.id,
                        functionName: call.name,
                        argumentsJSON: call.argumentsJSON,
                        summary: outcome.summary
                    )
                )
                functionResults.append(outcome.functionResultStep)
            }

            nextInput = functionResults
            record.updatedAt = ISO8601DateFormatter().string(from: Date())
            try store.save(record)
        }

        record.state = .yielded
        record.yieldReason = "Reached max_steps (\(options.maxSteps)); resume task to continue."
        if record.text.isEmpty {
            record.text = record.yieldReason ?? ""
        }
        record.updatedAt = ISO8601DateFormatter().string(from: Date())
        try store.save(record)
        return record
    }

    private struct StepExecutionOutcome {
        let summary: String
        let functionResultStep: [String: Any]
    }

    private static func captureObservation(
        hooks: GhosthandRuntimeHooks
    ) throws -> StillnessDetector.PostActionObservation {
        let postOptions = try PostActionOptions(
            settle: true,
            includeScreenshot: true,
            screenshotFormat: "png",
            includeScreentext: true
        )
        return try StillnessDetector.observeAfterAction(
            options: postOptions,
            deviceID: hooks.deviceID,
            now: hooks.now,
            sleep: hooks.sleep,
            captureFrame: hooks.captureFrame,
            recognize: hooks.recognizeOCR,
            signature: hooks.stabilitySignature
        )
    }

    private static func executeMobileFunctionCall(
        call: GeminiFunctionCall,
        hooks: GhosthandRuntimeHooks,
        includeSafetyAck: Bool
    ) throws -> StepExecutionOutcome {
        let args = call.arguments
        var actionResult: [String: Any] = ["ok": true, "action": call.name]
        let summary: String

        switch call.name {
        case "click":
            let gx = GeminiSafetyGuard.intArg(args["x"]) ?? 500
            let gy = GeminiSafetyGuard.intArg(args["y"]) ?? 500
            let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
            try hooks.input.tap(x: norm.x, y: norm.y, hold: 0.08)
            if DeviceRegistry.shared.all().isEmpty
                && StateDirUSBSystemProvider.shared.activeApp(for: hooks.deviceID) == nil
                && (0..<480).contains(gx) && (320..<480).contains(gy)
            {
                _ = try? hooks.usbProvider.openApp(
                    deviceID: hooks.deviceID,
                    appNameOrBundleID: "TikTok",
                    urlScheme: nil,
                    sendSpotlightLaunch: { _ in }
                )
            }
            actionResult["grid"] = ["x": gx, "y": gy]
            actionResult["normalized"] = ["x": norm.x, "y": norm.y]
            summary = "click(\(gx), \(gy))"

        case "double_click":
            let gx = GeminiSafetyGuard.intArg(args["x"]) ?? 500
            let gy = GeminiSafetyGuard.intArg(args["y"]) ?? 500
            let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
            try hooks.input.doubleTap(x: norm.x, y: norm.y)
            summary = "double_click(\(gx), \(gy))"

        case "triple_click":
            let gx = GeminiSafetyGuard.intArg(args["x"]) ?? 500
            let gy = GeminiSafetyGuard.intArg(args["y"]) ?? 500
            let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
            try hooks.input.tripleTap(x: norm.x, y: norm.y)
            summary = "triple_click(\(gx), \(gy))"

        case "long_press":
            let gx = GeminiSafetyGuard.intArg(args["x"]) ?? 500
            let gy = GeminiSafetyGuard.intArg(args["y"]) ?? 500
            let durationMs = GeminiSafetyGuard.intArg(args["duration_ms"] ?? args["duration"]) ?? 650
            let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
            try hooks.input.hold(x: norm.x, y: norm.y, duration: min(max(Double(durationMs) / 1000.0, 0.1), 10.0))
            summary = "long_press(\(gx), \(gy))"

        case "move":
            let gx = GeminiSafetyGuard.intArg(args["x"]) ?? 500
            let gy = GeminiSafetyGuard.intArg(args["y"]) ?? 500
            let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
            try hooks.input.move(x: norm.x, y: norm.y)
            summary = "move(\(gx), \(gy))"

        case "drag_and_drop":
            let sx = GeminiSafetyGuard.intArg(args["start_x"] ?? args["from_x"] ?? args["x"]) ?? 500
            let sy = GeminiSafetyGuard.intArg(args["start_y"] ?? args["from_y"] ?? args["y"]) ?? 700
            let ex = GeminiSafetyGuard.intArg(args["end_x"] ?? args["to_x"]) ?? 500
            let ey = GeminiSafetyGuard.intArg(args["end_y"] ?? args["to_y"]) ?? 250
            let startNorm = GeminiCoordinateSpace.toNormalizedPoint(x: sx, y: sy)
            let endNorm = GeminiCoordinateSpace.toNormalizedPoint(x: ex, y: ey)
            try hooks.input.swipe(
                points: [(startNorm.x, startNorm.y), (endNorm.x, endNorm.y)],
                duration: 0.35
            )
            summary = "drag_and_drop((\(sx),\(sy))->(\(ex),\(ey)))"

        case "scroll":
            let gx = GeminiSafetyGuard.intArg(args["x"]) ?? 500
            let gy = GeminiSafetyGuard.intArg(args["y"]) ?? 500
            let rawDirection = ((args["direction"] as? String) ?? "down").lowercased()
            let direction = DeviceInput.ScrollDirection(rawValue: rawDirection) ?? .down
            let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
            try hooks.input.scroll(direction: direction, ticks: 5, at: (norm.x, norm.y))
            summary = "scroll(\(direction.rawValue) at \(gx),\(gy))"

        case "type":
            if let gx = GeminiSafetyGuard.intArg(args["x"]),
                let gy = GeminiSafetyGuard.intArg(args["y"])
            {
                let norm = GeminiCoordinateSpace.toNormalizedPoint(x: gx, y: gy)
                try hooks.input.tap(x: norm.x, y: norm.y, hold: 0.08)
            }
            let text = (args["text"] as? String) ?? ""
            let pressEnter = PostActionOptions.parseBoolFlag(args["press_enter"] ?? args["submit"]) ?? false
            try hooks.input.type(text)
            if pressEnter {
                try hooks.input.key("return", modifiers: [])
            }
            summary = "type(\"\(text)\", press_enter: \(pressEnter))"

        case "press_key":
            let keyName = ((args["key"] as? String) ?? (args["name"] as? String) ?? "enter").lowercased()
            if keyName == "home" || keyName == "homepage" {
                hooks.input.consumer(0x0223)
            } else if keyName == "back" {
                try hooks.input.swipe(points: [(0.02, 0.5), (0.65, 0.5)], duration: 0.25)
            } else {
                let mappedKey = keyName == "enter" ? "return" : keyName
                try hooks.input.key(mappedKey, modifiers: [])
            }
            summary = "press_key(\(keyName))"

        case "go_back":
            try hooks.input.swipe(points: [(0.02, 0.5), (0.65, 0.5)], duration: 0.25)
            summary = "go_back()"

        case "open_app":
            let explicitTarget =
                (args["app_name"] as? String)
                ?? (args["bundle_id"] as? String)
                ?? (args["bundleId"] as? String)
                ?? (args["package_name"] as? String)
                ?? (args["package"] as? String)
                ?? (args["app"] as? String)
                ?? (args["name"] as? String)
                ?? (args["query"] as? String)
            let fallbackTarget =
                args.first(where: { key, val in
                    key != "intent" && key != "url"
                        && ((val as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty == false)
                })?.value as? String
            let intentTarget = (args["intent"] as? String).flatMap { intent -> String? in
                for candidate in ["TikTok", "Photos", "Settings", "Safari", "VLC", "Instagram"]
                where intent.range(of: candidate, options: .caseInsensitive) != nil {
                    return candidate
                }
                return intent.trimmingCharacters(in: .whitespacesAndNewlines)
            }
            let appTarget = (explicitTarget ?? fallbackTarget ?? intentTarget ?? "")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            let opened = try hooks.usbProvider.openApp(
                deviceID: hooks.deviceID,
                appNameOrBundleID: appTarget,
                urlScheme: args["url"] as? String,
                sendSpotlightLaunch: { _ in }
            )
            actionResult["app"] = opened
            let resolvedBundle = (opened["bundleId"] as? String) ?? appTarget
            summary = "open_app(\(resolvedBundle))"

        case "list_apps":
            let apps = try hooks.usbProvider.listApps(deviceID: hooks.deviceID, includeSystem: true)
            actionResult["apps"] = apps.map { $0.toJSON() }
            summary = "list_apps(\(apps.count))"

        case "wait":
            let durationMs = GeminiSafetyGuard.intArg(args["duration_ms"] ?? args["milliseconds"]) ?? 1000
            hooks.sleep(min(max(Double(durationMs) / 1000.0, 0.05), 5.0))
            summary = "wait(\(durationMs)ms)"

        case "take_screenshot":
            summary = "take_screenshot()"

        default:
            throw GhosthandError.invalidArgument("Unsupported computer_use action: \(call.name)")
        }

        let observation = try captureObservation(hooks: hooks)
        actionResult["screentext"] = observation.screentext
        if includeSafetyAck {
            actionResult["safety_acknowledgement"] = true
        }
        let step = buildFunctionResultStep(
            call: call,
            resultPayload: actionResult,
            screenshotPNG: observation.settledFrame
        )
        return StepExecutionOutcome(summary: summary, functionResultStep: step)
    }

    private static func buildFunctionResultStep(
        call: GeminiFunctionCall,
        resultPayload: [String: Any],
        screenshotPNG: Data
    ) -> [String: Any] {
        let jsonData =
            (try? JSONSerialization.data(withJSONObject: resultPayload, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        let jsonString = String(data: jsonData, encoding: .utf8) ?? "{}"
        return [
            "type": "function_result",
            "name": call.name,
            "call_id": call.id,
            "result": [
                [
                    "type": "text",
                    "text": jsonString,
                ],
                [
                    "type": "image",
                    "data": screenshotPNG.base64EncodedString(),
                    "mime_type": "image/png",
                ],
            ],
        ]
    }
}
