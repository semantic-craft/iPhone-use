import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import XCTest

@testable import iPhoneUse

final class GhosthandInputParityTests: XCTestCase {
    private var tempDir: URL!
    private var previousStateDir: String?

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousStateDir = ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"]
        tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-slice-c-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        setenv("IPHONE_USE_STATE_DIR", tempDir.path, 1)
    }

    override func tearDownWithError() throws {
        if let previousStateDir {
            setenv("IPHONE_USE_STATE_DIR", previousStateDir, 1)
        } else {
            unsetenv("IPHONE_USE_STATE_DIR")
        }
        if let tempDir {
            try? FileManager.default.removeItem(at: tempDir)
        }
        try super.tearDownWithError()
    }

    // MARK: - Helpers

    private func makePNGData(width: Int = 400, height: Int = 800, luma: UInt8 = 128) throws -> Data {
        var pixels = [UInt8](repeating: luma, count: width * height)
        let cgImage: CGImage = try pixels.withUnsafeMutableBytes { buffer in
            let context = try XCTUnwrap(
                CGContext(
                    data: buffer.baseAddress,
                    width: width,
                    height: height,
                    bitsPerComponent: 8,
                    bytesPerRow: width,
                    space: CGColorSpaceCreateDeviceGray(),
                    bitmapInfo: CGImageAlphaInfo.none.rawValue
                )
            )
            return try XCTUnwrap(context.makeImage())
        }
        let data = NSMutableData()
        let dest = try XCTUnwrap(
            CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil)
        )
        CGImageDestinationAddImage(dest, cgImage, nil)
        XCTAssertTrue(CGImageDestinationFinalize(dest))
        return data as Data
    }

    private func makeJSONRequest(
        _ method: String,
        _ path: String,
        body: [String: Any]? = nil
    ) throws -> HTTPRequest {
        if let body {
            let payload = try JSONSerialization.data(withJSONObject: body)
            let wire =
                Data("\(method) \(path) HTTP/1.1\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload
            return try XCTUnwrap(HTTPRequest.parse(wire))
        }
        let wire = Data("\(method) \(path) HTTP/1.1\r\n\r\n".utf8)
        return try XCTUnwrap(HTTPRequest.parse(wire))
    }

    // MARK: - 1. screentext (`x,y wxh text`) & Tiered OCR Matching

    func testScreentextFormatsTopLeftBoxDimensionsAndTieredMatchingPrefersExactLine() throws {
        let exactItem = ScreenOCR.Item(
            text: "Settings",
            box: CGRect(x: 0.10, y: 0.70, width: 0.25, height: 0.05),
            width: 400,
            height: 800,
            confidence: 0.98
        )
        let substringItem = ScreenOCR.Item(
            text: "Settings & Privacy",
            box: CGRect(x: 0.10, y: 0.80, width: 0.45, height: 0.05),
            width: 400,
            height: 800,
            confidence: 0.95
        )
        // box.maxY = 0.75 -> top-left Y = (1 - 0.75) * 800 = 200
        XCTAssertEqual(exactItem.boxX, 40)
        XCTAssertEqual(exactItem.boxY, 200)
        XCTAssertEqual(exactItem.width, 100)
        XCTAssertEqual(exactItem.height, 40)
        XCTAssertEqual(exactItem.screentextLine, "40,200 100x40 Settings")

        let ocrResult = ScreenOCR.Result(
            width: 400,
            height: 800,
            items: [substringItem, exactItem],
            screenHash: "hash-1"
        )
        XCTAssertEqual(
            ocrResult.screentext,
            "40,120 180x40 Settings & Privacy\n40,200 100x40 Settings"
        )

        // Exact line match ("settings") wins over substring match ("Settings & Privacy") even when substring is first
        let matched = try ScreenOCR.matchTiered(ocrResult, text: "settings")
        XCTAssertEqual(matched.text, "Settings")

        // Substring query ("privacy") matches the substring line
        let substringMatched = try ScreenOCR.matchTiered(ocrResult, text: "privacy")
        XCTAssertEqual(substringMatched.text, "Settings & Privacy")
    }

    // MARK: - 2. Post-Action Stillness Loop, Same-Call screenshot + screentext, and wait_text No-Retry Timeout

    func testPostActionStillnessLoopReturnsSettledScreenshotAndScreentextInSameCall() throws {
        var reports: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { id, bytes in reports.append((id, bytes)) },
            reportReadiness: { _, _, _ in true }
        )

        let frame1 = try makePNGData(luma: 40)
        let frame2 = try makePNGData(luma: 180)
        let frame3 = try makePNGData(luma: 180)  // Matches frame2 -> settled!
        var frameQueue = [frame1, frame2, frame3]
        var captureCount = 0
        var simulatedNow: TimeInterval = 100.0

        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in
                captureCount += 1
                if !frameQueue.isEmpty {
                    return frameQueue.removeFirst()
                }
                return frame3
            },
            recognizeOCR: { data, _ in
                let label = data == frame1 ? "Loading..." : "Done"
                return ScreenOCR.Result(
                    width: 400,
                    height: 800,
                    items: [
                        ScreenOCR.Item(
                            text: label,
                            x: 200,
                            y: 400,
                            boxX: 150,
                            boxY: 380,
                            width: 100,
                            height: 40
                        )
                    ],
                    screenHash: data == frame1 ? "h1" : "h2"
                )
            },
            stabilitySignature: { data in
                data == frame1 ? "sig-moving" : "sig-settled"
            },
            now: { simulatedNow },
            sleep: { delay in simulatedNow += delay }
        )

        let req = try makeJSONRequest(
            "POST",
            "/tap",
            body: [
                "x": 200,
                "y": 400,
                "waitText": "Done",
                "timeoutMs": 3000,
                "screenshot": "png",
                "screentext": true,
            ]
        )
        let response = ControlAPI.handle(
            req,
            ocrCapture: { _, _ in ("test-phone-1", frame3) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(response.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: response.body) as? [String: Any])
        XCTAssertEqual(json["ok"] as? Bool, true)
        XCTAssertEqual(json["screentext"] as? String, "150,380 100x40 Done")

        let screen = try XCTUnwrap(json["screen"] as? [String: Any])
        XCTAssertEqual(screen["width"] as? Int, 400)
        XCTAssertEqual(screen["height"] as? Int, 800)
        let lines = try XCTUnwrap(screen["lines"] as? [[String: Any]])
        XCTAssertEqual(lines.first?["text"] as? String, "Done")
        XCTAssertEqual(lines.first?["x"] as? Int, 150)
        XCTAssertEqual(lines.first?["y"] as? Int, 380)
        XCTAssertEqual(lines.first?["width"] as? Int, 100)
        XCTAssertEqual(lines.first?["height"] as? Int, 40)

        let screenshotDict = try XCTUnwrap(json["screenshot"] as? [String: Any])
        XCTAssertEqual(screenshotDict["format"] as? String, "png")
        XCTAssertEqual(screenshotDict["width"] as? Int, 400)
        XCTAssertEqual(screenshotDict["height"] as? Int, 800)
        XCTAssertEqual(Data(base64Encoded: try XCTUnwrap(screenshotDict["data"] as? String)), frame3)
        XCTAssertGreaterThanOrEqual(captureCount, 3)
    }

    func testWaitTextTimeoutWarnsInputAlreadySentAndNeverRepeatsInput() throws {
        var pressCount = 0
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { id, bytes in
                if id == .absolutePointer && bytes[0] == 1 {
                    pressCount += 1
                }
            },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 90)
        var simulatedNow: TimeInterval = 10.0

        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            recognizeOCR: { _, _ in
                ScreenOCR.Result(
                    width: 400,
                    height: 800,
                    items: [ScreenOCR.Item(text: "Still Loading", x: 100, y: 100, width: 80, height: 20)],
                    screenHash: "h1"
                )
            },
            now: { simulatedNow },
            sleep: { delay in simulatedNow += delay }
        )

        // Validate timeout_ms range 1...60000
        for invalidTimeout in [0, -100, 60_001] {
            let badReq = try makeJSONRequest(
                "POST",
                "/tap",
                body: ["x": 100, "y": 100, "wait_text": "Ready", "timeout_ms": invalidTimeout]
            )
            let badResp = ControlAPI.handle(
                badReq,
                ocrCapture: { _, _ in ("test-phone-1", frame) },
                runtimeHooks: hooks
            )
            XCTAssertEqual(badResp.status, 400)
        }
        XCTAssertEqual(pressCount, 0, "Invalid timeout_ms must fail before sending any input")

        // Valid timeout_ms that times out must send input ONCE and fail with wait-text-timeout
        let timeoutReq = try makeJSONRequest(
            "POST",
            "/tap",
            body: ["x": 100, "y": 100, "wait_text": "Payment Confirmed", "timeout_ms": 450]
        )
        let timeoutResp = ControlAPI.handle(
            timeoutReq,
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(timeoutResp.status, 408)
        XCTAssertEqual(pressCount, 1, "Input must be sent exactly once and never repeated on wait_text timeout")
        let errJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: timeoutResp.body) as? [String: Any])
        XCTAssertEqual(errJSON["code"] as? String, "wait-text-timeout")
        let errMessage = try XCTUnwrap(errJSON["error"] as? String)
        XCTAssertTrue(errMessage.contains("input was already sent"))
        XCTAssertTrue(errMessage.contains("do NOT repeat"))
    }

    // MARK: - 3. double_tap, triple_tap, hold (Coordinates & OCR Text Matching)

    func testDoubleTapTripleTapAndHoldSupportCoordinatesAndOCRText() throws {
        var events: [(ReportID, [UInt8])] = []
        var sleeps: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { sleeps.append($0) },
            reportSender: { id, bytes in events.append((id, bytes)) },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 100)
        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            recognizeOCR: { _, _ in
                ScreenOCR.Result(
                    width: 400,
                    height: 800,
                    items: [
                        ScreenOCR.Item(
                            text: "Open Album",
                            x: 200,
                            y: 400,
                            boxX: 140,
                            boxY: 380,
                            width: 120,
                            height: 40
                        )
                    ],
                    screenHash: "h-album"
                )
            }
        )

        // 1) double_tap by OCR text
        events.removeAll()
        let doubleTapResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/double-tap", body: ["text": "Open Album"]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(doubleTapResp.status, 200)
        let absoluteMoves = events.filter { $0.0 == .absolutePointer && $0.1[0] == 0 }
        let buttonDowns = events.filter { $0.0 == .absolutePointer && $0.1[0] == 1 }
        XCTAssertEqual(absoluteMoves.count, 3, "double_tap must position pointer once and release twice")
        XCTAssertEqual(buttonDowns.count, 2)

        // 2) triple_tap by coordinates
        events.removeAll()
        let tripleTapResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/triple_tap", body: ["x": 100, "y": 200]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(tripleTapResp.status, 200)
        XCTAssertEqual(events.filter { $0.0 == .absolutePointer && $0.1[0] == 0 }.count, 4)
        XCTAssertEqual(events.filter { $0.0 == .absolutePointer && $0.1[0] == 1 }.count, 3)

        // 3) hold by OCR text with durationMs = 1500
        events.removeAll()
        sleeps.removeAll()
        let holdResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/hold", body: ["text": "Open Album", "durationMs": 1500]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(holdResp.status, 200)
        XCTAssertEqual(events.filter { $0.0 == .absolutePointer && $0.1[0] == 1 }.count, 1)
        XCTAssertEqual(events.filter { $0.0 == .absolutePointer && $0.1[0] == 0 }.count, 2)
        XCTAssertTrue(sleeps.contains { abs($0 - 1.5) < 0.001 })
    }

    // MARK: - 4. hold_drag & scroll (up, down, left, right, ticks)

    func testHoldDragAndScrollDirectionsEmitExpectedHIDReports() throws {
        var events: [(ReportID, [UInt8])] = []
        var sleeps: [TimeInterval] = []
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { sleeps.append($0) },
            reportSender: { id, bytes in events.append((id, bytes)) },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 100)
        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame }
        )

        // 1) hold_drag: press at from, hold still for 1200ms, drag to to over 600ms, release
        let holdDragResp = ControlAPI.handle(
            try makeJSONRequest(
                "POST",
                "/hold-drag",
                body: [
                    "from": ["x": 100, "y": 200],
                    "to": ["x": 300, "y": 600],
                    "holdMs": 1200,
                    "durationMs": 600,
                ]
            ),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(holdDragResp.status, 200)
        XCTAssertTrue(sleeps.contains { abs($0 - 1.2) < 0.001 }, "hold_drag must pause for holdMs before dragging")
        let dragHeldReports = events.filter { $0.0 == .absolutePointer && $0.1[0] == 1 }
        XCTAssertGreaterThan(dragHeldReports.count, 2, "hold_drag must emit absolute drag movement while button is held")
        XCTAssertEqual(events.last?.0, .absolutePointer)
        XCTAssertEqual(events.last?.1[0], 0, "hold_drag must release button at the end")

        // 2) scroll up/down/left/right with ticks
        for (dir, expectedWheel, expectsShift) in [
            ("up", Int8(1), false),
            ("down", Int8(-1), false),
            ("left", Int8(1), true),
            ("right", Int8(-1), true),
        ] {
            events.removeAll()
            let scrollResp = ControlAPI.handle(
                try makeJSONRequest("POST", "/scroll", body: ["direction": dir, "ticks": 4]),
                ocrCapture: { _, _ in ("test-phone-1", frame) },
                runtimeHooks: hooks
            )
            XCTAssertEqual(scrollResp.status, 200)
            let wheelReports = events.filter { $0.0 == .relativeMouse && $0.1[3] != 0 }
            XCTAssertEqual(wheelReports.count, 4, "direction=\(dir)")
            XCTAssertTrue(
                wheelReports.allSatisfy { Int8(bitPattern: $0.1[3]) == expectedWheel },
                "direction=\(dir)"
            )
            let shiftReports = events.filter { $0.0 == .keyboard && $0.1[0] == 0x02 }
            XCTAssertEqual(!shiftReports.isEmpty, expectsShift, "direction=\(dir)")
        }
    }

    // MARK: - 5. wake, lock, unlock (Never Retry Wrong Passcode), mute & unmute

    func testWakeLockUnlockNeverRetriesWrongPasscodeAndMuteUnmuteVerifyState() throws {
        var events: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { id, bytes in events.append((id, bytes)) },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 100)
        var phoneLocked = true
        var unlockstaysLocked = true
        var observedMuted: Bool? = false
        var mutePressCount = 0

        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            isLocked: { phoneLocked },
            waitForFrame: { true },
            observeMutedState: { observedMuted }
        )

        // 1) wake when locked -> fails with 409 device-locked
        let wakeLockedResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/wake"),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(wakeLockedResp.status, 409)
        let wakeErr = try XCTUnwrap(JSONSerialization.jsonObject(with: wakeLockedResp.body) as? [String: Any])
        XCTAssertEqual(wakeErr["code"] as? String, "device-locked")

        // 2) unlock with wrong passcode -> types passcode ONCE, fails with 422 unlock-failed, never logs passcode
        events.removeAll()
        let secretPasscode = "948271"
        let unlockFailResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/unlock", body: ["passcode": secretPasscode]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(unlockFailResp.status, 422)
        let unlockErrJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: unlockFailResp.body) as? [String: Any])
        XCTAssertEqual(unlockErrJSON["code"] as? String, "unlock-failed")
        let rawErrorText = String(decoding: unlockFailResp.body, as: UTF8.self)
        XCTAssertFalse(rawErrorText.contains(secretPasscode), "Passcode must NEVER appear in error responses or logs")
        // Verify keyboard strokes: 2 Enter presses + 6 digits = 8 key-down reports, never retried!
        let keyDowns = events.filter { $0.0 == .keyboard && $0.1[2] != 0 }
        XCTAssertEqual(keyDowns.count, 8, "Wrong passcode must never be retried")

        // 3) unlock when passcode succeeds -> unlocks phone
        unlockstaysLocked = false
        let unlockSuccessHooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            isLocked: {
                if !unlockstaysLocked && events.filter({ $0.0 == .keyboard && $0.1[2] != 0 }).count >= 8 {
                    phoneLocked = false
                }
                return phoneLocked
            }
        )
        events.removeAll()
        let unlockOkResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/unlock", body: ["passcode": secretPasscode]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: unlockSuccessHooks
        )
        XCTAssertEqual(unlockOkResp.status, 200)
        XCTAssertFalse(phoneLocked)

        // 4) lock sends Ctrl+Cmd+Q and verifies lock state
        let lockHooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            isLocked: {
                // Verify Ctrl (0x01) + Cmd (0x08) = 0x09 with Q (0x14 = 20)
                if events.contains(where: { $0.0 == .keyboard && $0.1[0] == 0x09 && $0.1[2] == 20 }) {
                    phoneLocked = true
                }
                return phoneLocked
            }
        )
        events.removeAll()
        let lockResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/lock"),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: lockHooks
        )
        XCTAssertEqual(lockResp.status, 200)
        XCTAssertTrue(phoneLocked)

        // 5) key("mute") is rejected; mute/unmute toggle consumer 0x00E2 and confirm state
        let muteKeyResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/key", body: ["key": "mute"]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(muteKeyResp.status, 400)

        // If first press of mute toggles the wrong way (observedMuted == false on 1st check, true on 2nd), presses twice
        events.removeAll()
        mutePressCount = 0
        let muteHooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            observeMutedState: {
                mutePressCount += 1
                return mutePressCount >= 2
            }
        )
        let muteResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/mute"),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: muteHooks
        )
        XCTAssertEqual(muteResp.status, 200)
        let muteJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: muteResp.body) as? [String: Any])
        XCTAssertEqual(muteJSON["muted"] as? Bool, true)
        XCTAssertEqual(muteJSON["presses"] as? Int, 2)

        // If unconfirmed (nil), fails with 502 mute-unconfirmed and never presses again
        events.removeAll()
        observedMuted = nil
        let unconfirmedResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/unmute"),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(unconfirmedResp.status, 502)
        let unconfirmedJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: unconfirmedResp.body) as? [String: Any]
        )
        XCTAssertEqual(unconfirmedJSON["code"] as? String, "mute-unconfirmed")
        let consumerPresses = events.filter { $0.0 == .consumer && $0.1 == [0xE2, 0x00] }
        XCTAssertEqual(consumerPresses.count, 1, "Unconfirmed mute must never press the key a second time")
    }

    // MARK: - 6. record_start & record_stop Lifecycle

    func testScreenRecorderStartStopAndLeaseReleaseAutoStop() throws {
        var currentUptime: TimeInterval = 500.0
        let recorder = ScreenRecorderManager(
            nowUptime: { currentUptime },
            nowDate: { Date(timeIntervalSince1970: 1_700_000_000) }
        )
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { _, _ in },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 120)
        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            recorder: recorder
        )

        let outPath = tempDir.appendingPathComponent("clip.mp4").path
        let startResp = ControlAPI.handle(
            try makeJSONRequest(
                "POST",
                "/recording/start",
                body: ["outputPath": outPath, "maxDurationSeconds": 120, "fps": 30, "audio": false]
            ),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(startResp.status, 200)
        let startJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: startResp.body) as? [String: Any])
        XCTAssertEqual(startJSON["path"] as? String, outPath)
        XCTAssertEqual(startJSON["maxDurationSeconds"] as? Int, 120)
        XCTAssertEqual(startJSON["fps"] as? Int, 30)
        XCTAssertEqual(startJSON["audio"] as? Bool, false)

        // Starting a second recording on the same phone fails with 409 recording-active
        let duplicateResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/recording/start"),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(duplicateResp.status, 409)
        let dupJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: duplicateResp.body) as? [String: Any])
        XCTAssertEqual(dupJSON["code"] as? String, "recording-active")

        currentUptime += 2.5
        let stopResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/recording/stop"),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(stopResp.status, 200)
        let stopJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: stopResp.body) as? [String: Any])
        XCTAssertEqual(stopJSON["path"] as? String, outPath)
        XCTAssertEqual(stopJSON["stoppedBy"] as? String, "request")
        XCTAssertEqual(stopJSON["width"] as? Int, 400)
        XCTAssertEqual(stopJSON["height"] as? Int, 800)
        XCTAssertGreaterThan(stopJSON["bytes"] as? Int ?? 0, 0)
        XCTAssertGreaterThanOrEqual(stopJSON["frames"] as? Int ?? 0, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: outPath))
    }

    // MARK: - 7. Idle 10s Control Key Keepalive & screenshot(native: true)

    func testIdleTenSecondControlKeepaliveAndNativeScreenshot() throws {
        var events: [(ReportID, [UInt8])] = []
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { id, bytes in events.append((id, bytes)) },
            reportReadiness: { _, _, _ in true }
        )
        input.recordInputActivity(at: 100.0)

        let keepAlive = IdleKeepAliveController(idleInterval: 10.0)

        // At t = 109.5s (< 10s idle): no Control key tap
        let early = keepAlive.evaluateTick(
            now: 109.5,
            devices: [
                .init(
                    id: "test-phone-1",
                    hasUSBFrame: true,
                    isLocked: false,
                    isBluetoothReady: true,
                    lastInputUptime: input.lastInputUptime,
                    sendControlTap: { input.sendControlKeepAlive() }
                )
            ]
        )
        XCTAssertTrue(early.isEmpty)
        XCTAssertTrue(events.isEmpty)

        // Locked or unplugged phones never receive a Control tap even after 15s
        let skipped = keepAlive.evaluateTick(
            now: 115.0,
            devices: [
                .init(
                    id: "locked-phone",
                    hasUSBFrame: true,
                    isLocked: true,
                    isBluetoothReady: true,
                    lastInputUptime: 100.0,
                    sendControlTap: { input.sendControlKeepAlive() }
                ),
                .init(
                    id: "unplugged-phone",
                    hasUSBFrame: false,
                    isLocked: false,
                    isBluetoothReady: true,
                    lastInputUptime: 100.0,
                    sendControlTap: { input.sendControlKeepAlive() }
                ),
            ]
        )
        XCTAssertTrue(skipped.isEmpty)
        XCTAssertTrue(events.isEmpty)

        // At t = 110.0s (>= 10s idle, unlocked, USB + BLE ready): sends Control (0x01) down then 0x00 up
        let fired = keepAlive.evaluateTick(
            now: 110.0,
            devices: [
                .init(
                    id: "test-phone-1",
                    hasUSBFrame: true,
                    isLocked: false,
                    isBluetoothReady: true,
                    lastInputUptime: input.lastInputUptime,
                    sendControlTap: { input.sendControlKeepAlive() }
                )
            ]
        )
        XCTAssertEqual(fired, ["test-phone-1"])
        XCTAssertEqual(events.count, 2)
        XCTAssertEqual(events[0].0, .keyboard)
        XCTAssertEqual(events[0].1, [0x01, 0, 0, 0, 0, 0, 0, 0])
        XCTAssertEqual(events[1].0, .keyboard)
        XCTAssertEqual(events[1].1, [0x00, 0, 0, 0, 0, 0, 0, 0])

        // Native screenshot: GET /screenshot?native=1 sends Cmd+Shift+3 and returns X-Note: deleted
        events.removeAll()
        let nativeImage = try makePNGData(luma: 210)
        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in nativeImage },
            captureNativeScreenshot: {
                GhosthandDevicePrimitives.NativeScreenshotCapture(
                    data: nativeImage,
                    width: 400,
                    height: 800,
                    note: "deleted"
                )
            }
        )
        let nativeResp = ControlAPI.handle(
            try makeJSONRequest("GET", "/screenshot?native=1"),
            ocrCapture: { _, _ in ("test-phone-1", nativeImage) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(nativeResp.status, 200)
        XCTAssertEqual(nativeResp.headers["X-Note"], "deleted")
        XCTAssertEqual(nativeResp.body, nativeImage)
        // Cmd (0x08) + Shift (0x02) = 0x0A, key "3" = usage 0x20 (32)
        XCTAssertTrue(events.contains { $0.0 == .keyboard && $0.1[0] == 0x0A && $0.1[2] == 32 })
    }

    // MARK: - 8. MCP Tool Catalog & Action Translation Parity

    func testMCPCatalogExposesAllSliceCToolsAndTranslatesRequests() throws {
        let tools = MCPToolCatalog.tools(for: .en)
        let names = Set(tools.compactMap { $0["name"] as? String })
        let expectedNewTools: Set<String> = [
            "screentext", "double_tap", "triple_tap", "hold", "hold_drag", "scroll",
            "wake", "lock", "unlock", "mute", "unmute", "record_start", "record_stop",
        ]
        XCTAssertTrue(expectedNewTools.isSubset(of: names))

        let doubleTap = try XCTUnwrap(
            MCPToolRequest.action(
                named: "double_tap",
                arguments: [
                    "text": "Confirm",
                    "wait_text": "Success",
                    "timeout_ms": 4000,
                    "screentext": true,
                    "device": "iPhone",
                ],
                longEdge: 1000
            )
        )
        XCTAssertEqual(doubleTap.path, "/double_tap")
        XCTAssertEqual(doubleTap.body["text"] as? String, "Confirm")
        XCTAssertEqual(doubleTap.body["waitText"] as? String, "Success")
        XCTAssertEqual(doubleTap.body["timeoutMs"] as? Int, 4000)
        XCTAssertEqual(doubleTap.body["screentext"] as? Bool, true)
        XCTAssertEqual(doubleTap.body["device"] as? String, "iPhone")

        let holdDrag = try XCTUnwrap(
            MCPToolRequest.action(
                named: "hold_drag",
                arguments: [
                    "from": ["x": 100, "y": 200],
                    "to": ["x": 300, "y": 400],
                    "holdMs": 800,
                    "durationMs": 500,
                ],
                longEdge: 1000
            )
        )
        XCTAssertEqual(holdDrag.path, "/hold_drag")
        XCTAssertEqual(holdDrag.body["holdMs"] as? Int, 800)
        XCTAssertEqual(holdDrag.body["durationMs"] as? Int, 500)

        let scroll = try XCTUnwrap(
            MCPToolRequest.action(
                named: "scroll",
                arguments: ["direction": "down", "ticks": 7],
                longEdge: 1000
            )
        )
        XCTAssertEqual(scroll.path, "/scroll")
        XCTAssertEqual(scroll.body["direction"] as? String, "down")
        XCTAssertEqual(scroll.body["ticks"] as? Int, 7)

        XCTAssertThrowsError(
            try MCPToolRequest.action(
                named: "press_key",
                arguments: ["key": "mute"],
                longEdge: 1000
            )
        )
    }

    // MARK: - 9. Phone-Harness Ergonomics (Saw-List Diagnostics, tap_icon, scroll_until/collect, OCR Filtering)

    func testTapTextFailureIncludesSawListAndTapIconOffsetsAboveLabel() throws {
        var movedPoints: [(UInt16, UInt16)] = []
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 1000) },
            sleep: { _ in },
            reportSender: { id, bytes in
                if id == .absolutePointer, bytes.count == 5 {
                    let x = UInt16(bytes[1]) | (UInt16(bytes[2]) << 8)
                    let y = UInt16(bytes[3]) | (UInt16(bytes[4]) << 8)
                    movedPoints.append((x, y))
                }
            },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 100)
        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 1000),
            input: input,
            captureFrame: { _, _ in frame },
            recognizeOCR: { _, _ in
                ScreenOCR.Result(
                    width: 400,
                    height: 1000,
                    items: [
                        ScreenOCR.Item(text: "WeChat", x: 200, y: 500, width: 60, height: 20, confidence: 0.98),
                        ScreenOCR.Item(text: "Settings", x: 100, y: 500, width: 70, height: 20, confidence: 0.95),
                    ],
                    screenHash: "home-hash"
                )
            }
        )

        // 1) Missing text returns localized prefix + `saw: [...]`
        let missingResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/tap_text", body: ["text": "Alipay"]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(missingResp.status, 400)
        let missingJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: missingResp.body) as? [String: Any])
        let errText = try XCTUnwrap(missingJSON["error"] as? String)
        XCTAssertTrue(errText.hasPrefix(StringsAPI.current.ocrTextNotFound))
        XCTAssertTrue(errText.contains("saw: [\"WeChat\", \"Settings\"]"))

        // 2) tap_icon shifts Y upward above the text label (500 - 42 = 458)
        movedPoints.removeAll()
        let iconResp = ControlAPI.handle(
            try makeJSONRequest("POST", "/tap_icon", body: ["text": "WeChat"]),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(iconResp.status, 200)
        let firstMove = try XCTUnwrap(movedPoints.first)
        let expectedY = UInt16((458.0 / 1000.0 * 32767.0).rounded())
        XCTAssertEqual(firstMove.1, expectedY)
    }

    func testScrollUntilAndScrollCollectIgnoreStatusBarClockAndStopAtEnd() throws {
        var scrollCount = 0
        var frameIndex = 0
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { id, bytes in
                if id == .relativeMouse, bytes.count == 4, bytes[3] != 0 {
                    scrollCount += 1
                }
            },
            reportReadiness: { _, _, _ in true }
        )
        let frame = try makePNGData(luma: 100)

        let pages: [[ScreenOCR.Item]] = [
            [
                // Status bar clock at y = 20 (2.5% of 800 -> outside content band 6%..92%)
                ScreenOCR.Item(text: "09:41", x: 60, y: 20, width: 40, height: 16, confidence: 0.99),
                ScreenOCR.Item(text: "General", x: 200, y: 200, width: 100, height: 24, confidence: 0.98),
                ScreenOCR.Item(text: "Bluetooth", x: 200, y: 300, width: 100, height: 24, confidence: 0.98),
            ],
            [
                ScreenOCR.Item(text: "09:42", x: 60, y: 20, width: 40, height: 16, confidence: 0.99),
                ScreenOCR.Item(text: "Notifications", x: 200, y: 200, width: 120, height: 24, confidence: 0.98),
                ScreenOCR.Item(text: "Privacy & Security", x: 200, y: 320, width: 150, height: 24, confidence: 0.97),
            ],
            [
                ScreenOCR.Item(text: "09:43", x: 60, y: 20, width: 40, height: 16, confidence: 0.99),
                ScreenOCR.Item(text: "Notifications", x: 200, y: 200, width: 120, height: 24, confidence: 0.98),
                ScreenOCR.Item(text: "Privacy & Security", x: 200, y: 320, width: 150, height: 24, confidence: 0.97),
            ],
            [
                ScreenOCR.Item(text: "09:44", x: 60, y: 20, width: 40, height: 16, confidence: 0.99),
                ScreenOCR.Item(text: "Notifications", x: 200, y: 200, width: 120, height: 24, confidence: 0.98),
                ScreenOCR.Item(text: "Privacy & Security", x: 200, y: 320, width: 150, height: 24, confidence: 0.97),
            ],
        ]

        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            recognizeOCR: { _, _ in
                let idx = min(frameIndex, pages.count - 1)
                frameIndex += 1
                return ScreenOCR.Result(width: 400, height: 800, items: pages[idx], screenHash: "p-\(idx)")
            },
            sleep: { _ in }
        )

        // 1) scroll_until finds "Privacy & Security" on page 2
        frameIndex = 0
        scrollCount = 0
        let foundResp = ControlAPI.handle(
            try makeJSONRequest(
                "POST",
                "/scroll_until",
                body: ["until_text": "Privacy & Security", "direction": "down", "max_scrolls": 5]
            ),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(foundResp.status, 200)
        let foundJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: foundResp.body) as? [String: Any])
        XCTAssertEqual(foundJSON["found"] as? Bool, true)
        XCTAssertEqual(foundJSON["stopReason"] as? String, "found")
        XCTAssertEqual(foundJSON["scrolls"] as? Int, 1)

        // 2) scroll_collect stops on reached-end despite changing status-bar clock and excludes clock text
        frameIndex = 0
        let collectResp = ControlAPI.handle(
            try makeJSONRequest(
                "POST",
                "/scroll_collect",
                body: ["direction": "down", "max_scrolls": 8, "end_after": 2]
            ),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(collectResp.status, 200)
        let collectJSON = try XCTUnwrap(JSONSerialization.jsonObject(with: collectResp.body) as? [String: Any])
        XCTAssertEqual(collectJSON["stopReason"] as? String, "reached-end")
        let collectedItems = try XCTUnwrap(collectJSON["texts"] as? [String])
        XCTAssertEqual(
            collectedItems,
            ["General", "Bluetooth", "Notifications", "Privacy & Security"]
        )
    }

    func testOCRMinConfidenceContentOnlyAndProvenanceSource() throws {
        let frame = try makePNGData(luma: 100)
        let input = DeviceInput(
            host: UUID(),
            session: UUID(),
            screenSize: { CGSize(width: 400, height: 800) },
            sleep: { _ in },
            reportSender: { _, _ in },
            reportReadiness: { _, _, _ in true }
        )
        let hooks = GhosthandRuntimeHooks(
            deviceID: "test-phone-1",
            deviceName: "iPhone",
            screenSize: CGSize(width: 400, height: 800),
            input: input,
            captureFrame: { _, _ in frame },
            recognizeOCR: { _, _ in
                ScreenOCR.Result(
                    width: 400,
                    height: 800,
                    items: [
                        ScreenOCR.Item(text: "09:41", x: 50, y: 20, width: 40, height: 15, confidence: 0.99),
                        ScreenOCR.Item(text: "Noise", x: 200, y: 400, width: 50, height: 20, confidence: 0.25),
                        ScreenOCR.Item(text: "Confirm", x: 200, y: 500, width: 80, height: 24, confidence: 0.95),
                    ],
                    screenHash: "ocr-filter"
                )
            }
        )

        let resp = ControlAPI.handle(
            try makeJSONRequest(
                "POST",
                "/ocr",
                body: ["min_confidence": 0.5, "content_only": true]
            ),
            ocrCapture: { _, _ in ("test-phone-1", frame) },
            runtimeHooks: hooks
        )
        XCTAssertEqual(resp.status, 200)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
        let items = try XCTUnwrap(json["items"] as? [[String: Any]])
        XCTAssertEqual(items.count, 1)
        let firstItem = try XCTUnwrap(items.first)
        XCTAssertEqual(firstItem["text"] as? String, "Confirm")
        XCTAssertEqual(firstItem["source"] as? String, "pixels")

        // CLI subcommands for tap_icon, scroll_until, scroll_collect
        let cliTapIcon = try CLIRunner.buildRequest(from: ["tap_icon", "WeChat", "-d", "iPhone"])
        XCTAssertEqual(cliTapIcon.path, "/tap_icon")
        XCTAssertEqual(cliTapIcon.body["text"] as? String, "WeChat")
        XCTAssertEqual(cliTapIcon.body["icon"] as? Bool, true)

        let cliScrollUntil = try CLIRunner.buildRequest(
            from: ["scroll_until", "General", "--max-scrolls", "6"]
        )
        XCTAssertEqual(cliScrollUntil.path, "/scroll_until")
        XCTAssertEqual(cliScrollUntil.body["until_text"] as? String, "General")
        XCTAssertEqual(cliScrollUntil.body["max_scrolls"] as? Int, 6)
    }
}
