import Foundation
import SQLite3

private let sqliteTransient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

/// Branded lease identifier backed by `lease_counter` in `state.db`.
struct LeaseID: RawRepresentable, Hashable, Codable, CustomStringConvertible {
    let rawValue: Int64

    var description: String { String(rawValue) }

    init?(rawValue: Int64) {
        guard rawValue > 0 else { return nil }
        self.rawValue = rawValue
    }

    init(unchecked rawValue: Int64) {
        self.rawValue = rawValue
    }

    /// Parses `"42"`, `"studio:42"`, or numeric `42` into a validated `LeaseID`.
    static func parse(_ raw: Any?) -> LeaseID? {
        if let number = raw as? NSNumber {
            guard CFGetTypeID(number) != CFBooleanGetTypeID() else { return nil }
            let doubleValue = number.doubleValue
            guard doubleValue.isFinite, doubleValue.rounded(.towardZero) == doubleValue else { return nil }
            return LeaseID(rawValue: number.int64Value)
        }
        guard let text = raw as? String else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let suffix = trimmed.split(separator: ":", omittingEmptySubsequences: false).last.map(String.init) ?? trimmed
        guard let value = Int64(suffix) else { return nil }
        return LeaseID(rawValue: value)
    }
}

struct LeaseRecord: Equatable {
    let id: LeaseID
    let screenCaptureID: String
    let deviceName: String
    let label: String?
    let reason: String
    let acquiredAt: TimeInterval
    let idleTimeoutSeconds: TimeInterval
    let lastUsedAt: TimeInterval
    let lastCommand: String?

    var expiresAt: TimeInterval { lastUsedAt + idleTimeoutSeconds }

    /// Public lease holder summary embedded in `/devices`, `/setup_status`, and `device-leased` errors.
    func infoJSON() -> [String: Any] {
        var json: [String: Any] = [
            "reason": reason,
            "acquiredAt": LeaseStore.iso8601String(from: acquiredAt),
            "lastUsedAt": LeaseStore.iso8601String(from: lastUsedAt),
            "expiresAt": LeaseStore.iso8601String(from: expiresAt),
        ]
        if let label, !label.isEmpty {
            json["label"] = label
        }
        if let lastCommand, !lastCommand.isEmpty {
            json["lastCommand"] = lastCommand
        }
        return json
    }

    /// Full lease representation returned to the caller that acquired or waited for the lease.
    func leaseJSON() -> [String: Any] {
        var json = infoJSON()
        json["id"] = id.description
        json["device"] = screenCaptureID
        json["deviceName"] = deviceName
        json["idleTimeoutSeconds"] = Int(idleTimeoutSeconds.rounded())
        return json
    }
}

struct LeaseWaiterRecord: Equatable {
    let id: Int64
    let screenCaptureID: String
    let label: String?
    let reason: String
    let since: TimeInterval

    func json() -> [String: Any] {
        var item: [String: Any] = [
            "reason": reason,
            "since": LeaseStore.iso8601String(from: since),
        ]
        if let label, !label.isEmpty {
            item["label"] = label
        }
        return item
    }
}

struct LeaseAcquisition: Equatable {
    let lease: LeaseRecord
    let replaced: LeaseRecord?

    func json() -> [String: Any] {
        var payload = lease.leaseJSON()
        if let replaced {
            payload["replaced"] = replaced.infoJSON()
        }
        return payload
    }
}

enum LeaseError: Error, Equatable, CustomStringConvertible {
    case invalidReason
    case invalidIdleTimeout
    case invalidWaitTimeout
    case invalidLeaseID
    case forceAndWaitMutuallyExclusive
    case deviceLeased(deviceName: String, holder: LeaseRecord)
    case leaseInvalid(LeaseID)
    case waitTimedOut(deviceID: String, deviceName: String, holder: LeaseRecord?)
    case storageFailure(String)

