import Foundation
import GRDB

enum DiagnosticsLogLevel: String, Codable, CaseIterable, Sendable {
    case debug
    case info
    case warning
    case error
}

struct DiagnosticsLogEntry: Identifiable, Codable, Hashable, Sendable {
    let id: UUID
    let timestamp: Date
    let level: DiagnosticsLogLevel
    let category: String
    let message: String
    let metadata: [String: String]

    init(
        id: UUID = UUID(),
        timestamp: Date = Date(),
        level: DiagnosticsLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        self.id = id
        self.timestamp = timestamp
        self.level = level
        self.category = category
        self.message = message
        self.metadata = DiagnosticsLogStore.sanitizedMetadata(metadata)
    }
}

actor DiagnosticsLogStore {
    static let shared = DiagnosticsLogStore()

    nonisolated static var sharedLogFileURL: URL {
        FileManager.default.temporaryDirectory.appendingPathComponent("aperture-diagnostics-grdb.jsonl")
    }

    private static let newlineData = Data([0x0A])
    private static let maxStoredEntries = 5_000

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private var database: AppDatabase?
    private var pendingEntries: [DiagnosticsLogEntry] = []
    private var dropsEntriesUntilAttached = false
    private var dropEntriesCreatedBefore: Date?

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

    }

    nonisolated func configure(database: AppDatabase) {
        Task.detached(priority: .utility) {
            await DiagnosticsLogStore.shared.attach(database: database)
        }
    }

    nonisolated func record(
        _ level: DiagnosticsLogLevel,
        category: String,
        message: String,
        metadata: [String: String] = [:]
    ) {
        let entry = DiagnosticsLogEntry(
            level: level,
            category: category,
            message: message,
            metadata: metadata
        )
        Task.detached(priority: .utility) {
            await DiagnosticsLogStore.shared.append(entry)
        }
    }

    func detachForTesting() {
        database = nil
        pendingEntries.removeAll()
        dropsEntriesUntilAttached = true
    }

    func load(limit: Int = 1_500) -> [DiagnosticsLogEntry] {
        guard let database else {
            return Array(pendingEntries.suffix(limit))
        }
        let rows = (try? database.read { db in
            try Row.fetchAll(
                db,
                sql: """
                SELECT id, timestamp_ms, level_raw, category, message, metadata_json
                FROM diagnostic_log_entries
                ORDER BY timestamp_ms DESC
                LIMIT ?
                """,
                arguments: [limit]
            )
        }) ?? []
        return rows.reversed().compactMap(decodeEntry(row:))
    }

    func copyableText(limit: Int = 1_500) -> String {
        Self.format(entries: load(limit: limit))
    }

    func exportFile() throws -> URL {
        let entries = load(limit: Self.maxStoredEntries)
        var sourceData = Data()
        for entry in entries {
            if let data = try? encoder.encode(entry) {
                sourceData.append(data)
                sourceData.append(Self.newlineData)
            }
        }
        let stamp = Self.exportStampFormatter.string(from: Date())
        let exportURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("aperture-diagnostics-\(stamp).jsonl", isDirectory: false)
        if FileManager.default.fileExists(atPath: exportURL.path) {
            try FileManager.default.removeItem(at: exportURL)
        }
        try sourceData.write(to: exportURL, options: .atomic)
        return exportURL
    }

    func clear() throws {
        dropEntriesCreatedBefore = Date()
        pendingEntries.removeAll()
        try database?.write { db in
            try db.execute(sql: "DELETE FROM diagnostic_log_entries")
        }
    }

    func clear(database targetDatabase: AppDatabase) throws {
        dropEntriesCreatedBefore = Date()
        pendingEntries.removeAll()
        database = targetDatabase
        dropsEntriesUntilAttached = false
        try targetDatabase.write { db in
            try db.execute(sql: "DELETE FROM diagnostic_log_entries")
        }
    }

    /// After factory reset already deleted `diagnostic_log_entries` in its
    /// main transaction — only clear in-memory state (no nested GRDB write).
    func markClearedAfterWipe() {
        dropEntriesCreatedBefore = Date()
        pendingEntries.removeAll()
    }

    private func append(_ entry: DiagnosticsLogEntry) {
        if let dropEntriesCreatedBefore, entry.timestamp <= dropEntriesCreatedBefore {
            return
        }
        guard let database else {
            guard !dropsEntriesUntilAttached else { return }
            pendingEntries.append(entry)
            if pendingEntries.count > Self.maxStoredEntries {
                pendingEntries.removeFirst(pendingEntries.count - Self.maxStoredEntries)
            }
            return
        }
        try? database.write { db in
            try insert(entry, db: db)
            try db.execute(
                sql: """
                DELETE FROM diagnostic_log_entries
                WHERE id IN (
                    SELECT id FROM diagnostic_log_entries
                    ORDER BY timestamp_ms DESC
                    LIMIT -1 OFFSET ?
                )
                """,
                arguments: [Self.maxStoredEntries]
            )
        }
    }

    static func format(entries: [DiagnosticsLogEntry]) -> String {
        entries.map { entry in
            var parts = [
                isoFormatter.string(from: entry.timestamp),
                "[\(entry.level.rawValue.uppercased())]",
                entry.category,
                entry.message
            ]
            let metadata = entry.metadata
                .sorted { $0.key < $1.key }
                .map { "\($0.key)=\($0.value)" }
                .joined(separator: " ")
            if !metadata.isEmpty {
                parts.append(metadata)
            }
            return parts.joined(separator: " ")
        }
        .joined(separator: "\n")
    }

    static func sanitizedMetadata(_ metadata: [String: String]) -> [String: String] {
        metadata.reduce(into: [:]) { result, pair in
            let cleaned = pair.value
                .replacingOccurrences(of: "\n", with: " ")
                .replacingOccurrences(of: "\r", with: " ")
            if cleaned.count > 320 {
                result[pair.key] = String(cleaned.prefix(320)) + "..."
            } else {
                result[pair.key] = cleaned
            }
        }
    }

    static func elapsedMilliseconds(since start: Date) -> String {
        let milliseconds = max(0, Date().timeIntervalSince(start) * 1_000)
        return String(format: "%.1f", milliseconds)
    }

    static func elapsedMilliseconds(from start: Date, to end: Date) -> String {
        let milliseconds = max(0, end.timeIntervalSince(start) * 1_000)
        return String(format: "%.1f", milliseconds)
    }

    private func attach(database: AppDatabase) {
        self.database = database
        dropsEntriesUntilAttached = false
        guard !pendingEntries.isEmpty else { return }
        let pending: [DiagnosticsLogEntry]
        if let dropEntriesCreatedBefore {
            pending = pendingEntries.filter { $0.timestamp > dropEntriesCreatedBefore }
        } else {
            pending = pendingEntries
        }
        pendingEntries.removeAll()
        guard !pending.isEmpty else { return }
        try? database.write { db in
            for entry in pending {
                try insert(entry, db: db)
            }
        }
    }

    private func insert(_ entry: DiagnosticsLogEntry, db: Database) throws {
        let metadataData = (try? JSONEncoder().encode(entry.metadata)) ?? Data()
        let metadataJSON = String(data: metadataData, encoding: .utf8) ?? "{}"
        try db.execute(
            sql: """
            INSERT INTO diagnostic_log_entries
            (id, timestamp_ms, level_raw, category, message, metadata_json)
            VALUES (?, ?, ?, ?, ?, ?)
            ON CONFLICT(id) DO NOTHING
            """,
            arguments: [
                entry.id.uuidString,
                entry.timestamp.databaseMilliseconds,
                entry.level.rawValue,
                entry.category,
                entry.message,
                metadataJSON
            ]
        )
    }

    private func decodeEntry(row: Row) -> DiagnosticsLogEntry? {
        guard let idRaw = row["id"] as String?,
              let id = UUID(uuidString: idRaw),
              let timestampMs = row["timestamp_ms"] as Int64?,
              let levelRaw = row["level_raw"] as String?,
              let level = DiagnosticsLogLevel(rawValue: levelRaw),
              let category = row["category"] as String?,
              let message = row["message"] as String? else {
            return nil
        }
        let metadataJSON = row["metadata_json"] as String? ?? "{}"
        let metadataData = Data(metadataJSON.utf8)
        let metadata = (try? decoder.decode([String: String].self, from: metadataData)) ?? [:]
        return DiagnosticsLogEntry(
            id: id,
            timestamp: Date(databaseMilliseconds: timestampMs),
            level: level,
            category: category,
            message: message,
            metadata: metadata
        )
    }

    private nonisolated(unsafe) static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()

    private static let exportStampFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter
    }()
}

