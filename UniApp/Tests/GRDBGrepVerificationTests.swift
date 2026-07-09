import Foundation
import Testing

@Suite struct GRDBGrepVerificationTests {
    @Test("production sources do not reference deleted database framework symbols")
    func productionSourcesAreFreeOfDeletedStoreSymbols() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let sourcesDirectory = testsDirectory
            .deletingLastPathComponent()
            .appendingPathComponent("Sources", isDirectory: true)
        let forbidden = [
            "import SwiftData",
            "@Query",
            "@ModelActor",
            "@Model",
            "ModelContext",
            "ModelContainer",
            "FetchDescriptor",
            "#Predicate",
            "@AppStorage",
            "AppStorage(",
            "PersistentIdentifier",
            "PersistentModel",
            ".modelContainer",
            "modelContainer",
            "modelContext",
            "ApertureDatabase"
        ]
        let files = try swiftFiles(in: sourcesDirectory)
        var violations: [String] = []
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbidden where text.contains(token) {
                violations.append("\(file.path): \(token)")
            }
        }
        if !violations.isEmpty {
            Issue.record("Deleted database symbols found:\n\(violations.joined(separator: "\n"))")
        }
        #expect(violations.isEmpty)
    }

    @Test("production sources and resources use system fonts only")
    func productionUsesSystemFontsOnly() throws {
        let testsDirectory = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
        let appDirectory = testsDirectory.deletingLastPathComponent()
        let sourcesDirectory = appDirectory.appendingPathComponent("Sources", isDirectory: true)
        let forbiddenSourceTokens = [
            "Font.custom",
            ".font(.custom",
            "UIFont(name:",
            "UIFont.init(name:",
            "CTFontCreateWithName",
            "CTFontManagerRegister"
        ]

        var violations: [String] = []
        for file in try swiftFiles(in: sourcesDirectory) {
            let text = try String(contentsOf: file, encoding: .utf8)
            for token in forbiddenSourceTokens where text.contains(token) {
                violations.append("\(file.path): \(token)")
            }
        }

        let forbiddenFontExtensions: Set<String> = ["ttf", "otf", "ttc"]
        for file in try regularFiles(in: appDirectory)
            where forbiddenFontExtensions.contains(file.pathExtension.lowercased()) {
            violations.append("\(file.path): bundled font file")
        }

        if !violations.isEmpty {
            Issue.record("Custom font usage found:\n\(violations.joined(separator: "\n"))")
        }
        #expect(violations.isEmpty)
    }

    private func swiftFiles(in directory: URL) throws -> [URL] {
        try regularFiles(in: directory).filter { $0.pathExtension == "swift" }
    }

    private func regularFiles(in directory: URL) throws -> [URL] {
        let keys: [URLResourceKey] = [.isRegularFileKey]
        guard let enumerator = FileManager.default.enumerator(
            at: directory,
            includingPropertiesForKeys: keys,
            options: [.skipsHiddenFiles]
        ) else { return [] }
        return try enumerator.compactMap { item in
            guard let url = item as? URL else { return nil }
            let values = try url.resourceValues(forKeys: Set(keys))
            return values.isRegularFile == true ? url : nil
        }
    }
}