    var errorCode: String {
        switch self {
        case .invalidReason, .invalidIdleTimeout, .invalidWaitTimeout, .invalidLeaseID,
            .forceAndWaitMutuallyExclusive:
            return "invalid-argument"
        case .deviceLeased:
            return "device-leased"
        case .leaseInvalid:
            return "lease-invalid"
        case .waitTimedOut:
            return "lease-wait-timeout"
        case .storageFailure:
            return "lease-storage-error"
        }
    }

    var httpStatus: Int {
        switch self {
        case .invalidReason, .invalidIdleTimeout, .invalidWaitTimeout, .invalidLeaseID,
            .forceAndWaitMutuallyExclusive:
            return 400
        case .deviceLeased, .leaseInvalid, .waitTimedOut:
            return 409
        case .storageFailure:
            return 500
        }
    }

    var description: String {
        localizedDescription(for: AppLanguageStore.shared.language)
    }

    func localizedDescription(for language: AppLanguage) -> String {
        switch self {
        case .invalidReason:
            return language == .zh ? "缺少非空的 reason（租约原因）" : "a non-empty reason is required"
        case .invalidIdleTimeout:
            return language == .zh
                ? "idleTimeoutSeconds 必须是 1...86400 之间的有限数值"
                : "idleTimeoutSeconds must be a finite number in 1...86400"
        case .invalidWaitTimeout:
            return language == .zh
                ? "waitSeconds 必须是 0.05...3600 之间的有限数值"
                : "waitSeconds must be a finite number in 0.05...3600"
        case .invalidLeaseID:
            return language == .zh ? "无效的 lease ID" : "invalid lease ID"
        case .forceAndWaitMutuallyExclusive:
            return language == .zh
                ? "force 与 waitSeconds 不能同时使用"
                : "force and waitSeconds are mutually exclusive"
        case .deviceLeased(let deviceName, let holder):
            let who = holder.label.map { " (\($0))" } ?? ""
            let exp = LeaseStore.iso8601String(from: holder.expiresAt)
            return language == .zh
                ? "device-leased: \(deviceName) 正被租约占用\(who)，原因：\(holder.reason)，到期时间：\(exp)"
                : "device-leased: \(deviceName) is leased\(who) for \"\(holder.reason)\" until \(exp)"
        case .leaseInvalid(let leaseID):
            return language == .zh
                ? "lease-invalid: 租约 \(leaseID.description) 不存在、已过期或不属于该设备"
                : "lease-invalid: lease \(leaseID.description) is missing, expired, or belongs to another device"
        case .waitTimedOut(_, let deviceName, let holder):
            if let holder {
                let who = holder.label.map { " (\($0))" } ?? ""
                return language == .zh
                    ? "等待 \(deviceName) 租约释放超时；当前持有者\(who)：\(holder.reason)"
                    : "timed out waiting for lease on \(deviceName); still held\(who) for \"\(holder.reason)\""
            }
            return language == .zh
                ? "等待 \(deviceName) 租约释放超时"
                : "timed out waiting for lease on \(deviceName)"
        case .storageFailure(let detail):
            return language == .zh ? "租约存储错误：\(detail)" : "lease storage error: \(detail)"
        }
    }
}

/// Cross-process SQLite lease state machine stored in `<stateDir>/state.db`,
/// aligned with Ghosthand's `lease_counter` and `lease` schema.
final class LeaseStore {
    static let defaultIdleTimeoutSeconds: TimeInterval = 600

    private static let cacheLock = NSLock()
    private static var storesByPath: [String: LeaseStore] = [:]