struct DiagnosticsAPITrace: Sendable {
    let id: UUID
    let family: String
    let operation: String
    let startedAt: Date
    let metadata: [String: String]
}

actor DiagnosticsAPIMonitor {
    static let shared = DiagnosticsAPIMonitor()

    private var totalActive = 0
    private var activeByFamily: [String: Int] = [:]

    func begin(
        family: String,
        operation: String,
        metadata: [String: String] = [:]
    ) -> DiagnosticsAPITrace {
        let trace = DiagnosticsAPITrace(
            id: UUID(),
            family: family,
            operation: operation,
            startedAt: Date(),
            metadata: DiagnosticsLogStore.sanitizedMetadata(metadata)
        )

        totalActive += 1
        activeByFamily[family, default: 0] += 1

        var logMetadata = trace.metadata
        logMetadata["traceId"] = trace.id.uuidString
        logMetadata["family"] = family
        logMetadata["operation"] = operation
        logMetadata["activeTotal"] = "\(totalActive)"
        logMetadata["activeFamily"] = "\(activeByFamily[family, default: 0])"
        DiagnosticsLogStore.shared.record(
            .debug,
            category: "api-latency",
            message: "API request started",
            metadata: logMetadata
        )
        return trace
    }

    func finish(
        _ trace: DiagnosticsAPITrace,
        outcome: String,
        statusCode: Int? = nil,
        responseBytes: Int? = nil,
        error: (any Error)? = nil
    ) {
        totalActive = max(0, totalActive - 1)
        let activeFamily = max(0, activeByFamily[trace.family, default: 0] - 1)
        if activeFamily == 0 {
            activeByFamily[trace.family] = nil
        } else {
            activeByFamily[trace.family] = activeFamily
        }

        var metadata = trace.metadata
        metadata["traceId"] = trace.id.uuidString
        metadata["family"] = trace.family
        metadata["operation"] = trace.operation
        metadata["outcome"] = outcome
        metadata["elapsedMs"] = DiagnosticsLogStore.elapsedMilliseconds(since: trace.startedAt)
        metadata["activeTotalRemaining"] = "\(totalActive)"
        metadata["activeFamilyRemaining"] = "\(activeFamily)"
        if let statusCode {
            metadata["statusCode"] = "\(statusCode)"
        }
        if let responseBytes {
            metadata["responseBytes"] = "\(responseBytes)"
        }
        if let error {
            metadata["error"] = String(describing: error)
        }

        let level: DiagnosticsLogLevel
        switch outcome {
        case "succeeded":
            level = .info
        case "cancelled":
            level = .debug
        default:
            level = .warning
        }
        DiagnosticsLogStore.shared.record(
            level,
            category: "api-latency",
            message: "API request \(outcome)",
            metadata: metadata
        )
    }
}

