import Foundation

/// `iphone-use mcp`: an MCP server over stdio that forwards to the running app's HTTP API.
/// Screenshots are scaled so the long edge is at most `longEdge`; tap and swipe
/// coordinates are read in that scaled image's pixels.
enum MCPServer {
    static let longEdge = 1000
    static var base = URL(string: "http://127.0.0.1:7390")!

    /// This process's language, fetched from the app's /config because the stdio
    /// server is a separate process and cannot read the app's UserDefaults.
    /// Stays English until the app answers, including against older apps that
    /// predate the endpoint. Fetched once per process at initialize/tools/list.
    static var language: AppLanguage = .en
    private static var languageLoaded = false
    private static var devicesCache = DeviceListCache()

    struct DeviceListCache {
        private var data: Data?
        private var expires: TimeInterval = 0
        private var origin: String = ""

        mutating func invalidate() { data = nil }

        func isValid(origin: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Bool {
            data != nil && self.origin == origin && now < expires
        }

        mutating func load(
            origin: String, now: TimeInterval = ProcessInfo.processInfo.systemUptime,
            fresh: Bool = false, fetch: () throws -> Data
        ) throws -> Data {
            if !fresh, self.origin == origin, now < expires, let data { return data }
            invalidate()
            let loaded = try fetch()
            data = loaded
            self.origin = origin
            expires = now + 2
            return loaded
        }
    }

    private static var client: MCPHTTPClient { MCPHTTPClient(base: base, language: language) }

    static func run() -> Never {
        if let port = ProcessInfo.processInfo.environment["IPHONE_USE_PORT"] {
            base = URL(string: "http://127.0.0.1:\(port)")!
        }
        while let line = readLine() {
            guard let data = line.data(using: .utf8),
                let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
            else { continue }
            // Refresh before protocol handling so response(to:) stays free of I/O.
            if let method = message["method"] as? String,
                method == "initialize" || method == "tools/list"
            {
                refreshLanguage()
            }
            if let response = response(to: message, callTool: call) {
                write(response)
            }
        }
        exit(0)
    }

    /// Best-effort: any failure (app down, old app, bad JSON) keeps the previous
    /// language, so an unreachable app never stalls or breaks the handshake.
    private static func refreshLanguage() {
        guard !languageLoaded else { return }
        guard let (data, http) = try? client.get("/config", timeout: 2, allowAutoStart: false),
            http.statusCode == 200,
            let raw = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let parsed = (raw["language"] as? String).flatMap(AppLanguage.init(rawValue:))
        else { return }
        language = parsed
        languageLoaded = true
    }

    /// Builds one JSON-RPC reply. Notifications and malformed envelopes are silent.
    /// Injecting tool execution keeps protocol handling independent of the HTTP bridge.
    static func response(
        to message: [String: Any], callTool: (String, [String: Any]) -> [String: Any]
    ) -> [String: Any]? {
        guard let id = message["id"], let method = message["method"] as? String else { return nil }
        let params = message["params"] as? [String: Any] ?? [:]
        let result: [String: Any]
        switch method {
        case "initialize":
            result = [
                "protocolVersion": params["protocolVersion"] as? String ?? "2025-06-18",
                "capabilities": ["tools": [:]],
                "serverInfo": ["name": "iphone-use", "version": "0.2.0"],
                "instructions": StringsMCP(language: language).instructions,
            ]
        case "tools/list":
            // Rebuilt per request so a process that loaded one language at
            // initialize serves a fresher one if the app switched in between.
            result = ["tools": MCPToolCatalog.tools(for: language)]
        case "tools/call":
            result = callTool(params["name"] as? String ?? "", params["arguments"] as? [String: Any] ?? [:])
        case "ping":
            result = [:]
        default:
            let error: [String: Any] = ["code": -32601, "message": "method not found: \(method)"]
            return ["jsonrpc": "2.0", "id": id, "error": error]
        }
        return ["jsonrpc": "2.0", "id": id, "result": result]
    }

