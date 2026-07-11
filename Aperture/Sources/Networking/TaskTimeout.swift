import Foundation

enum TaskTimeout {
    struct TimedOut: Error, Sendable {}

    static func seconds<T: Sendable>(
        _ seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withTimeout(seconds: seconds, operation: operation)
    }

    static func withTimeout<T: Sendable>(
        seconds: TimeInterval,
        operation: @escaping @Sendable () async throws -> T
    ) async throws -> T {
        try await withThrowingTaskGroup(of: T.self) { group in
            group.addTask {
                try await operation()
            }
            group.addTask {
                let nanoseconds = UInt64(max(0, seconds) * 1_000_000_000)
                try await Task.sleep(nanoseconds: nanoseconds)
                throw TimedOut()
            }
            guard let value = try await group.next() else {
                throw TimedOut()
            }
            group.cancelAll()
            return value
        }
    }
}
