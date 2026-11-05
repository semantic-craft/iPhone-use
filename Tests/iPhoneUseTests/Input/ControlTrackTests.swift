import XCTest
@testable import iPhoneUse

final class ControlTrackTests: XCTestCase {
    func testTrackModeParsing() {
        XCTAssertEqual(ControlTrackMode.parse("standard"), .standard)
        XCTAssertEqual(ControlTrackMode.parse("retail"), .standard)
        XCTAssertEqual(ControlTrackMode.parse("std"), .standard)
        XCTAssertEqual(ControlTrackMode.parse("enhanced"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("developer"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("dev"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("poki"), .enhanced)
        XCTAssertEqual(ControlTrackMode.parse("auto"), .auto)
        XCTAssertEqual(ControlTrackMode.parse("dual"), .auto)
        XCTAssertEqual(ControlTrackMode.parse("automatic"), .auto)
        XCTAssertNil(ControlTrackMode.parse("unknown"))
        XCTAssertNil(ControlTrackMode.parse(""))
        XCTAssertNil(ControlTrackMode.parse(nil))
    }

    func testCoordinatorInitialStateAndSwitchMode() {
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { _, _ in },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "test-device-001",
            mode: .auto,
            standardInputResolver: { dummyInput }
        )

        XCTAssertEqual(coordinator.mode, .auto)
        XCTAssertEqual(coordinator.state, .enhancedActive)
        XCTAssertNil(coordinator.degradationReason)

        coordinator.switchMode(.standard)
        XCTAssertEqual(coordinator.mode, .standard)
        XCTAssertEqual(coordinator.state, .standardActive)

        coordinator.switchMode(.enhanced)
        XCTAssertEqual(coordinator.mode, .enhanced)
        XCTAssertEqual(coordinator.state, .enhancedActive)
    }

    func testStandardModeAlwaysUsesStandardTrack() throws {
        var reportsSent: [(ReportID, [UInt8])] = []
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { reportID, bytes in
                reportsSent.append((reportID, bytes))
            },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "test-device-002",
            mode: .standard,
            standardInputResolver: { dummyInput }
        )

        try coordinator.button(name: "home")
        XCTAssertEqual(coordinator.state, .standardActive)
        XCTAssertFalse(reportsSent.isEmpty)
    }

    func testAutoModeFallbackToStandardWhenEnhancedFails() throws {
        var standardTapCalled = false
        let dummyInput = DeviceInput(
            host: UUID(),
            session: UUID(),
            sleep: { _ in },
            reportSender: { reportID, bytes in
                standardTapCalled = true
            },
            reportReadiness: { _, _, _ in true }
        )
        let coordinator = DualTrackInputCoordinator(
            udid: "non-existent-device-udid",
            mode: .auto,
            standardInputResolver: { dummyInput }
        )

        // Calling tap on auto mode with a non-existent device will cause enhanced driver to fail
        // and trigger automatic graceful fallback to standard input!
        try coordinator.tap(x: 100, y: 100, screenWidth: 390, screenHeight: 844)

        XCTAssertEqual(coordinator.state, .degradedToStandard)
        XCTAssertNotNil(coordinator.degradationReason)
        XCTAssertTrue(coordinator.degradationReason?.contains("Enhanced track failed on tap") == true)
        XCTAssertTrue(standardTapCalled)
    }

    func testControlAPITrackRoutes() throws {
        let reqStatus = HTTPRequest(method: "GET", path: "/track", query: [:], body: [:])
        let respStatus = ControlAPI.handle(reqStatus)
        // With no device connected, expect 400 or error json
        XCTAssertTrue(respStatus.status == 400 || respStatus.status == 200)

        let reqSwitchInvalid = HTTPRequest(
            method: "POST",
            path: "/track/switch",
            query: [:],
            body: ["mode": "invalid"]
        )
        let respSwitchInvalid = ControlAPI.handle(reqSwitchInvalid)
        XCTAssertEqual(respSwitchInvalid.status, 400)
    }
}
