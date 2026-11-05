import Darwin
import Foundation
import SQLite3
import XCTest

@testable import iPhoneUse

final class LeaseAndAddressingTests: XCTestCase {
    private var tempDirectory: URL!
    private var previousStateDir: String?
    private var previousLanguage: AppLanguage = .en

    override func setUpWithError() throws {
        try super.setUpWithError()
        previousLanguage = AppLanguageStore.shared.language
        AppLanguageStore.shared.set(.en)
        previousStateDir = ProcessInfo.processInfo.environment["IPHONE_USE_STATE_DIR"]
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-slice-b-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tempDirectory, withIntermediateDirectories: true)
        setenv("IPHONE_USE_STATE_DIR", tempDirectory.path, 1)
    }

    override func tearDownWithError() throws {
        MCPServiceLauncher.testSpawnerOverride = nil
        if let previousStateDir {
            setenv("IPHONE_USE_STATE_DIR", previousStateDir, 1)
        } else {
            unsetenv("IPHONE_USE_STATE_DIR")
        }
        AppLanguageStore.shared.set(previousLanguage)
        if let tempDirectory {
            try? FileManager.default.removeItem(at: tempDirectory)
        }
        try super.tearDownWithError()
    }

    // MARK: - 1. Device Addressing ("Hermes", "default", USB ID, Prefix)

    func testDeviceAddressingResolvesHermesCaseInsensitivelyAndDefaultAndPrefix() throws {
        let hermes = DeviceCandidate(id: "00008110-001A2B3C4D5E6F", name: "Hermes")
        let apollo = DeviceCandidate(id: "00008120-99887766554433", name: "Apollo")

        // Single connected phone: nil, empty, and "default" (any case) resolve to Hermes.
        for selector in [nil, "", "   ", "default", "DEFAULT", "Default"] {
            XCTAssertEqual(
                DeviceAddressing.resolve(selector, from: [hermes]),
                .success(hermes),
                "Selector \(String(describing: selector)) should resolve to single device"
            )
        }

        // Multiple connected phones: "default" fails with .multipleDevicesConnected,
        // while "Hermes" (case-insensitive), exact ID, and unique ID prefix resolve cleanly.
        let twoPhones = [hermes, apollo]
        XCTAssertEqual(
            DeviceAddressing.resolve("default", from: twoPhones),
            .failure(.multipleDevicesConnected(count: 2))
        )
        for query in ["Hermes", "hermes", "HERMES", "  hermes  "] {
            XCTAssertEqual(
                DeviceAddressing.resolve(query, from: twoPhones),
                .success(hermes)
            )
        }
        XCTAssertEqual(
            DeviceAddressing.resolve("00008120-99887766554433", from: twoPhones),
            .success(apollo)
        )
        XCTAssertEqual(
            DeviceAddressing.resolve("00008110", from: twoPhones),
            .success(hermes)
        )

        // Ambiguous prefix ("000081") and duplicate display names fail with .ambiguousMatch.
        XCTAssertEqual(
            DeviceAddressing.resolve("000081", from: twoPhones),
            .failure(.ambiguousMatch(query: "000081", count: 2))
        )
        let duplicateHermes = [
            hermes,
            DeviceCandidate(id: "00008130-11223344556677", name: "hermes"),
        ]
        XCTAssertEqual(
            DeviceAddressing.resolve("Hermes", from: duplicateHermes),
            .failure(.ambiguousMatch(query: "Hermes", count: 2))
        )
        XCTAssertEqual(
            DeviceAddressing.resolve("NonExistent", from: twoPhones),
            .failure(.noMatch(query: "NonExistent"))
        )
        XCTAssertEqual(
            DeviceAddressing.resolve(nil, from: []),
            .failure(.noDevicesConnected)
        )
    }

    func testMCPResolveDeviceSupportsHermesDefaultAndRejectsAmbiguousNames() throws {
        let singlePayload = try JSONSerialization.data(withJSONObject: [
            "devices": [
                ["id": "usb-hermes-01", "name": "Hermes"]
            ]
        ])
        XCTAssertEqual(try MCPServer.resolveDevice(nil, data: singlePayload), "usb-hermes-01")
        XCTAssertEqual(try MCPServer.resolveDevice("default", data: singlePayload), "usb-hermes-01")
        XCTAssertEqual(try MCPServer.resolveDevice("HERMES", data: singlePayload), "usb-hermes-01")
        XCTAssertEqual(try MCPServer.resolveDevice("usb-hermes", data: singlePayload), "usb-hermes-01")

        let multiPayload = try JSONSerialization.data(withJSONObject: [
            "devices": [
                ["id": "usb-hermes-01", "name": "Hermes"],
                ["id": "usb-apollo-02", "name": "Apollo"],
            ]
        ])
        XCTAssertEqual(try MCPServer.resolveDevice("hermes", data: multiPayload), "usb-hermes-01")
        XCTAssertEqual(try MCPServer.resolveDevice("Apollo", data: multiPayload), "usb-apollo-02")
        XCTAssertThrowsError(try MCPServer.resolveDevice("default", data: multiPayload)) { error in
            XCTAssertTrue(String(describing: error).contains("found 2"))
        }
    }

    // MARK: - 2. SQLite state.db Schema & Monotonic Lease State Machine

    func testSQLiteStateDBSchemaMatchesGhosthandAndMonotonicCounterPersistsAcrossRestarts() throws {
        var now: TimeInterval = 1_700_000_000
        let store1 = try LeaseStore(stateDirectory: tempDirectory, now: { now })

        let first = try store1.acquire(
            deviceID: "usb-hermes-01",
            deviceName: "Hermes",
            reason: "check messages",
            label: "agent-alpha"
        )
        XCTAssertEqual(first.lease.id.description, "1")
        XCTAssertEqual(first.lease.idleTimeoutSeconds, 600)
        XCTAssertNil(first.replaced)

        // Verify exact SQLite table & column names in state.db match Ghosthand's state.db schema.
        var db: OpaquePointer?
        XCTAssertEqual(sqlite3_open_v2(store1.databaseURL.path, &db, SQLITE_OPEN_READONLY, nil), SQLITE_OK)
        defer { if let db { sqlite3_close(db) } }

        func columns(of table: String) throws -> Set<String> {
            var stmt: OpaquePointer?
            XCTAssertEqual(sqlite3_prepare_v2(db, "PRAGMA table_info(\(table));", -1, &stmt, nil), SQLITE_OK)
            defer { sqlite3_finalize(stmt) }
            var names: Set<String> = []
            while sqlite3_step(stmt) == SQLITE_ROW {
                if let ptr = sqlite3_column_text(stmt, 1) {
                    names.insert(String(cString: ptr))
                }
            }
            return names
        }

        let counterCols = try columns(of: "lease_counter")
        XCTAssertTrue(counterCols.isSuperset(of: ["id", "value"]))
        let leaseCols = try columns(of: "lease")
        XCTAssertTrue(
            leaseCols.isSuperset(of: [
                "id", "screen_capture_id", "label", "reason",
                "acquired_at", "idle_timeout_s", "last_used_at", "last_command",
            ])
        )

        // Release lease 1, re-open a brand new LeaseStore on the same directory, and verify lease ID is 2.
        let released = try store1.release(leaseID: first.lease.id)
        XCTAssertEqual(released?.id, first.lease.id)
        // Idempotent second release succeeds and returns nil.
        XCTAssertNil(try store1.release(leaseID: first.lease.id))

        now += 10
        let store2 = try LeaseStore(stateDirectory: tempDirectory, now: { now })
        let second = try store2.acquire(
            deviceID: "usb-hermes-01",
            deviceName: "Hermes",
            reason: "open Safari",
            label: "agent-beta"
        )
        XCTAssertEqual(second.lease.id.description, "2")
        XCTAssertEqual(try store2.currentCounterValue(), 2)
    }

    func testLeaseContentionForceTakeoverAndTenMinuteIdleTimeoutWithUnleasedCompatibility() throws {
        var now: TimeInterval = 1_700_000_000
        let store = try LeaseStore(stateDirectory: tempDirectory, now: { now })

        // 1. Before any lease is acquired, direct unleased calls succeed.
        let unleased = try store.authorizeAndTouch(deviceID: "usb-hermes-01", leaseID: nil, command: "tap")
        XCTAssertEqual(unleased.deviceID, "usb-hermes-01")
        XCTAssertNil(unleased.lease)

        // 2. Agent A acquires a lease on Hermes (default 600s = 10-minute idle timeout).
        let acq1 = try store.acquire(
            deviceID: "usb-hermes-01",
            deviceName: "Hermes",
            reason: "wechat reply",
            label: "ses_a"
        )
        XCTAssertEqual(acq1.lease.id.description, "1")
        XCTAssertEqual(acq1.lease.idleTimeoutSeconds, 600)

        // 3. While Lease 1 is active, a competing acquire without force fails with .deviceLeased.
        XCTAssertThrowsError(
            try store.acquire(
                deviceID: "usb-hermes-01",
                deviceName: "Hermes",
                reason: "competing task",
                label: "ses_b"
            )
        ) { error in
            guard case LeaseError.deviceLeased(let name, let holder) = error else {
                return XCTFail("Expected .deviceLeased, got \(error)")
            }
            XCTAssertEqual(name, "Hermes")
            XCTAssertEqual(holder.label, "ses_a")
            XCTAssertEqual(holder.reason, "wechat reply")
        }

        // 4. Direct unleased call on Hermes is rejected while Lease 1 is active,
        //    whereas another unleased phone ("usb-apollo-02") remains usable without a lease.
        XCTAssertThrowsError(
            try store.authorizeAndTouch(deviceID: "usb-hermes-01", leaseID: nil, command: "tap")
        ) { error in
            XCTAssertEqual((error as? LeaseError)?.errorCode, "device-leased")
        }
        XCTAssertNoThrow(
            try store.authorizeAndTouch(deviceID: "usb-apollo-02", leaseID: nil, command: "tap")
        )

        // 5. Leased call at t + 300s refreshes last_used_at and extends expiry to t + 900s.
        //    Also verifies omitting deviceID resolves it from the lease.
        now += 300
        let touched = try store.authorizeAndTouch(deviceID: nil, leaseID: acq1.lease.id, command: "swipe")
        XCTAssertEqual(touched.deviceID, "usb-hermes-01")
        XCTAssertEqual(touched.lease?.lastUsedAt, now)
        XCTAssertEqual(touched.lease?.lastCommand, "swipe")
        XCTAssertEqual(touched.lease?.expiresAt, now + 600)

        // At t + 899s (599s after last activity), Lease 1 is still active.
        now += 599
        XCTAssertThrowsError(
            try store.authorizeAndTouch(deviceID: "usb-hermes-01", leaseID: nil, command: "tap")
        )

        // At t + 900s (600s idle timeout reached), Lease 1 expires automatically:
        // direct unleased calls succeed again and the old lease ID is rejected as lease-invalid.
        now += 1
        XCTAssertNoThrow(
            try store.authorizeAndTouch(deviceID: "usb-hermes-01", leaseID: nil, command: "tap")
        )
        XCTAssertThrowsError(
            try store.authorizeAndTouch(deviceID: "usb-hermes-01", leaseID: acq1.lease.id, command: "tap")
        ) { error in
            XCTAssertEqual((error as? LeaseError)?.errorCode, "lease-invalid")
        }

        // 6. Acquire Lease 2 and test force takeover -> Lease 3 with `replaced` populated.
        let acq2 = try store.acquire(
            deviceID: "usb-hermes-01",
            deviceName: "Hermes",
            reason: "long job",
            label: "ses_b"
        )
        XCTAssertEqual(acq2.lease.id.description, "2")
        now += 5
        let acq3 = try store.acquire(
            deviceID: "usb-hermes-01",
            deviceName: "Hermes",
            reason: "urgent override",
            label: "ses_c",
            force: true
        )
        XCTAssertEqual(acq3.lease.id.description, "3")
        XCTAssertEqual(acq3.replaced?.id, acq2.lease.id)
        XCTAssertEqual(acq3.replaced?.label, "ses_b")
    }

    func testWaitBlocksUntilReleaseOrExpiryAndExposesWaiterInQueue() throws {
        let store = try LeaseStore(stateDirectory: tempDirectory)
        let first = try store.acquire(
            deviceID: "usb-hermes-01",
            deviceName: "Hermes",
            reason: "first holder",
            label: "holder-1"
        )
        XCTAssertEqual(first.lease.id.description, "1")

        let waiterEntered = expectation(description: "waiter registered in SQLite")
        let waitFinished = expectation(description: "wait acquired lease after release")
        var waitedAcquisition: LeaseAcquisition?

        DispatchQueue.global(qos: .userInitiated).async {
            var notified = false
            do {
                let result = try store.wait(
                    deviceID: "usb-hermes-01",
                    deviceName: "Hermes",
                    reason: "queued task",
                    label: "waiter-2",
                    idleTimeoutSeconds: 600,
                    waitSeconds: 5,
                    pollInterval: 0.02,
                    sleep: { interval in
                        if !notified {
                            notified = true
                            waiterEntered.fulfill()
                        }
                        Thread.sleep(forTimeInterval: interval)
                    }
                )
                waitedAcquisition = result
            } catch {
                XCTFail("wait failed unexpectedly: \(error)")
            }
            waitFinished.fulfill()
        }

        wait(for: [waiterEntered], timeout: 2.0)
        let activeWaiters = try store.waiters(forDeviceID: "usb-hermes-01")
        XCTAssertEqual(activeWaiters.count, 1)
        XCTAssertEqual(activeWaiters.first?.label, "waiter-2")
        XCTAssertEqual(activeWaiters.first?.reason, "queued task")

        // Release Lease 1 so the waiting thread acquires Lease 2.
        _ = try store.release(leaseID: first.lease.id)
        wait(for: [waitFinished], timeout: 2.0)

        XCTAssertEqual(waitedAcquisition?.lease.id.description, "2")
        XCTAssertEqual(waitedAcquisition?.lease.label, "waiter-2")
        XCTAssertTrue(try store.waiters(forDeviceID: "usb-hermes-01").isEmpty)
    }

    // MARK: - 3. Setup Readiness Check (`setup_status`)

    func testSetupReadinessStepProgressionAndHermesSelection() throws {
        func makePhone(
            id: String = "usb-hermes-01",
            name: String = "Hermes",
            trusted: Bool = true,
            hasFrame: Bool = true,
            captureError: String? = nil,
            lockState: DeviceLockState = .notDetected,
            bluetoothState: DeviceBluetoothState = .connected,
            hasSavedPairing: Bool = true,
            pointerReady: Bool = true
        ) -> SetupInputs.PhoneSnapshot {
            SetupInputs.PhoneSnapshot(
                id: id,
                name: name,
                trusted: trusted,
                hasFrame: hasFrame,
                captureError: captureError,
                lockState: lockState,
                bluetoothState: bluetoothState,
                hasSavedPairing: hasSavedPairing,
                pointerReady: pointerReady,
                activeLease: nil,
                waiting: []
            )
        }

        // 1. USB attached but no trusted capture session yet -> synthesized phone with step = .trust
        let untrustedUSB = SetupReadiness.evaluate(
            query: nil,
            inputs: SetupInputs(
                macName: "Studio",
                camera: .authorized,
                bluetoothState: "poweredOn",
                usbAttachedCount: 1,
                phones: []
            )
        )
        XCTAssertFalse(untrustedUSB.ready)
        XCTAssertEqual(untrustedUSB.phones.first?.step, .trust)

        // 2. Locked phone -> step = .unlock
        let locked = SetupReadiness.evaluate(
            query: "hermes",
            inputs: SetupInputs(
                macName: "Studio",
                camera: .authorized,
                bluetoothState: "poweredOn",
                usbAttachedCount: 1,
                phones: [makePhone(lockState: .suspected)]
            )
        )
        XCTAssertFalse(locked.ready)
        XCTAssertEqual(locked.device, "usb-hermes-01")
        XCTAssertEqual(locked.phones.first?.step, .unlock)

        // 3. USB capture error -> step = .usbUnreadable
        let unreadable = SetupReadiness.evaluate(
            query: "Hermes",
            inputs: SetupInputs(
                macName: "Studio",
                camera: .authorized,
                bluetoothState: "poweredOn",
                usbAttachedCount: 1,
                phones: [makePhone(captureError: "cannot open (-11800)")]
            )
        )
        XCTAssertFalse(unreadable.ready)
        XCTAssertEqual(unreadable.phones.first?.step, .usbUnreadable)

        // 4. Bluetooth powered off -> step = .bluetoothUnavailable
        let btOff = SetupReadiness.evaluate(
            query: "Hermes",
            inputs: SetupInputs(
                macName: "Studio",
                camera: .authorized,
                bluetoothState: "poweredOff",
                usbAttachedCount: 1,
                phones: [makePhone()]
            )
        )
        XCTAssertFalse(btOff.ready)
        XCTAssertEqual(btOff.phones.first?.step, .bluetoothUnavailable)

        // 5. Unpaired Bluetooth -> step = .pair
        let unpaired = SetupReadiness.evaluate(
            query: "Hermes",
            inputs: SetupInputs(
                macName: "Studio",
                camera: .authorized,
                bluetoothState: "poweredOn",
                usbAttachedCount: 1,
                phones: [makePhone(bluetoothState: .disconnected, hasSavedPairing: false, pointerReady: false)]
            )
        )
        XCTAssertFalse(unpaired.ready)
        XCTAssertEqual(unpaired.phones.first?.step, .pair)

        // 6. Paired Bluetooth still reconnecting -> step = .connecting
        let connecting = SetupReadiness.evaluate(
            query: "Hermes",
            inputs: SetupInputs(
                macName: "Studio",
                camera: .authorized,
                bluetoothState: "poweredOn",
                usbAttachedCount: 1,
                phones: [makePhone(bluetoothState: .unmatched, hasSavedPairing: true, pointerReady: false)]
            )
        )
        XCTAssertFalse(connecting.ready)
        XCTAssertEqual(connecting.phones.first?.step, .connecting)

        // 7. Two phones connected (Hermes ready, Apollo locked):
        //    "default" is not ready (ambiguous), while query = "hermes" is ready!
        let twoPhonesInputs = SetupInputs(
            macName: "Studio",
            camera: .authorized,
            bluetoothState: "poweredOn",
            usbAttachedCount: 2,
            phones: [
                makePhone(id: "usb-hermes-01", name: "Hermes"),
                makePhone(id: "usb-apollo-02", name: "Apollo", lockState: .suspected),
            ]
        )
        let defaultReport = SetupReadiness.evaluate(query: "default", inputs: twoPhonesInputs)
        XCTAssertFalse(defaultReport.ready)
        XCTAssertNil(defaultReport.device)

        let hermesReport = SetupReadiness.evaluate(query: "hermes", inputs: twoPhonesInputs)
        XCTAssertTrue(hermesReport.ready)
        XCTAssertEqual(hermesReport.device, "usb-hermes-01")
    }

    // MARK: - 4. HTTP ControlAPI & MCP Auto-Start (`--resident-quiet`)

    func testHTTPControlAPILeaseAndSetupStatusRoutes() throws {
        let candidates = [
            DeviceCandidate(id: "usb-hermes-01", name: "Hermes"),
            DeviceCandidate(id: "usb-apollo-02", name: "Apollo"),
        ]
        let setupInputs = SetupInputs(
            macName: "Studio",
            camera: .authorized,
            bluetoothState: "poweredOn",
            usbAttachedCount: 2,
            phones: [
                SetupInputs.PhoneSnapshot(
                    id: "usb-hermes-01",
                    name: "Hermes",
                    trusted: true,
                    hasFrame: true,
                    captureError: nil,
                    lockState: .notDetected,
                    bluetoothState: .connected,
                    hasSavedPairing: true,
                    pointerReady: true,
                    activeLease: nil,
                    waiting: []
                )
            ]
        )

        func send(_ method: String, _ path: String, _ body: [String: Any] = [:]) throws -> (Int, [String: Any]) {
            let payload = try JSONSerialization.data(withJSONObject: body)
            let wire =
                Data("\(method) \(path) HTTP/1.1\r\nContent-Length: \(payload.count)\r\n\r\n".utf8) + payload
            let req = try XCTUnwrap(HTTPRequest.parse(wire))
            let resp = ControlAPI.handle(
                req,
                ocrCapture: { query, _ in (query ?? "usb-hermes-01", Data()) },
                deviceCandidates: candidates,
                setupInputs: setupInputs
            )
            let json = try XCTUnwrap(JSONSerialization.jsonObject(with: resp.body) as? [String: Any])
            return (resp.status, json)
        }

        // 1. GET /setup_status?device=hermes
        let (setupCode, setupJSON) = try send("GET", "/setup_status?device=hermes")
        XCTAssertEqual(setupCode, 200)
        XCTAssertEqual(setupJSON["ready"] as? Bool, true)
        XCTAssertEqual(setupJSON["device"] as? String, "usb-hermes-01")

        // 2. POST /leases with device="Hermes"
        let (acqCode, acqJSON) = try send(
            "POST",
            "/leases",
            ["device": "Hermes", "reason": "automated smoke test", "label": "http-client-1"]
        )
        XCTAssertEqual(acqCode, 200)
        XCTAssertEqual(acqJSON["id"] as? String, "1")
        XCTAssertEqual(acqJSON["device"] as? String, "usb-hermes-01")
        XCTAssertEqual(acqJSON["deviceName"] as? String, "Hermes")
        XCTAssertEqual(acqJSON["idleTimeoutSeconds"] as? Int, 600)

        // 3. Competing POST /leases without force returns HTTP 409 device-leased
        let (conflictCode, conflictJSON) = try send(
            "POST",
            "/leases",
            ["device": "hermes", "reason": "other client"]
        )
        XCTAssertEqual(conflictCode, 409)
        XCTAssertEqual(conflictJSON["code"] as? String, "device-leased")

        // 4. Unleased POST /home on Hermes returns HTTP 409 device-leased
        let (unleasedHomeCode, unleasedHomeJSON) = try send(
            "POST",
            "/home",
            ["device": "Hermes"]
        )
        XCTAssertEqual(unleasedHomeCode, 409)
        XCTAssertEqual(unleasedHomeJSON["code"] as? String, "device-leased")

        // 5. Release lease via POST /leases/release
        let (relCode, relJSON) = try send("POST", "/leases/release", ["lease": "1"])
        XCTAssertEqual(relCode, 200)
        XCTAssertEqual(relJSON["released"] as? Bool, true)
    }

    func testMCPAutoLaunchesResidentQuietDaemonAndExecutesHermesLeaseLifecycle() throws {
        // Bind an ephemeral localhost port by opening and closing a socket, then let the
        // auto-start spawner start a lightweight HTTPServer on that port when MCPServer connects!
        let probeSocket = socket(AF_INET, SOCK_STREAM, 0)
        XCTAssertGreaterThanOrEqual(probeSocket, 0)
        var addr = sockaddr_in()
        addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
        addr.sin_family = sa_family_t(AF_INET)
        addr.sin_port = 0
        addr.sin_addr = in_addr(s_addr: inet_addr("127.0.0.1"))
        let bindRC = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(probeSocket, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        XCTAssertEqual(bindRC, 0)
        var len = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(probeSocket, $0, &len)
            }
        }
        let port = UInt16(bigEndian: addr.sin_port)
        close(probeSocket)

        let previousBase = MCPServer.base
        MCPServer.base = URL(string: "http://127.0.0.1:\(port)")!
        defer { MCPServer.base = previousBase }

        var spawnedArguments: [[String]] = []
        var spawnedEnvironments: [[String: String]] = []
        var backgroundServer: HTTPServer?
        defer { _ = backgroundServer }

        MCPServiceLauncher.testSpawnerOverride = { _, arguments, environment, _ in
            spawnedArguments.append(arguments)
            spawnedEnvironments.append(environment)
            let server = HTTPServer(port: port) { request in
                switch (request.method, request.path) {
                case ("GET", "/config"):
                    return .json(["language": "en"])
                case ("GET", "/devices"):
                    return .json([
                        "devices": [
                            [
                                "id": "usb-hermes-01",
                                "name": "Hermes",
                                "bluetooth": true,
                                "bluetoothState": "connected",
                                "lockState": "notDetected",
                            ]
                        ]
                    ])
                default:
                    return ControlAPI.handle(request)
                }
            }
            try server.start()
            backgroundServer = server
        }

        // 1. Call `acquire` through MCPServer when the daemon is NOT running yet.
        //    MCPHTTPClient should auto-launch with `["--resident-quiet"]`, wait until `/config` is ready,
        //    resolve "hermes" case-insensitively, and acquire Lease 1!
        let acquireReply = MCPServer.executeToolCall(
            "acquire",
            ["device": "hermes", "reason": "MCP auto-start test", "label": "mcp-session"]
        )
        XCTAssertNil(acquireReply["isError"], "Expected acquire to succeed after auto-start: \(acquireReply)")
        XCTAssertEqual(spawnedArguments, [["--resident-quiet"]])
        XCTAssertEqual(spawnedEnvironments.first?["IPHONE_USE_PORT"], String(port))

        let acquireText = try XCTUnwrap(
            (acquireReply["content"] as? [[String: Any]])?.first?["text"] as? String
        )
        let acquireJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(acquireText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(acquireJSON["id"] as? String, "1")
        XCTAssertEqual(acquireJSON["device"] as? String, "usb-hermes-01")
        XCTAssertEqual(acquireJSON["deviceName"] as? String, "Hermes")

        // 2. Call `setup_status` via MCPServer and verify lease metadata is included.
        let statusReply = MCPServer.executeToolCall("setup_status", ["device": "Hermes"])
        XCTAssertNil(statusReply["isError"])
        let statusText = try XCTUnwrap(
            (statusReply["content"] as? [[String: Any]])?.first?["text"] as? String
        )
        let statusJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(statusText.utf8)) as? [String: Any]
        )
        XCTAssertNotNil(statusJSON["overview"])

        // 3. Release Lease 1 via MCPServer.
        let releaseReply = MCPServer.executeToolCall("release", ["lease": "1"])
        XCTAssertNil(releaseReply["isError"])
        let releaseText = try XCTUnwrap(
            (releaseReply["content"] as? [[String: Any]])?.first?["text"] as? String
        )
        let releaseJSON = try XCTUnwrap(
            JSONSerialization.jsonObject(with: Data(releaseText.utf8)) as? [String: Any]
        )
        XCTAssertEqual(releaseJSON["released"] as? Bool, true)
        // Verify the daemon was only spawned once across all three tool calls.
        XCTAssertEqual(spawnedArguments.count, 1)
    }
}
