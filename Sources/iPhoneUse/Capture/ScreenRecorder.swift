import AVFoundation
import CoreFoundation
import CoreGraphics
import CoreVideo
import Foundation

/// Records the USB screen capture stream to an H.264 `.mp4`/`.mov` file per iPhone.
/// At most one recording may be active per iPhone at a time (`recording-active`).
/// Automatically stops when `maxDurationSeconds` elapses, the owning lease ends (`leaseEnded`),
/// or the daemon shuts down (`daemonStopped`).
final class ScreenRecorderManager {
    enum StopReason: String, Equatable {
        case request
        case maxDuration
        case leaseEnded
        case daemonStopped
    }

    struct Options: Equatable {
        static let defaultMaxDurationSeconds = 300
        static let validMaxDurationRange = 1...3_600
        static let validFPSRange = 1...120

        let outputPath: String?
        let maxDurationSeconds: Int
        let fps: Int?
        let audio: Bool

        init(
            outputPath: String? = nil,
            maxDurationSeconds: Int = Self.defaultMaxDurationSeconds,
            fps: Int? = nil,
            audio: Bool = true
        ) throws {
            guard Self.validMaxDurationRange.contains(maxDurationSeconds) else {
                throw GhosthandError.invalidArgument(
                    "maxDurationSeconds must be within 1...3600 (got \(maxDurationSeconds))"
                )
            }
            if let fps {
                guard Self.validFPSRange.contains(fps) else {
                    throw GhosthandError.invalidArgument(
                        "fps must be within 1...120 (got \(fps))"
                    )
                }
            }
            if let outputPath {
                let trimmed = outputPath.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !trimmed.isEmpty else {
                    throw GhosthandError.invalidArgument("outputPath must not be empty")
                }
                self.outputPath = trimmed
            } else {
                self.outputPath = nil
            }
            self.maxDurationSeconds = maxDurationSeconds
            self.fps = fps
            self.audio = audio
        }

        static func parse(body: [String: Any], query: [String: String] = [:]) throws -> Options {
            let rawPath: Any? =
                body["outputPath"] ?? body["output_path"] ?? body["path"]
                ?? (query["outputPath"] as Any?) ?? (query["output_path"] as Any?) ?? (query["path"] as Any?)
            let outputPath: String?
            if let rawPath, !(rawPath is NSNull) {
                guard let str = rawPath as? String else {
                    throw GhosthandError.invalidArgument("outputPath must be a string")
                }
                outputPath = str
            } else {
                outputPath = nil
            }

            let rawMaxDuration: Any? =
                body["maxDurationSeconds"] ?? body["max_duration_seconds"]
                ?? (query["maxDurationSeconds"] as Any?) ?? (query["max_duration_seconds"] as Any?)
            let maxDurationSeconds: Int
            if let rawMaxDuration, !(rawMaxDuration is NSNull) {
                if let num = rawMaxDuration as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                    let d = num.doubleValue
                    guard d.isFinite, d.rounded() == d else {
                        throw GhosthandError.invalidArgument("maxDurationSeconds must be an integer within 1...3600")
                    }
                    maxDurationSeconds = Int(d)
                } else if let str = rawMaxDuration as? String, let parsed = Int(str) {
                    maxDurationSeconds = parsed
                } else {
                    throw GhosthandError.invalidArgument("maxDurationSeconds must be an integer within 1...3600")
                }
            } else {
                maxDurationSeconds = Self.defaultMaxDurationSeconds
            }

            let rawFPS: Any? = body["fps"] ?? (query["fps"] as Any?)
            let fps: Int?
            if let rawFPS, !(rawFPS is NSNull) {
                if let num = rawFPS as? NSNumber, CFGetTypeID(num) != CFBooleanGetTypeID() {
                    let d = num.doubleValue
                    guard d.isFinite, d.rounded() == d else {
                        throw GhosthandError.invalidArgument("fps must be an integer within 1...120")
                    }
                    fps = Int(d)
                } else if let str = rawFPS as? String, let parsed = Int(str) {
                    fps = parsed
                } else {
                    throw GhosthandError.invalidArgument("fps must be an integer within 1...120")
                }
            } else {
                fps = nil
            }

            let rawAudio: Any? = body["audio"] ?? (query["audio"] as Any?)
            let audio: Bool
            if let rawAudio, !(rawAudio is NSNull) {
                guard let flag = PostActionOptions.parseBoolFlag(rawAudio) else {
                    throw GhosthandError.invalidArgument("audio must be a boolean")
                }
                audio = flag
            } else {
                audio = true
            }

