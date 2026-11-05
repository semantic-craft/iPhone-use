import Darwin
import Foundation

/// Automatically launches the local `iphone-use` daemon in `--resident-quiet` mode
/// when an MCP tool call cannot connect to the local HTTP control server.
enum MCPServiceLauncher {
    typealias Spawner = (
        _ executable: URL,
        _ arguments: [String],
        _ environment: [String: String],
        _ logURL: URL
    ) throws -> Void

    /// Non-nil only when tests override the spawner in-process.
    nonisolated(unsafe) static var testSpawnerOverride: Spawner?

    static func resolveExecutableURL(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL? {
        if let override = environment["IPHONE_USE_EXECUTABLE"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            return URL(fileURLWithPath: override)
        }
        if let bundleExec = Bundle.main.executableURL,
            FileManager.default.isExecutableFile(atPath: bundleExec.path)
        {
            return bundleExec
        }
        if let arg0 = CommandLine.arguments.first, !arg0.isEmpty {
            let url = URL(fileURLWithPath: arg0)
            if FileManager.default.isExecutableFile(atPath: url.path) {
                return url
            }
        }
        return nil
    }

    /// Idempotently ensures the service at `base` is reachable.
    /// Returns `true` if the service became reachable, or `false` if auto-start is disabled or timed out.
    @discardableResult
    static func ensureRunning(
        base: URL,
        stateDirectory: URL? = nil,
        executableURL: URL? = nil,
        environment: [String: String] = ProcessInfo.processInfo.environment,
        timeout: TimeInterval = 10.0,
        pollInterval: TimeInterval = 0.1,
        probe: () -> Bool,
        spawn: Spawner? = nil,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) },
        now: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) -> Bool {
        if probe() {
            return true
        }
        if let flag = environment["IPHONE_USE_AUTO_START"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            flag == "0" || flag == "false" || flag == "no"
        {
            return false
        }

        let resolvedStateDir: URL
        if let stateDirectory {
            resolvedStateDir = stateDirectory
        } else if let dir = try? LeaseStore.defaultStateDirectory(environment: environment) {
            resolvedStateDir = dir
        } else {
            return false
        }

        do {
            try FileManager.default.createDirectory(at: resolvedStateDir, withIntermediateDirectories: true)
        } catch {
            return false
        }

        let port = base.port ?? 7390
        let lockURL = resolvedStateDir.appendingPathComponent("autostart-\(port).lock")
        let logURL = resolvedStateDir.appendingPathComponent("service-\(port).log")

        let fd = open(lockURL.path, O_CREAT | O_RDWR | O_CLOEXEC, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { return false }
        defer {
            _ = flock(fd, LOCK_UN)
            close(fd)
        }

        // Wait up to `timeout` for another process that might already be starting the daemon.
        let lockDeadline = now() + max(1.0, timeout)
        while true {
            if flock(fd, LOCK_EX | LOCK_NB) == 0 {
                break
            }
            if errno != EWOULDBLOCK && errno != EAGAIN && errno != EINTR {
                return false
            }
            if now() >= lockDeadline {
                return probe()
            }
            sleep(min(pollInterval, 0.05))
        }

        // Re-check inside the lock: if a peer just finished starting the daemon, we are done.
        if probe() {
            return true
        }

        guard let execURL = executableURL ?? resolveExecutableURL(environment: environment) else {
            return false
        }

        var childEnv = environment
        childEnv["IPHONE_USE_PORT"] = String(port)
        childEnv["IPHONE_USE_STATE_DIR"] = resolvedStateDir.path

        let effectiveSpawn = spawn ?? testSpawnerOverride ?? defaultSpawn
        do {
            try effectiveSpawn(execURL, ["--resident-quiet"], childEnv, logURL)
        } catch {
            return false
        }

        let readyDeadline = now() + max(0.2, timeout)
        while now() < readyDeadline {
            if probe() {
                return true
            }
            sleep(min(pollInterval, max(0.01, readyDeadline - now())))
        }
        return probe()
    }

    static func defaultSpawn(
        executable: URL,
        arguments: [String],
        environment: [String: String],
        logURL: URL
    ) throws {
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil)
        }
        let logHandle = try? FileHandle(forWritingTo: logURL)
        _ = try? logHandle?.seekToEnd()

        let process = Process()
        process.executableURL = executable
        process.arguments = arguments
        process.environment = environment
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = logHandle ?? FileHandle.nullDevice
        process.standardError = logHandle ?? FileHandle.nullDevice
        try process.run()
    }
}
