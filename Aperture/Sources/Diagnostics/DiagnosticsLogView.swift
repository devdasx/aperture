import SwiftUI
import UIKit

struct DiagnosticsLogView: View {
    @State private var entries: [DiagnosticsLogEntry] = []
    @State private var exportURL: URL?
    @State private var copied = false

    var body: some View {
        List {
            if entries.isEmpty {
                ContentUnavailableView {
                    Label("No logs yet", systemImage: "doc.text.magnifyingglass")
                } description: {
                    Text("Open the app, run a scan, or retry the failing flow.")
                }
                .listRowBackground(Color.clear)
            } else {
                Section {
                    ForEach(entries) { entry in
                        DiagnosticsLogRow(entry: entry)
                    }
                } header: {
                    Text("\(entries.count) recent entries")
                }
            }
        }
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
        .background(UniColors.Background.primary)
        .navigationTitle(Text("Diagnostics Logs"))
        .navigationBarTitleDisplayMode(.large)
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Button {
                    Task { await reload() }
                } label: {
                    Image(systemName: "arrow.clockwise")
                }
                .accessibilityLabel(Text("Refresh logs"))

                Button {
                    copyLogs()
                } label: {
                    Image(systemName: copied ? "checkmark" : "doc.on.doc")
                }
                .accessibilityLabel(Text("Copy logs"))

                if let exportURL {
                    ShareLink(item: exportURL) {
                        Image(systemName: "square.and.arrow.up")
                    }
                    .accessibilityLabel(Text("Export logs"))
                }
            }
        }
        .task {
            await reload()
        }
    }

    private func reload() async {
        let loaded = await DiagnosticsLogStore.shared.load()
        let preparedURL = try? await DiagnosticsLogStore.shared.exportFile()
        await MainActor.run {
            entries = loaded
            exportURL = preparedURL
        }
    }

    private func copyLogs() {
        Task {
            let text = await DiagnosticsLogStore.shared.copyableText()
            await MainActor.run {
                UIPasteboard.general.string = text
                copied = true
            }
            try? await Task.sleep(for: .seconds(1.2))
            await MainActor.run {
                copied = false
            }
        }
    }
}

private struct DiagnosticsLogRow: View {
    let entry: DiagnosticsLogEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(entry.level.rawValue.uppercased())
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(levelColor)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(levelColor.opacity(0.12), in: Capsule())

                Text(entry.category)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(UniColors.Text.secondary)

                Spacer(minLength: 8)

                Text(Self.timeFormatter.string(from: entry.timestamp))
                    .font(.caption2)
                    .foregroundStyle(UniColors.Text.tertiary)
            }

            Text(entry.message)
                .font(UniTypography.body)
                .foregroundStyle(UniColors.Text.primary)

            if !entry.metadata.isEmpty {
                Text(metadataText)
                    .font(.caption)
                    .foregroundStyle(UniColors.Text.secondary)
                    .textSelection(.enabled)
            }
        }
        .padding(.vertical, 6)
    }

    private var levelColor: Color {
        switch entry.level {
        case .debug: return .gray
        case .info: return .blue
        case .warning: return .orange
        case .error: return .red
        }
    }

    private var metadataText: String {
        entry.metadata
            .sorted { $0.key < $1.key }
            .map { "\($0.key): \($0.value)" }
            .joined(separator: "\n")
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .medium
        return formatter
    }()
}
