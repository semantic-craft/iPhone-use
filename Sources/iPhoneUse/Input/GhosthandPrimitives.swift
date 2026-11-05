import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO

/// Structured errors matching Ghosthand's problem codes and retry-safety guarantees.
struct GhosthandError: Error, CustomStringConvertible, Equatable {
    let code: String
    let httpStatus: Int
    let message: String

    var description: String { message }

    static func invalidArgument(_ detail: String) -> GhosthandError {
        GhosthandError(code: "invalid-argument", httpStatus: 400, message: detail)
    }

    static func unavailable(code: String, message: String) -> GhosthandError {
        GhosthandError(code: code, httpStatus: 503, message: message)
    }

    static func waitTextTimeout(text: String, timeoutMs: Int) -> GhosthandError {
        GhosthandError(
            code: "wait-text-timeout",
            httpStatus: 408,
            message:
                "wait-text-timeout: timed out after \(timeoutMs) ms waiting for \"\(text)\" on screen; input was already sent — do NOT repeat the input automatically"
        )
    }

    static let deviceLocked = GhosthandError(
        code: "device-locked",
        httpStatus: 409,
        message: "device-locked: iPhone is locked; unlock it before sending this command"
    )

    static let lockFailed = GhosthandError(
        code: "lock-failed",
        httpStatus: 502,
        message: "lock-failed: sent Control-Command-Q over Bluetooth keyboard, but USB lock state was not confirmed"
    )

    static let unlockFailed = GhosthandError(
        code: "unlock-failed",
        httpStatus: 422,
        message:
            "unlock-failed: iPhone remained locked after entering the passcode once; wrong passcodes are NEVER retried automatically because failed attempts count toward iPhone lockout"
    )

    static func muteUnconfirmed(targetMuted: Bool) -> GhosthandError {
        let action = targetMuted ? "mute" : "unmute"
        return GhosthandError(
            code: "mute-unconfirmed",
            httpStatus: 502,
            message:
                "mute-unconfirmed: could not confirm \(action) state from USB SpringBoard log; will not press Mute again"
        )
    }

    static let recordingActive = GhosthandError(
        code: "recording-active",
        httpStatus: 409,
        message: "recording-active: a screen recording is already active for this iPhone"
    )

    static let noRecording = GhosthandError(
        code: "no-recording",
        httpStatus: 409,
        message: "no-recording: no active or completed screen recording exists for this iPhone"
    )

    func json() -> [String: Any] {
        [
            "ok": false,
            "error": message,
            "code": code,
            "title": code,
            "status": httpStatus,
            "detail": message,
        ]
    }
}

/// Options controlling post-action stillness detection, `wait_text`, `screenshot`, and `screentext`
/// within the same HTTP or MCP input call.
struct PostActionOptions: Equatable {
    static let defaultWaitTextTimeoutMs = 5_000
    static let validTimeoutMsRange = 1...60_000

    let settle: Bool
    let waitText: String?
    let timeoutMs: Int
    let includeScreenshot: Bool
    let screenshotFormat: String
    let includeScreentext: Bool
    let maxEdge: Int?

    var requiresPostActionCapture: Bool {
        settle || waitText != nil || includeScreenshot || includeScreentext
    }