    /// Returns a `LeaseStore` bound to the current `IPHONE_USE_STATE_DIR` (or `~/Library/Logs/iPhoneUse`).
    static func current(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> LeaseStore {
        let dir = try defaultStateDirectory(environment: environment)
        let key = dir.standardizedFileURL.path
        return try cacheLock.withLock {
            if let existing = storesByPath[key] {
                return existing
            }
            let store = try LeaseStore(stateDirectory: dir)
            storesByPath[key] = store
            return store
        }
    }

    static func defaultStateDirectory(
        environment: [String: String] = ProcessInfo.processInfo.environment
    ) throws -> URL {
        if let override = environment["IPHONE_USE_STATE_DIR"]?.trimmingCharacters(in: .whitespacesAndNewlines),
            !override.isEmpty
        {
            guard override.hasPrefix("/") else {
                throw LeaseError.storageFailure("IPHONE_USE_STATE_DIR must be an absolute path")
            }
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Logs/iPhoneUse", isDirectory: true)
    }

    static func iso8601String(from timestamp: TimeInterval) -> String {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        return formatter.string(from: Date(timeIntervalSince1970: timestamp))
    }

    let stateDirectory: URL
    let databaseURL: URL
    private let lockURL: URL
    private let lock = NSLock()
    private var db: OpaquePointer?
    private var clock: () -> TimeInterval

    init(
        stateDirectory: URL? = nil,
        now: @escaping () -> TimeInterval = { Date().timeIntervalSince1970 }
    ) throws {
        let resolvedDir = try stateDirectory ?? Self.defaultStateDirectory()
        try FileManager.default.createDirectory(at: resolvedDir, withIntermediateDirectories: true)
        self.stateDirectory = resolvedDir
        self.databaseURL = resolvedDir.appendingPathComponent("state.db", isDirectory: false)
        self.lockURL = resolvedDir.appendingPathComponent("state.db.lock", isDirectory: false)
        self.clock = now

        try withStoreLock {
            var handle: OpaquePointer?
            let flags = SQLITE_OPEN_CREATE | SQLITE_OPEN_READWRITE | SQLITE_OPEN_FULLMUTEX
            let rc = sqlite3_open_v2(databaseURL.path, &handle, flags, nil)
            guard rc == SQLITE_OK, let handle else {
                let msg = handle.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "code \(rc)"
                if let handle { sqlite3_close(handle) }
                throw LeaseError.storageFailure("cannot open state.db: \(msg)")
            }
            self.db = handle
            sqlite3_busy_timeout(handle, 5_000)
            try initializeSchema()
        }
    }

    deinit {
        if let db {
            sqlite3_close_v2(db)
        }
    }

    private func withStoreLock<T>(_ body: () throws -> T) throws -> T {
        try lock.withLock {
            let fd = Darwin.open(lockURL.path, O_CREAT | O_RDWR, 0o600)
            if fd >= 0 {
                _ = flock(fd, LOCK_EX)
            }
            defer {
                if fd >= 0 {
                    _ = flock(fd, LOCK_UN)
                    _ = Darwin.close(fd)
                }
            }
            return try body()
        }
    }

    func setClock(_ newClock: @escaping () -> TimeInterval) {
        lock.withLock {
            self.clock = newClock
        }
    }

    /// Acquires an exclusive lease on `deviceID` (`screen_capture_id`).
    /// Lazily evicts any expired leases first inside the same `BEGIN IMMEDIATE` transaction.
    func acquire(
        deviceID: String,
        deviceName: String,
        reason: String,
        label: String? = nil,
        idleTimeoutSeconds: TimeInterval = LeaseStore.defaultIdleTimeoutSeconds,
        force: Bool = false,
        now overrideNow: TimeInterval? = nil
    ) throws -> LeaseAcquisition {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            throw LeaseError.invalidReason
        }
        guard idleTimeoutSeconds.isFinite, idleTimeoutSeconds >= 1, idleTimeoutSeconds <= 86_400 else {
            throw LeaseError.invalidIdleTimeout
        }
        let normalizedLabel = Self.normalizeOptional(label)

        let acquisition: LeaseAcquisition = try withStoreLock {
            let timestamp = overrideNow ?? clock()
            return try inImmediateTransaction {
                try reapExpiredLocked(now: timestamp)
                let existing = try selectLeaseLocked(forDeviceID: deviceID)
                if let existing, !force {
                    let holderName = existing.deviceName.isEmpty ? deviceName : existing.deviceName
                    throw LeaseError.deviceLeased(deviceName: holderName, holder: existing)
                }
                if existing != nil {
                    try deleteLeaseLocked(forDeviceID: deviceID)
                }
                let nextID = try nextCounterValueLocked()
                let record = LeaseRecord(
                    id: LeaseID(unchecked: nextID),
                    screenCaptureID: deviceID,
                    deviceName: deviceName,
                    label: normalizedLabel,
                    reason: trimmedReason,
                    acquiredAt: timestamp,
                    idleTimeoutSeconds: idleTimeoutSeconds,
                    lastUsedAt: timestamp,
                    lastCommand: "acquire"
                )
                try insertLeaseLocked(record)
                return LeaseAcquisition(lease: record, replaced: existing)
            }
        }
        if let replaced = acquisition.replaced {
            ScreenRecorderManager.shared.stopIfActive(forLease: replaced.id, stoppedBy: .leaseEnded)
        }
        return acquisition
    }

    /// Waits up to `waitSeconds` for another session's lease on `deviceID` to release or expire,
    /// recording a waiter row in `lease_waiter` while waiting, then acquires a fresh lease.
    func wait(
        deviceID: String,
        deviceName: String,
        reason: String,
        label: String? = nil,
        idleTimeoutSeconds: TimeInterval = LeaseStore.defaultIdleTimeoutSeconds,
        waitSeconds: TimeInterval = LeaseStore.defaultIdleTimeoutSeconds,
        pollInterval: TimeInterval = 0.05,
        sleep: (TimeInterval) -> Void = { Thread.sleep(forTimeInterval: $0) }
    ) throws -> LeaseAcquisition {
        let trimmedReason = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedReason.isEmpty else {
            throw LeaseError.invalidReason
        }
        guard idleTimeoutSeconds.isFinite, idleTimeoutSeconds >= 1, idleTimeoutSeconds <= 86_400 else {
            throw LeaseError.invalidIdleTimeout
        }
        guard waitSeconds.isFinite, waitSeconds >= 0.05, waitSeconds <= 3_600 else {
            throw LeaseError.invalidWaitTimeout
        }

        // Fast path: try acquiring immediately before registering a waiter.
        do {
            return try acquire(
                deviceID: deviceID,
                deviceName: deviceName,
                reason: trimmedReason,
                label: label,
                idleTimeoutSeconds: idleTimeoutSeconds,
                force: false
            )
        } catch LeaseError.deviceLeased {
            // Fall through to wait queue.
        }

        let start = lock.withLock { clock() }
        let deadline = start + waitSeconds
        let waiterID = try registerWaiter(
            deviceID: deviceID,
            label: Self.normalizeOptional(label),
            reason: trimmedReason,
            since: start
        )
        defer {
            unregisterWaiter(id: waiterID)
        }

        while true {
            let current = lock.withLock { clock() }
            let remaining = deadline - current
            if remaining <= 0 {
                break
            }
            sleep(min(pollInterval, max(0.005, remaining)))
            do {
                return try acquire(
                    deviceID: deviceID,
                    deviceName: deviceName,
                    reason: trimmedReason,
                    label: label,
                    idleTimeoutSeconds: idleTimeoutSeconds,
                    force: false
                )
            } catch LeaseError.deviceLeased {
                continue
            }
        }

        let holder = try? activeLease(forDeviceID: deviceID)
        throw LeaseError.waitTimedOut(deviceID: deviceID, deviceName: deviceName, holder: holder)
    }

    /// Idempotently releases a lease by ID. Returns the released record if it was active, or `nil` if already gone.
    @discardableResult
    func release(leaseID: LeaseID, now overrideNow: TimeInterval? = nil) throws -> LeaseRecord? {
        let released: LeaseRecord? = try withStoreLock {
            let timestamp = overrideNow ?? clock()
            return try inImmediateTransaction {
                try reapExpiredLocked(now: timestamp)
                let existing = try selectLeaseLocked(byID: leaseID.rawValue)
                if existing != nil {
                    try deleteLeaseLocked(byID: leaseID.rawValue)
                }
                return existing
            }
        }
        ScreenRecorderManager.shared.stopIfActive(forLease: leaseID, stoppedBy: .leaseEnded)
        return released
    }

    /// Validates lease ownership and refreshes `last_used_at` / `last_command`.
    /// - When `leaseID` is provided: verifies the lease exists, has not expired, and (if `deviceID` is given)
    ///   belongs to `deviceID`. Updates `last_used_at` and `last_command` and returns `(lease.screenCaptureID, updatedLease)`.
    /// - When `leaseID` is `nil`: preserves direct unleased compatibility by succeeding when `deviceID` is unleased,
    ///   and throwing `.deviceLeased` when another session holds an active lease on `deviceID`.
    @discardableResult
    func authorizeAndTouch(
        deviceID: String?,
        leaseID: LeaseID?,
        command: String?,
        now overrideNow: TimeInterval? = nil
    ) throws -> (deviceID: String?, lease: LeaseRecord?) {
        try withStoreLock {
            let timestamp = overrideNow ?? clock()
            return try inImmediateTransaction {
                try reapExpiredLocked(now: timestamp)
                if let leaseID {
                    guard let existing = try selectLeaseLocked(byID: leaseID.rawValue) else {
                        throw LeaseError.leaseInvalid(leaseID)
                    }
                    if let deviceID, !deviceID.isEmpty, existing.screenCaptureID != deviceID {
                        throw LeaseError.leaseInvalid(leaseID)
                    }
                    let updatedCommand = Self.normalizeOptional(command) ?? existing.lastCommand
                    try updateLeaseActivityLocked(
                        id: leaseID.rawValue,
                        lastUsedAt: timestamp,
                        lastCommand: updatedCommand
                    )
                    let updated = LeaseRecord(
                        id: existing.id,
                        screenCaptureID: existing.screenCaptureID,
                        deviceName: existing.deviceName,
                        label: existing.label,
                        reason: existing.reason,
                        acquiredAt: existing.acquiredAt,
                        idleTimeoutSeconds: existing.idleTimeoutSeconds,
                        lastUsedAt: timestamp,
                        lastCommand: updatedCommand
                    )
                    return (existing.screenCaptureID, updated)
                }

                guard let deviceID, !deviceID.isEmpty else {
                    return (nil, nil)
                }
                if let existing = try selectLeaseLocked(forDeviceID: deviceID) {
                    let holderName = existing.deviceName.isEmpty ? deviceID : existing.deviceName
                    throw LeaseError.deviceLeased(deviceName: holderName, holder: existing)
                }
                return (deviceID, nil)
            }
        }
    }

    /// Look up a lease by ID without mutating `last_used_at` (still reaps expired leases).
    func lease(byID leaseID: LeaseID, now overrideNow: TimeInterval? = nil) throws -> LeaseRecord? {
        try withStoreLock {
            let timestamp = overrideNow ?? clock()
            return try inImmediateTransaction {
                try reapExpiredLocked(now: timestamp)
                return try selectLeaseLocked(byID: leaseID.rawValue)
            }
        }
    }

    func activeLease(forDeviceID deviceID: String, now overrideNow: TimeInterval? = nil) throws -> LeaseRecord? {
        try withStoreLock {
            let timestamp = overrideNow ?? clock()
            return try inImmediateTransaction {
                try reapExpiredLocked(now: timestamp)
                return try selectLeaseLocked(forDeviceID: deviceID)
            }
        }
    }

    func activeLeasesByDevice(now overrideNow: TimeInterval? = nil) throws -> [String: LeaseRecord] {
        try withStoreLock {
            let timestamp = overrideNow ?? clock()
            return try inImmediateTransaction {
                try reapExpiredLocked(now: timestamp)
                let all = try selectAllLeasesLocked()
                return Dictionary(uniqueKeysWithValues: all.map { ($0.screenCaptureID, $0) })
            }
        }
    }

    func waiters(forDeviceID deviceID: String) throws -> [LeaseWaiterRecord] {
        try withStoreLock {
            try selectWaitersLocked(forDeviceID: deviceID)
        }
    }

    func currentCounterValue() throws -> Int64 {
        try withStoreLock {
            try readCounterValueLocked()
        }
    }

    // MARK: - Private SQLite Implementation

    private static func normalizeOptional(_ value: String?) -> String? {
        guard let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines), !trimmed.isEmpty else {
            return nil
        }
        return trimmed
    }