    private static func call(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        let table = StringsMCP(language: language)
        do {
            let observe = arguments["observe"] as? String ?? "full"
            guard arguments["observe"] == nil || arguments["observe"] is String,
                ["full", "ocr_diff", "none"].contains(observe)
            else { throw MCPError("observe must be full, ocr_diff or none") }
            let includeImage: Bool
            if let raw = arguments["include_image"] {
                guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
                    throw MCPError(StringsAPI(language: language).ocrParameterInvalid("include_image"))
                }
                includeImage = value.boolValue
            } else {
                includeImage = true
            }

            if name == "release" || name == "release_lease" {
                let rawLease = arguments["lease"] ?? arguments["lease_id"] ?? arguments["id"]
                guard let leaseID = LeaseID.parse(rawLease) else {
                    throw MCPError(LeaseError.invalidLeaseID.localizedDescription(for: language))
                }
                let store = try LeaseStore.current()
                let released = try store.release(leaseID: leaseID)
                return try jsonTextResult([
                    "ok": true,
                    "id": leaseID.description,
                    "released": released != nil,
                ])
            }

            if name == "acquire" || name == "acquire_lease" || name == "wait" || name == "wait_lease" {
                return try callAcquireOrWait(name: name, arguments: arguments)
            }

            if name == "setup_status" {
                return try callSetupStatus(arguments: arguments)
            }

            let rawLease = arguments["lease"] ?? arguments["lease_id"]
            let leaseID: LeaseID?
            if let rawLease, !(rawLease is NSNull) {
                if let str = rawLease as? String, str.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    leaseID = nil
                } else if let parsed = LeaseID.parse(rawLease) {
                    leaseID = parsed
                } else {
                    throw MCPError(LeaseError.invalidLeaseID.localizedDescription(for: language))
                }
            } else {
                leaseID = nil
            }