    init(
        settle: Bool = false,
        waitText: String? = nil,
        timeoutMs: Int = Self.defaultWaitTextTimeoutMs,
        includeScreenshot: Bool = false,
        screenshotFormat: String = "png",
        includeScreentext: Bool = false,
        maxEdge: Int? = nil
    ) throws {
        guard Self.validTimeoutMsRange.contains(timeoutMs) else {
            throw GhosthandError.invalidArgument(
                "timeout_ms must be within 1...60000 ms (got \(timeoutMs))"
            )
        }
        let normalizedWait: String?
        if let waitText {
            let trimmed = waitText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GhosthandError.invalidArgument("wait_text must not be empty")
            }
            normalizedWait = waitText
        } else {
            normalizedWait = nil
        }
        let formatLower = screenshotFormat.lowercased()
        guard formatLower == "png" || formatLower == "jpeg" || formatLower == "jpg" else {
            throw GhosthandError.invalidArgument("screenshot format must be png or jpeg")
        }
        self.waitText = normalizedWait
        self.timeoutMs = timeoutMs
        self.includeScreenshot = includeScreenshot
        self.screenshotFormat = formatLower == "jpg" ? "jpeg" : formatLower
        self.includeScreentext = includeScreentext
        self.settle = settle || normalizedWait != nil || includeScreenshot || includeScreentext
        self.maxEdge = maxEdge
    }

    static func parse(body: [String: Any], query: [String: String] = [:]) throws -> PostActionOptions {
        let rawWait: Any? =
            body["waitText"] ?? body["wait_text"]
            ?? (query["waitText"] as Any?) ?? (query["wait_text"] as Any?)
        let waitText: String?
        if let rawWait, !(rawWait is NSNull) {
            guard let str = rawWait as? String else {
                throw GhosthandError.invalidArgument("wait_text must be a string")
            }
            waitText = str
        } else {
            waitText = nil
        }

        let rawTimeout: Any? =
            body["timeoutMs"] ?? body["timeout_ms"]
            ?? (query["timeoutMs"] as Any?) ?? (query["timeout_ms"] as Any?)
        let timeoutMs: Int
        if let rawTimeout, !(rawTimeout is NSNull) {
            if let num = rawTimeout as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                let d = num.doubleValue
                guard d.isFinite, d.rounded() == d else {
                    throw GhosthandError.invalidArgument("timeout_ms must be an integer within 1...60000")
                }
                timeoutMs = Int(d)
            } else if let str = rawTimeout as? String, let parsed = Int(str) {
                timeoutMs = parsed
            } else {
                throw GhosthandError.invalidArgument("timeout_ms must be an integer within 1...60000")
            }
        } else {
            timeoutMs = Self.defaultWaitTextTimeoutMs
        }

        let settleFlag = Self.parseBoolFlag(body["settle"] ?? (query["settle"] as Any?)) ?? false
        let screentextFlag = Self.parseBoolFlag(body["screentext"] ?? (query["screentext"] as Any?)) ?? false

        var includeScreenshot = false
        var screenshotFormat = "png"
        let rawScreenshot: Any? = body["screenshot"] ?? (query["screenshot"] as Any?)
        if let rawScreenshot, !(rawScreenshot is NSNull) {
            if let flag = Self.parseBoolFlag(rawScreenshot) {
                includeScreenshot = flag
            } else if let str = rawScreenshot as? String {
                let lower = str.lowercased()
                if lower == "png" || lower == "jpeg" || lower == "jpg" {
                    includeScreenshot = true
                    screenshotFormat = lower == "jpg" ? "jpeg" : lower
                } else {
                    throw GhosthandError.invalidArgument("screenshot must be a boolean, png, or jpeg")
                }
            } else {
                throw GhosthandError.invalidArgument("screenshot must be a boolean, png, or jpeg")
            }
        }
        if let rawFormat = (body["format"] as? String) ?? query["format"], !rawFormat.isEmpty {
            screenshotFormat = rawFormat
        }
        let maxEdge = try OCRRequest.maxEdge(body) ?? query["maxEdge"].flatMap(Int.init)

        return try PostActionOptions(
            settle: settleFlag,
            waitText: waitText,
            timeoutMs: timeoutMs,
            includeScreenshot: includeScreenshot,
            screenshotFormat: screenshotFormat,
            includeScreentext: screentextFlag,
            maxEdge: maxEdge
        )
    }

    static func parseBoolFlag(_ raw: Any?) -> Bool? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let num = raw as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() {
            return num.boolValue
        }
        if let str = raw as? String {
            switch str.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes": return true
            case "0", "false", "no": return false
            default: return nil
            }
        }
        return nil
    }
}

/// Executes post-action `wait_text` polling and screen stillness detection (`settle`),
/// returning the settled screenshot and same-coordinate-space `screentext` (`x,y wxh text`).
enum StillnessDetector {
    struct PostActionObservation {
        let settledFrame: Data
        let ocrResult: ScreenOCR.Result
        let format: String

        var screentext: String { ocrResult.screentext }

