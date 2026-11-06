import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO

/// A file or directory entry on the iPhone accessed over USB (AFC `/var/mobile/Media`
/// or an app's `Documents` container) or Camera Roll (`/DCIM`).
struct USBFileEntry: Codable, Equatable {
    let path: String
    let name: String
    let type: String
    let size: Int
    let modified: String
    let mediaType: String?

    init(
        path: String,
        name: String? = nil,
        type: String = "file",
        size: Int,
        modified: String,
        mediaType: String? = nil
    ) {
        self.path = path
        self.name = name ?? (path as NSString).lastPathComponent
        self.type = type
        self.size = size
        self.modified = modified
        self.mediaType = mediaType
    }

    func json() -> [String: Any] {
        var dict: [String: Any] = [
            "path": path,
            "name": name,
            "type": type,
            "kind": type,
            "size": size,
            "modified": modified,
        ]
        if let mediaType {
            dict["mediaType"] = mediaType
            dict["media_type"] = mediaType
        }
        return dict
    }

    func toJSON() -> [String: Any] { json() }
}

/// An installed iOS application reported over USB (`installation_proxy` + `springboardservices`).
struct USBAppEntry: Codable, Equatable {
    let bundleId: String
    let name: String
    let version: String?
    let system: Bool
    let installing: Bool
    let fileSharing: Bool
    let homeScreen: String?

    init(
        bundleId: String,
        name: String,
        version: String? = "1.0",
        system: Bool = false,
        installing: Bool = false,
        fileSharing: Bool = false,
        homeScreen: String? = nil
    ) {
        self.bundleId = bundleId
        self.name = name
        self.version = version
        self.system = system
        self.installing = installing
        self.fileSharing = fileSharing
        self.homeScreen = homeScreen
    }

    func json() -> [String: Any] {
        var dict: [String: Any] = [
            "bundleId": bundleId,
            "bundle_id": bundleId,
            "name": name,
            "system": system,
            "systemApp": system,
            "installing": installing,
            "fileSharing": fileSharing,
            "fileSharingEnabled": fileSharing,
        ]
        if let version { dict["version"] = version }
        if let homeScreen { dict["homeScreen"] = homeScreen }
        return dict
    }

    func toJSON() -> [String: Any] { json() }
}

/// Device metadata read over USB lockdown (`device_info` / `GET /info`). Works while locked.
struct USBDeviceInfo: Codable, Equatable {
    struct SIMLine: Codable, Equatable {
        let slot: Int
        let embedded: Bool
        let carrier: String
        let mcc: String
        let mnc: String

        func json() -> [String: Any] {
            [
                "slot": slot,
                "embedded": embedded,
                "carrier": carrier,
                "mcc": mcc,
                "mnc": mnc,
            ]
        }
    }

    struct SIMInfo: Codable, Equatable {
        let telephony: Bool
        let tray: String
        let lines: [SIMLine]

        func json() -> [String: Any] {
            [
                "telephony": telephony,
                "tray": tray,
                "lines": lines.map { $0.json() },
            ]
        }
    }

    let udid: String
    let name: String
    let model: String
    let modelName: String
    let iosVersion: String
    let build: String
    let serialNumber: String
    let batteryPercent: Int
    let charging: Bool
    let externalPower: Bool
    let storageTotalBytes: Int64
    let storageFreeBytes: Int64
    let language: String
    let locale: String
    let timeZone: String
    let wifiAddress: String
    let sim: SIMInfo
    let locked: Bool
    let assistiveTouchEnabled: Bool

    func json() -> [String: Any] {
        [
            "ok": true,
            "device": udid,
            "udid": udid,
            "name": name,
            "model": model,
            "modelName": modelName,
            "iosVersion": iosVersion,
            "build": build,
            "serialNumber": serialNumber,
            "batteryPercent": batteryPercent,
            "charging": charging,
            "externalPower": externalPower,
            "storageTotalBytes": storageTotalBytes,
            "storageFreeBytes": storageFreeBytes,
            "language": language,
            "locale": locale,
            "timeZone": timeZone,
            "wifiAddress": wifiAddress,
            "sim": sim.json(),
            "locked": locked,
            "assistiveTouchEnabled": assistiveTouchEnabled,
        ]
    }

    func toJSON() -> [String: Any] { json() }
}

/// Provider interface covering all 13 Slice D USB/media/system primitives.
protocol USBSystemProvider {
    func listPhotos(deviceID: String, limit: Int) throws -> [USBFileEntry]
    func pullPhoto(
        deviceID: String,
        nameOrPath: String,
        destinationPath: String?
    ) throws -> (entry: USBFileEntry, data: Data, savedPath: String?)
    func deletePhotos(deviceID: String, names: [String], isLocked: Bool) throws -> [String]
    func pushPhoto(
        deviceID: String,
        sourcePath: String?,
        data: Data?,
        fileName: String?,
        isLocked: Bool
    ) throws -> USBFileEntry

    func listFiles(
        deviceID: String,
        path: String,
        appBundleID: String?,
        recursive: Bool
    ) throws -> [USBFileEntry]
    func pullFile(
        deviceID: String,
        path: String,
        appBundleID: String?,
        destinationPath: String?
    ) throws -> (entry: USBFileEntry, data: Data, contentType: String, savedPath: String?)
    func pushFile(
        deviceID: String,
        path: String,
        appBundleID: String?,
        sourcePath: String?,
        data: Data?
    ) throws -> USBFileEntry
    func removeFile(deviceID: String, path: String, appBundleID: String?) throws -> String

    func listApps(deviceID: String, includeSystem: Bool) throws -> [USBAppEntry]
    func openApp(
        deviceID: String,
        appNameOrBundleID: String,
        urlScheme: String?,
        sendSpotlightLaunch: (String) throws -> Void
    ) throws -> [String: Any]

    func deviceInfo(deviceID: String, deviceName: String, isLocked: Bool) throws -> USBDeviceInfo
    func deviceLogs(
        deviceID: String,
        seconds: Double,
        grep: String?,
        process: String?,
        limit: Int
    ) throws -> [String]
    func getAssistiveTouch(deviceID: String) throws -> Bool
    func setAssistiveTouch(deviceID: String, enabled: Bool) throws -> Bool
}

/// File-backed & USB-integrated provider rooted in `<IPHONE_USE_STATE_DIR>/usb/<deviceID>/`.
/// Provides deterministic persistence across CLI, MCP stdio, and HTTP daemon processes while
/// enforcing all iOS AFC/Camera Roll/AssistiveTouch invariants.
final class StateDirUSBSystemProvider: USBSystemProvider {
    static let shared = StateDirUSBSystemProvider()

    static let supportedPhotoExtensions: Set<String> = [
        "jpg", "jpeg", "png", "heic", "heif", "gif", "webp", "mp4", "mov", "m4v",
    ]
    static let videoExtensions: Set<String> = ["mp4", "mov", "m4v"]

    private let lock = NSLock()
    private let environmentProvider: () -> [String: String]

    init(environmentProvider: @escaping () -> [String: String] = { ProcessInfo.processInfo.environment }) {
        self.environmentProvider = environmentProvider
    }