            let actions: [MCPKeyboardAction]
            if name == "keyboard_sequence" {
                actions = try MCPKeyboardSequence.actions(arguments: arguments, language: language)
            } else {
                let action = try MCPToolRequest.action(
                    named: name, arguments: arguments, longEdge: longEdge, language: language)
                guard name == "list_devices" || name == "screenshot" || action != nil else {
                    return failure(table.unknownTool(name))
                }
                actions = action.map { [.request($0)] } ?? []
            }
            return try MCPAccess.withService(port: base.port ?? 7390, language: language) {
                let usedCache = name != "list_devices" && devicesCache.isValid(origin: base.absoluteString)
                let data = try devicesCache.load(origin: base.absoluteString, fresh: name == "list_devices") {
                    try client.get("/devices").0
                }
                if name == "list_devices" {
                    return ["content": [["type": "text", "text": enrichDeviceListText(data)]]]
                }
                let rawQuery = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
                let query = try resolveEffectiveMCPQuery(rawQuery, leaseID: leaseID)
                let device: String
                do {
                    device = try resolveDevice(query, data: data)
                } catch {
                    devicesCache.invalidate()
                    guard usedCache else { throw error }
                    let fresh = try devicesCache.load(origin: base.absoluteString) { try client.get("/devices").0 }
                    device = try resolveDevice(query, data: fresh)
                }
                return try MCPAccess.withDevice(port: base.port ?? 7390, id: device, language: language) {
                    let readOnlyNames: Set<String> = [
                        "screenshot", "ocr_screen", "screentext",
                        "photo_list", "photo_pull", "file_list", "file_pull",
                        "app_list", "device_info", "device_logs",
                    ]
                    let isReadOnlyTool =
                        readOnlyNames.contains(name)
                        || ((name == "assistivetouch" || name == "assistive_touch") && arguments["enabled"] == nil)
                    if leaseID != nil || !isReadOnlyTool {
                        do {
                            let store = try LeaseStore.current()
                            _ = try store.authorizeAndTouch(deviceID: device, leaseID: leaseID, command: name)
                        } catch let leaseError as LeaseError {
                            throw MCPError(leaseError.localizedDescription(for: language))
                        }
                    }
                    let directJSONTools: Set<String> = [
                        "ocr_screen", "screentext", "record_start", "recording_start",
                        "record_stop", "recording_stop", "lock",
                        "photo_list", "photo_pull", "photo_delete", "photo_push",
                        "file_list", "file_pull", "file_push", "file_remove",
                        "app_list", "open_app", "device_info", "device_logs",
                        "assistivetouch", "assistive_touch", "task",
                    ]
                    let isStructuredScroll =
                        name == "scroll"
                        && (arguments["until_text"] != nil || arguments["untilText"] != nil
                            || PostActionOptions.parseBoolFlag(arguments["collect"]) == true)
                    if directJSONTools.contains(name) || isStructuredScroll,
                        case .request(let action) = actions.first
                    {
                        var body = action.body
                        body["device"] = device
                        if let leaseID { body["lease"] = leaseID.description }
                        let data = try client.post(action.path, body)
                        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
                    }
                    let includeScreentext = PostActionOptions.parseBoolFlag(arguments["screentext"]) == true
                    let isNativeScreenshot =
                        name == "screenshot" && (PostActionOptions.parseBoolFlag(arguments["native"]) == true)
                    var lastPostResponse: Data?
                    for (index, action) in actions.enumerated() {
                        do {
                            switch action {
                            case .delay(let seconds):
                                Thread.sleep(forTimeInterval: seconds)
                            case .request(let request):
                                var body = request.body
                                body["device"] = device
                                lastPostResponse = try client.post(request.path, body)
                            }
                        } catch {
                            guard name == "keyboard_sequence" else { throw error }
                            throw MCPError(
                                table.keyboardStopped(index + 1, actions.count, "\(error)"))
                        }
                        if index < actions.count - 1 {
                            // Let focus changes settle without capturing every intermediate field.
                            Thread.sleep(forTimeInterval: 0.15)
                        }
                    }
                    if observe == "none"
                        || (name == "keyboard_sequence" && arguments["include_image"] as? Bool == false
                            && arguments["observe"] == nil)
                    {
                        if includeScreentext, let lastPostResponse,
                            let parsed = (try? JSONSerialization.jsonObject(with: lastPostResponse)) as? [String: Any],
                            let st = parsed["screentext"] as? String
                        {
                            return [
                                "content": [
                                    ["type": "text", "text": "{\"ok\":true}\n" + st]
                                ]
                            ]
                        }
                        return ["content": [["type": "text", "text": "{\"ok\":true}"]]]
                    }
                    if !actions.isEmpty {
                        // Keep the device lock through settling and final observation.
                        waitForStableFrame { remaining in
                            let encoded =
                                device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) ?? device
                            guard
                                let data = try? client.get(
                                    "/screenshot?maxEdge=64&device=\(encoded)&stability=1", timeout: remaining
                                ).0
                            else { return nil }
                            let hash = ScreenOCR.stabilitySignature(data)
                            return hash.isEmpty ? nil : hash
                        }
                    }
                    if observe == "ocr_diff" {
                        return try screenshot(device, includeImage: false, diff: true)
                    }
                    return try screenshot(
                        device,
                        includeImage: includeImage,
                        native: isNativeScreenshot,
                        includeScreentext: includeScreentext
                    )
                }
            }
        } catch let leaseError as LeaseError {
            devicesCache.invalidate()
            return failure(leaseError.localizedDescription(for: language))
        } catch {
            devicesCache.invalidate()
            return failure("\(error)")
        }
    }

    private static func resolveEffectiveMCPQuery(_ rawQuery: String?, leaseID: LeaseID?) throws -> String? {
        if let trimmed = rawQuery?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed.caseInsensitiveCompare("default") != .orderedSame
        {
            return rawQuery
        }
        guard let leaseID else { return rawQuery }
        let store = try LeaseStore.current()
        guard let record = try store.lease(byID: leaseID) else {
            throw LeaseError.leaseInvalid(leaseID)
        }
        return record.screenCaptureID
    }

    private static func enrichDeviceListText(_ data: Data) -> String {
        guard let store = try? LeaseStore.current(),
            let activeLeases = try? store.activeLeasesByDevice(),
            !activeLeases.isEmpty,
            var json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            var devices = json["devices"] as? [[String: Any]]
        else {
            return String(decoding: data, as: UTF8.self)
        }
        var modified = false
        for idx in devices.indices {
            if let id = devices[idx]["id"] as? String,
                devices[idx]["lease"] == nil,
                let lease = activeLeases[id]
            {
                devices[idx]["lease"] = lease.infoJSON()
                modified = true
            }
        }
        guard modified else {
            return String(decoding: data, as: UTF8.self)
        }
        json["devices"] = devices
        guard let encoded = try? JSONSerialization.data(withJSONObject: json, options: [.sortedKeys]) else {
            return String(decoding: data, as: UTF8.self)
        }
        return String(decoding: encoded, as: UTF8.self)
    }

    private static func callAcquireOrWait(name: String, arguments: [String: Any]) throws -> [String: Any] {
        let isWaitTool = name == "wait" || name == "wait_lease"
        guard let reason = arguments["reason"] as? String,
            !reason.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        else {
            throw LeaseError.invalidReason
        }
        let label = arguments["label"] as? String
        let idleTimeout: TimeInterval
        if let rawIdle = arguments["idleTimeoutSeconds"] ?? arguments["idle_timeout_s"], !(rawIdle is NSNull) {
            guard let num = rawIdle as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite
            else {
                throw LeaseError.invalidIdleTimeout
            }
            idleTimeout = num.doubleValue
        } else {
            idleTimeout = LeaseStore.defaultIdleTimeoutSeconds
        }
        let waitSeconds: TimeInterval?
        if let rawWait = arguments["waitSeconds"] ?? arguments["wait_seconds"], !(rawWait is NSNull) {
            guard let num = rawWait as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID(), num.doubleValue.isFinite
            else {
                throw LeaseError.invalidWaitTimeout
            }
            waitSeconds = num.doubleValue
        } else {
            waitSeconds = nil
        }
        let force: Bool
        if let rawForce = arguments["force"], !(rawForce is NSNull) {
            guard let num = rawForce as? NSNumber, CFGetTypeID(num) == CFBooleanGetTypeID() else {
                throw MCPError(StringsMCP(language: language).booleanRequired("force"))
            }
            force = num.boolValue
        } else {
            force = false
        }
        if force && (isWaitTool || waitSeconds != nil) {
            throw LeaseError.forceAndWaitMutuallyExclusive
        }

        return try MCPAccess.withService(port: base.port ?? 7390, language: language) {
            let query = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
            let data = try devicesCache.load(origin: base.absoluteString, fresh: true) {
                try client.get("/devices").0
            }
            let candidate = try resolveDeviceCandidate(query, data: data)
            let store = try LeaseStore.current()
            let acquisition: LeaseAcquisition
            if isWaitTool || waitSeconds != nil {
                acquisition = try store.wait(
                    deviceID: candidate.id,
                    deviceName: candidate.name,
                    reason: reason,
                    label: label,
                    idleTimeoutSeconds: idleTimeout,
                    waitSeconds: waitSeconds ?? LeaseStore.defaultIdleTimeoutSeconds
                )
            } else {
                acquisition = try store.acquire(
                    deviceID: candidate.id,
                    deviceName: candidate.name,
                    reason: reason,
                    label: label,
                    idleTimeoutSeconds: idleTimeout,
                    force: force
                )
            }
            return try jsonTextResult(acquisition.json())
        }
    }

    private static func callSetupStatus(arguments: [String: Any]) throws -> [String: Any] {
        let query = (arguments["device"] as? String) ?? (arguments["device_id"] as? String)
        return try MCPAccess.withService(port: base.port ?? 7390, language: language) {
            var setupPath = "/setup_status"
            if let query, !query.isEmpty,
                let encoded = query.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed)
            {
                setupPath += "?device=\(encoded)"
            }
            if let (data, http) = try? client.get(setupPath), http.statusCode == 200 {
                return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
            }
            // Fallback when talking to a mock server that only implements `/devices`.
            let data = try devicesCache.load(origin: base.absoluteString, fresh: true) {
                try client.get("/devices").0
            }
            guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                let devices = response["devices"] as? [[String: Any]]
            else {
                throw MCPError(StringsMCP(language: language).invalidDeviceList)
            }
            let store = try? LeaseStore.current()
            let activeLeases = (try? store?.activeLeasesByDevice()) ?? [:]
            let phones: [SetupInputs.PhoneSnapshot] = devices.compactMap { item in
                guard let id = item["id"] as? String, !id.isEmpty else { return nil }
                let name = (item["name"] as? String) ?? id
                let btConnected = (item["bluetooth"] as? Bool) ?? true
                let btStateRaw =
                    (item["bluetoothState"] as? String) ?? (btConnected ? "connected" : "disconnected")
                let btState = DeviceBluetoothState(rawValue: btStateRaw) ?? .connected
                let lockRaw = (item["lockState"] as? String) ?? "notDetected"
                let lockState = DeviceLockState(rawValue: lockRaw) ?? .notDetected
                let waiters = (try? store?.waiters(forDeviceID: id)) ?? []
                return SetupInputs.PhoneSnapshot(
                    id: id,
                    name: name,
                    trusted: true,
                    hasFrame: true,
                    captureError: item["captureError"] as? String,
                    lockState: lockState,
                    bluetoothState: btState,
                    hasSavedPairing: true,
                    pointerReady: btConnected,
                    activeLease: activeLeases[id],
                    waiting: waiters
                )
            }
            let inputs = SetupInputs(
                macName: Host.current().localizedName ?? ProcessInfo.processInfo.hostName,
                camera: .authorized,
                bluetoothState: "poweredOn",
                usbAttachedCount: phones.count,
                phones: phones
            )
            let report = SetupReadiness.evaluate(query: query, inputs: inputs)
            return try jsonTextResult(report.json())
        }
    }

    private static func jsonTextResult(_ object: [String: Any]) throws -> [String: Any] {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return ["content": [["type": "text", "text": String(decoding: data, as: UTF8.self)]]]
    }

    /// Bounded accumulated delays keep injected no-op sleep closures deterministic.
    static func waitForStableFrame(
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        frame: (TimeInterval) -> String?
    ) {
        let start = now()
        sleep(0.15)
        var elapsed = max(0.15, now() - start)
        guard elapsed < 0.6 else { return }
        var previous = frame(0.6 - elapsed)
        elapsed = max(elapsed, now() - start)
        if previous == nil {
            sleep(max(0, min(0.1, 0.6 - elapsed)))
            return
        }
        while elapsed < 0.6 {
            let interval = min(0.08, 0.6 - elapsed)
            sleep(interval)
            elapsed = max(elapsed + interval, now() - start)
            guard elapsed < 0.6 else { return }
            let current = frame(0.6 - elapsed)
            if let current, current == previous { return }
            previous = current
            elapsed = max(elapsed, now() - start)
        }
    }

    static func resolveDeviceCandidate(_ query: String?, data: Data) throws -> DeviceCandidate {
        guard let response = try JSONSerialization.jsonObject(with: data) as? [String: Any],
            let devices = response["devices"] as? [[String: Any]]
        else { throw MCPError(StringsMCP(language: language).invalidDeviceList) }
        let candidates: [DeviceCandidate] = devices.compactMap { item in
            guard let id = item["id"] as? String, !id.isEmpty else { return nil }
            let name = (item["name"] as? String) ?? id
            return DeviceCandidate(id: id, name: name)
        }
        switch DeviceAddressing.resolve(query, from: candidates) {
        case .success(let matched):
            return matched
        case .failure(.noDevicesConnected), .failure(.noMatch):
            throw MCPError(StringsMCP(language: language).expectedOneMatch(0))
        case .failure(.multipleDevicesConnected(let count)), .failure(.ambiguousMatch(_, let count)):
            throw MCPError(StringsMCP(language: language).expectedOneMatch(count))
        }
    }

    static func resolveDevice(_ query: String?, data: Data) throws -> String {
        try resolveDeviceCandidate(query, data: data).id
    }

    private static func screenshot(
        _ device: String?,
        includeImage: Bool,
        diff: Bool = false,
        native: Bool = false,
        includeScreentext: Bool = false
    ) throws -> [String: Any] {
        var path = "/screenshot?maxEdge=\(longEdge)"
        if let device, let encoded = device.addingPercentEncoding(withAllowedCharacters: .urlQueryAllowed) {
            path += "&device=\(encoded)"
        }
        if native {
            path += "&native=1"
        }
        path += "&ocr=1"
        let (image, response) = try client.get(path)
        let width = response.value(forHTTPHeaderField: "X-Image-Width") ?? "?"
        let height = response.value(forHTTPHeaderField: "X-Image-Height") ?? "?"
        let id = response.value(forHTTPHeaderField: "X-Device") ?? ""
        let serverOCR = response.value(forHTTPHeaderField: "X-Screen-OCR")
            .flatMap { Data(base64Encoded: $0) }.flatMap(ScreenOCR.decode)
        let ocr = serverOCR ?? ScreenOCR.recognize(image, device: id)
        if diff {
            guard !ocr.screenHash.isEmpty else { throw MCPError("OCR observation unavailable") }
            return ["content": [["type": "text", "text": ScreenOCR.summaryDiff(for: ocr, device: id)]]]
        }
        if !ocr.screenHash.isEmpty { _ = ScreenOCR.diff(device: id, current: ocr) }
        return screenshotContent(
            image: image, device: id, width: width, height: height,
            includeImage: includeImage, ocr: ocr,
            mimeType: response.value(forHTTPHeaderField: "Content-Type") ?? "image/jpeg",
            includeScreentext: includeScreentext)
    }

    /// Shared by image and text-only screenshots; OCR describes these exact bytes.
    static func screenshotContent(
        image: Data, device: String, width: String, height: String,
        includeImage: Bool, ocr: ScreenOCR.Result, mimeType: String = "image/jpeg",
        includeScreentext: Bool = false
    ) -> [String: Any] {
        var content: [[String: Any]] = []
        if includeImage {
            content.append(["type": "image", "data": image.base64EncodedString(), "mimeType": mimeType])
        }
        let caption = StringsMCP(language: language).screenshotCaption(device, width, height)
        var text = caption + (ocr.items.isEmpty ? "" : ocr.summary)
        if includeScreentext && !ocr.screentext.isEmpty {
            text += "\n" + ocr.screentext
        }
        content.append(["type": "text", "text": text])
        return ["content": content]
    }

    private static func write(_ object: [String: Any]) {
        guard let data = try? JSONSerialization.data(withJSONObject: object) else { return }
        FileHandle.standardOutput.write(data + Data("\n".utf8))
    }

    private static func failure(_ message: String) -> [String: Any] {
        ["content": [["type": "text", "text": message]], "isError": true]
    }

    static func executeToolCall(_ name: String, _ arguments: [String: Any]) -> [String: Any] {
        call(name, arguments)
    }

    struct MCPError: Error, CustomStringConvertible {
        let description: String
        init(_ description: String) { self.description = description }
    }
}

