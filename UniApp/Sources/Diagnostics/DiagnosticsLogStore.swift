import Foundation

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
        makeLogFileURL()
    }

    private static let maxLogFileBytes = 2_000_000
    private static let newlineData = Data([0x0A])

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder
    private let logFileURL: URL

    private init() {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder

        self.logFileURL = Self.makeLogFileURL()
        Self.prepareLogDirectory(for: logFileURL)
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

    func load(limit: Int = 1_500) -> [DiagnosticsLogEntry] {
        guard let data = try? Data(contentsOf: logFileURL),
              let text = String(data: data, encoding: .utf8) else {
            return []
        }

        let lines = text.split(separator: "\n", omittingEmptySubsequences: true)
        return lines.suffix(limit).compactMap { line in
            guard let lineData = String(line).data(using: .utf8) else { return nil }
            return try? decoder.decode(DiagnosticsLogEntry.self, from: lineData)
        }
    }

    func copyableText(limit: Int = 1_500) -> String {
        Self.format(entries: load(limit: limit))
    }

    func exportFile() throws -> URL {
        let sourceData = (try? Data(contentsOf: logFileURL)) ?? Data()
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
        Self.prepareLogDirectory(for: logFileURL)
        try Data().write(to: logFileURL, options: .atomic)
    }

    private func append(_ entry: DiagnosticsLogEntry) {
        Self.prepareLogDirectory(for: logFileURL)
        rotateIfNeeded()

        guard let data = try? encoder.encode(entry) else { return }
        if !FileManager.default.fileExists(atPath: logFileURL.path) {
            FileManager.default.createFile(atPath: logFileURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: logFileURL) else { return }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            handle.write(data)
            handle.write(Self.newlineData)
        } catch {
            try? handle.close()
        }
    }

    private func rotateIfNeeded() {
        guard let values = try? logFileURL.resourceValues(forKeys: [.fileSizeKey]),
              let size = values.fileSize,
              size > Self.maxLogFileBytes else {
            return
        }

        let marker = DiagnosticsLogEntry(
            level: .info,
            category: "diagnostics",
            message: "Diagnostics log rotated",
            metadata: ["previousBytes": "\(size)"]
        )
        if let markerData = try? encoder.encode(marker) {
            var data = markerData
            data.append(Self.newlineData)
            try? data.write(to: logFileURL, options: .atomic)
        } else {
            try? Data().write(to: logFileURL, options: .atomic)
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

    private static func makeLogFileURL() -> URL {
        let fm = FileManager.default
        let base = (try? fm.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )) ?? fm.urls(for: .documentDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSTemporaryDirectory())
        return base
            .appendingPathComponent("Aperture", isDirectory: true)
            .appendingPathComponent("Diagnostics", isDirectory: true)
            .appendingPathComponent("aperture-diagnostics.jsonl", isDirectory: false)
    }

    private static func prepareLogDirectory(for fileURL: URL) {
        let directory = fileURL.deletingLastPathComponent()
        if !FileManager.default.fileExists(atPath: directory.path) {
            try? FileManager.default.createDirectory(
                at: directory,
                withIntermediateDirectories: true
            )
        }

        var excludedDirectory = directory
        var values = URLResourceValues()
        values.isExcludedFromBackup = true
        try? excludedDirectory.setResourceValues(values)
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