    private func initializeSchema() throws {
        try execSQL("PRAGMA journal_mode = WAL;")
        try execSQL(
            """
            CREATE TABLE IF NOT EXISTS lease_counter (
                id INTEGER PRIMARY KEY CHECK (id = 1),
                value INTEGER NOT NULL
            );
            INSERT OR IGNORE INTO lease_counter (id, value) VALUES (1, 0);
            CREATE TABLE IF NOT EXISTS lease (
                id INTEGER PRIMARY KEY,
                screen_capture_id TEXT NOT NULL UNIQUE,
                device_name TEXT NOT NULL DEFAULT '',
                label TEXT,
                reason TEXT NOT NULL,
                acquired_at REAL NOT NULL,
                idle_timeout_s REAL NOT NULL DEFAULT 600,
                last_used_at REAL NOT NULL,
                last_command TEXT
            );
            CREATE TABLE IF NOT EXISTS lease_waiter (
                id INTEGER PRIMARY KEY AUTOINCREMENT,
                screen_capture_id TEXT NOT NULL,
                label TEXT,
                reason TEXT NOT NULL,
                since REAL NOT NULL
            );
            """
        )
        // Ensure compatibility if an older Ghosthand state.db was created without `device_name`.
        if !(try tableHasColumn(table: "lease", column: "device_name")) {
            try execSQL("ALTER TABLE lease ADD COLUMN device_name TEXT NOT NULL DEFAULT '';")
        }
    }