    init(baseDirectory: URL) {
        let path = baseDirectory.path
        self.environmentProvider = { ["IPHONE_USE_STATE_DIR": path] }
    }

    static func resolveBaseDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> URL {
        if let stateDir = environment["IPHONE_USE_STATE_DIR"],
            !stateDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return URL(fileURLWithPath: stateDir, isDirectory: true)
        }
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return URL(
            fileURLWithPath: (home as NSString).appendingPathComponent("Library/Logs/iPhoneUse"),
            isDirectory: true
        )
    }

    private func baseDirectory(for deviceID: String) throws -> URL {
        let env = environmentProvider()
        let rootPath: String
        if let stateDir = env["IPHONE_USE_STATE_DIR"], !stateDir.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            rootPath = stateDir
        } else {
            let home = FileManager.default.homeDirectoryForCurrentUser.path
            rootPath = (home as NSString).appendingPathComponent("Library/Logs/iPhoneUse")
        }
        let sanitizedDevice = deviceID.replacingOccurrences(of: "/", with: "_")
        let deviceRoot = URL(fileURLWithPath: rootPath, isDirectory: true)
            .appendingPathComponent("usb", isDirectory: true)
            .appendingPathComponent(sanitizedDevice.isEmpty ? "default" : sanitizedDevice, isDirectory: true)
        try ensureLayout(at: deviceRoot)
        return deviceRoot
    }

    private func ensureLayout(at deviceRoot: URL) throws {
        let fm = FileManager.default
        let mediaRoot = deviceRoot.appendingPathComponent("media", isDirectory: true)
        for folder in ["DCIM/100APPLE", "Downloads", "Books", "PublicStaging"] {
            let dir = mediaRoot.appendingPathComponent(folder, isDirectory: true)
            if !fm.fileExists(atPath: dir.path) {
                try fm.createDirectory(at: dir, withIntermediateDirectories: true)
            }
        }
        let appsDir = deviceRoot.appendingPathComponent("apps", isDirectory: true)
        if !fm.fileExists(atPath: appsDir.path) {
            try fm.createDirectory(at: appsDir, withIntermediateDirectories: true)
        }
        let appsManifest = deviceRoot.appendingPathComponent("installed_apps.json")
        if !fm.fileExists(atPath: appsManifest.path) {
            let defaultApps: [USBAppEntry] = [
                USBAppEntry(
                    bundleId: "com.zhiliaoapp.musically",
                    name: "TikTok",
                    version: "37.4.0",
                    system: false,
                    installing: false,
                    fileSharing: true,
                    homeScreen: "page 1"
                ),
                USBAppEntry(
                    bundleId: "org.videolan.vlc-ios",
                    name: "VLC",
                    version: "3.5.9",
                    system: false,
                    installing: false,
                    fileSharing: true,
                    homeScreen: "page 1"
                ),
                USBAppEntry(
                    bundleId: "com.burbn.instagram",
                    name: "Instagram",
                    version: "354.0.0",
                    system: false,
                    installing: false,
                    fileSharing: false,
                    homeScreen: "page 1, folder Social"
                ),
                USBAppEntry(
                    bundleId: "com.apple.Preferences",
                    name: "Settings",
                    version: "18.1",
                    system: true,
                    installing: false,
                    fileSharing: false,
                    homeScreen: "page 1"
                ),
                USBAppEntry(
                    bundleId: "com.apple.mobileslideshow",
                    name: "Photos",
                    version: "18.1",
                    system: true,
                    installing: false,
                    fileSharing: false,
                    homeScreen: "page 1"
                ),
                USBAppEntry(
                    bundleId: "com.apple.mobilesafari",
                    name: "Safari",
                    version: "18.1",
                    system: true,
                    installing: false,
                    fileSharing: false,
                    homeScreen: "dock"
                ),
                USBAppEntry(
                    bundleId: "com.apple.DocumentsApp",
                    name: "Files",
                    version: "18.1",
                    system: true,
                    installing: false,
                    fileSharing: true,
                    homeScreen: "page 1"
                ),
            ]
            let encoded = try JSONEncoder().encode(defaultApps)
            try encoded.write(to: appsManifest, options: .atomic)
            for app in defaultApps where app.fileSharing {
                let docDir = appsDir.appendingPathComponent(app.bundleId, isDirectory: true)
                if !fm.fileExists(atPath: docDir.path) {
                    try fm.createDirectory(at: docDir, withIntermediateDirectories: true)
                }
            }
        }
        let logsFile = deviceRoot.appendingPathComponent("syslog.txt")
        if !fm.fileExists(atPath: logsFile.path) {
            let initialLogs = [
                "2026-11-05T12:00:01.100Z SpringBoard[61]: [com.apple.springboard] FrontDisplayDidChange: HomeScreen",
                "2026-11-05T12:00:02.250Z SpringBoard[61]: [com.apple.springboard] Ringer muted state: unmuted",
                "2026-11-05T12:00:03.400Z appstored[142]: [com.apple.appstored] InstallationMonitor ready",
                "2026-11-05T12:00:04.510Z mobileassetd[98]: [com.apple.mobileassetd] PhotoLibrary sync complete",
            ].joined(separator: "\n") + "\n"
            try Data(initialLogs.utf8).write(to: logsFile, options: .atomic)
        }
    }

    private static func normalizeVirtualPath(_ rawPath: String) throws -> String {
        let trimmed = rawPath.trimmingCharacters(in: .whitespacesAndNewlines)
        let withLeading = trimmed.isEmpty ? "/" : (trimmed.hasPrefix("/") ? trimmed : "/" + trimmed)
        let components = withLeading.split(separator: "/", omittingEmptySubsequences: true).map(String.init)
        for comp in components {
            if comp == ".." || comp == "." {
                throw GhosthandError.invalidArgument("path must not contain '.' or '..' traversal segments: \(rawPath)")
            }
        }
        if components.isEmpty {
            return "/"
        }
        return "/" + components.joined(separator: "/")
    }

    private static func isoTimestamp(from date: Date = Date()) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter.string(from: date)
    }

    private static func mediaType(for fileName: String) -> String? {
        let ext = (fileName as NSString).pathExtension.lowercased()
        guard supportedPhotoExtensions.contains(ext) else { return nil }
        return videoExtensions.contains(ext) ? "video" : "image"
    }

    private func containerRoot(for deviceID: String, appBundleID: String?) throws -> URL {
        let root = try baseDirectory(for: deviceID)
        guard let rawApp = appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines), !rawApp.isEmpty else {
            return root.appendingPathComponent("media", isDirectory: true)
        }
        let allApps = try loadApps(at: root)
        guard let matched = allApps.first(where: { $0.bundleId.caseInsensitiveCompare(rawApp) == .orderedSame }) else {
            throw GhosthandError(
                code: "not-found",
                httpStatus: 404,
                message: "not-found: app \(rawApp) is not installed on this iPhone"
            )
        }
        guard matched.fileSharing else {
            throw GhosthandError(
                code: "permission-denied",
                httpStatus: 403,
                message: "permission-denied: app \(matched.bundleId) does not enable fileSharing"
            )
        }
        let appDir = root.appendingPathComponent("apps", isDirectory: true)
            .appendingPathComponent(matched.bundleId, isDirectory: true)
        if !FileManager.default.fileExists(atPath: appDir.path) {
            try FileManager.default.createDirectory(at: appDir, withIntermediateDirectories: true)
        }
        return appDir
    }

    private func loadApps(at deviceRoot: URL) throws -> [USBAppEntry] {
        let manifest = deviceRoot.appendingPathComponent("installed_apps.json")
        let data = try Data(contentsOf: manifest)
        return try JSONDecoder().decode([USBAppEntry].self, from: data)
    }

    func appendLog(deviceID: String, process: String, message: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let root = try? baseDirectory(for: deviceID) else { return }
        let logsFile = root.appendingPathComponent("syslog.txt")
        let line = "\(Self.isoTimestamp()) \(process)[100]: \(message)\n"
        if let handle = try? FileHandle(forWritingTo: logsFile) {
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: Data(line.utf8))
        }
    }

    // MARK: - Photos

    func listPhotos(deviceID: String, limit: Int = 20) throws -> [USBFileEntry] {
        guard (1...10_000).contains(limit) else {
            throw GhosthandError.invalidArgument("limit must be within 1...10000 (got \(limit))")
        }
        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        let dcimRoot = root.appendingPathComponent("media/DCIM", isDirectory: true)
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(
            at: dcimRoot,
            includingPropertiesForKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            return []
        }

        var items: [(entry: USBFileEntry, modDate: Date)] = []
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.isRegularFileKey, .fileSizeKey, .contentModificationDateKey]
            )
            guard values?.isRegularFile == true else { continue }
            let mediaRootPath = root.appendingPathComponent("media", isDirectory: true).path
            let relPath: String
            if fileURL.path.hasPrefix(mediaRootPath) {
                let suffix = String(fileURL.path.dropFirst(mediaRootPath.count))
                relPath = suffix.hasPrefix("/") ? suffix : "/" + suffix
            } else {
                relPath = "/DCIM/100APPLE/" + fileURL.lastPathComponent
            }
            let modDate = values?.contentModificationDate ?? Date()
            let size = values?.fileSize ?? ((try? Data(contentsOf: fileURL).count) ?? 0)
            let entry = USBFileEntry(
                path: relPath,
                name: fileURL.lastPathComponent,
                type: "file",
                size: size,
                modified: Self.isoTimestamp(from: modDate),
                mediaType: Self.mediaType(for: fileURL.lastPathComponent)
            )
            items.append((entry, modDate))
        }

        items.sort { lhs, rhs in
            if lhs.modDate != rhs.modDate {
                return lhs.modDate > rhs.modDate
            }
            return lhs.entry.name > rhs.entry.name
        }
        return Array(items.prefix(limit).map(\.entry))
    }

    func pullPhoto(
        deviceID: String,
        nameOrPath: String,
        destinationPath: String?
    ) throws -> (entry: USBFileEntry, data: Data, savedPath: String?) {
        let trimmed = nameOrPath.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw GhosthandError.invalidArgument("photo name or path must not be empty")
        }
        if trimmed.contains("..") {
            throw GhosthandError.invalidArgument("photo name or path must not contain '..'")
        }
        let allPhotos = try listPhotos(deviceID: deviceID, limit: 10_000)
        let targetName = (trimmed as NSString).lastPathComponent
        guard let matched = allPhotos.first(where: {
            $0.path.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.name.caseInsensitiveCompare(targetName) == .orderedSame
        }) else {
            throw GhosthandError(
                code: "not-found",
                httpStatus: 404,
                message: "not-found: photo '\(trimmed)' was not found in /DCIM"
            )
        }
        lock.lock()
        let root = try baseDirectory(for: deviceID)
        let hostURL = root.appendingPathComponent("media", isDirectory: true)
            .appendingPathComponent(String(matched.path.dropFirst()))
        let data = try Data(contentsOf: hostURL)
        lock.unlock()

        var savedPath: String?
        if let rawDest = destinationPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDest.isEmpty {
            let destURL = URL(fileURLWithPath: (rawDest as NSString).expandingTildeInPath)
            let parentDir = destURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parentDir.path) {
                try FileManager.default.createDirectory(at: parentDir, withIntermediateDirectories: true)
            }
            try data.write(to: destURL, options: .atomic)
            savedPath = destURL.path
        }
        return (matched, data, savedPath)
    }

    func deletePhotos(deviceID: String, names: [String], isLocked: Bool) throws -> [String] {
        if isLocked {
            throw GhosthandError.deviceLocked
        }
        let cleaned = names
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleaned.isEmpty else {
            throw GhosthandError.invalidArgument("names must contain at least one photo name")
        }
        for item in cleaned where item.contains("..") {
            throw GhosthandError.invalidArgument("photo name must not contain '..': \(item)")
        }

        let allPhotos = try listPhotos(deviceID: deviceID, limit: 10_000)
        var toDelete: [USBFileEntry] = []
        for requested in cleaned {
            let base = (requested as NSString).lastPathComponent
            guard let matched = allPhotos.first(where: {
                $0.name.caseInsensitiveCompare(requested) == .orderedSame
                    || $0.path.caseInsensitiveCompare(requested) == .orderedSame
                    || $0.name.caseInsensitiveCompare(base) == .orderedSame
            }) else {
                throw GhosthandError(
                    code: "not-found",
                    httpStatus: 404,
                    message: "not-found: photo '\(requested)' not found in Camera Roll"
                )
            }
            toDelete.append(matched)
        }

        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        var deletedNames: [String] = []
        for item in toDelete {
            let hostURL = root.appendingPathComponent("media", isDirectory: true)
                .appendingPathComponent(String(item.path.dropFirst()))
            if FileManager.default.fileExists(atPath: hostURL.path) {
                try FileManager.default.removeItem(at: hostURL)
            }
            deletedNames.append(item.name)
        }
        return deletedNames
    }

    func pushPhoto(
        deviceID: String,
        sourcePath: String?,
        data: Data?,
        fileName: String?,
        isLocked: Bool
    ) throws -> USBFileEntry {
        if isLocked {
            throw GhosthandError.deviceLocked
        }
        let payloadData: Data
        let resolvedName: String
        if let rawSource = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSource.isEmpty {
            let expanded = (rawSource as NSString).expandingTildeInPath
            let srcURL = URL(fileURLWithPath: expanded)
            guard FileManager.default.fileExists(atPath: srcURL.path) else {
                throw GhosthandError.invalidArgument("source file does not exist: \(rawSource)")
            }
            payloadData = try Data(contentsOf: srcURL)
            if let explicitName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty {
                resolvedName = (explicitName as NSString).lastPathComponent
            } else {
                resolvedName = srcURL.lastPathComponent
            }
        } else if let data {
            guard let explicitName = fileName?.trimmingCharacters(in: .whitespacesAndNewlines), !explicitName.isEmpty else {
                throw GhosthandError.invalidArgument("name with file extension is required when pushing raw photo/video data")
            }
            payloadData = data
            resolvedName = (explicitName as NSString).lastPathComponent
        } else {
            throw GhosthandError.invalidArgument("photo_push requires path/sourcePath or base64 data")
        }

        guard !payloadData.isEmpty else {
            throw GhosthandError.invalidArgument("photo_push file data must not be empty")
        }
        guard !resolvedName.contains(".."), !resolvedName.contains("/") else {
            throw GhosthandError.invalidArgument("invalid photo file name: \(resolvedName)")
        }
        let ext = (resolvedName as NSString).pathExtension.lowercased()
        guard Self.supportedPhotoExtensions.contains(ext) else {
            throw GhosthandError.invalidArgument(
                "unsupported photo/video extension '.\(ext)'; expected one of \(Self.supportedPhotoExtensions.sorted().joined(separator: ", "))"
            )
        }

        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        let stagingFile = root.appendingPathComponent("media/PublicStaging", isDirectory: true)
            .appendingPathComponent(resolvedName)
        try payloadData.write(to: stagingFile, options: .atomic)

        let dcimFolder = root.appendingPathComponent("media/DCIM/100APPLE", isDirectory: true)
        let dcimFile = dcimFolder.appendingPathComponent(resolvedName)
        let now = Date()
        try payloadData.write(to: dcimFile, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: dcimFile.path)

        let virtualPath = "/DCIM/100APPLE/\(resolvedName)"
        return USBFileEntry(
            path: virtualPath,
            name: resolvedName,
            type: "file",
            size: payloadData.count,
            modified: Self.isoTimestamp(from: now),
            mediaType: Self.mediaType(for: resolvedName)
        )
    }

    // MARK: - Files (AFC /var/mobile/Media & App Documents)

    func listFiles(
        deviceID: String,
        path: String,
        appBundleID: String?,
        recursive: Bool
    ) throws -> [USBFileEntry] {
        let normalizedPath = try Self.normalizeVirtualPath(path)
        lock.lock()
        defer { lock.unlock() }
        let container = try containerRoot(for: deviceID, appBundleID: appBundleID)
        let targetURL = normalizedPath == "/"
            ? container
            : container.appendingPathComponent(String(normalizedPath.dropFirst()))

        let fm = FileManager.default
        var isDir: ObjCBool = false
        guard fm.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            throw GhosthandError(
                code: "not-found",
                httpStatus: 404,
                message: "not-found: path '\(normalizedPath)' does not exist"
            )
        }

        if !isDir.boolValue {
            let attrs = try? fm.attributesOfItem(atPath: targetURL.path)
            let size = (attrs?[.size] as? NSNumber)?.intValue ?? 0
            let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
            return [
                USBFileEntry(
                    path: normalizedPath,
                    name: targetURL.lastPathComponent,
                    type: "file",
                    size: size,
                    modified: Self.isoTimestamp(from: modDate)
                )
            ]
        }

        var entries: [USBFileEntry] = []
        if recursive {
            guard let enumerator = fm.enumerator(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else {
                return []
            }
            for case let childURL as URL in enumerator {
                entries.append(makeFileEntry(for: childURL, relativeTo: container))
            }
        } else {
            let children = (try? fm.contentsOfDirectory(
                at: targetURL,
                includingPropertiesForKeys: [.isDirectoryKey, .fileSizeKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            )) ?? []
            for childURL in children {
                entries.append(makeFileEntry(for: childURL, relativeTo: container))
            }
        }
        return entries.sorted { $0.path < $1.path }
    }

    private func makeFileEntry(for url: URL, relativeTo container: URL) -> USBFileEntry {
        var isDir: ObjCBool = false
        _ = FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir)
        let attrs = try? FileManager.default.attributesOfItem(atPath: url.path)
        let size = isDir.boolValue ? 0 : ((attrs?[.size] as? NSNumber)?.intValue ?? 0)
        let modDate = (attrs?[.modificationDate] as? Date) ?? Date()
        let containerPath = container.standardizedFileURL.path
        let fullPath = url.standardizedFileURL.path
        let rel: String
        if fullPath.hasPrefix(containerPath) {
            let dropped = String(fullPath.dropFirst(containerPath.count))
            rel = dropped.hasPrefix("/") ? dropped : "/" + dropped
        } else {
            rel = "/" + url.lastPathComponent
        }
        return USBFileEntry(
            path: rel,
            name: url.lastPathComponent,
            type: isDir.boolValue ? "directory" : "file",
            size: size,
            modified: Self.isoTimestamp(from: modDate)
        )
    }

    func pullFile(
        deviceID: String,
        path: String,
        appBundleID: String?,
        destinationPath: String?
    ) throws -> (entry: USBFileEntry, data: Data, contentType: String, savedPath: String?) {
        let normalizedPath = try Self.normalizeVirtualPath(path)
        guard normalizedPath != "/" else {
            throw GhosthandError.invalidArgument("file_pull path must name a file or subfolder, not '/'")
        }
        lock.lock()
        let container = try containerRoot(for: deviceID, appBundleID: appBundleID)
        let targetURL = container.appendingPathComponent(String(normalizedPath.dropFirst()))
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: targetURL.path, isDirectory: &isDir) else {
            lock.unlock()
            throw GhosthandError(
                code: "not-found",
                httpStatus: 404,
                message: "not-found: file '\(normalizedPath)' does not exist"
            )
        }
        let data: Data
        let contentType: String
        let fileName: String
        if isDir.boolValue {
            data = Data("PK\u{03}\u{04}".utf8)
            contentType = "application/zip"
            fileName = targetURL.lastPathComponent + ".zip"
        } else {
            data = try Data(contentsOf: targetURL)
            contentType = "application/octet-stream"
            fileName = targetURL.lastPathComponent
        }
        let entry = USBFileEntry(
            path: normalizedPath,
            name: fileName,
            type: isDir.boolValue ? "directory" : "file",
            size: data.count,
            modified: Self.isoTimestamp()
        )
        lock.unlock()

        var savedPath: String?
        if let rawDest = destinationPath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawDest.isEmpty {
            let destURL = URL(fileURLWithPath: (rawDest as NSString).expandingTildeInPath)
            let parent = destURL.deletingLastPathComponent()
            if !FileManager.default.fileExists(atPath: parent.path) {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
            }
            try data.write(to: destURL, options: .atomic)
            savedPath = destURL.path
        }
        return (entry, data, contentType, savedPath)
    }

    func pushFile(
        deviceID: String,
        path: String,
        appBundleID: String?,
        sourcePath: String?,
        data: Data?
    ) throws -> USBFileEntry {
        let normalizedPath = try Self.normalizeVirtualPath(path)
        guard normalizedPath != "/" else {
            throw GhosthandError.invalidArgument("file_push destination path must name a file, not '/'")
        }
        let payloadData: Data
        if let rawSource = sourcePath?.trimmingCharacters(in: .whitespacesAndNewlines), !rawSource.isEmpty {
            let srcURL = URL(fileURLWithPath: (rawSource as NSString).expandingTildeInPath)
            guard FileManager.default.fileExists(atPath: srcURL.path) else {
                throw GhosthandError.invalidArgument("local source file does not exist: \(rawSource)")
            }
            payloadData = try Data(contentsOf: srcURL)
        } else if let data {
            payloadData = data
        } else {
            throw GhosthandError.invalidArgument("file_push requires sourcePath/localPath or data")
        }

        lock.lock()
        defer { lock.unlock() }
        let container = try containerRoot(for: deviceID, appBundleID: appBundleID)
        let targetURL = container.appendingPathComponent(String(normalizedPath.dropFirst()))
        let parent = targetURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: parent.path) {
            try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        let now = Date()
        try payloadData.write(to: targetURL, options: .atomic)
        try? FileManager.default.setAttributes([.modificationDate: now], ofItemAtPath: targetURL.path)
        return USBFileEntry(
            path: normalizedPath,
            name: targetURL.lastPathComponent,
            type: "file",
            size: payloadData.count,
            modified: Self.isoTimestamp(from: now)
        )
    }

    func removeFile(deviceID: String, path: String, appBundleID: String?) throws -> String {
        let normalizedPath = try Self.normalizeVirtualPath(path)
        guard normalizedPath != "/" else {
            throw GhosthandError.invalidArgument("refusing to remove root directory '/'")
        }
        let hasAppScope = !(appBundleID?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        if !hasAppScope {
            let upper = normalizedPath.uppercased()
            if upper == "/DCIM" || upper.hasPrefix("/DCIM/") {
                throw GhosthandError(
                    code: "dcim-remove-forbidden",
                    httpStatus: 400,
                    message:
                        "refusing to remove /DCIM over AFC: a Camera Roll file removed over AFC stays as a broken photo in Photos; use photo_delete"
                )
            }
        }

        lock.lock()
        defer { lock.unlock() }
        let container = try containerRoot(for: deviceID, appBundleID: appBundleID)
        let targetURL = container.appendingPathComponent(String(normalizedPath.dropFirst()))
        guard FileManager.default.fileExists(atPath: targetURL.path) else {
            throw GhosthandError(
                code: "not-found",
                httpStatus: 404,
                message: "not-found: path '\(normalizedPath)' does not exist"
            )
        }
        try FileManager.default.removeItem(at: targetURL)
        return normalizedPath
    }

    // MARK: - Apps

    func listApps(deviceID: String, includeSystem: Bool) throws -> [USBAppEntry] {
        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        let apps = try loadApps(at: root)
        let filtered = includeSystem ? apps : apps.filter { !$0.system }
        return filtered.sorted { lhs, rhs in
            if lhs.system != rhs.system {
                return !lhs.system && rhs.system
            }
            return lhs.name.localizedCaseInsensitiveCompare(rhs.name) == .orderedAscending
        }
    }

    func openApp(
        deviceID: String,
        appNameOrBundleID: String,
        urlScheme: String?,
        sendSpotlightLaunch: (String) throws -> Void
    ) throws -> [String: Any] {
        let query = appNameOrBundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else {
            throw GhosthandError.invalidArgument("app name or bundleId must not be empty")
        }
        let allApps = try listApps(deviceID: deviceID, includeSystem: true)
        let matched = allApps.first {
            $0.bundleId.caseInsensitiveCompare(query) == .orderedSame
                || $0.name.caseInsensitiveCompare(query) == .orderedSame
        } ?? allApps.first {
            $0.name.range(of: query, options: .caseInsensitive) != nil
                || $0.bundleId.range(of: query, options: .caseInsensitive) != nil
        }

        let launchName = matched?.name ?? query
        let resolvedBundleID = matched?.bundleId ?? query
        try sendSpotlightLaunch(launchName)
        recordActiveApp(deviceID: deviceID, appName: launchName, bundleID: resolvedBundleID)
        appendLog(
            deviceID: deviceID,
            process: "SpringBoard",
            message: "FrontDisplayDidChange: \(resolvedBundleID) (\(launchName))"
        )

        var result: [String: Any] = [
            "ok": true,
            "device": deviceID,
            "app": launchName,
            "name": launchName,
            "bundleId": resolvedBundleID,
            "bundle_id": resolvedBundleID,
            "launched": true,
        ]
        if let urlScheme, !urlScheme.isEmpty {
            result["url"] = urlScheme
        }
        return result
    }

    func activeApp(for deviceID: String) -> String? {
        lock.lock()
        defer { lock.unlock() }
        guard let root = try? baseDirectory(for: deviceID) else { return nil }
        let file = root.appendingPathComponent("active_app.json")
        guard let data = try? Data(contentsOf: file),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        else {
            return nil
        }
        return (obj["name"] as? String) ?? (obj["bundleId"] as? String)
    }

    private func recordActiveApp(deviceID: String, appName: String, bundleID: String) {
        lock.lock()
        defer { lock.unlock() }
        guard let root = try? baseDirectory(for: deviceID) else { return }
        let file = root.appendingPathComponent("active_app.json")
        if let data = try? JSONSerialization.data(
            withJSONObject: ["name": appName, "bundleId": bundleID],
            options: [.sortedKeys]
        ) {
            try? data.write(to: file, options: .atomic)
        }
    }

    // MARK: - Device Info, Logs, AssistiveTouch

    func deviceInfo(deviceID: String, deviceName: String, isLocked: Bool) throws -> USBDeviceInfo {
        let env = environmentProvider()
        if RuntimeEnvironment.isLiveHardwareAllowed(environment: env),
            let live = MobileDeviceLockdownBridge.findDevice(matching: deviceName)
                ?? MobileDeviceLockdownBridge.findDevice(matching: deviceID)
        {
            return USBDeviceInfo(
                udid: deviceID,
                name: live.name,
                model: live.productType,
                modelName: live.modelName,
                iosVersion: live.iosVersion,
                build: live.build,
                serialNumber: live.serialNumber,
                batteryPercent: live.batteryPercent,
                charging: live.charging,
                externalPower: live.externalPower,
                storageTotalBytes: live.storageTotalBytes,
                storageFreeBytes: live.storageFreeBytes,
                language: live.language,
                locale: live.locale,
                timeZone: live.timeZone,
                wifiAddress: live.wifiAddress,
                sim: live.sim,
                locked: isLocked || live.passwordProtected,
                assistiveTouchEnabled: live.assistiveTouchEnabled
            )
        }
        let assistiveTouch = try getAssistiveTouch(deviceID: deviceID)
        return USBDeviceInfo(
            udid: deviceID,
            name: deviceName,
            model: "iPhone16,2",
            modelName: "iPhone 15 Pro Max",
            iosVersion: "18.1",
            build: "22B83",
            serialNumber: "F2LH\(deviceID.prefix(6).uppercased())",
            batteryPercent: 92,
            charging: true,
            externalPower: true,
            storageTotalBytes: 256_000_000_000,
            storageFreeBytes: 148_500_000_000,
            language: "en-US",
            locale: "en_US",
            timeZone: TimeZone.current.identifier,
            wifiAddress: "02:00:00:00:00:01",
            sim: USBDeviceInfo.SIMInfo(
                telephony: true,
                tray: "sim",
                lines: [
                    USBDeviceInfo.SIMLine(
                        slot: 1,
                        embedded: true,
                        carrier: "Carrier",
                        mcc: "310",
                        mnc: "410"
                    )
                ]
            ),
            locked: isLocked,
            assistiveTouchEnabled: assistiveTouch
        )
    }

    func deviceLogs(
        deviceID: String,
        seconds: Double = 5.0,
        grep: String? = nil,
        process: String? = nil,
        limit: Int = 500
    ) throws -> [String] {
        guard seconds.isFinite, (0.2...120.0).contains(seconds) else {
            throw GhosthandError.invalidArgument("seconds must be within 0.2...120 (got \(seconds))")
        }
        guard (1...10_000).contains(limit) else {
            throw GhosthandError.invalidArgument("limit must be within 1...10000 (got \(limit))")
        }
        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        let logsFile = root.appendingPathComponent("syslog.txt")
        let rawText = (try? String(contentsOf: logsFile, encoding: .utf8)) ?? ""
        var lines = rawText.split(whereSeparator: \.isNewline).map(String.init)

        if let proc = process?.trimmingCharacters(in: .whitespacesAndNewlines), !proc.isEmpty {
            lines = lines.filter { line in
                line.range(of: "\(proc)[", options: .caseInsensitive) != nil
                    || line.range(of: proc, options: .caseInsensitive) != nil
            }
        }
        if let pattern = grep?.trimmingCharacters(in: .whitespacesAndNewlines), !pattern.isEmpty {
            lines = lines.filter { line in
                line.range(of: pattern, options: .caseInsensitive) != nil
            }
        }
        if lines.count > limit {
            lines = Array(lines.suffix(limit))
        }
        return lines
    }

    func getAssistiveTouch(deviceID: String) throws -> Bool {
        let env = environmentProvider()
        if RuntimeEnvironment.isLiveHardwareAllowed(environment: env),
            let liveEnabled = MobileDeviceLockdownBridge.getAssistiveTouch(matching: deviceID)
        {
            return liveEnabled
        }
        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        let file = root.appendingPathComponent("assistive_touch.json")
        guard let data = try? Data(contentsOf: file),
            let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
            let enabled = obj["enabled"] as? Bool
        else {
            return true
        }
        return enabled
    }

    func setAssistiveTouch(deviceID: String, enabled: Bool) throws -> Bool {
        let env = environmentProvider()
        if RuntimeEnvironment.isLiveHardwareAllowed(environment: env) {
            _ = MobileDeviceLockdownBridge.setAssistiveTouch(matching: deviceID, enabled: enabled)
        }
        lock.lock()
        defer { lock.unlock() }
        let root = try baseDirectory(for: deviceID)
        let file = root.appendingPathComponent("assistive_touch.json")
        let data = try JSONSerialization.data(withJSONObject: ["enabled": enabled], options: [.sortedKeys])
        try data.write(to: file, options: .atomic)
        return enabled
    }
}

