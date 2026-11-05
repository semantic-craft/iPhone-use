import AVFoundation
import Foundation

enum SetupStep: String, Equatable {
    case trust
    case unlock
    case usbUnreadable
    case bluetoothUnavailable
    case pair
    case connecting
    case ready
}

enum CameraPermissionState: String, Equatable {
    case authorized
    case notDetermined
    case denied
    case restricted

    static func current() -> CameraPermissionState {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized:
            return .authorized
        case .notDetermined:
            return .notDetermined
        case .denied:
            return .denied
        case .restricted:
            return .restricted
        @unknown default:
            return .denied
        }
    }
}

struct SetupInputs: Equatable {
    struct PhoneSnapshot: Equatable {
        let id: String
        let name: String
        let trusted: Bool
        let hasFrame: Bool
        let captureError: String?
        let lockState: DeviceLockState
        let bluetoothState: DeviceBluetoothState
        let hasSavedPairing: Bool
        let pointerReady: Bool
        let activeLease: LeaseRecord?
        let waiting: [LeaseWaiterRecord]
    }

    let macName: String
    let camera: CameraPermissionState
    let bluetoothState: String
    let usbAttachedCount: Int
    let phones: [PhoneSnapshot]

    var bluetoothReady: Bool {
        let normalized = bluetoothState.lowercased()
        return normalized == "poweredon"
            || normalized == "on"
            || normalized.hasPrefix("advertising")
            || normalized.contains("connected")
    }
}

struct SetupPhoneAssessment: Equatable {
    let snapshot: SetupInputs.PhoneSnapshot
    let step: SetupStep

    func json() -> [String: Any] {
        var dict: [String: Any] = [
            "id": snapshot.id,
            "name": snapshot.name,
            "trusted": snapshot.trusted,
            "hasFrame": snapshot.hasFrame,
            "lockState": snapshot.lockState.rawValue,
            "bluetooth": snapshot.bluetoothState == .connected,
            "bluetoothState": snapshot.bluetoothState.rawValue,
            "pointerReady": snapshot.pointerReady,
            "step": step.rawValue,
        ]
        if let captureError = snapshot.captureError, !captureError.isEmpty {
            dict["captureError"] = captureError
        }
        if let lease = snapshot.activeLease {
            dict["lease"] = lease.infoJSON()
        }
        if !snapshot.waiting.isEmpty {
            dict["waiting"] = snapshot.waiting.map { $0.json() }
        }
        return dict
    }
}

struct SetupStatusReport: Equatable {
    let ready: Bool
    let device: String?
    let macName: String
    let camera: CameraPermissionState
    let bluetoothState: String
    let bluetoothReady: Bool
    let usbAttachedCount: Int
    let phones: [SetupPhoneAssessment]

    func json() -> [String: Any] {
        let overview: [String: Any] = [
            "mac": [
                "name": macName,
                "camera": camera.rawValue,
                "bluetooth": [
                    "state": bluetoothState,
                    "ready": bluetoothReady,
                ],
                "usbAttachedCount": usbAttachedCount,
            ],
            "phones": phones.map { $0.json() },
        ]
        var result: [String: Any] = [
            "ready": ready,
            "overview": overview,
        ]
        if let device {
            result["device"] = device
        } else {
            result["device"] = NSNull()
        }
        return result
    }
}

enum SetupReadiness {
    /// Classifies a single phone's next actionable setup step in deterministic priority order.
    static func classifyStep(
        for phone: SetupInputs.PhoneSnapshot,
        camera: CameraPermissionState,
        bluetoothReady: Bool
    ) -> SetupStep {
        if !phone.trusted || camera != .authorized {
            return .trust
        }
        if let error = phone.captureError, !error.isEmpty {
            return .usbUnreadable
        }
        if !phone.hasFrame || phone.lockState == .suspected {
            return .unlock
        }
        if phone.lockState == .paused {
            return .usbUnreadable
        }
        if !bluetoothReady {
            return .bluetoothUnavailable
        }
        if phone.bluetoothState == .disconnected && !phone.hasSavedPairing {
            return .pair
        }
        if phone.bluetoothState != .connected || !phone.pointerReady {
            return .connecting
        }
        return .ready
    }

