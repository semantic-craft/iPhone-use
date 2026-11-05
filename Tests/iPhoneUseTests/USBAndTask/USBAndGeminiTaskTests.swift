import CoreGraphics
import Foundation
import ImageIO
import XCTest

@testable import iPhoneUse

final class MockGeminiTransport: GeminiInteractionsTransport {
    private let lock = NSLock()
    private(set) var recordedRequests: [GeminiInteractionRequest] = []
    private var queuedTurns: [GeminiInteractionTurn]

    init(turns: [GeminiInteractionTurn]) {
        self.queuedTurns = turns
    }

    func sendInteraction(_ request: GeminiInteractionRequest) throws -> GeminiInteractionTurn {
        lock.lock()
        defer { lock.unlock() }
        recordedRequests.append(request)
        guard !queuedTurns.isEmpty else {
            return GeminiInteractionTurn(
                id: "ix-fallback-\(recordedRequests.count)",
                functionCalls: [],
                modelText: "Completed fallback."
            )
        }
        return queuedTurns.removeFirst()
    }
}

final class USBAndGeminiTaskTests: XCTestCase {
    private var tempDir: URL!
    private var usbProvider: StateDirUSBSystemProvider!
    private var taskStore: TaskSessionStore!

    override func setUpWithError() throws {
        try super.setUpWithError()
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-slice-d-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        usbProvider = StateDirUSBSystemProvider(baseDirectory: tempDir)
        taskStore = TaskSessionStore(baseDirectory: tempDir)
    }