        func attach(to payload: inout [String: Any], includeScreenshot: Bool, includeScreentext: Bool) {
            if includeScreenshot {
                payload["screenshot"] = [
                    "format": format,
                    "width": ocrResult.width,
                    "height": ocrResult.height,
                    "data": settledFrame.base64EncodedString(),
                ]
            }
            if includeScreentext {
                payload["screentext"] = ocrResult.screentext
                payload["screen"] = ocrResult.screenTextJSON
            }
        }
    }

    /// Waits until two frames `pollInterval` (default 150 ms) apart have matching stability signatures,
    /// or until `timeout` (default 2.0 s) elapses. Returns the final settled frame.
    static func waitForStillness(
        pollInterval: TimeInterval = 0.15,
        timeout: TimeInterval = 2.0,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        captureFrame: () throws -> Data,
        signature: (Data) -> String = ScreenOCR.stabilitySignature
    ) throws -> Data {
        let start = now()
        var elapsed: TimeInterval = 0
        var latest = try captureFrame()
        var previousSig = signature(latest)
        while elapsed < timeout {
            let delay = min(pollInterval, max(0.01, timeout - elapsed))
            sleep(delay)
            elapsed = max(elapsed + delay, now() - start)
            let next = try captureFrame()
            let nextSig = signature(next)
            latest = next
            if !nextSig.isEmpty, nextSig == previousSig {
                return next
            }
            previousSig = nextSig
        }
        return latest
    }

    /// Runs `wait_text` polling (if requested) followed by stillness detection, then recognizes
    /// OCR once on the settled frame so `screenshot` and `screentext` share the exact same frame
    /// and coordinate space.
    static func observeAfterAction(
        options: PostActionOptions,
        deviceID: String,
        pollInterval: TimeInterval = 0.15,
        stillnessTimeout: TimeInterval = 2.0,
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        captureFrame: (_ png: Bool, _ maxEdge: Int?) throws -> Data,
        recognize: (Data, String) -> ScreenOCR.Result = { data, id in ScreenOCR.recognize(data, device: id) },
        signature: (Data) -> String = ScreenOCR.stabilitySignature
    ) throws -> PostActionObservation {
        let usePNG = options.screenshotFormat == "png" || options.includeScreentext || options.waitText != nil
        if let waitText = options.waitText {
            let timeoutSeconds = Double(options.timeoutMs) / 1000.0
            let start = now()
            var elapsed: TimeInterval = 0
            while true {
                let frame = try captureFrame(true, options.maxEdge)
                let ocr = recognize(frame, deviceID)
                let matched = ocr.items.contains {
                    $0.text.range(of: waitText, options: .caseInsensitive) != nil
                }
                if matched {
                    break
                }
                elapsed = max(elapsed, now() - start)
                if elapsed >= timeoutSeconds {
                    throw GhosthandError.waitTextTimeout(text: waitText, timeoutMs: options.timeoutMs)
                }
                let delay = min(pollInterval, max(0.001, timeoutSeconds - elapsed))
                sleep(delay)
                elapsed = max(elapsed + delay, now() - start)
            }
        }

        let settledPNGOrRequested = try waitForStillness(
            pollInterval: pollInterval,
            timeout: stillnessTimeout,
            now: now,
            sleep: sleep,
            captureFrame: { try captureFrame(usePNG, options.maxEdge) },
            signature: signature
        )
        let ocrResult = recognize(settledPNGOrRequested, deviceID)
        let finalFrame: Data
        if options.includeScreenshot && options.screenshotFormat == "jpeg" && usePNG {
            finalFrame = (try? captureFrame(false, options.maxEdge)) ?? settledPNGOrRequested
        } else {
            finalFrame = settledPNGOrRequested
        }
        return PostActionObservation(
            settledFrame: finalFrame,
            ocrResult: ocrResult,
            format: options.screenshotFormat
        )
    }
}

/// First-class list-walking state machine (`scroll_until` and `scroll_collect`) inspired by
/// `ShawnPana/phone-harness`, upgraded to use `StillnessDetector` after each scroll gesture.
/// End-of-list detection compares the scrollable content band (`6% < y < 92%`, `confidence >= 0.4`)
/// so status-bar clock/battery updates never prevent `reached-end` convergence.
enum ListScrollWalker {
    enum StopReason: String, Equatable {
        case found = "found"
        case reachedEnd = "reached-end"
        case maxScrolls = "max-scrolls"
    }