/// The stdio server's synchronous bridge to the app's local HTTP API.
/// Keep the semaphore wait and URLSession callback together: each MCP tool completes
/// its HTTP action before the server reads and processes the next input line.
private struct MCPHTTPClient {
    let base: URL
    let language: AppLanguage

    func get(
        _ path: String, timeout: TimeInterval = 60, allowAutoStart: Bool = true
    ) throws -> (Data, HTTPURLResponse) {
        try request(
            URLRequest(url: URL(string: path, relativeTo: base)!),
            timeout: timeout,
            allowAutoStart: allowAutoStart)
    }

    @discardableResult
    func post(_ path: String, _ body: [String: Any], allowAutoStart: Bool = true) throws -> Data {
        var request = URLRequest(url: URL(string: path, relativeTo: base)!)
        request.httpMethod = "POST"
        request.httpBody = try JSONSerialization.data(withJSONObject: body)
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        return try self.request(request, timeout: 60, allowAutoStart: allowAutoStart).0
    }

    private static func check(_ data: Data, status: Int, language: AppLanguage) -> MCPServer.MCPError {
        let body = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        let message = body?["error"] as? String ?? "HTTP \(status)"
        guard let body, body["failed_step"] != nil || body["completed"] != nil else {
            return MCPServer.MCPError(message)
        }
        var progress: [String: Any] = ["error": message]
        progress["failed_step"] = body["failed_step"]
        progress["completed"] = body["completed"]
        let encoded = try? JSONSerialization.data(withJSONObject: progress, options: [.sortedKeys])
        let details = encoded.map { String(decoding: $0, as: UTF8.self) } ?? message
        return MCPServer.MCPError(details + "\n" + StringsMCP(language: language).actStopped)
    }