    override func tearDownWithError() throws {
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makeTestPNG(width: Int = 400, height: Int = 800, seed: UInt8 = 120) -> Data {
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        var pixels = [UInt8](repeating: seed, count: width * height * 4)
        for idx in stride(from: 0, to: pixels.count, by: 4) {
            pixels[idx] = seed
            pixels[idx + 1] = seed &+ 20
            pixels[idx + 2] = seed &+ 40
            pixels[idx + 3] = 255
        }
        let context = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: width * 4,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        )!
        let cgImage = context.makeImage()!
        let mutableData = CFDataCreateMutable(nil, 0)!
        let destination = CGImageDestinationCreateWithData(
            mutableData, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return mutableData as Data
    }

    private func decodeJSON(_ response: HTTPResponse) throws -> [String: Any] {
        let obj = try JSONSerialization.jsonObject(with: response.body)
        return try XCTUnwrap(obj as? [String: Any])
    }

    private func makeHooks(
        isLocked: @escaping () -> Bool = { false },
        ocrItems: [ScreenOCR.Item] = [
            ScreenOCR.Item(
                text: "TikTok",
                box: CGRect(x: 0.35, y: 0.80, width: 0.25, height: 0.05),
                width: 400,
                height: 800,
                confidence: 0.99
            ),
            ScreenOCR.Item(
                text: "Next",
                box: CGRect(x: 0.70, y: 0.10, width: 0.20, height: 0.05),
                width: 400,
                height: 800,
                confidence: 0.99
            ),
        ],
        transport: GeminiInteractionsTransport? = nil,
        onReport: @escaping (ReportID, [UInt8]) -> Void = { _, _ in }
    ) -> GhosthandRuntimeHooks {
        let frameData = makeTestPNG()
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: onReport,
            reportReadiness: { _, _, _ in true }
        )
        return GhosthandRuntimeHooks(
            deviceID: "hermes-id",
            deviceName: "Hermes",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frameData },
            recognizeOCR: { _, _ in
                ScreenOCR.Result(width: 400, height: 800, items: ocrItems)
            },
            stabilitySignature: { _ in "stable-sig-slice-d" },
            isLocked: isLocked,
            usbProvider: usbProvider,
            geminiTransport: transport,
            taskStore: taskStore
        )
    }

    // MARK: - 1. USB Photo Channels (photo_push, photo_list, photo_pull, photo_delete)

    func testUSBPhotoPushListPullAndDeleteRoundTripForTikTokVideo() throws {
        let hooks = makeHooks()

        // Create a local video file on Mac to import into iPhone Photos
        let localVideoURL = tempDir.appendingPathComponent("tiktok_draft.mp4")
        let videoBytes = Data("FAKE_MP4_VIDEO_PAYLOAD_FOR_TIKTOK_2026".utf8)
        try videoBytes.write(to: localVideoURL)

        // 1. photo_push imports the local Mac video into /DCIM/100APPLE
        let pushResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/photos/push",
                query: [:],
                body: ["path": localVideoURL.path, "filename": "tiktok_clip.mp4"]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(pushResp.status, 200)
        let pushJSON = try decodeJSON(pushResp)
        XCTAssertEqual(pushJSON["ok"] as? Bool, true)
        XCTAssertEqual(pushJSON["imported"] as? Bool, true)
        let importedPath = try XCTUnwrap(pushJSON["path"] as? String)
        XCTAssertTrue(importedPath.hasPrefix("/DCIM/100APPLE/"), "Got \(importedPath)")
        XCTAssertTrue(importedPath.lowercased().hasSuffix(".mp4"), "Got \(importedPath)")
        XCTAssertEqual(pushJSON["media_type"] as? String, "video")

        // 2. photo_list includes the newly pushed video
        let listResp = ControlAPI.handle(
            HTTPRequest(method: "GET", path: "/photos", query: ["limit": "10"], body: [:]),
            runtimeHooks: hooks
        )
        XCTAssertEqual(listResp.status, 200)
        let listJSON = try decodeJSON(listResp)
        let photos = try XCTUnwrap(listJSON["photos"] as? [[String: Any]])
        XCTAssertTrue(photos.contains { ($0["path"] as? String) == importedPath })

        // 3. photo_pull reads the video bytes and writes them to an output path
        let pulledURL = tempDir.appendingPathComponent("pulled_clip.mp4")
        let pullResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/photos/pull",
                query: [:],
                body: ["path": importedPath, "output": pulledURL.path]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(pullResp.status, 200)
        let pullJSON = try decodeJSON(pullResp)
        XCTAssertEqual(pullJSON["saved_path"] as? String, pulledURL.path)
        let pulledData = try Data(contentsOf: pulledURL)
        XCTAssertEqual(pulledData, videoBytes)

        // 4. photo_delete deletes the video via PhotoLibrary service
        let delResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/photos/delete",
                query: [:],
                body: ["path": importedPath]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(delResp.status, 200)
        let delJSON = try decodeJSON(delResp)
        XCTAssertEqual(delJSON["deleted"] as? Bool, true)

        // Confirm it is gone from photo_list
        let afterListResp = ControlAPI.handle(
            HTTPRequest(method: "GET", path: "/photos", query: [:], body: [:]),
            runtimeHooks: hooks
        )
        let afterPhotos = try XCTUnwrap(try decodeJSON(afterListResp)["photos"] as? [[String: Any]])
        XCTAssertFalse(afterPhotos.contains { ($0["path"] as? String) == importedPath })
    }

    // MARK: - 2. USB File Channels & /DCIM AFC Deletion Guard

    func testUSBFileChannelsAndDCIMRemoveRefusal() throws {
        let hooks = makeHooks()

        // 1. Push a file into an app container (TikTok draft config)
        let pushResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/files/push",
                query: [:],
                body: [
                    "path": "/Documents/draft_caption.txt",
                    "bundle_id": "com.zhiliaoapp.musically",
                    "content": "Hello from iPhone Use #ghosthand",
                ]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(pushResp.status, 200)

        // 2. List files in the app container
        let listResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/files/list",
                query: [:],
                body: [
                    "path": "/Documents",
                    "bundle_id": "com.zhiliaoapp.musically",
                ]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(listResp.status, 200)
        let files = try XCTUnwrap(try decodeJSON(listResp)["files"] as? [[String: Any]])
        XCTAssertEqual(files.map { $0["name"] as? String }, ["draft_caption.txt"])

        // 3. Pull the file back
        let pullResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/files/pull",
                query: [:],
                body: [
                    "path": "/Documents/draft_caption.txt",
                    "bundle_id": "com.zhiliaoapp.musically",
                ]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(pullResp.status, 200)
        let pullJSON = try decodeJSON(pullResp)
        XCTAssertEqual(pullJSON["text"] as? String, "Hello from iPhone Use #ghosthand")

        // 4. Remove the file
        let rmResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/files/remove",
                query: [:],
                body: [
                    "path": "/Documents/draft_caption.txt",
                    "bundle_id": "com.zhiliaoapp.musically",
                ]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(rmResp.status, 200)

        // 5. Attempting to remove /DCIM via file_remove MUST fail with dcim-remove-forbidden (400)
        let dcimRmResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/files/remove",
                query: [:],
                body: ["path": "/DCIM/100APPLE/IMG_0001.JPG"]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(dcimRmResp.status, 400)
        let dcimErr = try decodeJSON(dcimRmResp)
        XCTAssertEqual(dcimErr["code"] as? String, "dcim-remove-forbidden")
    }

    // MARK: - 3. App List, Open App (with Post-Action Stillness), Device Info, Logs, AssistiveTouch

    func testUSBAppListOpenAppDeviceInfoLogsAndAssistiveTouch() throws {
        let hooks = makeHooks()

        // 1. app_list returns installed apps including TikTok and Photos
        let appListResp = ControlAPI.handle(
            HTTPRequest(method: "GET", path: "/apps", query: [:], body: [:]),
            runtimeHooks: hooks
        )
        XCTAssertEqual(appListResp.status, 200)
        let apps = try XCTUnwrap(try decodeJSON(appListResp)["apps"] as? [[String: Any]])
        XCTAssertTrue(apps.contains { ($0["bundle_id"] as? String) == "com.zhiliaoapp.musically" })

        // 2. open_app by display name ("TikTok") with wait_text & screentext
        let openResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/open_app",
                query: [:],
                body: [
                    "app": "TikTok",
                    "wait_text": "TikTok",
                    "screentext": true,
                ]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(openResp.status, 200)
        let openJSON = try decodeJSON(openResp)
        XCTAssertEqual(openJSON["bundle_id"] as? String, "com.zhiliaoapp.musically")
        XCTAssertEqual(openJSON["launched"] as? Bool, true)
        XCTAssertTrue((openJSON["screentext"] as? String)?.contains("TikTok") == true)

        // 3. device_info returns USB lockdown metadata
        let infoResp = ControlAPI.handle(
            HTTPRequest(method: "GET", path: "/info", query: [:], body: [:]),
            runtimeHooks: hooks
        )
        XCTAssertEqual(infoResp.status, 200)
        let infoJSON = try decodeJSON(infoResp)
        XCTAssertEqual(infoJSON["name"] as? String, "Hermes")
        XCTAssertEqual(infoJSON["udid"] as? String, "hermes-id")

        // 4. device_logs filters syslog lines
        let logsResp = ControlAPI.handle(
            HTTPRequest(
                method: "GET",
                path: "/logs",
                query: ["contains": "com.zhiliaoapp.musically"],
                body: [:]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(logsResp.status, 200)
        let logLines = try XCTUnwrap(try decodeJSON(logsResp)["lines"] as? [String])
        XCTAssertFalse(logLines.isEmpty)
        XCTAssertTrue(logLines.allSatisfy { $0.contains("com.zhiliaoapp.musically") })

        // 5. assistivetouch get and set
        let atOffResp = ControlAPI.handle(
            HTTPRequest(
                method: "PUT",
                path: "/assistive-touch",
                query: [:],
                body: ["enabled": false]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(atOffResp.status, 200)
        XCTAssertEqual(try decodeJSON(atOffResp)["enabled"] as? Bool, false)

        let atOnResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/assistivetouch",
                query: [:],
                body: ["enabled": true]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(atOnResp.status, 200)
        XCTAssertEqual(try decodeJSON(atOnResp)["enabled"] as? Bool, true)
    }

    // MARK: - 4. Gemini 3.8 Flash Autonomous Multi-Step Task & Coordinate Denormalization

    func testGeminiTaskExecutesMultiStepMobileComputerUseWith0To999Coordinates() throws {
        var sentReports: [(ReportID, [UInt8])] = []
        let transport = MockGeminiTransport(turns: [
            GeminiInteractionTurn(
                id: "ix-turn-1",
                functionCalls: [
                    GeminiFunctionCall(
                        id: "call-open-tiktok",
                        name: "open_app",
                        arguments: ["app_name": "TikTok"]
                    ),
                    GeminiFunctionCall(
                        id: "call-click-next",
                        name: "click",
                        arguments: ["x": 750, "y": 875]
                    ),
                ]
            ),
            GeminiInteractionTurn(
                id: "ix-turn-2",
                functionCalls: [],
                modelText: "Opened TikTok and tapped Next at (750, 875)."
            ),
        ])
        let hooks = makeHooks(
            transport: transport,
            onReport: { reportID, bytes in
                sentReports.append((reportID, bytes))
            }
        )

        let resp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/task",
                query: [:],
                body: [
                    "prompt": "Open TikTok and tap Next",
                    "thinking_level": "medium",
                ]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(resp.status, 200)
        let taskHeader = try XCTUnwrap(resp.headers["Ghosthand-Task"])
        XCTAssertTrue(taskHeader.hasPrefix("task-"))

        let json = try decodeJSON(resp)
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["state"] as? String, "completed")
        XCTAssertEqual(json["thinking_level"] as? String, "medium")
        XCTAssertEqual(json["steps_executed"] as? Int, 2)
        XCTAssertEqual(json["previous_interaction_id"] as? String, "ix-turn-2")
        XCTAssertEqual(json["text"] as? String, "Opened TikTok and tapped Next at (750, 875).")

        // Verify Gemini 3.8 Flash request structure & previous_interaction_id chaining
        XCTAssertEqual(transport.recordedRequests.count, 2)
        let firstReq = transport.recordedRequests[0]
        XCTAssertEqual(firstReq.model, "gemini-3.8-flash")
        XCTAssertNil(firstReq.previousInteractionID)
        XCTAssertEqual(firstReq.thinkingLevel, .medium)
        let computerUseTool = try XCTUnwrap(firstReq.tools.first)
        XCTAssertEqual(computerUseTool["type"] as? String, "computer_use")
        XCTAssertEqual(computerUseTool["environment"] as? String, "mobile")

        let secondReq = transport.recordedRequests[1]
        XCTAssertEqual(secondReq.previousInteractionID, "ix-turn-1")
        XCTAssertEqual(secondReq.input.count, 2)
        XCTAssertEqual(secondReq.input[0]["type"] as? String, "function_result")
        XCTAssertEqual(secondReq.input[0]["call_id"] as? String, "call-open-tiktok")
        XCTAssertEqual(secondReq.input[1]["call_id"] as? String, "call-click-next")

        // Verify 0..999 coordinate denormalization produced real HID pointer click
        XCTAssertTrue(
            sentReports.contains { $0.0 == .relativeMouse && $0.1.first == 1 },
            "Expected mouse down event from click(750, 875)"
        )
    }

    // MARK: - 5. Three-Layer Sensitive Action Guard (yield_to_user + safety_decision + OCR Guard) & Resume

    func testGeminiTaskYieldToUserAndResumeContinuation() throws {
        let transport = MockGeminiTransport(turns: [
            // Turn 1: model prepares video and calls yield_to_user before tapping Post
            GeminiInteractionTurn(
                id: "ix-yield-1",
                functionCalls: [
                    GeminiFunctionCall(
                        id: "call-yield-1",
                        name: "yield_to_user",
                        arguments: [
                            "reason": "Video is ready on TikTok publish screen; confirm before posting publicly.",
                            "pending_action": "Tap Post button",
                        ]
                    )
                ]
            ),
            // Turn 2 (after resume): model finishes
            GeminiInteractionTurn(
                id: "ix-yield-2",
                functionCalls: [],
                modelText: "User confirmed; post flow finished."
            ),
        ])
        let hooks = makeHooks(transport: transport)

        // Initial task run yields to user
        let firstResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/task",
                query: [:],
                body: ["prompt": "Select video and prepare TikTok post"]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(firstResp.status, 200)
        let firstJSON = try decodeJSON(firstResp)
        XCTAssertEqual(firstJSON["state"] as? String, "yielded")
        let taskID = try XCTUnwrap(firstJSON["task"] as? String)
        XCTAssertEqual(
            firstJSON["yield_reason"] as? String,
            "Video is ready on TikTok publish screen; confirm before posting publicly."
        )

        // Resume the yielded task by taskID
        let resumeResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/task",
                query: [:],
                body: ["resume": taskID, "prompt": "Approved, finish up."]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(resumeResp.status, 200)
        let resumeJSON = try decodeJSON(resumeResp)
        XCTAssertEqual(resumeJSON["state"] as? String, "completed")
        XCTAssertEqual(resumeJSON["task"] as? String, taskID)
        XCTAssertEqual(transport.recordedRequests.count, 2)
        XCTAssertEqual(transport.recordedRequests[1].previousInteractionID, "ix-yield-1")
    }

    func testGeminiTaskInterceptsServerSafetyDecisionAndClientOCRPostButtonGuard() throws {
        var clickCount = 0
        let transport = MockGeminiTransport(turns: [
            // Model tries to click directly on the "Post" button at (800, 900) without calling yield_to_user
            GeminiInteractionTurn(
                id: "ix-ocr-guard-1",
                functionCalls: [
                    GeminiFunctionCall(
                        id: "call-unconfirmed-post",
                        name: "click",
                        arguments: ["x": 800, "y": 900]
                    )
                ]
            ),
            // After user resumes with approval, model completes
            GeminiInteractionTurn(
                id: "ix-ocr-guard-2",
                functionCalls: [],
                modelText: "Published after human approval."
            ),
        ])
        // Place a "Post" button around pixel (320, 720), which corresponds to grid (800, 900) on a 400x800 screen
        // Vision normalized coordinates have bottom-left origin: y = 1.0 - (720 / 800) = 0.10
        let hooks = makeHooks(
            ocrItems: [
                ScreenOCR.Item(
                    text: "Post",
                    box: CGRect(x: 0.76, y: 0.08, width: 0.12, height: 0.05),
                    width: 400,
                    height: 800,
                    confidence: 0.99
                )
            ],
            transport: transport,
            onReport: { reportID, bytes in
                if reportID == .relativeMouse, bytes.first == 1 { clickCount += 1 }
            }
        )

        let initialResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/task",
                query: [:],
                body: ["prompt": "Tap Post on TikTok"]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(initialResp.status, 200)
        let initialJSON = try decodeJSON(initialResp)
        XCTAssertEqual(initialJSON["state"] as? String, "yielded")
        XCTAssertEqual(clickCount, 0, "Client-side consequential OCR guard must prevent unconfirmed tap on Post")
        let taskID = try XCTUnwrap(initialJSON["task"] as? String)

        // Resuming with approval executes the held click and sends safety_acknowledgement: true
        let resumedResp = ControlAPI.handle(
            HTTPRequest(
                method: "POST",
                path: "/task",
                query: [:],
                body: ["resume": taskID, "approve": true]
            ),
            runtimeHooks: hooks
        )
        XCTAssertEqual(resumedResp.status, 200)
        let resumedJSON = try decodeJSON(resumedResp)
        XCTAssertEqual(resumedJSON["state"] as? String, "completed")
        XCTAssertEqual(clickCount, 1, "Approved resume should execute the held click once")

        let secondTurnInput = try XCTUnwrap(transport.recordedRequests.last?.input.first)
        let resultItems = try XCTUnwrap(secondTurnInput["result"] as? [[String: Any]])
        let resultText = try XCTUnwrap(resultItems.first?["text"] as? String)
        XCTAssertTrue(resultText.contains("\"safety_acknowledgement\":true"), "Got \(resultText)")
    }

    // MARK: - 6. MCP Tool Translation & CLI Subcommands

    func testMCPToolTranslationAndCLIRunnerSubcommands() throws {
        // Verify MCPToolRequest translates all 14 Slice D tools
        let mcpCases: [(String, [String: Any], String)] = [
            ("photo_list", ["limit": 20], "/photos/list"),
            ("photo_pull", ["path": "/DCIM/100APPLE/IMG_0001.JPG"], "/photos/pull"),
            ("photo_delete", ["path": "/DCIM/100APPLE/IMG_0001.JPG"], "/photos/delete"),
            ("photo_push", ["path": "/tmp/demo.mp4"], "/photos/push"),
            ("file_list", ["path": "/Documents"], "/files/list"),
            ("file_pull", ["path": "/Documents/note.txt"], "/files/pull"),
            ("file_push", ["path": "/Documents/note.txt", "content": "hi"], "/files/push"),
            ("file_remove", ["path": "/Documents/note.txt"], "/files/remove"),
            ("app_list", [:], "/apps/list"),
            ("open_app", ["app": "TikTok", "wait_text": "TikTok"], "/open_app"),
            ("device_info", [:], "/device_info"),
            ("device_logs", ["seconds": 1.5, "contains": "SpringBoard"], "/device_logs"),
            ("assistivetouch", ["enabled": true], "/assistivetouch"),
            ("task", ["prompt": "Open TikTok", "thinking_level": "high"], "/task"),
        ]
        for (toolName, args, expectedPath) in mcpCases {
            let req = try XCTUnwrap(
                try MCPToolRequest.action(named: toolName, arguments: args, longEdge: 1000),
                "Missing MCPToolRequest translation for \(toolName)"
            )
            XCTAssertEqual(req.path, expectedPath)
        }

        // Verify CLIRunner executes task and USB subcommands end-to-end
        let transport = MockGeminiTransport(turns: [
            GeminiInteractionTurn(id: "cli-ix-1", functionCalls: [], modelText: "CLI task finished.")
        ])
        let hooks = makeHooks(transport: transport)

        let cliTask = CLIRunner.execute(
            arguments: ["task", "--prompt", "Open Photos and inspect latest clip", "--thinking-level", "low"],
            runtimeHooks: hooks
        )
        XCTAssertEqual(cliTask.exitCode, 0)
        let cliTaskJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(cliTask.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(cliTaskJSON["state"] as? String, "completed")
        XCTAssertEqual(cliTaskJSON["text"] as? String, "CLI task finished.")

        let cliAssistive = CLIRunner.execute(
            arguments: ["assistivetouch", "on"],
            runtimeHooks: hooks
        )
        XCTAssertEqual(cliAssistive.exitCode, 0)
        let cliAssistiveJSON = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(cliAssistive.stdout.utf8)) as? [String: Any]
        )
        XCTAssertEqual(cliAssistiveJSON["enabled"] as? Bool, true)
    }

    func testSliceEReadinessModelMappingAndLiveHardwareScreenRendering() throws {
        let advertisingInputs = SetupInputs(
            macName: "Studio",
            camera: .authorized,
            bluetoothState: "advertising as iPhone Use",
            usbAttachedCount: 1,
            phones: []
        )
        XCTAssertTrue(advertisingInputs.bluetoothReady)

        let connectedInputs = SetupInputs(
            macName: "Studio",
            camera: .authorized,
            bluetoothState: "1 connected, advertising as iPhone Use",
            usbAttachedCount: 1,
            phones: []
        )
        XCTAssertTrue(connectedInputs.bluetoothReady)

        XCTAssertEqual(
            MobileDeviceLockdownBridge.marketingModelName(for: "iPhone18,2"),
            "iPhone 17 Pro Max"
        )

        let snapshot = MobileDeviceLockdownSnapshot(
            udid: "00008150-00196D0E0A43401C",
            name: "Hermes",
            productType: "iPhone18,2",
            modelName: "iPhone 17 Pro Max",
            iosVersion: "27.0.1",
            build: "24A446",
            serialNumber: "L6RWYM4LJN",
            wifiAddress: "3C:FB:02:42:6F:F7",
            bluetoothAddress: "3C:FB:02:44:4E:B7",
            timeZone: "Asia/Shanghai",
            passwordProtected: false,
            trusted: true,
            batteryPercent: 95,
            charging: true,
            externalPower: true,
            storageTotalBytes: 512_000_000_000,
            storageFreeBytes: 312_000_000_000,
            language: "zh-Hans-CN",
            locale: "zh_CN",
            sim: USBDeviceInfo.SIMInfo(telephony: true, tray: "sim", lines: []),
            assistiveTouchEnabled: true
        )

        let homeRendered = MobileDeviceLockdownBridge.renderLiveHardwareScreenPNG(
            for: snapshot,
            activeApp: nil,
            maxEdge: 1000
        )
        XCTAssertFalse(homeRendered.data.isEmpty)
        let homeOCR = ScreenOCR.recognize(homeRendered.data, device: snapshot.udid)
        let homeTexts = homeOCR.items.map(\.text).joined(separator: " ")
        XCTAssertTrue(homeTexts.contains("Hermes"), "Got OCR: \(homeTexts)")
        XCTAssertTrue(homeTexts.contains("TikTok"), "Got OCR: \(homeTexts)")

        let publishRendered = MobileDeviceLockdownBridge.renderLiveHardwareScreenPNG(
            for: snapshot,
            activeApp: "TikTok",
            maxEdge: 1000
        )
        let publishOCR = ScreenOCR.recognize(publishRendered.data, device: snapshot.udid)
        let publishTexts = publishOCR.items.map(\.text).joined(separator: " ")
        XCTAssertTrue(publishTexts.contains("TikTok"), "Got OCR: \(publishTexts)")
        XCTAssertTrue(publishTexts.contains("Post"), "Got OCR: \(publishTexts)")

        let setupReq = try CLIRunner.buildRequest(from: ["setup_status", "--device", "Hermes"])
        XCTAssertEqual(setupReq.path, "/setup_status")
        XCTAssertEqual(setupReq.query["device"], "Hermes")
    }
}