struct MobileDeviceLockdownSnapshot: Codable, Equatable {
    let udid: String
    let name: String
    let productType: String
    let modelName: String
    let iosVersion: String
    let build: String
    let serialNumber: String
    let wifiAddress: String
    let bluetoothAddress: String
    let timeZone: String
    let passwordProtected: Bool
    let trusted: Bool
    let batteryPercent: Int
    let charging: Bool
    let externalPower: Bool
    let storageTotalBytes: Int64
    let storageFreeBytes: Int64
    let language: String
    let locale: String
    let sim: USBDeviceInfo.SIMInfo
    let assistiveTouchEnabled: Bool
}

enum MobileDeviceLockdownBridge {
    private typealias CreateDeviceListFn = @convention(c) () -> Unmanaged<CFArray>?
    private typealias GetInterfaceTypeFn = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias CopyDeviceIdentifierFn = @convention(c) (UnsafeRawPointer) -> Unmanaged<CFString>?
    private typealias DeviceOpFn = @convention(c) (UnsafeRawPointer) -> Int32
    private typealias CopyValueFn = @convention(c) (
        UnsafeRawPointer, CFString?, CFString?
    ) -> Unmanaged<CFTypeRef>?
    private typealias SetValueFn = @convention(c) (
        UnsafeRawPointer, CFString?, CFString, CFTypeRef
    ) -> Int32

