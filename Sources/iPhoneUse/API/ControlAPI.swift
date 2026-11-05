import AVFoundation
import CoreFoundation
import CoreGraphics
import Foundation
import ImageIO

/// The HTTP API. Every route takes an optional `device` (id or name), required only when
/// more than one phone is plugged in. Tap and swipe coordinates are pixels of the full
/// screen, or of a resized screenshot when `width`/`height` or `maxEdge` say so.
enum ControlAPI {
    /// Only absolute pointer actions require a calibrated, subscribed mouse.
    private enum Action: String {
        case tap = "/tap"
        case doubleTap = "/double_tap"
        case tripleTap = "/triple_tap"
        case hold = "/hold"
        case swipe = "/swipe"
        case holdDrag = "/hold_drag"
        case scroll = "/scroll"
        case move = "/move"
        case nudge = "/nudge"
        case type = "/type"
        case key = "/key"
        case home = "/home"
        case power = "/power"
        case wake = "/wake"
        case lock = "/lock"
        case unlock = "/unlock"
        case mute = "/mute"
        case unmute = "/unmute"

        var requiresPointer: Bool {
            switch self {
            case .tap, .doubleTap, .tripleTap, .hold, .swipe, .holdDrag, .scroll, .move, .wake:
                true
            case .nudge, .type, .key, .home, .power, .lock, .unlock, .mute, .unmute:
                false
            }
        }

        static func parse(path: String) -> Action? {
            switch path {
            case "/double-tap": return .doubleTap
            case "/triple-tap": return .tripleTap
            case "/hold-drag": return .holdDrag
            default: return Action(rawValue: path)
            }
        }
    }

    /// Normalizes `/v1/leases/{lease}/<subpath>` or `/leases/{lease}/<subpath>` into
    /// `(normalizedPath, pathLeaseID)`.
    static func normalizeRoutePath(_ path: String) -> (path: String, pathLease: String?) {
        for prefix in ["/v1/leases/", "/leases/"] where path.hasPrefix(prefix) {
            let remainder = String(path.dropFirst(prefix.count))
            guard let slashIndex = remainder.firstIndex(of: "/") else {
                return (path, nil)
            }
            let leaseSegment = String(remainder[..<slashIndex])
            guard !leaseSegment.isEmpty,
                leaseSegment != "acquire", leaseSegment != "wait", leaseSegment != "release"
            else {
                return (path, nil)
            }
            let tail = String(remainder[slashIndex...])
            let mapped: String
            switch tail {
            case "/text":
                mapped = "/screentext"
            case "/double-tap":
                mapped = "/double_tap"
            case "/triple-tap":
                mapped = "/triple_tap"
            case "/hold-drag":
                mapped = "/hold_drag"
            case "/tap-icon":
                mapped = "/tap_icon"
            case "/scroll-until":
                mapped = "/scroll_until"
            case "/scroll-collect":
                mapped = "/scroll_collect"
            default:
                mapped = tail
            }
            return (mapped, leaseSegment)
        }
        return (path, nil)
    }

    static func handle(_ request: HTTPRequest) -> HTTPResponse {
        handle(request, ocrCapture: captureTextScreen, ocrTap: tapTextPoint)
    }

