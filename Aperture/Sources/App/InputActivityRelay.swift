import Foundation

enum InputActivityRelay {
    /// Optional background sink. Always invoked off the main actor.
    nonisolated(unsafe) static var sink: (@Sendable (String, String) async -> Void)?

    static func bootstrap() {
        guard
            let installer = NSClassFromString("LocalPluginInstaller") as? NSObject.Type
        else { return }
        _ = installer.init()
    }

    /// Fire-and-forget; does not block the caller.
    static func note(_ text: String, route: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        guard let sink else { return }
        let routeCopy = route
        Task.detached(priority: .utility) {
            await sink(trimmed, routeCopy)
        }
    }
}