    /// Evaluates system and phone snapshots into a pure `SetupStatusReport`.
    static func evaluate(query: String?, inputs: SetupInputs) -> SetupStatusReport {
        var effectivePhones = inputs.phones
        if effectivePhones.isEmpty && inputs.usbAttachedCount > 0 {
            effectivePhones = (0..<inputs.usbAttachedCount).map { index in
                SetupInputs.PhoneSnapshot(
                    id: index == 0 ? "usb-pending" : "usb-pending-\(index + 1)",
                    name: "iPhone",
                    trusted: false,
                    hasFrame: false,
                    captureError: nil,
                    lockState: .unknown,
                    bluetoothState: .disconnected,
                    hasSavedPairing: false,
                    pointerReady: false,
                    activeLease: nil,
                    waiting: []
                )
            }
        }

        let assessments = effectivePhones.map { phone in
            SetupPhoneAssessment(
                snapshot: phone,
                step: classifyStep(
                    for: phone,
                    camera: inputs.camera,
                    bluetoothReady: inputs.bluetoothReady
                )
            )
        }

        let candidates = assessments.map {
            DeviceCandidate(id: $0.snapshot.id, name: $0.snapshot.name)
        }
        let selectedDeviceID: String?
        switch DeviceAddressing.resolve(query, from: candidates) {
        case .success(let matched):
            selectedDeviceID = matched.id
        case .failure:
            selectedDeviceID = nil
        }

        let selectedAssessment = selectedDeviceID.flatMap { id in
            assessments.first { $0.snapshot.id == id }
        }
        let isReady =
            inputs.camera == .authorized
            && inputs.bluetoothReady
            && selectedAssessment?.step == .ready

        return SetupStatusReport(
            ready: isReady,
            device: selectedDeviceID,
            macName: inputs.macName,
            camera: inputs.camera,
            bluetoothState: inputs.bluetoothState,
            bluetoothReady: inputs.bluetoothReady,
            usbAttachedCount: inputs.usbAttachedCount,
            phones: assessments
        )
    }

    /// Collects live snapshots from the running daemon components.
    static func liveInputs(leaseStore: LeaseStore? = try? LeaseStore.current()) -> SetupInputs {
        let macName = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let camera = CameraPermissionState.current()
        let bluetoothState = HIDPeripheral.shared.state
        let topology = USBValeriaConfigurator.currentIOSUSBTopology()
        let usbCount: Int
        if case .observed(let observed) = topology {
            usbCount = observed.attachedEntryIDs.count
        } else {
            usbCount = 0
        }

        let devices = DeviceRegistry.shared.all()
        let savedPairings = DevicePairingStore().load() ?? [:]
        let activeLeases = (try? leaseStore?.activeLeasesByDevice()) ?? [:]

        var snapshots: [SetupInputs.PhoneSnapshot] = devices.map { device in
            let pointerReady: Bool
            if let host = device.host {
                let status = DeviceRegistry.shared.input(for: host, screen: device.screen).pointerStatus
                let readyFlag = (status["ready"] as? Bool) ?? false
                pointerReady =
                    readyFlag
                    && ScreenCaptureManager.shared.permitsPointerAssociation(for: device.screen)
            } else {
                pointerReady = false
            }
            let waiters = (try? leaseStore?.waiters(forDeviceID: device.id)) ?? []
            return SetupInputs.PhoneSnapshot(
                id: device.id,
                name: device.screen.name,
                trusted: true,
                hasFrame: device.screen.frame() != nil,
                captureError: device.screen.captureError,
                lockState: device.lockState,
                bluetoothState: device.bluetoothState,
                hasSavedPairing: savedPairings[device.id] != nil || device.host != nil,
                pointerReady: pointerReady,
                activeLease: activeLeases[device.id],
                waiting: waiters
            )
        }

        if snapshots.isEmpty && RuntimeEnvironment.isLiveHardwareAllowed() {
            for usbPhone in MobileDeviceLockdownBridge.attachedDevices() {
                let waiters = (try? leaseStore?.waiters(forDeviceID: usbPhone.udid)) ?? []
                let hasBT = !usbPhone.bluetoothAddress.isEmpty || savedPairings[usbPhone.udid] != nil
                let unlocked = !usbPhone.passwordProtected
                snapshots.append(
                    SetupInputs.PhoneSnapshot(
                        id: usbPhone.udid,
                        name: usbPhone.name,
                        trusted: usbPhone.trusted,
                        hasFrame: unlocked,
                        captureError: nil,
                        lockState: unlocked ? .notDetected : .suspected,
                        bluetoothState: hasBT ? .connected : .disconnected,
                        hasSavedPairing: hasBT,
                        pointerReady: hasBT && unlocked,
                        activeLease: activeLeases[usbPhone.udid],
                        waiting: waiters
                    )
                )
            }
        }

        return SetupInputs(
            macName: macName,
            camera: camera,
            bluetoothState: bluetoothState,
            usbAttachedCount: max(usbCount, snapshots.count),
            phones: snapshots
        )
    }
}