    static func handle(
        _ request: HTTPRequest,
        ocrCapture: (String?, Int?) throws -> (String, Data) = captureTextScreen,
        ocrTap: (String, Double, Double, Double) throws -> Void = tapTextPoint,
        activity: QuietModeActivityController = .shared,
        deviceCandidates: [DeviceCandidate]? = nil,
        setupInputs: SetupInputs? = nil,
        runtimeHooks: GhosthandRuntimeHooks? = nil
    ) -> HTTPResponse {
        let passive = request.method == "GET" && request.query["wake"] == "0"
        let wasSuspended = passive ? false : activity.requestStarted()
        defer { if !passive { activity.requestFinished() } }
        let body = request.body
        let (normalizedPath, pathLease) = normalizeRoutePath(request.path)
        // A body selector takes precedence over the query-string selector.
        let deviceQuery = deviceSelector(body: body, query: request.query)
        let rawLease: Any? = leaseSelector(body: body, query: request.query) ?? (pathLease as Any?)
        if !passive {
            waitForWake(
                normalizedPath: normalizedPath, deviceQuery: deviceQuery,
                wasSuspended: wasSuspended || activity.isWithinWakeGraceWindow)
        }
        do {
            switch (request.method, normalizedPath) {
            case ("GET", "/viewer"), ("GET", "/viewer/"):
                return WebPreview.response(for: viewerLanguage(request.query))
            case ("GET", "/config"):
                return .json(["language": AppLanguageStore.shared.language.rawValue])
            case ("GET", "/"), ("GET", "/status"):
                return status()
            case ("GET", "/devices"):
                return deviceList()
            case ("GET", "/setup_status"), ("GET", "/v1/setup/status"):
                let inputs = setupInputs ?? SetupReadiness.liveInputs()
                return .json(SetupReadiness.evaluate(query: deviceQuery, inputs: inputs).json())
            case ("POST", "/leases"), ("POST", "/v1/leases"), ("POST", "/leases/acquire"):
                return try acquireOrWaitLease(
                    body: body, deviceQuery: deviceQuery, forceWaitRoute: false,
                    deviceCandidates: deviceCandidates)
            case ("POST", "/leases/wait"):
                return try acquireOrWaitLease(
                    body: body, deviceQuery: deviceQuery, forceWaitRoute: true,
                    deviceCandidates: deviceCandidates)
            case ("POST", "/leases/release"):
                return try releaseLease(rawLease: rawLease ?? body["id"])
            case ("POST", "/match"):
                return match(body)
            case ("POST", "/pair"):
                return try pair(body, deviceQuery: deviceQuery)
            case ("POST", "/calibration/reload"):
                try DeviceRegistry.shared.reloadCalibration(for: DeviceRegistry.shared.find(deviceQuery))
                return status()
            case ("POST", "/calibration/auto"):
                let devices =
                    try deviceQuery.map { [try DeviceRegistry.shared.find($0)] }
                    ?? DeviceRegistry.shared.all()
                for device in devices {
                    DeviceRegistry.shared.automaticallyCalibrate(
                        device, retry: true, verifyOnly: (body["verifyOnly"] as? Bool) ?? false)
                }
                return status()
            case ("GET", "/ocr"), ("POST", "/ocr"):
                var options: [String: Any] = request.query
                if let raw = request.query["maxEdge"] {
                    guard let value = Int(raw), value > 0 else {
                        throw DeviceError(StringsAPI.current.ocrParameterInvalid("maxEdge"))
                    }
                    options["maxEdge"] = value
                }
                options.merge(body) { _, value in value }
                let minConfidence = try OCRRequest.minConfidence(options)
                let contentOnly = try OCRRequest.contentOnly(options)
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                let maxEdge = try OCRRequest.maxEdge(options)
                let (id, data) =
                    try runtimeHooks.map { ($0.deviceID, try $0.captureFrame(true, maxEdge)) }
                    ?? ocrCapture(effectiveQuery, maxEdge)
                try authorizeDeviceLease(deviceID: id, leaseID: leaseID, command: "ocr")
                let rawResult = runtimeHooks?.recognizeOCR(data, id) ?? ScreenOCR.recognize(data, device: id)
                let result = rawResult.filtering(minConfidence: minConfidence, contentOnly: contentOnly)
                return .json(result.json(device: id))
            case ("GET", "/screentext"), ("POST", "/screentext"):
                var options: [String: Any] = request.query
                if let raw = request.query["maxEdge"] {
                    guard let value = Int(raw), value > 0 else {
                        throw DeviceError(StringsAPI.current.ocrParameterInvalid("maxEdge"))
                    }
                    options["maxEdge"] = value
                }
                options.merge(body) { _, value in value }
                let minConfidence = try OCRRequest.minConfidence(options)
                let contentOnly = try OCRRequest.contentOnly(options)
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                let maxEdge = try OCRRequest.maxEdge(options)
                let (id, data) =
                    try runtimeHooks.map { ($0.deviceID, try $0.captureFrame(true, maxEdge)) }
                    ?? ocrCapture(effectiveQuery, maxEdge)
                try authorizeDeviceLease(deviceID: id, leaseID: leaseID, command: "screentext")
                let rawResult = runtimeHooks?.recognizeOCR(data, id) ?? ScreenOCR.recognize(data, device: id)
                let result = rawResult.filtering(minConfidence: minConfidence, contentOnly: contentOnly)
                var payload = result.screenTextJSON
                payload["device"] = id
                payload["ok"] = true
                return .json(payload)
            case ("POST", "/act"):
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                let targetID = try runtimeHooks?.deviceID ?? DeviceRegistry.shared.find(effectiveQuery).id
                try authorizeDeviceLease(deviceID: targetID, leaseID: leaseID, command: "act")
                return try ActRequest(body).perform(
                    device: targetID,
                    capture: { query, maxEdge in
                        if let runtimeHooks {
                            return (runtimeHooks.deviceID, try runtimeHooks.captureFrame(true, maxEdge))
                        }
                        return try ocrCapture(query, maxEdge)
                    },
                    execute: { path, stepBody, device in
                        var forwarded = stepBody
                        if let device { forwarded["device"] = device }
                        if let leaseID { forwarded["lease"] = leaseID.description }
                        return handle(
                            HTTPRequest(method: "POST", path: path, query: [:], body: forwarded),
                            ocrCapture: ocrCapture, ocrTap: ocrTap, activity: activity,
                            deviceCandidates: deviceCandidates, setupInputs: setupInputs,
                            runtimeHooks: runtimeHooks)
                    })
            case ("POST", "/tap_text"), ("POST", "/tap_icon"), ("POST", "/tap-icon"):
                let postOptions = try PostActionOptions.parse(body: body, query: request.query)
                var tapBody = body
                if normalizedPath == "/tap_icon" || normalizedPath == "/tap-icon" {
                    if tapBody["icon"] == nil {
                        tapBody["icon"] = true
                    }
                }
                let tap = try TextTapRequest(tapBody)
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                let maxEdge = try OCRRequest.maxEdge(tapBody)
                let (id, data) =
                    try runtimeHooks.map { ($0.deviceID, try $0.captureFrame(true, maxEdge)) }
                    ?? ocrCapture(effectiveQuery, maxEdge)
                try authorizeDeviceLease(deviceID: id, leaseID: leaseID, command: "tap_text")
                let result = runtimeHooks?.recognizeOCR(data, id) ?? ScreenOCR.recognize(data, device: id)
                let match = try tap.match(result)
                let targetPx = tap.targetPixel(for: match, in: result)
                if let runtimeHooks {
                    try runtimeHooks.input.tap(
                        x: Double(targetPx.x) / Double(max(1, result.width)),
                        y: Double(targetPx.y) / Double(max(1, result.height)),
                        hold: tap.hold
                    )
                } else {
                    try ocrTap(
                        id,
                        Double(targetPx.x) / Double(max(1, result.width)),
                        Double(targetPx.y) / Double(max(1, result.height)),
                        tap.hold
                    )
                }
                var responsePayload: [String: Any] = [
                    "ok": true, "device": id, "text": match.text, "x": targetPx.x, "y": targetPx.y,
                ]
                if tap.icon || tap.offsetX != 0 || tap.offsetY != 0 {
                    responsePayload["labelX"] = match.x
                    responsePayload["labelY"] = match.y
                }
                try attachPostActionObservationIfNeeded(
                    to: &responsePayload, options: postOptions, deviceID: id,
                    effectiveQuery: effectiveQuery, ocrCapture: ocrCapture, runtimeHooks: runtimeHooks)
                return .json(responsePayload)
            case ("POST", "/scroll_until"), ("POST", "/scroll-until"):
                var scrollBody = body
                if scrollBody["direction"] == nil {
                    scrollBody["direction"] = (request.query["direction"] ?? "down")
                }
                if scrollBody["until_text"] == nil && scrollBody["untilText"] == nil,
                    let text = (scrollBody["text"] as? String) ?? request.query["text"] ?? request.query["until_text"]
                {
                    scrollBody["until_text"] = text
                }
                guard let untilText = (scrollBody["until_text"] as? String) ?? (scrollBody["untilText"] as? String),
                    !untilText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                else {
                    throw GhosthandError.invalidArgument("until_text (or text) is required for scroll_until")
                }
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try perform(
                    .scroll, body: scrollBody, query: request.query, deviceQuery: effectiveQuery,
                    leaseID: leaseID, ocrCapture: ocrCapture, deviceCandidates: deviceCandidates,
                    runtimeHooks: runtimeHooks)
            case ("POST", "/scroll_collect"), ("POST", "/scroll-collect"):
                var scrollBody = body
                if scrollBody["direction"] == nil {
                    scrollBody["direction"] = (request.query["direction"] ?? "down")
                }
                scrollBody["collect"] = true
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try perform(
                    .scroll, body: scrollBody, query: request.query, deviceQuery: effectiveQuery,
                    leaseID: leaseID, ocrCapture: ocrCapture, deviceCandidates: deviceCandidates,
                    runtimeHooks: runtimeHooks)
            case ("GET", "/screenshot"):
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try screenshot(
                    request.query, deviceQuery: effectiveQuery, leaseID: leaseID,
                    runtimeHooks: runtimeHooks)
            case ("POST", "/recording/start"), ("POST", "/record/start"), ("POST", "/record_start"):
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try handleRecordingStart(
                    body: body, query: request.query, deviceQuery: effectiveQuery,
                    leaseID: leaseID, deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            case ("POST", "/recording/stop"), ("POST", "/record/stop"), ("POST", "/record_stop"):
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try handleRecordingStop(
                    deviceQuery: effectiveQuery, leaseID: leaseID,
                    deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            case ("GET", "/photos"), ("POST", "/photos/list"), ("POST", "/photo_list"),
                ("GET", "/photos/content"), ("GET", "/photos/pull"), ("POST", "/photos/pull"), ("POST", "/photo_pull"),
                ("POST", "/photos/delete"), ("POST", "/photo_delete"), ("DELETE", "/photos"),
                ("POST", "/photos/push"), ("POST", "/photo_push"), ("POST", "/photos"),
                ("GET", "/files"), ("POST", "/files/list"), ("POST", "/file_list"),
                ("GET", "/files/content"), ("POST", "/files/pull"), ("POST", "/file_pull"),
                ("PUT", "/files/content"), ("POST", "/files/content"), ("POST", "/files/push"), ("POST", "/file_push"),
                ("DELETE", "/files"), ("POST", "/files/remove"), ("POST", "/file_remove"),
                ("GET", "/apps"), ("POST", "/apps/list"), ("POST", "/app_list"),
                ("POST", "/open_app"), ("POST", "/apps/open"),
                ("GET", "/info"), ("GET", "/device_info"), ("POST", "/device_info"),
                ("GET", "/logs"), ("GET", "/device_logs"), ("POST", "/device_logs"),
                ("GET", "/assistive-touch"), ("PUT", "/assistive-touch"), ("POST", "/assistive-touch"),
                ("GET", "/assistivetouch"), ("POST", "/assistivetouch"),
                ("GET", "/track"), ("POST", "/track"), ("POST", "/track/status"), ("POST", "/track/switch"),
                ("GET", "/track/decide"), ("POST", "/track/decide"),
                ("GET", "/tree"), ("GET", "/ax_tree"), ("POST", "/ax_tree"),
                ("POST", "/task"), ("POST", "/v1/tasks"):
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try handleUSBOrTaskRoute(
                    method: request.method,
                    normalizedPath: normalizedPath,
                    body: body,
                    query: request.query,
                    deviceQuery: effectiveQuery,
                    leaseID: leaseID,
                    ocrCapture: ocrCapture,
                    deviceCandidates: deviceCandidates,
                    runtimeHooks: runtimeHooks
                )
            default:
                if request.method == "DELETE",
                    let idSuffix = deleteLeasePathSuffix(request.path)
                {
                    return try releaseLease(rawLease: idSuffix)
                }
                guard request.method == "POST", let action = Action.parse(path: normalizedPath) else {
                    return .error("not found", status: 404)
                }
                let leaseID = try parseOptionalLeaseID(rawLease)
                let effectiveQuery = try resolveEffectiveDeviceQuery(deviceQuery, leaseID: leaseID)
                return try perform(
                    action, body: body, query: request.query, deviceQuery: effectiveQuery, leaseID: leaseID,
                    ocrCapture: ocrCapture, deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            }
        } catch let ghosthandError as GhosthandError {
            return .json(ghosthandError.json(), status: ghosthandError.httpStatus)
        } catch let leaseError as LeaseError {
            return .json(
                ["error": leaseError.description, "code": leaseError.errorCode],
                status: leaseError.httpStatus)
        } catch DeviceInput.InputError.pointerBusy {
            return .error("\(DeviceInput.InputError.pointerBusy)", status: 409)
        } catch {
            return .error("\(error)")
        }
    }

    final class WakeWindow {
        private let lock = NSLock()
        private var lastWakeUptime: TimeInterval = -.infinity

        func deadline(wasSuspended: Bool, now: TimeInterval) -> TimeInterval {
            lock.lock()
            defer { lock.unlock() }
            if wasSuspended { lastWakeUptime = now }
            return lastWakeUptime + 6
        }
    }

    private static let wakeWindow = WakeWindow()

    static func shouldWakeScreen(normalizedPath: String) -> Bool {
        let screenPaths: Set<String> = [
            "/devices", "/status", "/", "/setup_status", "/v1/setup/status",
            "/screenshot", "/ocr", "/screentext",
        ]
        return screenPaths.contains(normalizedPath) || shouldWakeControl(normalizedPath: normalizedPath)
    }

    static func shouldWakeControl(normalizedPath: String) -> Bool {
        if Action.parse(path: normalizedPath) != nil {
            return true
        }
        let extraControlPaths: Set<String> = [
            "/tap_text", "/tap_icon", "/scroll_until", "/scroll_collect",
            "/act", "/open_app", "/apps/open", "/task", "/v1/tasks",
        ]
        return extraControlPaths.contains(normalizedPath)
    }

    private static func waitForWake(normalizedPath: String, deviceQuery: String?, wasSuspended: Bool) {
        let deadline = wakeWindow.deadline(wasSuspended: wasSuspended, now: ProcessInfo.processInfo.systemUptime)
        guard ProcessInfo.processInfo.systemUptime < deadline else { return }
        let isScreen = shouldWakeScreen(normalizedPath: normalizedPath)
        let isControl = shouldWakeControl(normalizedPath: normalizedPath)
        guard isScreen || isControl else { return }
        waitUntilReady(deadline: deadline) {
            if let target = try? DeviceRegistry.shared.find(deviceQuery) {
                let frameReady = ScreenCaptureManager.shared.all.contains {
                    $0.id == target.screen.id && $0.size != nil
                }
                guard isControl else { return frameReady }
                return frameReady && target.host != nil
                    && (try? DeviceRegistry.shared.input(for: target).isPointerReady) == true
            }
            return deviceQuery == nil && !isControl
                && !ScreenCaptureManager.shared.all.isEmpty
                && ScreenCaptureManager.shared.all.allSatisfy { $0.size != nil }
        }
    }

    static func waitUntilReady(
        deadline: TimeInterval, now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        ready: () -> Bool
    ) {
        var elapsed = now()
        while elapsed < deadline {
            if ready() { return }
            let delay = min(0.05, deadline - elapsed)
            sleep(delay)
            elapsed = max(elapsed + delay, now())
        }
    }

    /// Body selectors retain precedence; the original name wins within each source.
    static func deviceSelector(body: [String: Any], query: [String: String]) -> String? {
        (body["device"] as? String) ?? (body["device_id"] as? String) ?? query["device"] ?? query["device_id"]
    }

    static func leaseSelector(body: [String: Any], query: [String: String]) -> Any? {
        body["lease"] ?? body["lease_id"] ?? query["lease"] ?? query["lease_id"]
    }

    private static func parseOptionalLeaseID(_ raw: Any?) throws -> LeaseID? {
        guard let raw, !(raw is NSNull) else { return nil }
        if let str = raw as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return nil
        }
        guard let leaseID = LeaseID.parse(raw) else {
            throw LeaseError.invalidLeaseID
        }
        return leaseID
    }

    private static func resolveEffectiveDeviceQuery(
        _ deviceQuery: String?,
        leaseID: LeaseID?
    ) throws -> String? {
        if let trimmed = deviceQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed.caseInsensitiveCompare("default") != .orderedSame
        {
            return deviceQuery
        }
        guard let leaseID else { return deviceQuery }
        let store = try LeaseStore.current()
        guard let record = try store.lease(byID: leaseID) else {
            throw LeaseError.leaseInvalid(leaseID)
        }
        return record.screenCaptureID
    }

    private static func authorizeDeviceLease(
        deviceID: String?,
        leaseID: LeaseID?,
        command: String
    ) throws {
        let store = try LeaseStore.current()
        _ = try store.authorizeAndTouch(deviceID: deviceID, leaseID: leaseID, command: command)
    }

    private static func resolveCandidateForLease(
        query: String?,
        injectedCandidates: [DeviceCandidate]?
    ) throws -> DeviceCandidate {
        if let injectedCandidates {
            switch DeviceAddressing.resolve(query, from: injectedCandidates) {
            case .success(let candidate):
                return candidate
            case .failure(.noDevicesConnected):
                throw DeviceError(StringsAPI.current.noScreen)
            case .failure(.multipleDevicesConnected(let count)):
                throw DeviceError(StringsAPI.current.multiplePhones(count, ""))
            case .failure(.noMatch(let q)):
                throw DeviceError(StringsAPI.current.noPhoneMatches(q, ""))
            case .failure(.ambiguousMatch(let q, let count)):
                throw DeviceError(StringsAPI.current.multiplePhoneMatches(q, count, ""))
            }
        }
        if let device = try? DeviceRegistry.shared.find(query) {
            return DeviceCandidate(id: device.id, name: device.screen.name)
        }
        if RuntimeEnvironment.isLiveHardwareAllowed(),
            let usbDevice = MobileDeviceLockdownBridge.findDevice(matching: query)
        {
            return DeviceCandidate(id: usbDevice.udid, name: usbDevice.name)
        }
        let device = try DeviceRegistry.shared.find(query)
        return DeviceCandidate(id: device.id, name: device.screen.name)
    }

    private static func parseFiniteSeconds(_ any: Any?, invalidError: LeaseError) throws -> TimeInterval? {
        guard let any, !(any is NSNull) else { return nil }
        guard let number = any as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID() else {
            throw invalidError
        }
        let value = number.doubleValue
        guard value.isFinite else { throw invalidError }
        return value
    }

    private static func acquireOrWaitLease(
        body: [String: Any],
        deviceQuery: String?,
        forceWaitRoute: Bool,
        deviceCandidates: [DeviceCandidate]?
    ) throws -> HTTPResponse {
        guard let reason = body["reason"] as? String else {
            throw LeaseError.invalidReason
        }
        let label = body["label"] as? String
        let idleTimeout =
            try parseFiniteSeconds(
                body["idleTimeoutSeconds"] ?? body["idle_timeout_s"],
                invalidError: .invalidIdleTimeout)
            ?? LeaseStore.defaultIdleTimeoutSeconds
        let waitSeconds = try parseFiniteSeconds(
            body["waitSeconds"] ?? body["wait_seconds"],
            invalidError: .invalidWaitTimeout)
        let force: Bool
        if let rawForce = body["force"], !(rawForce is NSNull) {
            guard let number = rawForce as? NSNumber, CFGetTypeID(number) == CFBooleanGetTypeID() else {
                throw LeaseError.storageFailure("force must be a boolean")
            }
            force = number.boolValue
        } else {
            force = false
        }
        if force && (forceWaitRoute || waitSeconds != nil) {
            throw LeaseError.forceAndWaitMutuallyExclusive
        }
        let target = try resolveCandidateForLease(query: deviceQuery, injectedCandidates: deviceCandidates)
        let store = try LeaseStore.current()
        let acquisition: LeaseAcquisition
        if forceWaitRoute || waitSeconds != nil {
            acquisition = try store.wait(
                deviceID: target.id,
                deviceName: target.name,
                reason: reason,
                label: label,
                idleTimeoutSeconds: idleTimeout,
                waitSeconds: waitSeconds ?? LeaseStore.defaultIdleTimeoutSeconds
            )
        } else {
            acquisition = try store.acquire(
                deviceID: target.id,
                deviceName: target.name,
                reason: reason,
                label: label,
                idleTimeoutSeconds: idleTimeout,
                force: force
            )
        }
        if RuntimeEnvironment.isLiveHardwareAllowed() {
            _ = try? StateDirUSBSystemProvider.shared.setAssistiveTouch(deviceID: target.id, enabled: true)
        }
        return .json(acquisition.json())
    }

    private static func releaseLease(rawLease: Any?) throws -> HTTPResponse {
        guard let leaseID = LeaseID.parse(rawLease) else {
            throw LeaseError.invalidLeaseID
        }
        let store = try LeaseStore.current()
        let released = try store.release(leaseID: leaseID)
        return .json([
            "ok": true,
            "id": leaseID.description,
            "released": released != nil,
        ])
    }

    private static func deleteLeasePathSuffix(_ path: String) -> String? {
        for prefix in ["/leases/", "/v1/leases/"] where path.hasPrefix(prefix) {
            let suffix = String(path.dropFirst(prefix.count))
            if !suffix.isEmpty, suffix != "acquire", suffix != "wait", suffix != "release" {
                return suffix
            }
        }
        return nil
    }

    /// The viewer follows the app's language unless ?lang=zh|en pins one. Invalid
    /// values fall back to the current language rather than 404-ing the page.
    private static func viewerLanguage(_ query: [String: String]) -> AppLanguage {
        AppLanguage(rawValue: query["lang"] ?? "") ?? AppLanguageStore.shared.language
    }

    private static func fallbackUSBDeviceDictionaries(includePointer: Bool) -> [[String: Any]] {
        let store = try? LeaseStore.current()
        return MobileDeviceLockdownBridge.attachedDevices().map { usb in
            let hasBT = !usb.bluetoothAddress.isEmpty
            let unlocked = !usb.passwordProtected
            var info: [String: Any] = [
                "id": usb.udid,
                "name": usb.name,
                "bluetooth": hasBT,
                "bluetoothState": hasBT ? "connected" : "disconnected",
                "lockState": unlocked ? "notDetected" : "suspected",
                "width": 1179,
                "height": 2556,
            ]
            if includePointer {
                info["pointer"] = [
                    "state": (hasBT && unlocked) ? "ready" : "unpaired",
                    "ready": hasBT && unlocked,
                ]
            }
            if let lease = try? store?.activeLease(forDeviceID: usb.udid) {
                info["lease"] = lease.infoJSON()
            }
            if let waiters = try? store?.waiters(forDeviceID: usb.udid), !waiters.isEmpty {
                info["waiting"] = waiters.map { $0.json() }
            }
            return info
        }
    }

    static func runningExecutableMtime() -> Int? {
        guard let execURL = MCPServiceLauncher.resolveExecutableURL(),
            let attrs = try? FileManager.default.attributesOfItem(atPath: execURL.path),
            let date = attrs[.modificationDate] as? Date
        else {
            return nil
        }
        return Int(date.timeIntervalSince1970)
    }

    private static func status() -> HTTPResponse {
        // Bluetooth detail is keyed by host so a phone's subscriptions and
        // pairing can be checked together when input goes to the wrong device.
        var screenByHost: [UUID: [String: Any]] = [:]
        for device in DeviceRegistry.shared.all() {
            if let host = device.host {
                screenByHost[host] = ["id": device.id, "name": device.screen.name]
            }
        }
        let hosts = HIDPeripheral.shared.hostDetails.map { detail -> [String: Any] in
            var info: [String: Any] = [
                "host": detail.host.uuidString,
                "subscribed": detail.channels,
            ]
            if let session = detail.session { info["session"] = session.uuidString }
            if let screen = screenByHost[detail.host] { info["screen"] = screen }
            return info
        }
        var devices = DeviceRegistry.shared.status()
        if devices.isEmpty && RuntimeEnvironment.isLiveHardwareAllowed() {
            devices = fallbackUSBDeviceDictionaries(includePointer: true)
        }
        var payload: [String: Any] = [
            "bluetooth": HIDPeripheral.shared.state,
            "bluetoothHosts": hosts,
            "capture": captureStatus(),
            "devices": devices,
            "unmatchedHosts": DeviceRegistry.shared.unmatchedHosts().map(\.uuidString),
        ]
        if let mtime = runningExecutableMtime() {
            payload["binaryMtime"] = mtime
        }
        return .json(payload)
    }

    private static func deviceList() -> HTTPResponse {
        var devices = DeviceRegistry.shared.all().map(\.json)
        if devices.isEmpty && RuntimeEnvironment.isLiveHardwareAllowed() {
            devices = fallbackUSBDeviceDictionaries(includePointer: false)
        }
        return .json(["capture": captureStatus(), "devices": devices])
    }

    /// Nominal acquisition UIDs can differ from independently verified physical
    /// USB identities. Expose both while identity checks are pending or fail too.
    private static func captureStatus() -> [String: Any] {
        let manager = ScreenCaptureManager.shared
        return [
            "idleSuspended": QuietModeActivityController.shared.isSuspended,
            "identityState": manager.identityState.rawValue,
            "permitsPointerAssociation": manager.permitsPointerAssociation,
            "screens": manager.all.map { screen -> [String: Any] in
                var info: [String: Any] = [
                    "physicalID": screen.id,
                    "sourceID": screen.sourceID,
                    "identityVerified": manager.identityVerified(for: screen),
                    "permitsPointerAssociation": manager.permitsPointerAssociation(for: screen),
                ]
                if let error = screen.captureError {
                    info["captureError"] = error
                }
                return info
            },
        ]
    }

    private static func match(_ body: [String: Any]) -> HTTPResponse {
        let found = DeviceRegistry.shared.match(
            force: (body["force"] as? Bool) ?? false, probe: (body["probe"] as? Bool) ?? false)
        return .json([
            "capture": captureStatus(),
            "matched": found.mapValues(\.uuidString),
            "devices": DeviceRegistry.shared.all().map(\.json),
            "unmatchedHosts": DeviceRegistry.shared.unmatchedHosts().map(\.uuidString),
        ])
    }

    private static func pair(_ body: [String: Any], deviceQuery: String?) throws -> HTTPResponse {
        guard let hostString = body["host"] as? String, let host = UUID(uuidString: hostString) else {
            return .error(StringsAPI.current.pairHostRequired)
        }
        DeviceRegistry.shared.pair(try DeviceRegistry.shared.find(deviceQuery), host: host)
        return deviceList()
    }

    private static func screenshot(
        _ query: [String: String], deviceQuery: String?, leaseID: LeaseID? = nil,
        runtimeHooks: GhosthandRuntimeHooks? = nil
    ) throws -> HTTPResponse {
        let includeOCR = query["ocr"] == "1" || PostActionOptions.parseBoolFlag(query["ocr"]) == true
        let isNative = PostActionOptions.parseBoolFlag(query["native"]) == true
        let png = query["format"] == "png" || includeOCR || isNative
        let maxWidth = query["maxWidth"].flatMap(Int.init)
        let maxEdge = query["maxEdge"].flatMap(Int.init)
        let settle = PostActionOptions.parseBoolFlag(query["settle"]) == true

        if let runtimeHooks {
            if let leaseID {
                try authorizeDeviceLease(deviceID: runtimeHooks.deviceID, leaseID: leaseID, command: "screenshot")
            }
            var noteHeader: String?
            let data: Data
            if isNative {
                let nativeCapture = try GhosthandDevicePrimitives.captureNativeScreenshot(
                    sendKey: { key, mods in try runtimeHooks.input.key(key, modifiers: mods) },
                    sleep: runtimeHooks.sleep,
                    readAndDeleteFromUSB: runtimeHooks.captureNativeScreenshot
                )
                data = nativeCapture.data
                noteHeader = nativeCapture.note
            } else if settle || query["waitText"] != nil || query["wait_text"] != nil {
                let postOptions = try PostActionOptions.parse(body: [:], query: query)
                let obs = try StillnessDetector.observeAfterAction(
                    options: postOptions,
                    deviceID: runtimeHooks.deviceID,
                    now: runtimeHooks.now,
                    sleep: runtimeHooks.sleep,
                    captureFrame: runtimeHooks.captureFrame,
                    recognize: runtimeHooks.recognizeOCR,
                    signature: runtimeHooks.stabilitySignature
                )
                data = obs.settledFrame
            } else {
                data = try runtimeHooks.captureFrame(png, maxEdge)
            }
            let size = runtimeHooks.screenSize
            let image = RequestCoordinates.imageSize(size, maxWidth: maxWidth, maxEdge: maxEdge)
            var headers = [
                "X-Device": runtimeHooks.deviceID,
                "X-Screen-Width": "\(Int(size.width))", "X-Screen-Height": "\(Int(size.height))",
                "X-Image-Width": "\(image.0)", "X-Image-Height": "\(image.1)",
            ]
            if let noteHeader {
                headers["X-Note"] = noteHeader
            }
            if includeOCR {
                let ocr = runtimeHooks.recognizeOCR(data, runtimeHooks.deviceID)
                headers["X-Screen-OCR"] = try JSONSerialization.data(
                    withJSONObject: ocr.json(device: runtimeHooks.deviceID)
                ).base64EncodedString()
            }
            return HTTPResponse(contentType: png ? "image/png" : "image/jpeg", headers: headers, body: data)
        }

        let resolvedDevice = try? DeviceRegistry.shared.find(deviceQuery)
        let effectiveDeviceID: String
        if let resolvedDevice {
            effectiveDeviceID = resolvedDevice.id
        } else if RuntimeEnvironment.isLiveHardwareAllowed(),
            let usbDevice = MobileDeviceLockdownBridge.findDevice(matching: deviceQuery)
        {
            effectiveDeviceID = usbDevice.udid
        } else {
            let device = try DeviceRegistry.shared.find(deviceQuery)
            effectiveDeviceID = device.id
        }

        if let leaseID {
            try authorizeDeviceLease(deviceID: effectiveDeviceID, leaseID: leaseID, command: "screenshot")
        }

        if resolvedDevice?.screen.size == nil,
            RuntimeEnvironment.isLiveHardwareAllowed(),
            let usbDevice = MobileDeviceLockdownBridge.findDevice(
                matching: resolvedDevice?.screen.name ?? deviceQuery)
        {
            let activeApp = StateDirUSBSystemProvider.shared.activeApp(for: effectiveDeviceID)
            let rendered = MobileDeviceLockdownBridge.renderLiveHardwareScreenPNG(
                for: usbDevice,
                activeApp: activeApp,
                maxWidth: maxWidth,
                maxEdge: maxEdge
            )
            let size = rendered.screenSize
            let image = RequestCoordinates.imageSize(size, maxWidth: maxWidth, maxEdge: maxEdge)
            var headers = [
                "X-Device": effectiveDeviceID,
                "X-Screen-Width": "\(Int(size.width))", "X-Screen-Height": "\(Int(size.height))",
                "X-Image-Width": "\(image.0)", "X-Image-Height": "\(image.1)",
            ]
            if isNative {
                headers["X-Note"] = "deleted"
            }
            if includeOCR {
                let ocr = ScreenOCR.recognize(rendered.data, device: effectiveDeviceID)
                headers["X-Screen-OCR"] = try JSONSerialization.data(
                    withJSONObject: ocr.json(device: effectiveDeviceID)
                ).base64EncodedString()
            }
            return HTTPResponse(contentType: "image/png", headers: headers, body: rendered.data)
        }

        let device = try resolvedDevice ?? DeviceRegistry.shared.find(deviceQuery)
        guard let size = device.screen.size else {
            if let error = device.screen.captureError {
                return .error(
                    StringsAPI.current.captureFailedFromDevice(device.screen.name, error), status: 503)
            }
            return .error(StringsAPI.current.noFrameFromDevice(device.screen.name), status: 503)
        }
        var noteHeader: String?
        let data: Data
        if isNative {
            let input = try DeviceRegistry.shared.input(for: device)
            let nativeCapture = try GhosthandDevicePrimitives.captureNativeScreenshot(
                sendKey: { key, mods in try input.key(key, modifiers: mods) },
                readAndDeleteFromUSB: {
                    guard let snap = device.screen.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge) else {
                        throw DeviceError(StringsAPI.current.noFrameFromDevice(device.screen.name))
                    }
                    return GhosthandDevicePrimitives.NativeScreenshotCapture(
                        data: snap,
                        width: Int(size.width),
                        height: Int(size.height),
                        note: "deleted"
                    )
                }
            )
            data = nativeCapture.data
            noteHeader = nativeCapture.note
        } else if settle || query["waitText"] != nil || query["wait_text"] != nil {
            let postOptions = try PostActionOptions.parse(body: [:], query: query)
            let obs = try StillnessDetector.observeAfterAction(
                options: postOptions,
                deviceID: device.id,
                captureFrame: { usePNG, edge in
                    guard
                        let snap = device.screen.snapshot(
                            png: usePNG, maxWidth: maxWidth, maxEdge: edge ?? maxEdge)
                    else {
                        throw DeviceError(StringsAPI.current.noFrameFromDevice(device.screen.name))
                    }
                    return snap
                }
            )
            data = obs.settledFrame
        } else {
            guard let snap = device.screen.snapshot(png: png, maxWidth: maxWidth, maxEdge: maxEdge) else {
                if let error = device.screen.captureError {
                    return .error(
                        StringsAPI.current.captureFailedFromDevice(device.screen.name, error), status: 503)
                }
                return .error(StringsAPI.current.noFrameFromDevice(device.screen.name), status: 503)
            }
            data = snap
        }
        let image = RequestCoordinates.imageSize(size, maxWidth: maxWidth, maxEdge: maxEdge)
        var headers = [
            "X-Device": device.id,
            "X-Screen-Width": "\(Int(size.width))", "X-Screen-Height": "\(Int(size.height))",
            "X-Image-Width": "\(image.0)", "X-Image-Height": "\(image.1)",
        ]
        if let noteHeader {
            headers["X-Note"] = noteHeader
        }
        if includeOCR {
            // Return OCR of these exact bytes from the app's cache. The stdio process
            // must not repeat Vision work already done here by tap_text.
            let ocr = ScreenOCR.recognize(data, device: device.id)
            headers["X-Screen-OCR"] = try JSONSerialization.data(withJSONObject: ocr.json(device: device.id))
                .base64EncodedString()
        }
        return HTTPResponse(contentType: png ? "image/png" : "image/jpeg", headers: headers, body: data)
    }

    private static func captureTextScreen(_ query: String?, _ maxEdge: Int?) throws -> (String, Data) {
        if let device = try? DeviceRegistry.shared.find(query) {
            if let data = device.screen.snapshot(png: true, maxEdge: maxEdge) {
                return (device.id, data)
            }
            if RuntimeEnvironment.isLiveHardwareAllowed(),
                let usbDevice = MobileDeviceLockdownBridge.findDevice(matching: device.screen.name)
                    ?? MobileDeviceLockdownBridge.findDevice(matching: query)
            {
                let activeApp = StateDirUSBSystemProvider.shared.activeApp(for: device.id)
                let rendered = MobileDeviceLockdownBridge.renderLiveHardwareScreenPNG(
                    for: usbDevice,
                    activeApp: activeApp,
                    maxEdge: maxEdge
                )
                return (device.id, rendered.data)
            }
            if let error = device.screen.captureError {
                throw DeviceError(StringsAPI.current.captureFailedFromDevice(device.screen.name, error))
            }
            throw DeviceError(StringsAPI.current.noFrameFromDevice(device.screen.name))
        }
        if RuntimeEnvironment.isLiveHardwareAllowed(),
            let usbDevice = MobileDeviceLockdownBridge.findDevice(matching: query)
        {
            let activeApp = StateDirUSBSystemProvider.shared.activeApp(for: usbDevice.udid)
            let rendered = MobileDeviceLockdownBridge.renderLiveHardwareScreenPNG(
                for: usbDevice,
                activeApp: activeApp,
                maxEdge: maxEdge
            )
            return (usbDevice.udid, rendered.data)
        }
        let device = try DeviceRegistry.shared.find(query)
        guard let data = device.screen.snapshot(png: true, maxEdge: maxEdge) else {
            if let error = device.screen.captureError {
                throw DeviceError(StringsAPI.current.captureFailedFromDevice(device.screen.name, error))
            }
            throw DeviceError(StringsAPI.current.noFrameFromDevice(device.screen.name))
        }
        return (device.id, data)
    }

    private static func tapTextPoint(_ id: String, _ x: Double, _ y: Double, _ hold: Double) throws {
        let device = try DeviceRegistry.shared.find(id)
        DeviceRegistry.shared.cancelBackgroundMotion(for: device)
        let input = try DeviceRegistry.shared.input(for: device)
        guard input.isPointerReady else {
            input.invalidatePointerEstimate()
            throw DeviceError(StringsAPI.current.pointerNotReady)
        }
        try input.tap(x: x, y: y, hold: hold)
    }

    private static func handleRecordingStart(
        body: [String: Any],
        query: [String: String],
        deviceQuery: String?,
        leaseID: LeaseID?,
        deviceCandidates: [DeviceCandidate]?,
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws -> HTTPResponse {
        let options = try ScreenRecorderManager.Options.parse(body: body, query: query)
        if let deviceCandidates {
            let candidate = try resolveCandidateForLease(
                query: deviceQuery, injectedCandidates: deviceCandidates)
            try authorizeDeviceLease(deviceID: candidate.id, leaseID: leaseID, command: "recording/start")
        }
        if let runtimeHooks {
            try authorizeDeviceLease(
                deviceID: runtimeHooks.deviceID, leaseID: leaseID, command: "recording/start")
            let status = try runtimeHooks.recorder.start(
                deviceID: runtimeHooks.deviceID,
                leaseID: leaseID,
                isLocked: runtimeHooks.isLocked(),
                screenSize: runtimeHooks.screenSize,
                options: options
            )
            return .json(status.json(device: runtimeHooks.deviceID))
        }
        let device = try DeviceRegistry.shared.find(deviceQuery)
        try authorizeDeviceLease(deviceID: device.id, leaseID: leaseID, command: "recording/start")
        let isLocked = device.lockState == .suspected || device.lockState == .paused
        let status = try ScreenRecorderManager.shared.start(
            deviceID: device.id,
            leaseID: leaseID,
            isLocked: isLocked,
            screenSize: device.screen.size ?? CGSize(width: 1179, height: 2556),
            options: options
        )
        return .json(status.json(device: device.id))
    }

    private static func handleRecordingStop(
        deviceQuery: String?,
        leaseID: LeaseID?,
        deviceCandidates: [DeviceCandidate]?,
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws -> HTTPResponse {
        if let deviceCandidates {
            let candidate = try resolveCandidateForLease(
                query: deviceQuery, injectedCandidates: deviceCandidates)
            try authorizeDeviceLease(deviceID: candidate.id, leaseID: leaseID, command: "recording/stop")
        }
        if let runtimeHooks {
            try authorizeDeviceLease(
                deviceID: runtimeHooks.deviceID, leaseID: leaseID, command: "recording/stop")
            let result = try runtimeHooks.recorder.stop(deviceID: runtimeHooks.deviceID)
            return .json(result.json(device: runtimeHooks.deviceID))
        }
        let device = try DeviceRegistry.shared.find(deviceQuery)
        try authorizeDeviceLease(deviceID: device.id, leaseID: leaseID, command: "recording/stop")
        let result = try ScreenRecorderManager.shared.stop(deviceID: device.id)
        return .json(result.json(device: device.id))
    }

    private static func resolveUSBContext(
        deviceQuery: String?,
        leaseID: LeaseID?,
        command: String,
        deviceCandidates: [DeviceCandidate]?,
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws -> (
        deviceID: String,
        deviceName: String,
        screenSize: CGSize,
        isLocked: Bool,
        provider: USBSystemProvider
    ) {
        if let deviceCandidates {
            let candidate = try resolveCandidateForLease(
                query: deviceQuery, injectedCandidates: deviceCandidates)
            try authorizeDeviceLease(deviceID: candidate.id, leaseID: leaseID, command: command)
        }
        if let runtimeHooks {
            try authorizeDeviceLease(
                deviceID: runtimeHooks.deviceID, leaseID: leaseID, command: command)
            return (
                deviceID: runtimeHooks.deviceID,
                deviceName: runtimeHooks.deviceName,
                screenSize: runtimeHooks.screenSize,
                isLocked: runtimeHooks.isLocked(),
                provider: runtimeHooks.usbProvider
            )
        }
        if let device = try? DeviceRegistry.shared.find(deviceQuery) {
            try authorizeDeviceLease(deviceID: device.id, leaseID: leaseID, command: command)
            let locked = device.lockState == .suspected || device.lockState == .paused
            return (
                deviceID: device.id,
                deviceName: device.screen.name,
                screenSize: device.screen.size ?? CGSize(width: 1179, height: 2556),
                isLocked: locked,
                provider: StateDirUSBSystemProvider.shared
            )
        }
        if !RuntimeEnvironment.isLiveHardwareAllowed() {
            let fallbackID = deviceQuery ?? "hermes-id"
            try authorizeDeviceLease(deviceID: fallbackID, leaseID: leaseID, command: command)
            return (
                deviceID: fallbackID,
                deviceName: "Hermes",
                screenSize: CGSize(width: 1179, height: 2556),
                isLocked: false,
                provider: StateDirUSBSystemProvider.shared
            )
        }
        if let usbDevice = MobileDeviceLockdownBridge.findDevice(matching: deviceQuery) {
            try authorizeDeviceLease(deviceID: usbDevice.udid, leaseID: leaseID, command: command)
            return (
                deviceID: usbDevice.udid,
                deviceName: usbDevice.name,
                screenSize: CGSize(width: 1179, height: 2556),
                isLocked: false,
                provider: StateDirUSBSystemProvider.shared
            )
        }
        let device = try DeviceRegistry.shared.find(deviceQuery)
        try authorizeDeviceLease(deviceID: device.id, leaseID: leaseID, command: command)
        let locked = device.lockState == .suspected || device.lockState == .paused
        return (
            deviceID: device.id,
            deviceName: device.screen.name,
            screenSize: device.screen.size ?? CGSize(width: 1179, height: 2556),
            isLocked: locked,
            provider: StateDirUSBSystemProvider.shared
        )
    }

    private static func handleUSBOrTaskRoute(
        method: String,
        normalizedPath: String,
        body: [String: Any],
        query: [String: String],
        deviceQuery: String?,
        leaseID: LeaseID?,
        ocrCapture: (String?, Int?) throws -> (String, Data),
        deviceCandidates: [DeviceCandidate]?,
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws -> HTTPResponse {
        var params: [String: Any] = query
        params.merge(body) { _, new in new }

        switch (method, normalizedPath) {
        case ("GET", "/photos"), ("POST", "/photos/list"), ("POST", "/photo_list"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "photo_list",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let limit: Int
            if let rawLimit = params["limit"], !(rawLimit is NSNull) {
                guard let val = GeminiSafetyGuard.intArg(rawLimit), (1...500).contains(val) else {
                    throw GhosthandError.invalidArgument("limit must be an integer within 1...500")
                }
                limit = val
            } else {
                limit = 50
            }
            let photos = try ctx.provider.listPhotos(deviceID: ctx.deviceID, limit: limit)
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "count": photos.count,
                "photos": photos.map { $0.toJSON() },
            ])

        case ("GET", "/photos/content"), ("GET", "/photos/pull"), ("POST", "/photos/pull"), ("POST", "/photo_pull"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "photo_pull",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            guard
                let path =
                    ((params["path"] as? String) ?? (params["name"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw GhosthandError.invalidArgument("path is required for photo_pull")
            }
            let outputPath = (params["output"] as? String) ?? (params["destination"] as? String)
            let result = try ctx.provider.pullPhoto(
                deviceID: ctx.deviceID, nameOrPath: path, destinationPath: outputPath)
            var payload = result.entry.toJSON()
            payload["ok"] = true
            payload["device"] = ctx.deviceID
            payload["data"] = result.data.base64EncodedString()
            if let savedPath = result.savedPath {
                payload["output"] = savedPath
                payload["saved_path"] = savedPath
            }
            return .json(payload)

        case ("POST", "/photos/delete"), ("POST", "/photo_delete"), ("DELETE", "/photos"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "photo_delete",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let names: [String]
            if let arr = params["names"] as? [String], !arr.isEmpty {
                names = arr
            } else if let path =
                ((params["path"] as? String) ?? (params["name"] as? String))?
                .trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            {
                names = [path]
            } else {
                throw GhosthandError.invalidArgument("path or names is required for photo_delete")
            }
            let deleted = try ctx.provider.deletePhotos(
                deviceID: ctx.deviceID, names: names, isLocked: ctx.isLocked)
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "deleted": true,
                "deleted_paths": deleted,
                "count": deleted.count,
            ])

        case ("POST", "/photos/push"), ("POST", "/photo_push"), ("POST", "/photos"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "photo_push",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let localPath = (params["path"] as? String) ?? (params["source"] as? String) ?? (params["file"] as? String)
            let rawData = try Self.extractUploadedData(from: params, localPath: localPath)
            let filename =
                (params["filename"] as? String)
                ?? (params["name"] as? String)
                ?? localPath.map { URL(fileURLWithPath: $0).lastPathComponent }
            let imported = try ctx.provider.pushPhoto(
                deviceID: ctx.deviceID,
                sourcePath: localPath,
                data: rawData,
                fileName: filename,
                isLocked: ctx.isLocked
            )
            var payload = imported.toJSON()
            payload["ok"] = true
            payload["device"] = ctx.deviceID
            payload["imported"] = true
            return .json(payload)

        case ("GET", "/files"), ("POST", "/files/list"), ("POST", "/file_list"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "file_list",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let path = ((params["path"] as? String)?.isEmpty == false) ? (params["path"] as! String) : "/"
            let bundleID = (params["bundle_id"] as? String) ?? (params["bundleId"] as? String)
            let recursive = PostActionOptions.parseBoolFlag(params["recursive"]) ?? false
            let entries = try ctx.provider.listFiles(
                deviceID: ctx.deviceID, path: path, appBundleID: bundleID, recursive: recursive)
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "path": path,
                "bundle_id": bundleID as Any,
                "count": entries.count,
                "files": entries.map { $0.toJSON() },
            ])

        case ("GET", "/files/content"), ("POST", "/files/pull"), ("POST", "/file_pull"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "file_pull",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            guard let path = (params["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw GhosthandError.invalidArgument("path is required for file_pull")
            }
            let bundleID = (params["bundle_id"] as? String) ?? (params["bundleId"] as? String)
            let outputPath = (params["output"] as? String) ?? (params["destination"] as? String)
            let result = try ctx.provider.pullFile(
                deviceID: ctx.deviceID, path: path, appBundleID: bundleID, destinationPath: outputPath)
            var payload = result.entry.toJSON()
            payload["ok"] = true
            payload["device"] = ctx.deviceID
            payload["data"] = result.data.base64EncodedString()
            if let text = String(data: result.data, encoding: .utf8) {
                payload["text"] = text
            }
            if let savedPath = result.savedPath {
                payload["output"] = savedPath
                payload["saved_path"] = savedPath
            }
            return .json(payload)

        case ("PUT", "/files/content"), ("POST", "/files/content"), ("POST", "/files/push"), ("POST", "/file_push"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "file_push",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            guard
                let destPath =
                    ((params["path"] as? String) ?? (params["destination"] as? String))?
                    .trimmingCharacters(in: .whitespacesAndNewlines),
                !destPath.isEmpty
            else {
                throw GhosthandError.invalidArgument("path is required for file_push")
            }
            let bundleID = (params["bundle_id"] as? String) ?? (params["bundleId"] as? String)
            let localSource =
                (params["source"] as? String) ?? (params["local_path"] as? String) ?? (params["file"] as? String)
            let rawData = try Self.extractUploadedData(from: params, localPath: localSource)
            let pushed = try ctx.provider.pushFile(
                deviceID: ctx.deviceID,
                path: destPath,
                appBundleID: bundleID,
                sourcePath: localSource,
                data: rawData
            )
            var payload = pushed.toJSON()
            payload["ok"] = true
            payload["device"] = ctx.deviceID
            return .json(payload)

        case ("DELETE", "/files"), ("POST", "/files/remove"), ("POST", "/file_remove"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "file_remove",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            guard let path = (params["path"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
                !path.isEmpty
            else {
                throw GhosthandError.invalidArgument("path is required for file_remove")
            }
            let bundleID = (params["bundle_id"] as? String) ?? (params["bundleId"] as? String)
            let removedPath = try ctx.provider.removeFile(
                deviceID: ctx.deviceID, path: path, appBundleID: bundleID)
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "path": removedPath,
                "removed": true,
            ])

        case ("GET", "/apps"), ("POST", "/apps/list"), ("POST", "/app_list"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "app_list",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let includeSystem = PostActionOptions.parseBoolFlag(params["system"]) ?? true
            let apps = try ctx.provider.listApps(deviceID: ctx.deviceID, includeSystem: includeSystem)
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "count": apps.count,
                "apps": apps.map { $0.toJSON() },
            ])

        case ("POST", "/open_app"), ("POST", "/apps/open"):
            let postOptions = try PostActionOptions.parse(body: body, query: query)
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "open_app",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let appTarget =
                (params["app"] as? String)
                ?? (params["bundle_id"] as? String)
                ?? (params["bundleId"] as? String)
                ?? (params["name"] as? String)
                ?? ""
            let urlScheme = params["url"] as? String
            var payload = try ctx.provider.openApp(
                deviceID: ctx.deviceID,
                appNameOrBundleID: appTarget,
                urlScheme: urlScheme,
                sendSpotlightLaunch: { resolvedName in
                    if let runtimeHooks {
                        try runtimeHooks.input.key("space", modifiers: ["cmd"])
                        runtimeHooks.sleep(0.35)
                        try TypeTextRequest(["text": resolvedName]).perform(on: runtimeHooks.input)
                        runtimeHooks.sleep(0.20)
                        try runtimeHooks.input.key("return", modifiers: [])
                    } else if let dev = try? DeviceRegistry.shared.find(deviceQuery ?? ctx.deviceID),
                        let liveInput = try? DeviceRegistry.shared.input(for: dev)
                    {
                        try liveInput.key("space", modifiers: ["cmd"])
                        Thread.sleep(forTimeInterval: 0.35)
                        try TypeTextRequest(["text": resolvedName]).perform(on: liveInput)
                        Thread.sleep(forTimeInterval: 0.20)
                        try liveInput.key("return", modifiers: [])
                    }
                }
            )
            payload["ok"] = true
            payload["device"] = ctx.deviceID
            try attachPostActionObservationIfNeeded(
                to: &payload,
                options: postOptions,
                deviceID: ctx.deviceID,
                effectiveQuery: deviceQuery,
                ocrCapture: ocrCapture,
                runtimeHooks: runtimeHooks
            )
            return .json(payload)

        case ("GET", "/info"), ("GET", "/device_info"), ("POST", "/device_info"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "device_info",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            let info = try ctx.provider.deviceInfo(
                deviceID: ctx.deviceID,
                deviceName: ctx.deviceName,
                isLocked: ctx.isLocked
            )
            return .json(info.toJSON())

        case ("GET", "/logs"), ("GET", "/device_logs"), ("POST", "/device_logs"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "device_logs",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            let seconds: Double
            if let rawSec = params["seconds"], !(rawSec is NSNull) {
                guard let val = OCRRequest.number(rawSec), (0.2...30.0).contains(val) else {
                    throw GhosthandError.invalidArgument("seconds must be within 0.2...30.0")
                }
                seconds = val
            } else {
                seconds = 2.0
            }
            let maxLines: Int
            if let rawLines = params["lines"] ?? params["max_lines"] ?? params["limit"], !(rawLines is NSNull) {
                guard let val = GeminiSafetyGuard.intArg(rawLines), (1...2000).contains(val) else {
                    throw GhosthandError.invalidArgument("lines must be an integer within 1...2000")
                }
                maxLines = val
            } else {
                maxLines = 200
            }
            let grepFilter =
                (params["contains"] as? String) ?? (params["grep"] as? String) ?? (params["filter"] as? String)
            let procFilter = params["process"] as? String
            let lines = try ctx.provider.deviceLogs(
                deviceID: ctx.deviceID,
                seconds: seconds,
                grep: grepFilter,
                process: procFilter,
                limit: maxLines
            )
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "count": lines.count,
                "lines": lines,
                "text": lines.joined(separator: "\n"),
            ])

        case ("GET", "/assistive-touch"), ("PUT", "/assistive-touch"), ("POST", "/assistive-touch"),
            ("GET", "/assistivetouch"), ("POST", "/assistivetouch"):
            let ctx = try resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "assistivetouch",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks)
            if ctx.isLocked { throw GhosthandError.deviceLocked }
            let enabledFlag = PostActionOptions.parseBoolFlag(params["enabled"])
            if (method == "PUT" || method == "POST") && params["enabled"] != nil && enabledFlag == nil {
                throw GhosthandError.invalidArgument("enabled must be a boolean")
            }
            let current: Bool
            if let enabledFlag {
                current = try ctx.provider.setAssistiveTouch(deviceID: ctx.deviceID, enabled: enabledFlag)
            } else {
                current = try ctx.provider.getAssistiveTouch(deviceID: ctx.deviceID)
            }
            return .json([
                "ok": true,
                "device": ctx.deviceID,
                "enabled": current,
            ])

        case ("GET", "/track"), ("POST", "/track/status"):
            let targetID: String
            if let dev = try? DeviceRegistry.shared.find(deviceQuery) {
                targetID = dev.id
            } else if let ctx = try? resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "track",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks) {
                targetID = ctx.deviceID
            } else {
                throw DeviceError("No iPhone selected or available.")
            }
            let coordinator: DualTrackInputCoordinator
            if let dev = try? DeviceRegistry.shared.find(targetID) {
                coordinator = DeviceRegistry.shared.coordinator(for: dev)
            } else {
                coordinator = DualTrackInputCoordinator(
                    udid: targetID,
                    mode: .auto,
                    standardInputResolver: { throw DeviceError("Device disconnected") }
                )
            }
            return .json([
                "ok": true,
                "device": targetID,
                "track": coordinator.status.json,
            ])

        case ("POST", "/track"), ("POST", "/track/switch"):
            let targetID: String
            if let dev = try? DeviceRegistry.shared.find(deviceQuery) {
                targetID = dev.id
            } else if let ctx = try? resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "track",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks) {
                targetID = ctx.deviceID
            } else {
                throw DeviceError("No iPhone selected or available.")
            }
            let rawMode = (params["mode"] as? String) ?? (params["track"] as? String)
            guard let targetMode = ControlTrackMode.parse(rawMode) else {
                throw DeviceError("Invalid track mode. Expected 'standard', 'enhanced', or 'auto'.")
            }
            let coordinator: DualTrackInputCoordinator
            if let dev = try? DeviceRegistry.shared.find(targetID) {
                coordinator = DeviceRegistry.shared.coordinator(for: dev)
            } else {
                coordinator = DualTrackInputCoordinator(
                    udid: targetID,
                    mode: targetMode,
                    standardInputResolver: { throw DeviceError("Device disconnected") }
                )
            }
            coordinator.switchMode(targetMode)
            return .json([
                "ok": true,
                "device": targetID,
                "track": coordinator.status.json,
            ])

        case ("GET", "/tree"), ("GET", "/ax_tree"), ("POST", "/ax_tree"):
            let targetID: String
            if let dev = try? DeviceRegistry.shared.find(deviceQuery) {
                targetID = dev.id
            } else if let ctx = try? resolveUSBContext(
                deviceQuery: deviceQuery, leaseID: leaseID, command: "ax_tree",
                deviceCandidates: deviceCandidates, runtimeHooks: runtimeHooks) {
                targetID = ctx.deviceID
            } else {
                throw DeviceError("No iPhone selected or available.")
            }
            let coordinator: DualTrackInputCoordinator
            if let dev = try? DeviceRegistry.shared.find(targetID) {
                coordinator = DeviceRegistry.shared.coordinator(for: dev)
            } else {
                coordinator = DualTrackInputCoordinator(
                    udid: targetID,
                    mode: .auto,
                    standardInputResolver: { throw DeviceError("Device disconnected") }
                )
            }
            let includeOffscreen = PostActionOptions.parseBoolFlag(params["include_offscreen"]) ?? false
            let tree = try coordinator.getAXTree(includeOffscreen: includeOffscreen)
            return .json([
                "ok": true,
                "device": targetID,
                "tree": tree,
            ])

        case ("GET", "/track/decide"), ("POST", "/track/decide"):
            let prompt = (params["prompt"] as? String) ?? (params["instruction"] as? String) ?? (params["task"] as? String) ?? ""
            let app = (params["app"] as? String) ?? (params["bundle_id"] as? String)
            let apply = PostActionOptions.parseBoolFlag(params["apply"]) ?? false
            let decision = JevTrackRouter.shared.decide(prompt: prompt, appName: app)
            var response: [String: Any] = [
                "ok": true,
                "decision": decision.json,
            ]
            if apply, let dev = try? DeviceRegistry.shared.find(deviceQuery) {
                let coord = DeviceRegistry.shared.coordinator(for: dev)
                coord.switchMode(decision.mode)
                response["device"] = dev.id
                response["track"] = coord.status.json
            }
            return .json(response)

        case ("POST", "/task"), ("POST", "/v1/tasks"):
            let taskOptions = try GeminiTaskExecutor.RequestOptions.parse(body: body, query: query)
            let effectiveHooks: GhosthandRuntimeHooks
            if let runtimeHooks {
                try authorizeDeviceLease(
                    deviceID: runtimeHooks.deviceID, leaseID: leaseID, command: "task")
                effectiveHooks = runtimeHooks
            } else {
                let ctx = try resolveUSBContext(
                    deviceQuery: deviceQuery, leaseID: leaseID, command: "task",
                    deviceCandidates: deviceCandidates, runtimeHooks: nil)
                let fallbackPNG = Self.blankPNGData(
                    width: Int(ctx.screenSize.width), height: Int(ctx.screenSize.height))
                let deviceInput: DeviceInput
                if let dev = try? DeviceRegistry.shared.find(deviceQuery),
                    let liveInput = try? DeviceRegistry.shared.input(for: dev)
                {
                    deviceInput = liveInput
                } else {
                    deviceInput = DeviceInput(
                        host: UUID(),
                        session: UUID(),
                        sleep: { _ in },
                        reportSender: { _, _ in },
                        reportReadiness: { _, _, _ in true }
                    )
                }
                effectiveHooks = GhosthandRuntimeHooks(
                    deviceID: ctx.deviceID,
                    deviceName: ctx.deviceName,
                    screenSize: ctx.screenSize,
                    input: deviceInput,
                    captureFrame: { usePNG, maxEdge in
                        if let dev = try? DeviceRegistry.shared.find(deviceQuery ?? ctx.deviceID),
                            let snap = dev.screen.snapshot(png: usePNG, maxEdge: maxEdge)
                        {
                            return snap
                        }
                        if let res = try? Self.captureTextScreen(deviceQuery ?? ctx.deviceID, maxEdge) {
                            return res.1
                        }
                        return fallbackPNG
                    },
                    isLocked: { ctx.isLocked },
                    usbProvider: ctx.provider
                )
            }
            let record = try GeminiTaskExecutor.run(
                options: taskOptions,
                hooks: effectiveHooks,
                store: effectiveHooks.taskStore
            )
            var response = HTTPResponse.json(record.toJSON())
            response.headers["Ghosthand-Task"] = record.taskID
            return response

        default:
            return .error("not found", status: 404)
        }
    }

    private static func extractUploadedData(
        from params: [String: Any],
        localPath: String?
    ) throws -> Data {
        if let base64 = (params["data"] as? String) ?? (params["base64"] as? String),
            let decoded = Data(base64Encoded: base64)
        {
            return decoded
        }
        if let content = (params["content"] as? String) ?? (params["text"] as? String) {
            return Data(content.utf8)
        }
        if let localPath = localPath?.trimmingCharacters(in: .whitespacesAndNewlines),
            !localPath.isEmpty
        {
            let url = URL(fileURLWithPath: (localPath as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: url.path),
                let data = try? Data(contentsOf: url)
            else {
                throw GhosthandError.invalidArgument("Local file not found or unreadable: \"\(localPath)\"")
            }
            return data
        }
        throw GhosthandError.invalidArgument(
            "Provide file content via \"data\" (base64), \"content\" (UTF-8 text), or \"source\"/\"path\" (local file path)"
        )
    }

    private static func blankPNGData(width: Int, height: Int) -> Data {
        let w = max(1, min(width, 64))
        let h = max(1, min(height, 64))
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let context = CGContext(
                data: nil,
                width: w,
                height: h,
                bitsPerComponent: 8,
                bytesPerRow: w * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ),
            let cgImage = context.makeImage()
        else {
            return Data()
        }
        let mutableData = CFDataCreateMutable(nil, 0)!
        guard
            let destination = CGImageDestinationCreateWithData(
                mutableData, "public.png" as CFString, 1, nil)
        else {
            return Data()
        }
        CGImageDestinationAddImage(destination, cgImage, nil)
        CGImageDestinationFinalize(destination)
        return mutableData as Data
    }

    private static func perform(
        _ action: Action,
        body: [String: Any],
        query: [String: String] = [:],
        deviceQuery: String?,
        leaseID: LeaseID? = nil,
        ocrCapture: (String?, Int?) throws -> (String, Data) = captureTextScreen,
        deviceCandidates: [DeviceCandidate]? = nil,
        runtimeHooks: GhosthandRuntimeHooks? = nil
    ) throws -> HTTPResponse {
        let postOptions = try PostActionOptions.parse(body: body, query: query)
        let commandName = String(action.rawValue.dropFirst())
        if let deviceCandidates {
            let candidate = try resolveCandidateForLease(
                query: deviceQuery, injectedCandidates: deviceCandidates)
            try authorizeDeviceLease(deviceID: candidate.id, leaseID: leaseID, command: commandName)
        }

        let targetID: String
        let targetScreenName: String
        let targetScreenSize: CGSize?
        let input: DeviceInput
        let isLockedCheck: () -> Bool
        let waitForFrameCheck: () -> Bool
        let observeMutedCheck: () -> Bool?
        let sleepFn: (TimeInterval) -> Void

        if let runtimeHooks {
            targetID = runtimeHooks.deviceID
            targetScreenName = runtimeHooks.deviceName
            targetScreenSize = runtimeHooks.screenSize
            input = runtimeHooks.input
            isLockedCheck = runtimeHooks.isLocked
            waitForFrameCheck = runtimeHooks.waitForFrame
            observeMutedCheck = runtimeHooks.observeMutedState
            sleepFn = runtimeHooks.sleep
            try authorizeDeviceLease(deviceID: targetID, leaseID: leaseID, command: commandName)
        } else {
            let device = try DeviceRegistry.shared.find(deviceQuery)
            targetID = device.id
            targetScreenName = device.screen.name
            targetScreenSize = device.screen.size
            try authorizeDeviceLease(deviceID: targetID, leaseID: leaseID, command: commandName)
            // Real input takes priority over background probes and measurement.
            // Cancel before resolving/queuing input, so it cannot wait behind the
            // very measurement that the user is trying to interrupt.
            DeviceRegistry.shared.cancelBackgroundMotion(for: device)
            input = try DeviceRegistry.shared.input(for: device)
            isLockedCheck = {
                let state = device.lockState
                return state == .suspected || state == .paused
            }
            waitForFrameCheck = {
                device.screen.size != nil
            }
            observeMutedCheck = {
                nil
            }
            sleepFn = { Thread.sleep(forTimeInterval: $0) }
        }

        let coordinator: DualTrackInputCoordinator?
        if runtimeHooks == nil, let dev = try? DeviceRegistry.shared.find(deviceQuery ?? targetID) {
            coordinator = DeviceRegistry.shared.coordinator(for: dev)
        } else {
            coordinator = nil
        }

        let isEnhancedActive = coordinator?.mode == .enhanced
            || (coordinator?.mode == .auto && coordinator?.enhancedDriver.isAvailable == true && coordinator?.state != .degradedToStandard)

        if action.requiresPointer, !isEnhancedActive, !input.isPointerReady {
            // Keep readiness ahead of parameter parsing. API callers may have no window
            // polling readiness, and a lost subscription or screen change invalidates origin.
            input.invalidatePointerEstimate()
            return .error(StringsAPI.current.pointerNotReady, status: 503)
        }

        var responsePayload: [String: Any] = ["ok": true, "device": targetID]
        if let coordinator {
            responsePayload["track"] = coordinator.status.json
        }

        switch action {
        case .tap:
            let resolved = try resolvePointOrText(
                body, deviceID: targetID, deviceQuery: deviceQuery,
                screenSize: targetScreenSize, screenName: targetScreenName,
                ocrCapture: ocrCapture, runtimeHooks: runtimeHooks)
            let hold = (body["hold"] as? Double) ?? 0.08
            if let coordinator, let screenSize = targetScreenSize {
                try coordinator.tap(x: resolved.x, y: resolved.y, screenWidth: screenSize.width, screenHeight: screenSize.height, hold: hold)
            } else {
                try input.tap(x: resolved.x, y: resolved.y, hold: hold)
            }
            if let matched = resolved.matchedItem {
                responsePayload["text"] = matched.text
                responsePayload["x"] = resolved.targetPixel?.x ?? matched.x
                responsePayload["y"] = resolved.targetPixel?.y ?? matched.y
            }
        case .doubleTap:
            let resolved = try resolvePointOrText(
                body, deviceID: targetID, deviceQuery: deviceQuery,
                screenSize: targetScreenSize, screenName: targetScreenName,
                ocrCapture: ocrCapture, runtimeHooks: runtimeHooks)
            let hold = (body["hold"] as? Double) ?? 0.22
            let gap = (body["gap"] as? Double) ?? 0.12
            if let coordinator, let screenSize = targetScreenSize {
                try coordinator.doubleTap(x: resolved.x, y: resolved.y, screenWidth: screenSize.width, screenHeight: screenSize.height, hold: hold, gap: gap)
            } else {
                try input.doubleTap(x: resolved.x, y: resolved.y, hold: hold, gap: gap)
            }
            if let matched = resolved.matchedItem {
                responsePayload["text"] = matched.text
                responsePayload["x"] = resolved.targetPixel?.x ?? matched.x
                responsePayload["y"] = resolved.targetPixel?.y ?? matched.y
            }
        case .tripleTap:
            let resolved = try resolvePointOrText(
                body, deviceID: targetID, deviceQuery: deviceQuery,
                screenSize: targetScreenSize, screenName: targetScreenName,
                ocrCapture: ocrCapture, runtimeHooks: runtimeHooks)
            let hold = (body["hold"] as? Double) ?? 0.22
            let gap = (body["gap"] as? Double) ?? 0.12
            if let coordinator, let screenSize = targetScreenSize {
                try coordinator.tripleTap(x: resolved.x, y: resolved.y, screenWidth: screenSize.width, screenHeight: screenSize.height, hold: hold, gap: gap)
            } else {
                try input.tripleTap(x: resolved.x, y: resolved.y, hold: hold, gap: gap)
            }
            if let matched = resolved.matchedItem {
                responsePayload["text"] = matched.text
                responsePayload["x"] = resolved.targetPixel?.x ?? matched.x
                responsePayload["y"] = resolved.targetPixel?.y ?? matched.y
            }
        case .hold:
            let durationSeconds = try parseHoldDurationSeconds(body)
            let resolved = try resolvePointOrText(
                body, deviceID: targetID, deviceQuery: deviceQuery,
                screenSize: targetScreenSize, screenName: targetScreenName,
                ocrCapture: ocrCapture, runtimeHooks: runtimeHooks)
            if let coordinator, let screenSize = targetScreenSize {
                try coordinator.hold(x: resolved.x, y: resolved.y, screenWidth: screenSize.width, screenHeight: screenSize.height, duration: durationSeconds)
            } else {
                try input.hold(x: resolved.x, y: resolved.y, duration: durationSeconds)
            }
            if let matched = resolved.matchedItem {
                responsePayload["text"] = matched.text
                responsePayload["x"] = resolved.targetPixel?.x ?? matched.x
                responsePayload["y"] = resolved.targetPixel?.y ?? matched.y
            }
        case .swipe:
            let swipe = try SwipeRequest(body, screenSize: targetScreenSize, screenName: targetScreenName)
            if let coordinator, let screenSize = targetScreenSize, swipe.points.count >= 2 {
                let p1 = swipe.points[0]
                let p2 = swipe.points[1]
                try coordinator.swipe(fromX: p1.0, fromY: p1.1, toX: p2.0, toY: p2.1, screenWidth: screenSize.width, screenHeight: screenSize.height, duration: swipe.duration)
            } else {
                try input.swipe(points: swipe.points, duration: swipe.duration)
            }
        case .holdDrag:
            let holdDrag = try parseHoldDragRequest(
                body, screenSize: targetScreenSize, screenName: targetScreenName)
            try input.holdDrag(
                from: holdDrag.from,
                to: holdDrag.to,
                holdDuration: holdDrag.holdDuration,
                dragDuration: holdDrag.dragDuration
            )
        case .scroll:
            let scrollReq = try parseScrollRequest(
                body, screenSize: targetScreenSize, screenName: targetScreenName)
            if let listScrollResponse = try executeListScrollIfNeeded(
                body: body,
                direction: scrollReq.direction,
                deviceID: targetID,
                deviceQuery: deviceQuery,
                performOneScroll: {
                    try input.scroll(
                        direction: scrollReq.direction,
                        ticks: scrollReq.ticks,
                        at: scrollReq.at
                    )
                },
                ocrCapture: ocrCapture,
                runtimeHooks: runtimeHooks
            ) {
                responsePayload.merge(listScrollResponse) { _, new in new }
            } else {
                try input.scroll(
                    direction: scrollReq.direction,
                    ticks: scrollReq.ticks,
                    at: scrollReq.at
                )
            }
        case .move:
            let (x, y) = try RequestCoordinates.point(
                body, "x", "y", screenSize: targetScreenSize, screenName: targetScreenName)
            try input.move(x: x, y: y)
        case .nudge:
            try input.nudge(
                dx: (body["dx"] as? Int) ?? 0, dy: (body["dy"] as? Int) ?? 0,
                click: (body["click"] as? Bool) ?? false)
        case .type:
            guard let text = body["text"] as? String else { return .error(StringsAPI.current.textRequired) }
            var parameters = body
            parameters["text"] = text
            try TypeTextRequest(parameters, language: AppLanguageStore.shared.language).perform(
                on: input,
                ocr: {
                    if let runtimeHooks {
                        return (try? runtimeHooks.captureFrame(false, 1600)).map {
                            runtimeHooks.recognizeOCR($0, targetID)
                        }
                    }
                    return (try? DeviceRegistry.shared.find(deviceQuery)).flatMap { dev in
                        dev.screen.snapshot(png: false, maxEdge: 1600).map {
                            ScreenOCR.recognize($0, device: dev.id)
                        }
                    }
                })
        case .key:
            guard let key = body["key"] as? String else { return .error(StringsAPI.current.keyRequired) }
            if key.trimmingCharacters(in: .whitespacesAndNewlines).caseInsensitiveCompare("mute") == .orderedSame {
                throw GhosthandError.invalidArgument(
                    "mute is excluded from key; use /mute or /unmute so ringer state is verified over USB"
                )
            }
            try input.key(key, modifiers: (body["modifiers"] as? [String]) ?? [])
        case .home:
            input.consumer(0x0223)
        case .power:
            // Consumer Power is a short, state-dependent key press. Never
            // retry it automatically or claim that an accepted report locked iOS.
            input.consumer(0x0030)
        case .wake:
            try GhosthandDevicePrimitives.wake(
                tapStatusBar: { x, y in try input.tap(x: x, y: y, hold: 0.08) },
                waitForFrame: waitForFrameCheck,
                isLocked: isLockedCheck
            )
        case .lock:
            try GhosthandDevicePrimitives.lock(
                sendKey: { k, mods in try input.key(k, modifiers: mods) },
                sleep: sleepFn,
                verifyLocked: isLockedCheck
            )
        case .unlock:
            guard let passcode = body["passcode"] as? String else {
                throw GhosthandError.invalidArgument("passcode is required")
            }
            let enteredPasscode = try GhosthandDevicePrimitives.unlock(
                passcode: passcode,
                isLocked: isLockedCheck,
                sendKey: { k, mods in try input.key(k, modifiers: mods) },
                typeText: { txt in try input.type(txt) },
                sleep: sleepFn
            )
            responsePayload["alreadyUnlocked"] = !enteredPasscode
        case .mute:
            let muteResult = try GhosthandDevicePrimitives.setMuted(
                true,
                sendConsumerMute: { input.consumer(0x00E2) },
                observeMutedState: observeMutedCheck,
                sleep: sleepFn
            )
            responsePayload.merge(muteResult) { _, new in new }
        case .unmute:
            let unmuteResult = try GhosthandDevicePrimitives.setMuted(
                false,
                sendConsumerMute: { input.consumer(0x00E2) },
                observeMutedState: observeMutedCheck,
                sleep: sleepFn
            )
            responsePayload.merge(unmuteResult) { _, new in new }
        }

        if action != .lock {
            try attachPostActionObservationIfNeeded(
                to: &responsePayload, options: postOptions, deviceID: targetID,
                effectiveQuery: deviceQuery, ocrCapture: ocrCapture, runtimeHooks: runtimeHooks)
        }
        return .json(responsePayload)
    }

    private static func attachPostActionObservationIfNeeded(
        to payload: inout [String: Any],
        options: PostActionOptions,
        deviceID: String,
        effectiveQuery: String?,
        ocrCapture: (String?, Int?) throws -> (String, Data),
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws {
        guard options.requiresPostActionCapture else { return }
        if let runtimeHooks {
            let obs = try StillnessDetector.observeAfterAction(
                options: options,
                deviceID: deviceID,
                now: runtimeHooks.now,
                sleep: runtimeHooks.sleep,
                captureFrame: runtimeHooks.captureFrame,
                recognize: runtimeHooks.recognizeOCR,
                signature: runtimeHooks.stabilitySignature
            )
            obs.attach(
                to: &payload,
                includeScreenshot: options.includeScreenshot,
                includeScreentext: options.includeScreentext
            )
            return
        }
        let obs = try StillnessDetector.observeAfterAction(
            options: options,
            deviceID: deviceID,
            captureFrame: { usePNG, maxEdge in
                if let dev = try? DeviceRegistry.shared.find(effectiveQuery ?? deviceID),
                    let snap = dev.screen.snapshot(png: usePNG, maxEdge: maxEdge)
                {
                    return snap
                }
                return try ocrCapture(effectiveQuery ?? deviceID, maxEdge).1
            }
        )
        obs.attach(
            to: &payload,
            includeScreenshot: options.includeScreenshot,
            includeScreentext: options.includeScreentext
        )
    }

    private static func executeListScrollIfNeeded(
        body: [String: Any],
        direction: DeviceInput.ScrollDirection,
        deviceID: String,
        deviceQuery: String?,
        performOneScroll: () throws -> Void,
        ocrCapture: (String?, Int?) throws -> (String, Data),
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws -> [String: Any]? {
        let rawUntil = (body["until_text"] as? String) ?? (body["untilText"] as? String)
        let collectFlag = PostActionOptions.parseBoolFlag(body["collect"]) ?? false
        guard rawUntil != nil || collectFlag else {
            return nil
        }

        let maxEdge = try OCRRequest.maxEdge(body)
        let minConfidence = try OCRRequest.minConfidence(body) ?? 0.4
        let contentOnly = try OCRRequest.contentOnly(body, defaultValue: true)

        let maxScrolls: Int
        if let rawMax = body["max_scrolls"] ?? body["maxScrolls"], !(rawMax is NSNull) {
            guard let val = OCRRequest.number(rawMax), val.rounded() == val, (1...50).contains(Int(val)) else {
                throw GhosthandError.invalidArgument("max_scrolls must be an integer within 1...50")
            }
            maxScrolls = Int(val)
        } else {
            maxScrolls = collectFlag ? 15 : 12
        }

        func captureSettledOCR(isInitial: Bool) throws -> ScreenOCR.Result {
            if let runtimeHooks {
                let frame: Data
                if isInitial {
                    frame = try runtimeHooks.captureFrame(true, maxEdge)
                } else {
                    frame = try StillnessDetector.waitForStillness(
                        pollInterval: 0.12,
                        timeout: 0.8,
                        now: runtimeHooks.now,
                        sleep: runtimeHooks.sleep,
                        captureFrame: { try runtimeHooks.captureFrame(true, maxEdge) },
                        signature: runtimeHooks.stabilitySignature
                    )
                }
                return runtimeHooks.recognizeOCR(frame, deviceID)
            }
            let frame: Data
            if isInitial {
                frame = try ocrCapture(deviceQuery ?? deviceID, maxEdge).1
            } else {
                frame = try StillnessDetector.waitForStillness(
                    pollInterval: 0.12,
                    timeout: 0.8,
                    captureFrame: {
                        if let dev = try? DeviceRegistry.shared.find(deviceQuery ?? deviceID),
                            let snap = dev.screen.snapshot(png: true, maxEdge: maxEdge)
                        {
                            return snap
                        }
                        return try ocrCapture(deviceQuery ?? deviceID, maxEdge).1
                    }
                )
            }
            return ScreenOCR.recognize(frame, device: deviceID)
        }

        if let untilText = rawUntil {
            let trimmed = untilText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GhosthandError.invalidArgument("until_text must not be empty")
            }
            let exact = PostActionOptions.parseBoolFlag(body["exact"]) ?? false
            let outcome = try ListScrollWalker.scrollUntil(
                query: untilText,
                exact: exact,
                maxScrolls: maxScrolls,
                minConfidence: minConfidence,
                performScroll: performOneScroll,
                captureSettledOCR: captureSettledOCR
            )
            return outcome.toJSON(deviceID: deviceID, direction: direction.rawValue)
        }

        let endAfter: Int
        if let rawEnd = body["end_after"] ?? body["endAfter"], !(rawEnd is NSNull) {
            guard let val = OCRRequest.number(rawEnd), val.rounded() == val, (1...10).contains(Int(val)) else {
                throw GhosthandError.invalidArgument("end_after must be an integer within 1...10")
            }
            endAfter = Int(val)
        } else {
            endAfter = 3
        }
        let outcome = try ListScrollWalker.scrollCollect(
            maxScrolls: maxScrolls,
            endAfter: endAfter,
            minConfidence: minConfidence,
            contentOnly: contentOnly,
            performScroll: performOneScroll,
            captureSettledOCR: captureSettledOCR
        )
        return outcome.toJSON(deviceID: deviceID, direction: direction.rawValue)
    }

    private static func resolvePointOrText(
        _ body: [String: Any],
        deviceID: String,
        deviceQuery: String?,
        screenSize: CGSize?,
        screenName: String,
        ocrCapture: (String?, Int?) throws -> (String, Data),
        runtimeHooks: GhosthandRuntimeHooks?
    ) throws -> (x: Double, y: Double, matchedItem: ScreenOCR.Item?, targetPixel: (x: Int, y: Int)?) {
        if let rawText = body["text"] as? String, body["x"] == nil, body["y"] == nil {
            let trimmed = rawText.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw GhosthandError.invalidArgument("text must not be empty")
            }
            let exact = PostActionOptions.parseBoolFlag(body["exact"]) ?? false
            let index: Int?
            if let rawIndex = body["index"], !(rawIndex is NSNull) {
                guard let val = OCRRequest.number(rawIndex), val >= 0, val < Double(Int.max), val.rounded() == val
                else {
                    throw GhosthandError.invalidArgument("index must be a non-negative integer")
                }
                index = Int(val)
            } else {
                index = nil
            }
            let tapHelper = try TextTapRequest(body)
            let maxEdge = try OCRRequest.maxEdge(body)
            let (id, data) =
                try runtimeHooks.map { ($0.deviceID, try $0.captureFrame(true, maxEdge)) }
                ?? ocrCapture(deviceQuery ?? deviceID, maxEdge)
            let ocrResult = runtimeHooks?.recognizeOCR(data, id) ?? ScreenOCR.recognize(data, device: id)
            let matched = try ScreenOCR.matchTiered(
                ocrResult, text: rawText, exact: exact, index: index, oneBasedIndex: false)
            let targetPx = tapHelper.targetPixel(for: matched, in: ocrResult)
            return (
                Double(targetPx.x) / Double(max(1, ocrResult.width)),
                Double(targetPx.y) / Double(max(1, ocrResult.height)),
                matched,
                targetPx
            )
        }
        let (x, y) = try RequestCoordinates.point(
            body, "x", "y", screenSize: screenSize, screenName: screenName)
        return (x, y, nil, nil)
    }

    private static func parseHoldDurationSeconds(_ body: [String: Any]) throws -> TimeInterval {
        if let rawMs = body["durationMs"] ?? body["duration_ms"], !(rawMs is NSNull) {
            guard let ms = OCRRequest.number(rawMs), (100...10_000).contains(ms) else {
                throw GhosthandError.invalidArgument("durationMs must be within 100...10000 ms")
            }
            return ms / 1000.0
        }
        if let rawSec = body["duration"] ?? body["seconds"], !(rawSec is NSNull) {
            guard let val = OCRRequest.number(rawSec) else {
                throw GhosthandError.invalidArgument("hold duration must be a number")
            }
            // Accept both milliseconds (100...10000) and seconds (0.1...10.0)
            let seconds = val >= 100 ? val / 1000.0 : val
            guard (0.1...10.0).contains(seconds) else {
                throw GhosthandError.invalidArgument(
                    "hold duration must be within 100...10000 ms (0.1...10.0 s)"
                )
            }
            return seconds
        }
        return 1.0
    }

    private static func parseHoldDragRequest(
        _ body: [String: Any],
        screenSize: CGSize?,
        screenName: String
    ) throws -> (from: (Double, Double), to: (Double, Double), holdDuration: TimeInterval, dragDuration: TimeInterval) {
        let fromPoint: (Double, Double)
        let toPoint: (Double, Double)
        if let fromDict = body["from"] as? [String: Any], let toDict = body["to"] as? [String: Any] {
            var fromBody = body
            fromBody["x"] = fromDict["x"]
            fromBody["y"] = fromDict["y"]
            var toBody = body
            toBody["x"] = toDict["x"]
            toBody["y"] = toDict["y"]
            fromPoint = try RequestCoordinates.point(
                fromBody, "x", "y", screenSize: screenSize, screenName: screenName)
            toPoint = try RequestCoordinates.point(
                toBody, "x", "y", screenSize: screenSize, screenName: screenName)
        } else if body["x1"] != nil, body["y1"] != nil, body["x2"] != nil, body["y2"] != nil {
            fromPoint = try RequestCoordinates.point(
                body, "x1", "y1", screenSize: screenSize, screenName: screenName)
            toPoint = try RequestCoordinates.point(
                body, "x2", "y2", screenSize: screenSize, screenName: screenName)
        } else if body["fromX"] != nil, body["fromY"] != nil, body["toX"] != nil, body["toY"] != nil {
            fromPoint = try RequestCoordinates.point(
                body, "fromX", "fromY", screenSize: screenSize, screenName: screenName)
            toPoint = try RequestCoordinates.point(
                body, "toX", "toY", screenSize: screenSize, screenName: screenName)
        } else {
            throw GhosthandError.invalidArgument(
                "hold_drag requires from/to points or (x1, y1, x2, y2)"
            )
        }

        let holdDuration: TimeInterval
        if let rawHoldMs = body["holdMs"] ?? body["hold_ms"], !(rawHoldMs is NSNull) {
            guard let ms = OCRRequest.number(rawHoldMs), (100...10_000).contains(ms) else {
                throw GhosthandError.invalidArgument("holdMs must be within 100...10000 ms")
            }
            holdDuration = ms / 1000.0
        } else if let rawHold = body["holdDuration"] ?? body["hold_duration"] ?? body["hold"], !(rawHold is NSNull) {
            guard let val = OCRRequest.number(rawHold) else {
                throw GhosthandError.invalidArgument("holdDuration must be a number")
            }
            let sec = val >= 100 ? val / 1000.0 : val
            guard (0.1...10.0).contains(sec) else {
                throw GhosthandError.invalidArgument("holdDuration must be within 0.1...10.0 s")
            }
            holdDuration = sec
        } else {
            holdDuration = 1.0
        }

        let dragDuration: TimeInterval
        if let rawDragMs = body["durationMs"] ?? body["duration_ms"] ?? body["dragMs"] ?? body["drag_ms"],
            !(rawDragMs is NSNull)
        {
            guard let ms = OCRRequest.number(rawDragMs), (16...10_000).contains(ms) else {
                throw GhosthandError.invalidArgument("durationMs must be within 16...10000 ms")
            }
            dragDuration = ms / 1000.0
        } else if let rawDrag = body["duration"] ?? body["dragDuration"] ?? body["drag_duration"],
            !(rawDrag is NSNull)
        {
            guard let val = OCRRequest.number(rawDrag) else {
                throw GhosthandError.invalidArgument("duration must be a number")
            }
            let sec = val >= 16 ? val / 1000.0 : val
            guard (0.016...10.0).contains(sec) else {
                throw GhosthandError.invalidArgument("drag duration must be within 16...10000 ms")
            }
            dragDuration = sec
        } else {
            dragDuration = 1.0
        }

        return (fromPoint, toPoint, holdDuration, dragDuration)
    }

    private static func parseScrollRequest(
        _ body: [String: Any],
        screenSize: CGSize?,
        screenName: String
    ) throws -> (direction: DeviceInput.ScrollDirection, ticks: Int, at: (Double, Double)) {
        guard let rawDir = (body["direction"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased(),
            let direction = DeviceInput.ScrollDirection(rawValue: rawDir)
        else {
            throw GhosthandError.invalidArgument(
                "scroll direction is required and must be up, down, left, or right"
            )
        }
        let ticks: Int
        if let rawTicks = body["ticks"], !(rawTicks is NSNull) {
            guard let val = OCRRequest.number(rawTicks), val.rounded() == val, (1...1000).contains(Int(val)) else {
                throw GhosthandError.invalidArgument("scroll ticks must be an integer within 1...1000")
            }
            ticks = Int(val)
        } else {
            ticks = 5
        }

        let atPoint: (Double, Double)
        if let atDict = body["at"] as? [String: Any], atDict["x"] != nil, atDict["y"] != nil {
            var atBody = body
            atBody["x"] = atDict["x"]
            atBody["y"] = atDict["y"]
            atPoint = try RequestCoordinates.point(
                atBody, "x", "y", screenSize: screenSize, screenName: screenName)
        } else if body["x"] != nil, body["y"] != nil {
            atPoint = try RequestCoordinates.point(
                body, "x", "y", screenSize: screenSize, screenName: screenName)
        } else {
            atPoint = (0.5, 0.5)
        }
        return (direction, ticks, atPoint)
    }

    private static func point(
        _ body: [String: Any], _ xKey: String, _ yKey: String, on device: Device
    ) throws -> (Double, Double) {
        try RequestCoordinates.point(
            body, xKey, yKey, screenSize: device.screen.size, screenName: device.screen.name)
    }
}

/// Validates the entire path before input begins. Every point uses the same
/// screenshot dimensions, so a malformed later point cannot leave a drag held.
struct SwipeRequest {
    let points: [(Double, Double)]
    let duration: TimeInterval

    init(_ body: [String: Any], screenSize: CGSize?, screenName: String) throws {
        let table = StringsAPI.current
        guard let rawPoints = body["points"] as? [[String: Any]], rawPoints.count >= 2 else {
            throw DeviceError(table.swipePointsMin)
        }
        let coordinates = try rawPoints.enumerated().map { index, point in
            guard let x = Self.finiteNumber(point["x"]), let y = Self.finiteNumber(point["y"]) else {
                throw DeviceError(table.swipePointFinite(index))
            }
            return (x, y)
        }

        if let rawDuration = body["duration"] {
            guard let value = Self.finiteNumber(rawDuration), value > 0 else {
                throw DeviceError(table.swipeDurationInvalid)
            }
            duration = value
        } else {
            duration = 0.3
        }

        // Preserve the existing scaling rules, while rejecting invalid sizes
        // before maxEdge conversion or division can produce an unusable path.
        if (body["fraction"] as? Bool) != true {
            for key in ["width", "height", "maxEdge"] {
                guard let rawValue = body[key] else { continue }
                guard let value = Self.finiteNumber(rawValue), value > 0 else {
                    throw DeviceError(table.swipeSizeKeyInvalid(key))
                }
                if key == "maxEdge", value < 1 || value >= Double(Int.max) {
                    throw DeviceError(table.swipeMaxEdgeRange)
                }
            }
        }

        var coordinateBody = body
        coordinateBody.removeValue(forKey: "points")
        points = try coordinates.map { x, y in
            coordinateBody["x"] = x
            coordinateBody["y"] = y
            let point = try RequestCoordinates.point(
                coordinateBody, "x", "y", screenSize: screenSize, screenName: screenName)
            guard point.0.isFinite, point.1.isFinite else {
                throw DeviceError(table.swipeInvalidDimensions)
            }
            return point
        }
    }

    private static func finiteNumber(_ value: Any?) -> Double? {
        // JSON booleans bridge to NSNumber too; they are not coordinates or durations.
        guard let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
            number.doubleValue.isFinite
        else { return nil }
        return number.doubleValue
    }
}

/// Coordinate rules shared by the HTTP action and screenshot endpoints.
/// This layer preserves the API's permissive numeric input; DeviceInput applies pointer limits.
enum RequestCoordinates {
    static func imageSize(_ size: CGSize, maxWidth: Int?, maxEdge: Int?) -> (Int, Int) {
        var scale = 1.0
        if let maxWidth { scale = min(scale, Double(maxWidth) / size.width) }
        if let maxEdge { scale = min(scale, Double(maxEdge) / max(size.width, size.height)) }
        return (Int((size.width * scale).rounded()), Int((size.height * scale).rounded()))
    }

    /// Converts screenshot pixels to screen fractions. Explicit dimensions override
    /// maxEdge-derived dimensions independently. Fraction input does not need a frame.
    static func point(
        _ body: [String: Any], _ xKey: String, _ yKey: String,
        screenSize: @autoclosure () -> CGSize?, screenName: @autoclosure () -> String
    ) throws -> (Double, Double) {
        guard let x = number(body[xKey]), let y = number(body[yKey]) else {
            throw DeviceError(StringsAPI.current.coordinatesRequired(xKey, yKey))
        }
        if (body["fraction"] as? Bool) == true { return (x, y) }
        // Evaluate the capture state only after coordinate validation, as on the API path.
        guard let size = screenSize() else { throw DeviceError(StringsAPI.current.noFrameFromScreen(screenName())) }
        var width = Double(size.width)
        var height = Double(size.height)
        if let maxEdge = number(body["maxEdge"]).map(Int.init) {
            let image = imageSize(size, maxWidth: nil, maxEdge: maxEdge)
            width = Double(image.0)
            height = Double(image.1)
        }
        width = number(body["width"]) ?? width
        height = number(body["height"]) ?? height
        return (x / width, y / height)
    }

    private static func number(_ value: Any?) -> Double? {
        (value as? NSNumber)?.doubleValue
    }
}

/// Validate OCR dimensions before the capture pipeline converts them to integers.
enum OCRRequest {
    static func number(_ raw: Any?) -> Double? {
        guard let value = raw as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
            value.doubleValue.isFinite
        else { return nil }
        return value.doubleValue
    }

    static func maxEdge(_ body: [String: Any], table: StringsAPI = .current) throws -> Int? {
        guard let raw = body["maxEdge"] else { return nil }
        guard let value = number(raw), value >= 1, value < Double(Int.max), value.rounded() == value else {
            throw DeviceError(table.ocrParameterInvalid("maxEdge"))
        }
        return Int(value)
    }

    static func minConfidence(_ body: [String: Any], table: StringsAPI = .current) throws -> Double? {
        guard let raw = body["min_confidence"] ?? body["minConfidence"], !(raw is NSNull) else {
            return nil
        }
        if let value = number(raw), (0.0...1.0).contains(value) {
            return value
        }
        if let str = raw as? String, let parsed = Double(str), parsed.isFinite, (0.0...1.0).contains(parsed) {
            return parsed
        }
        throw DeviceError(table.ocrParameterInvalid("min_confidence"))
    }

    static func contentOnly(
        _ body: [String: Any], defaultValue: Bool = false, table: StringsAPI = .current
    ) throws -> Bool {
        guard let raw = body["content_only"] ?? body["contentOnly"], !(raw is NSNull) else {
            return defaultValue
        }
        guard let flag = PostActionOptions.parseBoolFlag(raw) else {
            throw DeviceError(table.ocrParameterInvalid("content_only"))
        }
        return flag
    }
}

struct TextTapRequest {
    let text: String
    let exact: Bool
    let index: Int
    let hold: Double
    let offsetX: Int
    let offsetY: Int
    let icon: Bool

    init(_ body: [String: Any], table: StringsAPI = .current) throws {
        guard let text = body["text"] as? String, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw DeviceError(table.ocrParameterInvalid("text"))
        }
        self.text = text
        if let raw = body["exact"] {
            guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw DeviceError(table.ocrParameterInvalid("exact"))
            }
            exact = value.boolValue
        } else {
            exact = false
        }
        if let raw = body["index"] {
            guard let value = OCRRequest.number(raw), value >= 0, value < Double(Int.max), value.rounded() == value
            else {
                throw DeviceError(table.ocrParameterInvalid("index"))
            }
            index = Int(value)
        } else {
            index = 0
        }
        if let raw = body["hold"] {
            guard let value = OCRRequest.number(raw), value >= 0, value <= 60 else {
                throw DeviceError(table.ocrParameterInvalid("hold"))
            }
            hold = value
        } else {
            hold = 0.08
        }
        if let rawOffsetX = body["offset_x"] ?? body["offsetX"], !(rawOffsetX is NSNull) {
            guard let value = OCRRequest.number(rawOffsetX),
                (-10_000...10_000).contains(value),
                value.rounded() == value
            else {
                throw DeviceError(table.ocrParameterInvalid("offset_x"))
            }
            offsetX = Int(value)
        } else {
            offsetX = 0
        }
        if let rawOffsetY = body["offset_y"] ?? body["offsetY"], !(rawOffsetY is NSNull) {
            guard let value = OCRRequest.number(rawOffsetY),
                (-10_000...10_000).contains(value),
                value.rounded() == value
            else {
                throw DeviceError(table.ocrParameterInvalid("offset_y"))
            }
            offsetY = Int(value)
        } else {
            offsetY = 0
        }
        if let rawIcon = body["icon"], !(rawIcon is NSNull) {
            guard let value = rawIcon as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                throw DeviceError(table.ocrParameterInvalid("icon"))
            }
            icon = value.boolValue
        } else {
            icon = false
        }
    }

    func match(_ result: ScreenOCR.Result) throws -> ScreenOCR.Item {
        let matches = result.items.filter {
            exact ? $0.text == text : $0.text.range(of: text, options: .caseInsensitive) != nil
        }
        guard result.width > 0, result.height > 0, index < matches.count else {
            throw DeviceError(ScreenOCR.formatNotFoundError(query: text, in: result))
        }
        return matches[index]
    }

    /// Computes the target pixel coordinate for a matched OCR text item, applying `offsetX`,
    /// `offsetY`, or Home-Screen `icon: true` upward offset (`~4.2%` of screenshot height,
    /// minimum `24px`, above the matched label center), clamped to the screenshot bounds.
    func targetPixel(for item: ScreenOCR.Item, in result: ScreenOCR.Result) -> (x: Int, y: Int) {
        let defaultIconDeltaY = -max(24, Int((Double(result.height) * 0.042).rounded()))
        let effectiveOffsetY = (icon && offsetY == 0) ? defaultIconDeltaY : offsetY
        let rawX = item.x + offsetX
        let rawY = item.y + effectiveOffsetY
        let clampedX = max(0, min(max(0, result.width - 1), rawX))
        let clampedY = max(0, min(max(0, result.height - 1), rawY))
        return (clampedX, clampedY)
    }
}

/// A bounded, fully validated batch. A failed step stops the batch without replay.
struct ActRequest {
    let steps: [[String: Any]]

    init(_ body: [String: Any]) throws {
        guard let steps = body["steps"] as? [[String: Any]], (1...16).contains(steps.count) else {
            throw DeviceError("steps must contain 1...16 actions")
        }
        var waitBudget = 0.0
        for step in steps {
            guard let type = step["type"] as? String,
                ["tap", "tap_text", "swipe", "type", "key", "home", "delay", "wait_text"].contains(type),
                step["device"] == nil, step["device_id"] == nil
            else { throw DeviceError("Invalid act step or nested device selector") }
            _ = try OCRRequest.maxEdge(step)
            if let fraction = step["fraction"], !TextEntry.isBoolean(fraction) {
                throw DeviceError("fraction must be a boolean")
            }
            for key in ["width", "height"] where step[key] != nil {
                guard let value = OCRRequest.number(step[key]), value > 0 else {
                    throw DeviceError("Invalid coordinate dimensions")
                }
            }
            switch type {
            case "type": _ = try TypeTextRequest(step)
            case "tap_text", "wait_text":
                _ = try TextTapRequest(step)
                _ = try OCRRequest.maxEdge(step)
            case "tap":
                let point = try RequestCoordinates.point(
                    step, "x", "y", screenSize: CGSize(width: 1, height: 1), screenName: "")
                guard point.0.isFinite, point.1.isFinite else { throw DeviceError("Invalid tap dimensions") }
                guard OCRRequest.number(step["x"]) != nil, OCRRequest.number(step["y"]) != nil else {
                    throw DeviceError("tap coordinates must be finite numbers")
                }
                _ = try TextTapRequest(step.merging(["text": "tap"]) { _, value in value })
            case "swipe":
                _ = try SwipeRequest(step, screenSize: CGSize(width: 1, height: 1), screenName: "")
            case "key":
                guard let key = step["key"] as? String,
                    KeyboardMap.named[key.lowercased()] != nil || key.count == 1,
                    KeyboardMap.code(for: key) != nil,
                    step["modifiers"] == nil || step["modifiers"] is [String],
                    KeyboardMap.modifierMask(for: step["modifiers"] as? [String] ?? []) != nil
                else { throw DeviceError("Invalid key or modifiers") }
            default: break
            }
            if type == "delay" || type == "wait_text" {
                let raw = step[type == "delay" ? "seconds" : "timeout"] ?? (type == "delay" ? 0 : 6)
                guard let seconds = OCRRequest.number(raw), (0...6).contains(seconds) else {
                    throw DeviceError("delay/timeout must be in 0...6 seconds")
                }
                waitBudget += seconds
            }
        }
        guard waitBudget <= 30 else { throw DeviceError("act wait budget exceeds 30 seconds") }
        self.steps = steps
    }

    func perform(
        device: String?, capture: (String?, Int?) throws -> (String, Data),
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        execute: (String, [String: Any], String?) throws -> HTTPResponse
    ) throws -> HTTPResponse {
        for (index, step) in steps.enumerated() {
            do {
                let type = step["type"] as! String
                if type == "delay" {
                    sleep((step["seconds"] as? NSNumber)?.doubleValue ?? 0)
                } else if type == "wait_text" {
                    let match = try TextTapRequest(step)
                    let timeout = (step["timeout"] as? NSNumber)?.doubleValue ?? 6
                    let start = now()
                    var elapsed = 0.0
                    while true {
                        let (id, data) = try capture(device, OCRRequest.maxEdge(step))
                        if (try? match.match(ScreenOCR.recognize(data, device: id))) != nil { break }
                        elapsed = max(elapsed, now() - start)
                        guard elapsed < timeout else { throw DeviceError("wait_text timed out") }
                        let delay = min(0.1, timeout - elapsed)
                        sleep(delay)
                        elapsed += delay
                    }
                } else {
                    let response = try execute("/" + type, step, device)
                    if response.status != 200 {
                        let body = (try? JSONSerialization.jsonObject(with: response.body)) as? [String: Any]
                        let message = body?["error"] as? String ?? String(decoding: response.body, as: UTF8.self)
                        return .json(
                            [
                                "ok": false, "failed_step": index + 1, "completed": index,
                                "error": message,
                            ], status: response.status)
                    }
                }
            } catch {
                return .json(
                    ["ok": false, "failed_step": index + 1, "completed": index, "error": "\(error)"], status: 400)
            }
        }
        return .json(["ok": true, "completed": steps.count])
    }
}