    struct UntilOutcome {
        let found: Bool
        let stop: StopReason
        let scrolls: Int
        let matchedItem: ScreenOCR.Item?
        let lastOCR: ScreenOCR.Result

        func toJSON(deviceID: String, direction: String) -> [String: Any] {
            var payload: [String: Any] = [
                "ok": true,
                "device": deviceID,
                "found": found,
                "stop": stop.rawValue,
                "stopReason": stop.rawValue,
                "scrolls": scrolls,
                "direction": direction,
                "screentext": lastOCR.screentext,
                "screen": lastOCR.screenTextJSON,
            ]
            if let matchedItem {
                payload["text"] = matchedItem.text
                payload["x"] = matchedItem.x
                payload["y"] = matchedItem.y
                payload["item"] = matchedItem.json
                payload["match"] = matchedItem.json
            } else {
                payload["saw"] = Array(
                    lastOCR.items
                        .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                        .filter { !$0.isEmpty }
                        .prefix(30)
                )
            }
            return payload
        }
    }

    struct CollectOutcome {
        let stop: StopReason
        let scrolls: Int
        let texts: [String]
        let items: [[String: Any]]
        let lastOCR: ScreenOCR.Result

        func toJSON(deviceID: String, direction: String) -> [String: Any] {
            [
                "ok": true,
                "device": deviceID,
                "stop": stop.rawValue,
                "stopReason": stop.rawValue,
                "scrolls": scrolls,
                "direction": direction,
                "count": texts.count,
                "texts": texts,
                "items": items,
                "screentext": texts.joined(separator: "\n"),
            ]
        }
    }