    private func tableHasColumn(table: String, column: String) throws -> Bool {
        let stmt = try prepare("PRAGMA table_info(\(table));")
        defer { sqlite3_finalize(stmt) }
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let cName = sqlite3_column_text(stmt, 1), String(cString: cName) == column {
                return true
            }
        }
        return false
    }

    private func inImmediateTransaction<T>(_ body: () throws -> T) throws -> T {
        try execSQL("BEGIN IMMEDIATE TRANSACTION;")
        do {
            let result = try body()
            try execSQL("COMMIT;")
            return result
        } catch {
            try? execSQL("ROLLBACK;")
            throw error
        }
    }

    private func reapExpiredLocked(now: TimeInterval) throws {
        let selectExpired = try prepare("SELECT id FROM lease WHERE (last_used_at + idle_timeout_s) <= ?1;")
        var expiredIDs: [LeaseID] = []
        sqlite3_bind_double(selectExpired, 1, now)
        while sqlite3_step(selectExpired) == SQLITE_ROW {
            expiredIDs.append(LeaseID(unchecked: sqlite3_column_int64(selectExpired, 0)))
        }
        sqlite3_finalize(selectExpired)

        let stmt = try prepare("DELETE FROM lease WHERE (last_used_at + idle_timeout_s) <= ?1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, now)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastSQLiteError(prefix: "reapExpired")
        }
        for expiredID in expiredIDs {
            ScreenRecorderManager.shared.stopIfActive(forLease: expiredID, stoppedBy: .leaseEnded)
        }
    }

    private func nextCounterValueLocked() throws -> Int64 {
        let update = try prepare("UPDATE lease_counter SET value = value + 1 WHERE id = 1;")
        defer { sqlite3_finalize(update) }
        guard sqlite3_step(update) == SQLITE_DONE else {
            throw lastSQLiteError(prefix: "increment lease_counter")
        }
        return try readCounterValueLocked()
    }

    private func readCounterValueLocked() throws -> Int64 {
        let query = try prepare("SELECT value FROM lease_counter WHERE id = 1;")
        defer { sqlite3_finalize(query) }
        guard sqlite3_step(query) == SQLITE_ROW else {
            throw lastSQLiteError(prefix: "read lease_counter")
        }
        return sqlite3_column_int64(query, 0)
    }

    private func insertLeaseLocked(_ record: LeaseRecord) throws {
        let stmt = try prepare(
            """
            INSERT INTO lease (
                id, screen_capture_id, device_name, label, reason,
                acquired_at, idle_timeout_s, last_used_at, last_command
            ) VALUES (?1, ?2, ?3, ?4, ?5, ?6, ?7, ?8, ?9);
            """
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, record.id.rawValue)
        bindText(stmt, index: 2, value: record.screenCaptureID)
        bindText(stmt, index: 3, value: record.deviceName)
        bindOptionalText(stmt, index: 4, value: record.label)
        bindText(stmt, index: 5, value: record.reason)
        sqlite3_bind_double(stmt, 6, record.acquiredAt)
        sqlite3_bind_double(stmt, 7, record.idleTimeoutSeconds)
        sqlite3_bind_double(stmt, 8, record.lastUsedAt)
        bindOptionalText(stmt, index: 9, value: record.lastCommand)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastSQLiteError(prefix: "insert lease")
        }
    }

    private func updateLeaseActivityLocked(
        id: Int64,
        lastUsedAt: TimeInterval,
        lastCommand: String?
    ) throws {
        let stmt = try prepare(
            "UPDATE lease SET last_used_at = ?1, last_command = ?2 WHERE id = ?3;"
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, lastUsedAt)
        bindOptionalText(stmt, index: 2, value: lastCommand)
        sqlite3_bind_int64(stmt, 3, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastSQLiteError(prefix: "update lease activity")
        }
    }

    private func deleteLeaseLocked(forDeviceID deviceID: String) throws {
        let stmt = try prepare("DELETE FROM lease WHERE screen_capture_id = ?1;")
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: deviceID)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastSQLiteError(prefix: "delete lease by device")
        }
    }

    private func deleteLeaseLocked(byID id: Int64) throws {
        let stmt = try prepare("DELETE FROM lease WHERE id = ?1;")
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw lastSQLiteError(prefix: "delete lease by id")
        }
    }

    private func selectLeaseLocked(forDeviceID deviceID: String) throws -> LeaseRecord? {
        let stmt = try prepare(
            """
            SELECT id, screen_capture_id, device_name, label, reason,
                   acquired_at, idle_timeout_s, last_used_at, last_command
            FROM lease
            WHERE screen_capture_id = ?1
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: deviceID)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readLeaseRow(stmt)
    }

    private func selectLeaseLocked(byID id: Int64) throws -> LeaseRecord? {
        let stmt = try prepare(
            """
            SELECT id, screen_capture_id, device_name, label, reason,
                   acquired_at, idle_timeout_s, last_used_at, last_command
            FROM lease
            WHERE id = ?1
            LIMIT 1;
            """
        )
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readLeaseRow(stmt)
    }

    private func selectAllLeasesLocked() throws -> [LeaseRecord] {
        let stmt = try prepare(
            """
            SELECT id, screen_capture_id, device_name, label, reason,
                   acquired_at, idle_timeout_s, last_used_at, last_command
            FROM lease
            ORDER BY id ASC;
            """
        )
        defer { sqlite3_finalize(stmt) }
        var rows: [LeaseRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            rows.append(readLeaseRow(stmt))
        }
        return rows
    }

    private func readLeaseRow(_ stmt: OpaquePointer) -> LeaseRecord {
        let id = sqlite3_column_int64(stmt, 0)
        let screenCaptureID = columnText(stmt, index: 1) ?? ""
        let deviceName = columnText(stmt, index: 2) ?? ""
        let label = columnText(stmt, index: 3)
        let reason = columnText(stmt, index: 4) ?? ""
        let acquiredAt = sqlite3_column_double(stmt, 5)
        let idleTimeout = sqlite3_column_double(stmt, 6)
        let lastUsedAt = sqlite3_column_double(stmt, 7)
        let lastCommand = columnText(stmt, index: 8)
        return LeaseRecord(
            id: LeaseID(unchecked: id),
            screenCaptureID: screenCaptureID,
            deviceName: deviceName,
            label: label,
            reason: reason,
            acquiredAt: acquiredAt,
            idleTimeoutSeconds: idleTimeout,
            lastUsedAt: lastUsedAt,
            lastCommand: lastCommand
        )
    }

    private func registerWaiter(
        deviceID: String,
        label: String?,
        reason: String,
        since: TimeInterval
    ) throws -> Int64 {
        try withStoreLock {
            try inImmediateTransaction {
                let stmt = try prepare(
                    """
                    INSERT INTO lease_waiter (screen_capture_id, label, reason, since)
                    VALUES (?1, ?2, ?3, ?4);
                    """
                )
                defer { sqlite3_finalize(stmt) }
                bindText(stmt, index: 1, value: deviceID)
                bindOptionalText(stmt, index: 2, value: label)
                bindText(stmt, index: 3, value: reason)
                sqlite3_bind_double(stmt, 4, since)
                guard sqlite3_step(stmt) == SQLITE_DONE else {
                    throw lastSQLiteError(prefix: "insert lease_waiter")
                }
                return sqlite3_last_insert_rowid(db)
            }
        }
    }

    private func unregisterWaiter(id: Int64) {
        _ = try? withStoreLock {
            _ = try? inImmediateTransaction {
                let stmt = try prepare("DELETE FROM lease_waiter WHERE id = ?1;")
                defer { sqlite3_finalize(stmt) }
                sqlite3_bind_int64(stmt, 1, id)
                _ = sqlite3_step(stmt)
            }
        }
    }

    private func selectWaitersLocked(forDeviceID deviceID: String) throws -> [LeaseWaiterRecord] {
        let stmt = try prepare(
            """
            SELECT id, screen_capture_id, label, reason, since
            FROM lease_waiter
            WHERE screen_capture_id = ?1
            ORDER BY since ASC, id ASC;
            """
        )
        defer { sqlite3_finalize(stmt) }
        bindText(stmt, index: 1, value: deviceID)
        var waiters: [LeaseWaiterRecord] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            waiters.append(
                LeaseWaiterRecord(
                    id: sqlite3_column_int64(stmt, 0),
                    screenCaptureID: columnText(stmt, index: 1) ?? "",
                    label: columnText(stmt, index: 2),
                    reason: columnText(stmt, index: 3) ?? "",
                    since: sqlite3_column_double(stmt, 4)
                )
            )
        }
        return waiters
    }

    private func execSQL(_ sql: String) throws {
        guard let db else { throw LeaseError.storageFailure("database closed") }
        var errMsg: UnsafeMutablePointer<CChar>?
        let rc = sqlite3_exec(db, sql, nil, nil, &errMsg)
        if rc != SQLITE_OK {
            let message = errMsg.map { String(cString: $0) } ?? "SQLite error \(rc)"
            sqlite3_free(errMsg)
            throw LeaseError.storageFailure(message)
        }
    }

    private func prepare(_ sql: String) throws -> OpaquePointer {
        guard let db else { throw LeaseError.storageFailure("database closed") }
        var stmt: OpaquePointer?
        let rc = sqlite3_prepare_v2(db, sql, -1, &stmt, nil)
        guard rc == SQLITE_OK, let stmt else {
            throw lastSQLiteError(prefix: "prepare")
        }
        return stmt
    }

    private func bindText(_ stmt: OpaquePointer, index: Int32, value: String) {
        _ = value.withCString { cStr in
            sqlite3_bind_text(stmt, index, cStr, -1, sqliteTransient)
        }
    }

    private func bindOptionalText(_ stmt: OpaquePointer, index: Int32, value: String?) {
        if let value {
            bindText(stmt, index: index, value: value)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func columnText(_ stmt: OpaquePointer, index: Int32) -> String? {
        guard sqlite3_column_type(stmt, index) != SQLITE_NULL,
            let ptr = sqlite3_column_text(stmt, index)
        else {
            return nil
        }
        return String(cString: ptr)
    }

    private func lastSQLiteError(prefix: String) -> LeaseError {
        let msg = db.flatMap { sqlite3_errmsg($0) }.map { String(cString: $0) } ?? "unknown error"
        return .storageFailure("\(prefix): \(msg)")
    }
}
