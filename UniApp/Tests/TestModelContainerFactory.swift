import Foundation
import SwiftData
@testable import Aperture

/// Shared SwiftData test-container factory.
///
/// The app schema is large enough that iOS 26.5's in-memory SwiftData store can
/// fail to load it with `loadIssueModelContainer` while the same schema opens
/// cleanly as SQLite. Use a unique temporary on-disk store per test fixture so
/// repository tests exercise the production store shape without sharing state.
enum TestModelContainerFactory {
    static func makeContainer(name: String = #function) throws -> ModelContainer {
        let safeName = name.replacingOccurrences(of: "()", with: "")
            .replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(safeName)-\(UUID().uuidString).sqlite", isDirectory: false)
        let schema = Schema(ApertureSchemaV1.models)
        let config = ModelConfiguration(
            schema: schema,
            url: url,
            allowsSave: true,
            cloudKitDatabase: .none
        )
        return try ModelContainer(for: schema, configurations: [config])
    }
}