    static func contentBandTextSet(
        from ocr: ScreenOCR.Result,
        minConfidence: Double = 0.4
    ) -> Set<String> {
        let band = ocr.filtering(minConfidence: minConfidence, contentOnly: true)
        return Set(
            band.items
                .map { $0.text.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
    }

    /// Scrolls until `query` is visible on screen, or until 2 consecutive scrolls produce an
    /// identical content-band text set (`reached-end`), or `maxScrolls` is reached (`max-scrolls`).
    static func scrollUntil(
        query: String,
        exact: Bool = false,
        index: Int? = nil,
        maxScrolls: Int = 12,
        minConfidence: Double = 0.4,
        performScroll: () throws -> Void,
        captureSettledOCR: (_ isInitial: Bool) throws -> ScreenOCR.Result
    ) throws -> UntilOutcome {
        let clampedMax = max(1, min(50, maxScrolls))
        var currentOCR = try captureSettledOCR(true)
        if let initialMatch = try? ScreenOCR.matchTiered(
            currentOCR, text: query, exact: exact, index: index, oneBasedIndex: false)
        {
            return UntilOutcome(
                found: true,
                stop: .found,
                scrolls: 0,
                matchedItem: initialMatch,
                lastOCR: currentOCR
            )
        }

        var previousBand = contentBandTextSet(from: currentOCR, minConfidence: minConfidence)
        var unchangedStreak = 0

        for step in 1...clampedMax {
            try performScroll()
            currentOCR = try captureSettledOCR(false)
            if let match = try? ScreenOCR.matchTiered(
                currentOCR, text: query, exact: exact, index: index, oneBasedIndex: false)
            {
                return UntilOutcome(
                    found: true,
                    stop: .found,
                    scrolls: step,
                    matchedItem: match,
                    lastOCR: currentOCR
                )
            }
            let currentBand = contentBandTextSet(from: currentOCR, minConfidence: minConfidence)
            if currentBand == previousBand {
                unchangedStreak += 1
                if unchangedStreak >= 2 {
                    return UntilOutcome(
                        found: false,
                        stop: .reachedEnd,
                        scrolls: step,
                        matchedItem: nil,
                        lastOCR: currentOCR
                    )
                }
            } else {
                unchangedStreak = 0
                previousBand = currentBand
            }
        }

        return UntilOutcome(
            found: false,
            stop: .maxScrolls,
            scrolls: clampedMax,
            matchedItem: nil,
            lastOCR: currentOCR
        )
    }

    /// Walks a scrollable list and collects unique content-band text items in reading order,
    /// stopping when `endAfter` consecutive scrolls add 0 new items (`reached-end`) or
    /// `maxScrolls` is reached (`max-scrolls`).
    static func scrollCollect(
        maxScrolls: Int = 15,
        endAfter: Int = 3,
        minConfidence: Double = 0.4,
        contentOnly: Bool = true,
        performScroll: () throws -> Void,
        captureSettledOCR: (_ isInitial: Bool) throws -> ScreenOCR.Result
    ) throws -> CollectOutcome {
        let clampedMax = max(1, min(50, maxScrolls))
        let clampedEndAfter = max(1, min(10, endAfter))

        var seen = Set<String>()
        var collectedTexts: [String] = []
        var collectedItems: [[String: Any]] = []

        func absorb(_ ocr: ScreenOCR.Result) -> Int {
            let filtered = ocr.filtering(minConfidence: minConfidence, contentOnly: contentOnly)
            var added = 0
            for item in filtered.items {
                let trimmed = item.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty, !seen.contains(trimmed) else { continue }
                seen.insert(trimmed)
                collectedTexts.append(trimmed)
                collectedItems.append(item.lineJSON)
                added += 1
            }
            return added
        }

        var currentOCR = try captureSettledOCR(true)
        _ = absorb(currentOCR)

        var staleScrolls = 0
        for step in 1...clampedMax {
            try performScroll()
            currentOCR = try captureSettledOCR(false)
            let newlyAdded = absorb(currentOCR)
            if newlyAdded == 0 {
                staleScrolls += 1
                if staleScrolls >= clampedEndAfter {
                    return CollectOutcome(
                        stop: .reachedEnd,
                        scrolls: step,
                        texts: collectedTexts,
                        items: collectedItems,
                        lastOCR: currentOCR
                    )
                }
            } else {
                staleScrolls = 0
            }
        }

        return CollectOutcome(
            stop: .maxScrolls,
            scrolls: clampedMax,
            texts: collectedTexts,
            items: collectedItems,
            lastOCR: currentOCR
        )
    }
}

/// Implements Ghosthand's stateful device primitives (`wake`, `lock`, `unlock`, `mute`, `unmute`,
/// and `screenshot(native: true)`) with injectable hardware hooks for deterministic testing.
enum GhosthandDevicePrimitives {
    struct NativeScreenshotCapture {
        let data: Data
        let width: Int
        let height: Int
        let note: String
    }

    /// Wakes the screen by clicking at the top-center status bar `(0.5, 0.02)`, waits for a USB frame,
    /// and fails with `device-locked` if the phone is locked.
    static func wake(
        tapStatusBar: (Double, Double) throws -> Void,
        waitForFrame: () -> Bool,
        isLocked: () -> Bool
    ) throws {
        try tapStatusBar(0.5, 0.02)
        guard waitForFrame() else {
            throw DeviceError("No frame from iPhone screen after wake click")
        }
        if isLocked() {
            throw GhosthandError.deviceLocked
        }
    }

    /// Locks the iPhone by sending `Control-Command-Q` on the Bluetooth keyboard and verifying
    /// lock state over USB (`lock-failed` if not locked).
    static func lock(
        sendKey: (String, [String]) throws -> Void,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        verifyLocked: () -> Bool
    ) throws {
        try sendKey("q", ["ctrl", "cmd"])
        sleep(0.25)
        guard verifyLocked() else {
            throw GhosthandError.lockFailed
        }
    }

    /// Unlocks the iPhone using the Bluetooth keyboard:
    /// 1. Validates that `passcode` is non-empty printable US-ASCII (`0x20...0x7E`).
    /// 2. If already unlocked, leaves the phone as is without typing the passcode.
    /// 3. Otherwise sends `Enter` to wake, pauses, sends `Enter` to open the passcode screen,
    ///    pauses, types the passcode once, and checks lock state.
    /// 4. **Never retries a wrong passcode** (`unlock-failed`), and never logs or echoes `passcode`.
    @discardableResult
    static func unlock(
        passcode: String,
        isLocked: () -> Bool,
        sendKey: (String, [String]) throws -> Void,
        typeText: (String) throws -> Void,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> Bool {
        guard !passcode.isEmpty,
            passcode.utf8.allSatisfy({ (0x20...0x7E).contains($0) })
        else {
            throw GhosthandError.invalidArgument(
                "passcode must be non-empty printable US-ASCII (0x20...0x7E)"
            )
        }
        if !isLocked() {
            return false
        }
        try sendKey("return", [])
        sleep(0.35)
        try sendKey("return", [])
        sleep(0.45)
        try typeText(passcode)
        sleep(0.35)
        guard !isLocked() else {
            throw GhosthandError.unlockFailed
        }
        return true
    }

    /// Sets the iPhone ringer mute state using Bluetooth consumer usage `0x00E2` (Mute) and
    /// verifies the resulting state over USB SpringBoard logs:
    /// - Consumer `0x00E2` is a toggle in iOS.
    /// - After the first press, if the observed state is the opposite of `targetMuted`
    ///   (because the phone was already in `targetMuted`), presses `0x00E2` once more.
    /// - If the state cannot be confirmed from USB, fails with `mute-unconfirmed` and never presses again.
    static func setMuted(
        _ targetMuted: Bool,
        sendConsumerMute: () -> Void,
        observeMutedState: () -> Bool?,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> [String: Any] {
        sendConsumerMute()
        sleep(0.15)
        guard let firstObserved = observeMutedState() else {
            throw GhosthandError.muteUnconfirmed(targetMuted: targetMuted)
        }
        if firstObserved == targetMuted {
            return ["ok": true, "muted": targetMuted, "presses": 1]
        }
        // First press toggled away from the desired state; toggle once more to restore it.
        sendConsumerMute()
        sleep(0.15)
        guard let secondObserved = observeMutedState(), secondObserved == targetMuted else {
            throw GhosthandError.muteUnconfirmed(targetMuted: targetMuted)
        }
        return ["ok": true, "muted": targetMuted, "presses": 2]
    }

    /// Takes a real iOS screenshot (`Command-Shift-3` on Bluetooth keyboard), reads it over USB
    /// (capturing system alerts hidden from USB video capture), and deletes the temporary photo.
    static func captureNativeScreenshot(
        sendKey: (String, [String]) throws -> Void,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        readAndDeleteFromUSB: () throws -> NativeScreenshotCapture
    ) throws -> NativeScreenshotCapture {
        try sendKey("3", ["cmd", "shift"])
        sleep(0.35)
        return try readAndDeleteFromUSB()
    }
}

/// Keeps every unlocked USB- and Bluetooth-connected iPhone awake by sending a harmless
/// Left Control modifier key tap after 10 seconds of idle. Locked or unplugged iPhones
/// receive no key so iOS Auto-Lock works normally.
final class IdleKeepAliveController {
    struct MonitoredDevice {
        let id: String
        let hasUSBFrame: Bool
        let isLocked: Bool
        let isBluetoothReady: Bool
        let lastInputUptime: TimeInterval
        let sendControlTap: () -> Bool
    }

    static let shared = IdleKeepAliveController()
    static let defaultIdleInterval: TimeInterval = 10.0

    let idleInterval: TimeInterval
    private let lock = NSLock()
    private var lastKeepAliveByDevice: [String: TimeInterval] = [:]
    private var timer: DispatchSourceTimer?

    init(idleInterval: TimeInterval = IdleKeepAliveController.defaultIdleInterval) {
        self.idleInterval = idleInterval
    }

    /// Evaluates one keepalive tick across `devices` at `now` and returns the IDs of devices
    /// that received a Control key tap.
    @discardableResult
    func evaluateTick(now: TimeInterval, devices: [MonitoredDevice]) -> [String] {
        lock.lock()
        defer { lock.unlock() }

        let activeIDs = Set(devices.map(\.id))
        lastKeepAliveByDevice = lastKeepAliveByDevice.filter { activeIDs.contains($0.key) }

        var fired: [String] = []
        for device in devices {
            guard device.hasUSBFrame, !device.isLocked, device.isBluetoothReady else {
                continue
            }
            let baseline = max(device.lastInputUptime, lastKeepAliveByDevice[device.id] ?? -.infinity)
            guard now - baseline >= idleInterval else {
                continue
            }
            if device.sendControlTap() {
                lastKeepAliveByDevice[device.id] = now
                fired.append(device.id)
            }
        }
        return fired
    }

    func start(
        queue: DispatchQueue = DispatchQueue(label: "iphone-use.idle-keepalive", qos: .utility),
        provider: @escaping () -> [MonitoredDevice]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard timer == nil else { return }
        let source = DispatchSource.makeTimerSource(queue: queue)
        source.schedule(deadline: .now() + 1.0, repeating: 1.0)
        source.setEventHandler { [weak self] in
            guard let self else { return }
            self.evaluateTick(now: ProcessInfo.processInfo.systemUptime, devices: provider())
        }
        timer = source
        source.resume()
    }

    func stop() {
        lock.lock()
        defer { lock.unlock() }
        timer?.cancel()
        timer = nil
    }
}

/// Injectable runtime hooks for `ControlAPI` so tests can verify the complete post-action stillness loop,
/// `wait_text`, `screentext`, and all Bluetooth/screen primitives without touching physical hardware.
struct GhosthandRuntimeHooks {
    let deviceID: String
    let deviceName: String
    let screenSize: CGSize
    let input: DeviceInput
    let captureFrame: (_ png: Bool, _ maxEdge: Int?) throws -> Data
    let recognizeOCR: (Data, String) -> ScreenOCR.Result
    let stabilitySignature: (Data) -> String
    let isLocked: () -> Bool
    let waitForFrame: () -> Bool
    let observeMutedState: () -> Bool?
    let captureNativeScreenshot: () throws -> GhosthandDevicePrimitives.NativeScreenshotCapture
    let now: () -> TimeInterval
    let sleep: (TimeInterval) -> Void
    let recorder: ScreenRecorderManager
    let usbProvider: USBSystemProvider
    let geminiTransport: GeminiInteractionsTransport?
    let taskStore: TaskSessionStore

    init(
        deviceID: String = "hermes-id",
        deviceName: String = "Hermes",
        screenSize: CGSize = CGSize(width: 400, height: 800),
        input: DeviceInput,
        captureFrame: @escaping (_ png: Bool, _ maxEdge: Int?) throws -> Data,
        recognizeOCR: @escaping (Data, String) -> ScreenOCR.Result = { data, id in
            ScreenOCR.recognize(data, device: id)
        },
        stabilitySignature: @escaping (Data) -> String = ScreenOCR.stabilitySignature,
        isLocked: @escaping () -> Bool = { false },
        waitForFrame: @escaping () -> Bool = { true },
        observeMutedState: @escaping () -> Bool? = { true },
        captureNativeScreenshot: (
            () throws -> GhosthandDevicePrimitives.NativeScreenshotCapture
        )? = nil,
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: @escaping (TimeInterval) -> Void = { _ in },
        recorder: ScreenRecorderManager = .shared,
        usbProvider: USBSystemProvider = StateDirUSBSystemProvider.shared,
        geminiTransport: GeminiInteractionsTransport? = nil,
        taskStore: TaskSessionStore = .shared
    ) {
        self.deviceID = deviceID
        self.deviceName = deviceName
        self.screenSize = screenSize
        self.input = input
        self.captureFrame = captureFrame
        self.recognizeOCR = recognizeOCR
        self.stabilitySignature = stabilitySignature
        self.isLocked = isLocked
        self.waitForFrame = waitForFrame
        self.observeMutedState = observeMutedState
        self.captureNativeScreenshot =
            captureNativeScreenshot ?? {
                let data = try captureFrame(true, nil)
                return GhosthandDevicePrimitives.NativeScreenshotCapture(
                    data: data,
                    width: Int(screenSize.width),
                    height: Int(screenSize.height),
                    note: "deleted"
                )
            }
        self.now = now
        self.sleep = sleep
        self.recorder = recorder
        self.usbProvider = usbProvider
        self.geminiTransport = geminiTransport
        self.taskStore = taskStore
    }
}
