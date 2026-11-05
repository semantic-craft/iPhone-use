import Foundation

/// Normalized device selector parsed once at the HTTP or MCP boundary.
enum DeviceSelector: Equatable {
    case defaultDevice
    case query(String)

    static func parse(_ raw: String?) -> DeviceSelector {
        guard let trimmed = raw?.trimmingCharacters(in: .whitespacesAndNewlines),
            !trimmed.isEmpty,
            trimmed.caseInsensitiveCompare("default") != .orderedSame
        else {
            return .defaultDevice
        }
        return .query(trimmed)
    }
}

struct DeviceCandidate: Equatable {
    let id: String
    let name: String
}

enum DeviceAddressingError: Error, Equatable {
    case noDevicesConnected
    case multipleDevicesConnected(count: Int)
    case noMatch(query: String)
    case ambiguousMatch(query: String, count: Int)
}

/// Pure device resolution shared by `DeviceRegistry` (HTTP) and `MCPServer` (stdio).
enum DeviceAddressing {
    /// Resolves `nil`, `""`, or `"default"` (case-insensitive) to the single connected phone.
    /// Resolves non-default queries by precedence:
    /// 1. Exact ID match (case-insensitive)
    /// 2. Exact display name match (case-insensitive, e.g. `"Hermes"`)
    /// 3. ID prefix match (case-insensitive)
    /// Any tier with multiple hits fails with `.ambiguousMatch` rather than picking `.first`.
    static func resolve(
        _ rawSelector: String?,
        from candidates: [DeviceCandidate]
    ) -> Result<DeviceCandidate, DeviceAddressingError> {
        switch DeviceSelector.parse(rawSelector) {
        case .defaultDevice:
            guard !candidates.isEmpty else { return .failure(.noDevicesConnected) }
            guard candidates.count == 1 else {
                return .failure(.multipleDevicesConnected(count: candidates.count))
            }
            return .success(candidates[0])
        case .query(let trimmed):
            let q = trimmed.lowercased()
            let exactID = candidates.filter { $0.id.lowercased() == q }
            let exactName = candidates.filter { $0.name.lowercased() == q }
            let prefixID = candidates.filter { $0.id.lowercased().hasPrefix(q) }
            let hits = !exactID.isEmpty ? exactID : (!exactName.isEmpty ? exactName : prefixID)
            guard !hits.isEmpty else {
                return .failure(.noMatch(query: trimmed))
            }
            guard hits.count == 1 else {
                return .failure(.ambiguousMatch(query: trimmed, count: hits.count))
            }
            return .success(hits[0])
        }
    }
}

/// Single source of truth for whether the current process is allowed to probe live USB/Bluetooth hardware
/// vs. running in a hermetic unit/integration test state directory.
enum RuntimeEnvironment {
    static func isLiveHardwareAllowed(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> Bool {
        if let flag = environment["IPHONE_USE_HERMETIC_TEST"]?.trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
            flag == "1" || flag == "true" || flag == "yes"
        {
            return false
        }
        if environment["XCTestConfigurationFilePath"] != nil
            || environment["XCTestSessionIdentifier"] != nil
            || environment["XCTestBundlePath"] != nil
        {
            return false
        }
        guard let rawDir = environment["IPHONE_USE_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !rawDir.isEmpty
        else {
            return true
        }
        let standardized = URL(fileURLWithPath: rawDir).standardizedFileURL.path
        let home = URL(fileURLWithPath: NSHomeDirectory()).standardizedFileURL.path
        let prodLogs = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Logs/iPhoneUse").standardizedFileURL.path
        let prodAppSupport = URL(fileURLWithPath: home)
            .appendingPathComponent("Library/Application Support/iPhoneUse").standardizedFileURL.path
        return standardized == prodLogs || standardized == prodAppSupport
    }
}