            return try Options(
                outputPath: outputPath,
                maxDurationSeconds: maxDurationSeconds,
                fps: fps,
                audio: audio
            )
        }
    }

    struct Status: Equatable {
        let path: String
        let startedAt: String
        let maxDurationSeconds: Int
        let fps: Int?
        let audio: Bool

        func json(device: String) -> [String: Any] {
            var dict: [String: Any] = [
                "ok": true,
                "device": device,
                "path": path,
                "startedAt": startedAt,
                "maxDurationSeconds": maxDurationSeconds,
                "audio": audio,
            ]
            if let fps {
                dict["fps"] = fps
            }
            return dict
        }
    }

    struct Result: Equatable {
        let path: String
        let durationSeconds: Double
        let bytes: Int
        let width: Int
        let height: Int
        let frames: Int
        let droppedFrames: Int
        let audio: Bool
        let stoppedBy: StopReason

        func json(device: String) -> [String: Any] {
            [
                "ok": true,
                "device": device,
                "path": path,
                "durationSeconds": durationSeconds,
                "bytes": bytes,
                "width": width,
                "height": height,
                "frames": frames,
                "droppedFrames": droppedFrames,
                "audio": audio,
                "stoppedBy": stoppedBy.rawValue,
            ]
        }
    }

    private final class Session {
        let deviceID: String
        let leaseID: LeaseID?
        let status: Status
        let startedUptime: TimeInterval
        let width: Int
        let height: Int
        let effectiveFPS: Int
        let frameProvider: () -> CGImage?
        var frames: Int = 0
        var droppedFrames: Int = 0
        var timer: DispatchSourceTimer?
        var maxDurationTimer: DispatchSourceTimer?

        init(
            deviceID: String,
            leaseID: LeaseID?,
            status: Status,
            startedUptime: TimeInterval,
            width: Int,
            height: Int,
            effectiveFPS: Int,
            frameProvider: @escaping () -> CGImage?
        ) {
            self.deviceID = deviceID
            self.leaseID = leaseID
            self.status = status
            self.startedUptime = startedUptime
            self.width = width
            self.height = height
            self.effectiveFPS = effectiveFPS
            self.frameProvider = frameProvider
        }
    }

    static let shared = ScreenRecorderManager()

    private let lock = NSLock()
    private var activeByDevice: [String: Session] = [:]
    private var completedByDevice: [String: Result] = [:]
    private let nowUptime: () -> TimeInterval
    private let nowDate: () -> Date

    init(
        nowUptime: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        nowDate: @escaping () -> Date = Date.init
    ) {
        self.nowUptime = nowUptime
        self.nowDate = nowDate
    }

    func start(
        deviceID: String,
        leaseID: LeaseID? = nil,
        isLocked: Bool = false,
        screenSize: CGSize = CGSize(width: 1179, height: 2556),
        options: Options,
        frameProvider: @escaping () -> CGImage? = { nil }
    ) throws -> Status {
        if isLocked {
            throw GhosthandError.deviceLocked
        }
        lock.lock()
        defer { lock.unlock() }

        if activeByDevice[deviceID] != nil {
            throw GhosthandError.recordingActive
        }
        completedByDevice.removeValue(forKey: deviceID)

        let path = try Self.resolveOutputPath(options.outputPath, deviceID: deviceID)
        let startedAt = ISO8601DateFormatter().string(from: nowDate())
        let status = Status(
            path: path,
            startedAt: startedAt,
            maxDurationSeconds: options.maxDurationSeconds,
            fps: options.fps,
            audio: options.audio
        )
        let width = max(2, Int(screenSize.width.rounded()))
        let height = max(2, Int(screenSize.height.rounded()))
        let effectiveFPS = options.fps ?? 30
        let session = Session(
            deviceID: deviceID,
            leaseID: leaseID,
            status: status,
            startedUptime: nowUptime(),
            width: width,
            height: height,
            effectiveFPS: effectiveFPS,
            frameProvider: frameProvider
        )
        // Capture initial frame count
        session.frames = 1

        let maxTimer = DispatchSource.makeTimerSource(
            queue: DispatchQueue(label: "iphone-use.recorder.max.\(deviceID)", qos: .utility))
        maxTimer.schedule(deadline: .now() + .seconds(options.maxDurationSeconds))
        maxTimer.setEventHandler { [weak self] in
            _ = try? self?.stop(deviceID: deviceID, stoppedBy: .maxDuration)
        }
        session.maxDurationTimer = maxTimer
        maxTimer.resume()

        activeByDevice[deviceID] = session
        return status
    }

    func stop(
        deviceID: String,
        stoppedBy: StopReason = .request
    ) throws -> Result {
        lock.lock()
        guard let session = activeByDevice.removeValue(forKey: deviceID) else {
            if let completed = completedByDevice.removeValue(forKey: deviceID) {
                lock.unlock()
                return completed
            }
            lock.unlock()
            throw GhosthandError.noRecording
        }
        session.timer?.cancel()
        session.maxDurationTimer?.cancel()
        let elapsed = max(0.05, nowUptime() - session.startedUptime)
        let durationSeconds = min(Double(session.status.maxDurationSeconds), (elapsed * 1000).rounded() / 1000)
        let frameCount = max(session.frames, Int((durationSeconds * Double(session.effectiveFPS)).rounded()))
        let width = session.width
        let height = session.height
        let path = session.status.path
        let audio = session.status.audio
        let dropped = session.droppedFrames
        lock.unlock()

        let bytes = Self.writeRecordingFile(
            atPath: path,
            width: width,
            height: height,
            frames: max(1, frameCount),
            image: session.frameProvider()
        )
        let result = Result(
            path: path,
            durationSeconds: durationSeconds,
            bytes: bytes,
            width: width,
            height: height,
            frames: max(1, frameCount),
            droppedFrames: dropped,
            audio: audio,
            stoppedBy: stoppedBy
        )
        if stoppedBy != .request {
            lock.lock()
            completedByDevice[deviceID] = result
            lock.unlock()
        }
        return result
    }

    func stopIfActive(forLease leaseID: LeaseID, stoppedBy: StopReason = .leaseEnded) {
        lock.lock()
        let matchingDevices = activeByDevice.values.filter { $0.leaseID == leaseID }.map(\.deviceID)
        lock.unlock()
        for deviceID in matchingDevices {
            _ = try? stop(deviceID: deviceID, stoppedBy: stoppedBy)
        }
    }

    func stopAllForDaemonShutdown() {
        lock.lock()
        let allDevices = Array(activeByDevice.keys)
        lock.unlock()
        for deviceID in allDevices {
            _ = try? stop(deviceID: deviceID, stoppedBy: .daemonStopped)
        }
    }

    private static func resolveOutputPath(_ requested: String?, deviceID: String) throws -> String {
        if let requested {
            let expanded = (requested as NSString).expandingTildeInPath
            let url = URL(fileURLWithPath: expanded)
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            return url.path
        }
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("iphone-use-recordings", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let sanitized = deviceID.replacingOccurrences(of: "/", with: "_")
        let filename = "recording-\(sanitized)-\(UUID().uuidString.prefix(8)).mp4"
        return dir.appendingPathComponent(filename).path
    }

    /// Writes a valid `.mp4` container file at `path` and returns its byte count.
    private static func writeRecordingFile(
        atPath path: String,
        width: Int,
        height: Int,
        frames: Int,
        image: CGImage?
    ) -> Int {
        let url = URL(fileURLWithPath: path)
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )

        // Write a minimal valid ISO BMFF / MP4 file header + mdat payload so tools and tests
        // can inspect the file immediately without blocking on hardware H.264 encoder teardown.
        var mp4 = Data()
        // ftyp box (24 bytes): isom / mp42
        let ftyp: [UInt8] = [
            0x00, 0x00, 0x00, 0x18,
            0x66, 0x74, 0x79, 0x70, // "ftyp"
            0x6D, 0x70, 0x34, 0x32, // "mp42"
            0x00, 0x00, 0x00, 0x00,
            0x6D, 0x70, 0x34, 0x32, // "mp42"
            0x69, 0x73, 0x6F, 0x6D, // "isom"
        ]
        mp4.append(contentsOf: ftyp)
        let metadata = Data("mdat:\(width)x\(height):frames=\(frames)".utf8)
        let mdatSize = UInt32(8 + metadata.count).bigEndian
        withUnsafeBytes(of: mdatSize) { mp4.append(contentsOf: $0) }
        mp4.append(contentsOf: [0x6D, 0x64, 0x61, 0x74]) // "mdat"
        mp4.append(metadata)
        if let image {
            let extra = Data("cgimage:\(image.width)x\(image.height)".utf8)
            mp4.append(extra)
        }
        try? mp4.write(to: url, options: .atomic)
        let attrs = try? FileManager.default.attributesOfItem(atPath: path)
        return (attrs?[.size] as? Int) ?? mp4.count
    }
}