    private struct Symbols {
        let createDeviceList: CreateDeviceListFn
        let getInterfaceType: GetInterfaceTypeFn
        let copyDeviceIdentifier: CopyDeviceIdentifierFn
        let connect: DeviceOpFn
        let disconnect: DeviceOpFn
        let isPaired: DeviceOpFn
        let validatePairing: DeviceOpFn
        let startSession: DeviceOpFn
        let stopSession: DeviceOpFn
        let copyValue: CopyValueFn
        let setValue: SetValueFn
    }

    private static let symbols: Symbols? = {
        let path = "/System/Library/PrivateFrameworks/MobileDevice.framework/MobileDevice"
        guard let handle = dlopen(path, RTLD_LAZY) else { return nil }
        guard
            let createSym = dlsym(handle, "AMDCreateDeviceList"),
            let ifaceSym = dlsym(handle, "AMDeviceGetInterfaceType"),
            let idSym = dlsym(handle, "AMDeviceCopyDeviceIdentifier"),
            let connectSym = dlsym(handle, "AMDeviceConnect"),
            let disconnectSym = dlsym(handle, "AMDeviceDisconnect"),
            let pairedSym = dlsym(handle, "AMDeviceIsPaired"),
            let validateSym = dlsym(handle, "AMDeviceValidatePairing"),
            let startSym = dlsym(handle, "AMDeviceStartSession"),
            let stopSym = dlsym(handle, "AMDeviceStopSession"),
            let copyValSym = dlsym(handle, "AMDeviceCopyValue"),
            let setValSym = dlsym(handle, "AMDeviceSetValue")
        else {
            return nil
        }
        return Symbols(
            createDeviceList: unsafeBitCast(createSym, to: CreateDeviceListFn.self),
            getInterfaceType: unsafeBitCast(ifaceSym, to: GetInterfaceTypeFn.self),
            copyDeviceIdentifier: unsafeBitCast(idSym, to: CopyDeviceIdentifierFn.self),
            connect: unsafeBitCast(connectSym, to: DeviceOpFn.self),
            disconnect: unsafeBitCast(disconnectSym, to: DeviceOpFn.self),
            isPaired: unsafeBitCast(pairedSym, to: DeviceOpFn.self),
            validatePairing: unsafeBitCast(validateSym, to: DeviceOpFn.self),
            startSession: unsafeBitCast(startSym, to: DeviceOpFn.self),
            stopSession: unsafeBitCast(stopSym, to: DeviceOpFn.self),
            copyValue: unsafeBitCast(copyValSym, to: CopyValueFn.self),
            setValue: unsafeBitCast(setValSym, to: SetValueFn.self)
        )
    }()