    private func probeReady() -> Bool {
        guard let url = URL(string: "/config", relativeTo: base) else { return false }
        var probeRequest = URLRequest(url: url)
        probeRequest.timeoutInterval = 1.0
        guard case .success((_, let http)) = sendOnce(probeRequest, timeout: 1.0) else {
            return false
        }
        return http.statusCode == 200
    }

    private func request(
        _ request: URLRequest, timeout: TimeInterval, allowAutoStart: Bool = true
    ) throws -> (Data, HTTPURLResponse) {
        switch sendOnce(request, timeout: timeout) {
        case .success(let pair):
            return pair
        case .httpError(let err):
            throw err
        case .connectionError(let err):
            guard allowAutoStart else { throw err }
            let started = MCPServiceLauncher.ensureRunning(
                base: base,
                probe: { self.probeReady() }
            )
            guard started else { throw err }
            switch sendOnce(request, timeout: timeout) {
            case .success(let pair):
                return pair
            case .httpError(let retryErr), .connectionError(let retryErr):
                throw retryErr
            }
        }
    }

    private enum SendOutcome {
        case success((Data, HTTPURLResponse))
        case httpError(Error)
        case connectionError(Error)
    }

    private func sendOnce(_ request: URLRequest, timeout: TimeInterval) -> SendOutcome {
        let table = StringsMCP(language: language)
        var outcome: SendOutcome = .connectionError(MCPServer.MCPError(table.noResponse))
        let done = DispatchSemaphore(value: 0)
        var request = request
        request.timeoutInterval = timeout
        URLSession.shared.dataTask(with: request) { data, response, error in
            if let error {
                outcome = .connectionError(MCPServer.MCPError(table.appNotRunning(error.localizedDescription)))
            } else if let data, let http = response as? HTTPURLResponse {
                if http.statusCode == 200 {
                    outcome = .success((data, http))
                } else {
                    outcome = .httpError(Self.check(data, status: http.statusCode, language: language))
                }
            }
            done.signal()
        }.resume()
        done.wait()
        return outcome
    }
}