extension URLSession {
    func apertureData(
        for request: URLRequest,
        family: String,
        operation: String,
        metadata: [String: String] = [:]
    ) async throws -> (Data, URLResponse) {
        var traceMetadata = metadata
        if let url = request.url {
            traceMetadata["host"] = traceMetadata["host"] ?? (url.host ?? "")
            traceMetadata["path"] = traceMetadata["path"] ?? url.path
            traceMetadata["scheme"] = traceMetadata["scheme"] ?? (url.scheme ?? "")
        }
        traceMetadata["httpMethod"] = traceMetadata["httpMethod"] ?? (request.httpMethod ?? "GET")

        let trace = await DiagnosticsAPIMonitor.shared.begin(
            family: family,
            operation: operation,
            metadata: traceMetadata
        )
        do {
            let result = try await data(for: request)
            let statusCode = (result.1 as? HTTPURLResponse)?.statusCode
            await DiagnosticsAPIMonitor.shared.finish(
                trace,
                outcome: "succeeded",
                statusCode: statusCode,
                responseBytes: result.0.count
            )
            return result
        } catch is CancellationError {
            await DiagnosticsAPIMonitor.shared.finish(
                trace,
                outcome: "cancelled",
                error: CancellationError()
            )
            throw CancellationError()
        } catch {
            let outcome: String
            if let urlError = error as? URLError, urlError.code == .cancelled {
                outcome = "cancelled"
            } else {
                outcome = "failed"
            }
            await DiagnosticsAPIMonitor.shared.finish(
                trace,
                outcome: outcome,
                error: error
            )
            throw error
        }
    }
}