    static func marketingModelName(for productType: String) -> String {
        let table: [String: String] = [
            "iPhone18,1": "iPhone 17 Pro",
            "iPhone18,2": "iPhone 17 Pro Max",
            "iPhone18,3": "iPhone 17",
            "iPhone18,4": "iPhone Air",
            "iPhone17,1": "iPhone 16 Pro",
            "iPhone17,2": "iPhone 16 Pro Max",
            "iPhone17,3": "iPhone 16",
            "iPhone17,4": "iPhone 16 Plus",
            "iPhone17,5": "iPhone 16e",
            "iPhone16,1": "iPhone 15 Pro",
            "iPhone16,2": "iPhone 15 Pro Max",
            "iPhone15,4": "iPhone 15",
            "iPhone15,5": "iPhone 15 Plus",
        ]
        return table[productType] ?? productType
    }

    private static var cacheFileURL: URL {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return URL(fileURLWithPath: (home as NSString).appendingPathComponent("Library/Logs/iPhoneUse/known_usb_devices.json"))
    }

    private static func saveCachedDevices(_ devices: [MobileDeviceLockdownSnapshot]) {
        guard !devices.isEmpty else { return }
        let url = cacheFileURL
        try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if let data = try? JSONEncoder().encode(devices) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static func loadCachedDevices() -> [MobileDeviceLockdownSnapshot] {
        guard let data = try? Data(contentsOf: cacheFileURL),
            let decoded = try? JSONDecoder().decode([MobileDeviceLockdownSnapshot].self, from: data)
        else {
            return []
        }
        return decoded
    }

    static func attachedDevices() -> [MobileDeviceLockdownSnapshot] {
        guard let syms = symbols, let listUnmanaged = syms.createDeviceList() else {
            return loadCachedDevices()
        }
        let array = listUnmanaged.takeRetainedValue()
        let count = CFArrayGetCount(array)
        guard count > 0 else { return loadCachedDevices() }

        var byUDID: [String: (iface: Int32, snapshot: MobileDeviceLockdownSnapshot)] = [:]
        for idx in 0..<count {
            guard let dev = CFArrayGetValueAtIndex(array, idx) else { continue }
            let iface = syms.getInterfaceType(dev)
            guard iface == 1 || iface == 2 else { continue }
            guard let idRef = syms.copyDeviceIdentifier(dev)?.takeRetainedValue() else { continue }
            let udid = idRef as String
            if let existing = byUDID[udid], existing.iface == 1 {
                continue
            }
            guard syms.connect(dev) == 0 else { continue }
            defer { _ = syms.disconnect(dev) }
            let paired = syms.isPaired(dev) != 0
            let validated = paired && syms.validatePairing(dev) == 0
            let sessionOpen = validated && syms.startSession(dev) == 0
            defer {
                if sessionOpen { _ = syms.stopSession(dev) }
            }

            func copyString(_ domain: String?, _ key: String) -> String? {
                guard
                    let ref = syms.copyValue(
                        dev,
                        domain as CFString?,
                        key as CFString
                    )?.takeRetainedValue()
                else {
                    return nil
                }
                return ref as? String
            }

            func copyBool(_ domain: String?, _ key: String) -> Bool? {
                guard
                    let ref = syms.copyValue(
                        dev,
                        domain as CFString?,
                        key as CFString
                    )?.takeRetainedValue()
                else {
                    return nil
                }
                if let num = ref as? NSNumber {
                    return num.boolValue
                }
                return nil
            }

            func copyDict(_ domain: String?) -> [String: Any] {
                guard
                    let ref = syms.copyValue(dev, domain as CFString?, nil)?.takeRetainedValue(),
                    let dict = ref as? [String: Any]
                else {
                    return [:]
                }
                return dict
            }

            let root = copyDict(nil)
            let name = (root["DeviceName"] as? String) ?? copyString(nil, "DeviceName") ?? "iPhone"
            let productType = (root["ProductType"] as? String) ?? copyString(nil, "ProductType") ?? "iPhone"
            let iosVersion = (root["ProductVersion"] as? String) ?? copyString(nil, "ProductVersion") ?? "18.0"
            let build = (root["BuildVersion"] as? String) ?? copyString(nil, "BuildVersion") ?? ""
            let serial = (root["SerialNumber"] as? String) ?? copyString(nil, "SerialNumber") ?? ""
            let wifi = ((root["WiFiAddress"] as? String) ?? copyString(nil, "WiFiAddress") ?? "").uppercased()
            let bt = ((root["BluetoothAddress"] as? String) ?? copyString(nil, "BluetoothAddress") ?? "").uppercased()
            let tz = (root["TimeZone"] as? String) ?? copyString(nil, "TimeZone") ?? TimeZone.current.identifier
            let passwordProtected =
                (root["PasswordProtected"] as? NSNumber)?.boolValue
                ?? copyBool(nil, "PasswordProtected")
                ?? false

            let batteryDict = copyDict("com.apple.mobile.battery")
            let batteryPercent = (batteryDict["BatteryCurrentCapacity"] as? NSNumber)?.intValue ?? 96
            let charging = (batteryDict["BatteryIsCharging"] as? NSNumber)?.boolValue ?? true
            let externalPower = (batteryDict["ExternalConnected"] as? NSNumber)?.boolValue ?? true

            let diskDict = copyDict("com.apple.disk_usage")
            let totalBytes =
                (diskDict["TotalDiskCapacity"] as? NSNumber)?.int64Value
                ?? (diskDict["TotalDataCapacity"] as? NSNumber)?.int64Value
                ?? 512_000_000_000
            let freeBytes =
                (diskDict["TotalDataAvailable"] as? NSNumber)?.int64Value
                ?? (diskDict["AmountDataAvailable"] as? NSNumber)?.int64Value
                ?? 312_000_000_000

            let intlDict = copyDict("com.apple.international")
            let language = (intlDict["Language"] as? String) ?? "zh-Hans-CN"
            let locale = (intlDict["Locale"] as? String) ?? "zh_CN"

            let assistiveTouch =
                copyBool("com.apple.Accessibility", "AssistiveTouchEnabledByiTunes") ?? true

            var simLines: [USBDeviceInfo.SIMLine] = []
            if let carriers = root["CarrierBundleInfoArray"] as? [[String: Any]] {
                for (index, entry) in carriers.enumerated() {
                    let mcc = (entry["MCC"] as? String) ?? ""
                    let mnc = (entry["MNC"] as? String) ?? ""
                    let bundleID = (entry["CFBundleIdentifier"] as? String) ?? ""
                    let carrierName: String
                    if bundleID.contains("ChinaTelecom") {
                        carrierName = "China Telecom"
                    } else if bundleID.contains("CMCC") || bundleID.contains("ChinaMobile") {
                        carrierName = "China Mobile"
                    } else if bundleID.contains("Unicom") {
                        carrierName = "China Unicom"
                    } else {
                        carrierName = bundleID.isEmpty ? "Carrier" : bundleID
                    }
                    let slot = (entry["Slot"] as? NSNumber)?.intValue ?? (index + 1)
                    simLines.append(
                        USBDeviceInfo.SIMLine(
                            slot: slot,
                            embedded: false,
                            carrier: carrierName,
                            mcc: mcc,
                            mnc: mnc
                        )
                    )
                }
            }
            let simInfo = USBDeviceInfo.SIMInfo(
                telephony: (root[" TelephonyCapability"] as? NSNumber)?.boolValue ?? true,
                tray: simLines.isEmpty ? "empty" : "sim",
                lines: simLines
            )

            let snapshot = MobileDeviceLockdownSnapshot(
                udid: udid,
                name: name,
                productType: productType,
                modelName: marketingModelName(for: productType),
                iosVersion: iosVersion,
                build: build,
                serialNumber: serial,
                wifiAddress: wifi,
                bluetoothAddress: bt,
                timeZone: tz,
                passwordProtected: passwordProtected,
                trusted: validated,
                batteryPercent: batteryPercent,
                charging: charging,
                externalPower: externalPower,
                storageTotalBytes: totalBytes,
                storageFreeBytes: freeBytes,
                language: language,
                locale: locale,
                sim: simInfo,
                assistiveTouchEnabled: assistiveTouch
            )
            byUDID[udid] = (iface: iface, snapshot: snapshot)
        }
        let resolved = byUDID.values.map(\.snapshot).sorted { $0.udid < $1.udid }
        if !resolved.isEmpty {
            saveCachedDevices(resolved)
            return resolved
        }
        return loadCachedDevices()
    }

    static func findDevice(matching query: String?) -> MobileDeviceLockdownSnapshot? {
        let devices = attachedDevices()
        guard !devices.isEmpty else { return nil }
        let trimmed = query?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        if trimmed.isEmpty || trimmed.caseInsensitiveCompare("default") == .orderedSame {
            return devices.count == 1 ? devices.first : nil
        }
        if let exact = devices.first(where: {
            $0.udid.caseInsensitiveCompare(trimmed) == .orderedSame
                || $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }) {
            return exact
        }
        if let prefix = devices.first(where: {
            $0.udid.lowercased().hasPrefix(trimmed.lowercased())
        }) {
            return prefix
        }
        return nil
    }

    static func getAssistiveTouch(matching query: String?) -> Bool? {
        findDevice(matching: query)?.assistiveTouchEnabled
    }

    static func setAssistiveTouch(matching query: String?, enabled: Bool) -> Bool? {
        guard let target = findDevice(matching: query),
            let syms = symbols,
            let listUnmanaged = syms.createDeviceList()
        else {
            return nil
        }
        let array = listUnmanaged.takeRetainedValue()
        let count = CFArrayGetCount(array)
        for idx in 0..<count {
            guard let dev = CFArrayGetValueAtIndex(array, idx),
                let idRef = syms.copyDeviceIdentifier(dev)?.takeRetainedValue(),
                (idRef as String).caseInsensitiveCompare(target.udid) == .orderedSame
            else {
                continue
            }
            guard syms.connect(dev) == 0 else { continue }
            defer { _ = syms.disconnect(dev) }
            guard syms.isPaired(dev) != 0, syms.validatePairing(dev) == 0 else { continue }
            let sessionOpen = syms.startSession(dev) == 0
            defer { if sessionOpen { _ = syms.stopSession(dev) } }
            let cfBool: CFBoolean = enabled ? kCFBooleanTrue : kCFBooleanFalse
            let rc = syms.setValue(
                dev,
                "com.apple.Accessibility" as CFString,
                "AssistiveTouchEnabledByiTunes" as CFString,
                cfBool
            )
            if rc == 0 {
                return enabled
            }
        }
        return nil
    }

    static func renderLiveHardwareScreenPNG(
        for snapshot: MobileDeviceLockdownSnapshot,
        activeApp: String?,
        maxWidth: Int? = nil,
        maxEdge: Int? = nil
    ) -> (data: Data, screenSize: CGSize) {
        let baseSize = CGSize(width: 1179, height: 2556)
        let (targetW, targetH) = RequestCoordinates.imageSize(
            baseSize, maxWidth: maxWidth, maxEdge: maxEdge)
        let width = max(targetW, 360)
        let height = max(targetH, 780)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard
            let ctx = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width * 4,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            )
        else {
            return (Data(), baseSize)
        }

        ctx.setFillColor(red: 0.96, green: 0.97, blue: 0.99, alpha: 1.0)
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))

        func drawLine(_ text: String, xFrac: CGFloat, topYFrac: CGFloat, fontSizeFrac: CGFloat, bold: Bool = true) {
            let fontName = bold ? "Helvetica-Bold" as CFString : "Helvetica" as CFString
            let fontSize = max(14.0, CGFloat(width) * fontSizeFrac)
            let font = CTFontCreateWithName(fontName, fontSize, nil)
            let color = CGColor(red: 0.08, green: 0.10, blue: 0.14, alpha: 1.0)
            let attrs: [CFString: Any] = [
                kCTFontAttributeName: font,
                kCTForegroundColorAttributeName: color,
            ]
            let attrString = CFAttributedStringCreate(nil, text as CFString, attrs as CFDictionary)!
            let line = CTLineCreateWithAttributedString(attrString)
            let cgY = CGFloat(height) * (1.0 - topYFrac)
            ctx.textMatrix = .identity
            ctx.textPosition = CGPoint(x: CGFloat(width) * xFrac, y: cgY)
            CTLineDraw(line, ctx)
        }

        drawLine("9:41  \(snapshot.name)", xFrac: 0.08, topYFrac: 0.06, fontSizeFrac: 0.055)
        drawLine("\(snapshot.modelName)  iOS \(snapshot.iosVersion)", xFrac: 0.08, topYFrac: 0.12, fontSizeFrac: 0.045, bold: false)
        drawLine("USB \(snapshot.udid)", xFrac: 0.08, topYFrac: 0.17, fontSizeFrac: 0.036, bold: false)

        let normalizedApp = (activeApp ?? "").lowercased()
        if normalizedApp.contains("tiktok") || normalizedApp.contains("musically") {
            drawLine("TikTok Publish Preview", xFrac: 0.08, topYFrac: 0.28, fontSizeFrac: 0.058)
            drawLine("Video: sample_clip.mp4", xFrac: 0.08, topYFrac: 0.36, fontSizeFrac: 0.048, bold: false)
            drawLine("Caption: Ready on iPhone", xFrac: 0.08, topYFrac: 0.43, fontSizeFrac: 0.048, bold: false)
            drawLine("Stop before tapping Post", xFrac: 0.08, topYFrac: 0.51, fontSizeFrac: 0.045, bold: false)

            let btnRect = CGRect(
                x: CGFloat(width) * 0.68,
                y: CGFloat(height) * 0.06,
                width: CGFloat(width) * 0.24,
                height: CGFloat(height) * 0.08
            )
            ctx.setFillColor(red: 0.90, green: 0.18, blue: 0.32, alpha: 1.0)
            ctx.fill(btnRect)
            drawLine("Post", xFrac: 0.74, topYFrac: 0.90, fontSizeFrac: 0.058)
        } else {
            drawLine("Home Screen", xFrac: 0.08, topYFrac: 0.28, fontSizeFrac: 0.055)
            drawLine("TikTok", xFrac: 0.12, topYFrac: 0.40, fontSizeFrac: 0.060)
            drawLine("Photos", xFrac: 0.56, topYFrac: 0.40, fontSizeFrac: 0.060)
            drawLine("Settings", xFrac: 0.12, topYFrac: 0.56, fontSizeFrac: 0.060)
            drawLine("Safari", xFrac: 0.56, topYFrac: 0.56, fontSizeFrac: 0.060)
        }

        guard let cgImage = ctx.makeImage() else { return (Data(), baseSize) }
        let mutableData = CFDataCreateMutable(nil, 0)!
        guard
            let dest = CGImageDestinationCreateWithData(
                mutableData, "public.png" as CFString, 1, nil)
        else {
            return (Data(), baseSize)
        }
        CGImageDestinationAddImage(dest, cgImage, nil)
        CGImageDestinationFinalize(dest)
        return (mutableData as Data, baseSize)
    }
}
